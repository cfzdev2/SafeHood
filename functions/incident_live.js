"use strict";

const {randomBytes} = require("node:crypto");
const {decodeJpegBase64, normalizeDocumentId} =
  require("./camera_event_snapshot");

const leaseMillis = 12000;
const minimumFrameInterval = 500;
const maximumFrameBytes = 96 * 1024;
const validSessionId = /^[a-f0-9]{32}$/;

/**
 * Validate the dimensions of the first frame header without decoding pixels.
 * @param {Buffer} bytes The bounded JPEG.
 * @return {boolean} Whether a small baseline or progressive frame is present.
 */
function smallJpeg(bytes) {
  for (let offset = 2; offset + 3 < bytes.length;) {
    if (bytes[offset++] !== 0xff) return false;
    while (bytes[offset] === 0xff) offset++;
    const marker = bytes[offset++];
    if (marker === 0xda || marker === 0xd9 || offset + 2 > bytes.length) {
      return false;
    }
    const length = bytes.readUInt16BE(offset);
    if (length < 2 || offset + length > bytes.length) return false;
    if ([0xc0, 0xc1, 0xc2].includes(marker)) {
      if (length < 8) return false;
      const height = bytes.readUInt16BE(offset + 3);
      const width = bytes.readUInt16BE(offset + 5);
      return width > 0 && width <= 320 && height > 0 && height <= 320;
    }
    offset += length;
  }
  return false;
}

/**
 * One transient, silent preview per incident. Only its reporter can publish.
 * @param {Object} dependencies Firestore, timestamp and error factories.
 * @return {Function} Callable handler.
 */
function createIncidentLiveHandler({
  db, Timestamp, HttpsError, now = Date.now,
}) {
  return async (request) => {
    const auth = request.auth;
    if (!auth) throw new HttpsError("unauthenticated", "Zaloguj się.");
    if (auth.token.email_verified !== true) {
      throw new HttpsError("permission-denied", "Zweryfikuj adres e-mail.");
    }

    const data = request.data || {};
    let incidentId;
    try {
      incidentId = normalizeDocumentId(data.incidentId, "incidentId");
    } catch (_) {
      throw new HttpsError("invalid-argument", "Nieprawidłowe zgłoszenie.");
    }
    const action = data.action;
    if (!["start", "frame", "stop"].includes(action)) {
      throw new HttpsError("invalid-argument", "Nieprawidłowa operacja LIVE.");
    }
    const sessionId = action === "start" ?
      randomBytes(16).toString("hex") : data.sessionId;
    if (typeof sessionId !== "string" || !validSessionId.test(sessionId)) {
      throw new HttpsError("invalid-argument", "Nieprawidłowa sesja LIVE.");
    }
    let jpeg;
    if (action === "frame") {
      try {
        jpeg = decodeJpegBase64(data.jpeg, {maximumBytes: maximumFrameBytes});
        if (!smallJpeg(jpeg)) throw new Error("Nieprawidłowe wymiary JPEG.");
      } catch (_) {
        throw new HttpsError("invalid-argument", "Nieprawidłowa klatka LIVE.");
      }
    }

    const incidentRef = db.collection("incidents").doc(incidentId);
    const previewRef = incidentRef.collection("live").doc("current");
    return db.runTransaction(async (transaction) => {
      const incident = (await transaction.get(incidentRef)).data();
      if (!incident || incident.reporterId !== auth.uid) {
        throw new HttpsError(
            "permission-denied", "Brak dostępu do transmisji.",
        );
      }
      const preview = (await transaction.get(previewRef)).data();
      if (action === "stop") {
        if (preview && preview.sessionId === sessionId) {
          transaction.delete(previewRef);
        }
        return {ok: true};
      }

      const timestamp = now();
      const end = incident.expiresAt;
      if (incident.status !== "active" ||
          !Array.isArray(incident.participantIds) ||
          !incident.participantIds.includes(auth.uid) ||
          typeof incident.cameraId !== "string" || !incident.cameraId.trim() ||
          !end || typeof end.toMillis !== "function" ||
          end.toMillis() <= timestamp) {
        throw new HttpsError(
            "failed-precondition", "Zgłoszenie jest nieaktywne.",
        );
      }
      const leaseUntil = Timestamp.fromMillis(
          Math.min(timestamp + leaseMillis, end.toMillis()),
      );
      if (action === "start") {
        transaction.set(previewRef, {sessionId, leaseUntil});
        return {sessionId};
      }
      if (!preview || preview.sessionId !== sessionId ||
          preview.leaseUntil.toMillis() <= timestamp) {
        throw new HttpsError("failed-precondition", "Transmisja zakończona.");
      }
      if (preview.lastFrameAt &&
          timestamp - preview.lastFrameAt.toMillis() < minimumFrameInterval) {
        return {ok: true, accepted: false};
      }
      transaction.set(previewRef, {
        sessionId, leaseUntil, jpeg,
        lastFrameAt: Timestamp.fromMillis(timestamp),
      });
      return {ok: true, accepted: true};
    });
  };
}

module.exports = {createIncidentLiveHandler};
