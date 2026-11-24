"use strict";

const {decodeJpegBase64, normalizeDocumentId} =
  require("./camera_event_snapshot");
const {smallJpeg} = require("./incident_live");

/**
 * Restricted receiver API. Clients never receive the camera URI or login.
 * @param {Object} dependencies Authenticated receiver and Firestore.
 * @return {Object} Session list and frame handlers.
 */
function createBridgeIncidentLiveApi({db, Timestamp, authenticate,
  now = Date.now}) {
  const valid = (grant, report, camera, identity, timestamp) =>
    grant?.ownerId === identity.ownerId &&
    grant.bridgeId === identity.bridgeId &&
    grant.expiresAt?.toMillis() > timestamp &&
    report?.reporterId === identity.ownerId &&
    report.cameraId === grant.cameraId && report.status === "active" &&
    report.expiresAt?.toMillis() > timestamp &&
    Array.isArray(report.participantIds) &&
    report.participantIds.includes(identity.ownerId) &&
    camera && !camera.deletionPending &&
    camera.bridgeId === identity.bridgeId &&
    camera.monitoringMode === "bridge";

  const list = async (request, response) => {
    if (request.method !== "POST") {
      response.status(405).json({error: "POST required."});
      return;
    }
    try {
      const identity = await authenticate(request);
      if (!identity) {
        response.status(401).json({error: "Brak dostępu."});
        return;
      }
      const snapshot = await db.collection("incidentLiveGrants")
          .where("bridgeId", "==", identity.bridgeId).limit(100).get();
      const sessions = [];
      for (const entry of snapshot.docs) {
        const grant = entry.data();
        if (grant.ownerId !== identity.ownerId) continue;
        const reportRef = db.collection("incidents").doc(grant.incidentId);
        const cameraRef = db.collection("users").doc(identity.ownerId)
            .collection("cameras").doc(grant.cameraId);
        const [report, camera, preview] = await db.getAll(
            reportRef, cameraRef, reportRef.collection("live").doc("current"),
        );
        if (!valid(grant, report.data(), camera.data(), identity, now()) ||
            preview.data()?.sessionId !== grant.sessionId ||
            preview.data()?.publisher !== "bridge") {
          await entry.ref.delete();
          continue;
        }
        if (sessions.length < 25) {
          sessions.push({
            incidentId: grant.incidentId, cameraId: grant.cameraId,
            sessionId: grant.sessionId,
            expiresAtMillis: grant.expiresAt.toMillis(),
          });
        }
      }
      response.status(200).json({sessions});
    } catch (_) {
      response.status(500).json({error: "Nie udało się pobrać transmisji."});
    }
  };

  const publish = async (request, response) => {
    if (request.method !== "POST") {
      response.status(405).json({error: "POST required."});
      return;
    }
    try {
      const identity = await authenticate(request);
      if (!identity) {
        response.status(401).json({error: "Brak dostępu."});
        return;
      }
      const data = request.body || {};
      const incidentId = normalizeDocumentId(data.incidentId, "incidentId");
      const sessionId = data.sessionId;
      if (!/^[a-f0-9]{32}$/.test(sessionId || "")) throw new TypeError();
      const jpeg = decodeJpegBase64(data.jpegBase64,
          {maximumBytes: 96 * 1024});
      if (!smallJpeg(jpeg) || !Number.isSafeInteger(data.capturedAtMillis) ||
          now() - data.capturedAtMillis > 8000 ||
          data.capturedAtMillis - now() > 5000) throw new TypeError();
      const reportRef = db.collection("incidents").doc(incidentId);
      const previewRef = reportRef.collection("live").doc("current");
      const grantRef = db.collection("incidentLiveGrants").doc(sessionId);
      const accepted = await db.runTransaction(async (transaction) => {
        const report = (await transaction.get(reportRef)).data();
        const preview = (await transaction.get(previewRef)).data();
        const grant = (await transaction.get(grantRef)).data();
        if (!grant || grant.incidentId !== incidentId ||
            preview?.sessionId !== sessionId ||
            preview.publisher !== "bridge") {
          return null;
        }
        const camera = (await transaction.get(db.collection("users")
            .doc(identity.ownerId).collection("cameras").doc(grant.cameraId)))
            .data();
        const timestamp = now();
        if (!valid(grant, report, camera, identity, timestamp)) return null;
        if (preview.lastFrameAt &&
            timestamp - preview.lastFrameAt.toMillis() < 1000) return false;
        transaction.set(previewRef, {sessionId, publisher: "bridge", jpeg,
          lastFrameAt: Timestamp.fromMillis(timestamp),
          leaseUntil: Timestamp.fromMillis(Math.min(timestamp + 12000,
              report.expiresAt.toMillis(), grant.expiresAt.toMillis())),
        });
        return true;
      });
      if (accepted === null) {
        response.status(403).json({error: "Transmisja zakończona."});
      } else {
        response.status(200).json({ok: true, accepted});
      }
    } catch (error) {
      const invalid = error instanceof TypeError ||
        ["invalid-id", "invalid-base64", "invalid-jpeg"].includes(error.code);
      response.status(invalid ? 400 : 500).json({
        error: invalid ? "Nieprawidłowa klatka transmisji." :
          "Nie udało się przesłać obrazu.",
      });
    }
  };
  return {list, publish};
}

module.exports = {createBridgeIncidentLiveApi};
