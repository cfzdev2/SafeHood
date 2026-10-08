"use strict";

const {createHash} = require("node:crypto");
const {normalizeDocumentId} = require("./camera_event_snapshot");

const maximumClipBytes = 6 * 1024 * 1024;
const uuidPattern = new RegExp(
    "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-" +
    "[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
);

const fail = (message, status = 400) => {
  throw Object.assign(new Error(message), {status});
};

/**
 * Czyta skończone, ograniczone rozmiarem kontenery ISO BMFF.
 * @param {Buffer} bytes Plik.
 * @param {number} start Początek.
 * @param {number} end Koniec.
 * @return {Array<Object>} Kontenery.
 */
function boxes(bytes, start, end) {
  const result = [];
  for (let position = start; position < end;) {
    if (position + 8 > end || result.length > 10000) {
      fail("Uszkodzona struktura MP4.");
    }
    let size = bytes.readUInt32BE(position);
    let header = 8;
    if (size === 1) {
      if (position + 16 > end) fail("Urwany kontener MP4.");
      size = Number(bytes.readBigUInt64BE(position + 8));
      header = 16;
    } else if (size === 0) {
      size = end - position;
    }
    if (!Number.isSafeInteger(size) || size < header ||
        position + size > end) fail("Nieprawidłowy rozmiar kontenera MP4.");
    result.push({type: bytes.toString("ascii", position + 4, position + 8),
      start: position + header, end: position + size});
    position += size;
  }
  return result;
}

/**
 * Sprawdza MP4 H.264 z jedną ścieżką wideo i odczytuje czas filmu.
 * @param {Buffer} bytes Plik.
 * @return {Object} Wymiary i czas trwania.
 */
function inspectMp4(bytes) {
  if (!Buffer.isBuffer(bytes) || bytes.length < 100 ||
      bytes.length > maximumClipBytes) fail("Nieprawidłowy rozmiar nagrania.");
  const top = boxes(bytes, 0, bytes.length);
  const movie = top.filter((box) => box.type === "moov");
  const brand = top[0];
  if (!brand || brand.type !== "ftyp" || brand.end - brand.start < 8 ||
      !["isom", "iso2", "avc1", "mp41", "mp42"].includes(
          bytes.toString("ascii", brand.start, brand.start + 4),
      ) || movie.length !== 1 ||
      !top.some((box) => box.type === "mdat" && box.end > box.start)) {
    fail("Wymagane jest kompletne nagranie MP4.");
  }
  const children = boxes(bytes, movie[0].start, movie[0].end);
  const headers = children.filter((box) => box.type === "mvhd");
  const tracks = children.filter((box) => box.type === "trak");
  if (headers.length !== 1 || tracks.length !== 1) {
    fail("Nagranie musi zawierać jedną ścieżkę wideo.");
  }
  const header = headers[0];
  const version = bytes[header.start];
  const offset = version === 0 ? 12 : 20;
  if (![0, 1].includes(version) ||
      header.start + offset + (version === 0 ? 8 : 12) > header.end) {
    fail("Nieprawidłowy nagłówek czasu MP4.");
  }
  const scale = bytes.readUInt32BE(header.start + offset);
  const duration = version === 0 ?
      bytes.readUInt32BE(header.start + offset + 4) :
      Number(bytes.readBigUInt64BE(header.start + offset + 4));
  const durationMillis = Math.round(duration * 1000 / scale);
  if (!scale || !Number.isSafeInteger(durationMillis) ||
      durationMillis < 1000 || durationMillis > 30000) {
    fail("Nagranie musi trwać od 1 do 30 sekund.");
  }
  const child = (parent, type) => {
    const found = boxes(bytes, parent.start, parent.end)
        .filter((box) => box.type === type);
    if (found.length !== 1) fail("Niekompletna ścieżka MP4.");
    return found[0];
  };
  const media = child(tracks[0], "mdia");
  const handler = child(media, "hdlr");
  if (handler.start + 12 > handler.end ||
      bytes.toString("ascii", handler.start + 8, handler.start + 12) !==
        "vide") fail("Wymagana jest ścieżka wideo.");
  const table = child(child(media, "minf"), "stbl");
  const description = child(table, "stsd");
  if (description.start + 8 > description.end ||
      bytes.readUInt32BE(description.start + 4) !== 1) {
    fail("Nieprawidłowy opis ścieżki MP4.");
  }
  const entries = boxes(bytes, description.start + 8, description.end);
  if (entries.length !== 1 || entries[0].type !== "avc1" ||
      entries[0].start + 78 > entries[0].end) {
    fail("Wymagane jest wideo H.264.");
  }
  const width = bytes.readUInt16BE(entries[0].start + 24);
  const height = bytes.readUInt16BE(entries[0].start + 26);
  if (!width || !height || width > 1280 || height > 720 ||
      !boxes(bytes, entries[0].start + 78, entries[0].end)
          .some((box) => box.type === "avcC" && box.end - box.start >= 7)) {
    fail("Nieprawidłowe wymiary lub konfiguracja H.264.");
  }
  return {durationMillis, width, height};
}

/**
 * Dekoduje ograniczony plik; kontrola odbywa się przed alokacją bufora.
 * @param {*} value Base64.
 * @return {Object} Plik i jego metadane.
 */
function decodeClip(value) {
  if (typeof value !== "string" || !value.length ||
      value.length > 4 * Math.ceil(maximumClipBytes / 3) ||
      value.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(value)) {
    fail("Nieprawidłowe dane nagrania.");
  }
  const bytes = Buffer.from(value, "base64");
  if (bytes.toString("base64") !== value) fail("Niepoprawne Base64.");
  return {bytes, ...inspectMp4(bytes)};
}

/**
 * Tworzy handler uploadu, z tymi samymi zależnościami w testach i Firebase.
 * @param {Object} dependencies Uwierzytelnianie, Firestore i Storage.
 * @return {Function} Handler HTTP.
 */
function createClipUploadHandler({db, authenticate, getBucket,
  FieldValue, Timestamp, log = console}) {
  return async (request, response) => {
    if (request.method !== "POST") {
      response.status(405).json({error: "POST required."});
      return;
    }
    let createdFile = null;
    let createdGeneration = null;
    try {
      const identity = await authenticate(request);
      if (!identity) fail("Nieprawidłowe dane Bridge.", 401);
      const data = request.body || {};
      const cameraId = normalizeDocumentId(data.cameraId, "cameraId");
      const externalEventId = data.externalEventId;
      if (!uuidPattern.test(externalEventId)) fail("Nieprawidłowe UUID.");
      const receiptId = createHash("sha256").update(JSON.stringify([
        identity.ownerId, identity.bridgeId, cameraId, externalEventId,
      ])).digest("hex");
      const cameraRef = db.collection("users").doc(identity.ownerId)
          .collection("cameras").doc(cameraId);
      const receiptRef = db.collection("bridgeCameraEventReceipts")
          .doc(receiptId);
      const [cameraSnapshot, receiptSnapshot] = await db.getAll(
          cameraRef, receiptRef,
      );
      const checkCamera = (snapshot) => {
        if (!snapshot.exists) fail("Kamera nie istnieje.", 404);
        const camera = snapshot.data();
        if (camera.deletionPending === true ||
            camera.bridgeId !== identity.bridgeId ||
            camera.connectionType !== "onvif" ||
            camera.aiRecordingEnabled !== true) {
          fail("Nagrywanie tej kamery jest niedostępne.", 403);
        }
      };
      checkCamera(cameraSnapshot);
      if (!receiptSnapshot.exists) {
        fail("Zdarzenie oczekuje na przyjęcie przez backend.", 409);
      }
      const receipt = receiptSnapshot.data();
      if (receipt.ownerId !== identity.ownerId ||
          receipt.cameraId !== cameraId ||
          receipt.bridgeId !== identity.bridgeId ||
          receipt.externalEventId !== externalEventId ||
          receipt.source !== "local-ai" || !receipt.result) {
        fail("Nieprawidłowe powiązanie nagrania.", 403);
      }
      const eventId = normalizeDocumentId(receipt.result.eventId, "eventId");
      const eventRef = db.collection("cameraEvents").doc(eventId);
      const checkEvent = (snapshot) => {
        if (!snapshot.exists) fail("Zdarzenie nie istnieje.", 404);
        const event = snapshot.data();
        if (event.ownerId !== identity.ownerId || event.cameraId !== cameraId ||
            (event.source !== "local-ai" &&
              event.hasLocalAiDetection !== true)) {
          fail("Bridge nie może zapisać nagrania tego zdarzenia.", 403);
        }
      };
      checkEvent(await eventRef.get());
      const clip = decodeClip(data.mp4Base64);
      const prebufferMillis = data.prebufferMillis;
      const occurredAtMillis = data.occurredAtMillis;
      if (!Number.isSafeInteger(prebufferMillis) || prebufferMillis < 0 ||
          prebufferMillis > 5000 || prebufferMillis >= clip.durationMillis ||
          !Number.isSafeInteger(occurredAtMillis) ||
          Date.parse(receipt.occurredAt) !== occurredAtMillis) {
        fail("Nieprawidłowy czas nagrania.");
      }
      const clipPath = `users/${identity.ownerId}/cameraEvents/` +
          `${eventId}/clip.mp4`;
      const file = getBucket().file(clipPath);
      let alreadyExists = false;
      let metadata;
      try {
        [metadata] = await file.getMetadata();
        alreadyExists = true;
      } catch (error) {
        if (Number(error.code) !== 404) throw error;
      }
      if (!alreadyExists) {
        try {
          await file.save(clip.bytes, {
            resumable: false, validation: "crc32c",
            preconditionOpts: {ifGenerationMatch: 0},
            metadata: {
              contentType: "video/mp4", cacheControl: "private, max-age=0",
              metadata: {
                ownerId: identity.ownerId, cameraId, eventId,
                source: "local-ai", externalEventId,
                durationMillis: String(clip.durationMillis),
                prebufferMillis: String(prebufferMillis),
                occurredAtMillis: String(occurredAtMillis),
              },
            },
          });
          createdFile = clipPath;
        } catch (error) {
          if (Number(error.code) !== 412) throw error;
          alreadyExists = true;
        }
        [metadata] = await file.getMetadata();
      }
      if (createdFile) createdGeneration = metadata.generation;
      const attributes = metadata.metadata || {};
      const size = Number(metadata.size);
      const duration = Number(attributes.durationMillis);
      const prebuffer = Number(attributes.prebufferMillis);
      const occurredAt = Number(attributes.occurredAtMillis);
      if (metadata.contentType !== "video/mp4" ||
          attributes.ownerId !== identity.ownerId ||
          attributes.cameraId !== cameraId || attributes.eventId !== eventId ||
          attributes.source !== "local-ai" ||
          !uuidPattern.test(attributes.externalEventId) ||
          !Number.isSafeInteger(size) || size < 100 ||
          size > maximumClipBytes || !Number.isSafeInteger(duration) ||
          duration < 1000 || duration > 30000 ||
          !Number.isSafeInteger(prebuffer) || prebuffer < 0 ||
          prebuffer > 5000 || prebuffer >= duration ||
          !Number.isSafeInteger(occurredAt)) {
        fail("Istniejące nagranie ma nieprawidłowe metadane.", 500);
      }
      await db.runTransaction(async (transaction) => {
        const currentCamera = await transaction.get(cameraRef);
        const currentEvent = await transaction.get(eventRef);
        checkCamera(currentCamera);
        checkEvent(currentEvent);
        if (currentEvent.data().clipPath !== clipPath) {
          transaction.update(eventRef, {
            clipPath, clipDurationMillis: duration,
            clipPrebufferMillis: prebuffer,
            clipStartedAt: Timestamp.fromMillis(occurredAt - prebuffer),
            clipEndedAt: Timestamp.fromMillis(
                occurredAt - prebuffer + duration,
            ),
            clipUpdatedAt: FieldValue.serverTimestamp(),
            updatedAt: FieldValue.serverTimestamp(),
          });
        }
      });
      response.status(200).json({ok: true, externalEventId, eventId,
        clipPath, size, durationMillis: duration,
        prebufferMillis: prebuffer, alreadyExists});
    } catch (error) {
      const status = error.status ||
          (String(error.code || "").startsWith("invalid-") ? 400 : 500);
      if (createdFile && createdGeneration && [403, 404].includes(status)) {
        await getBucket().file(createdFile, {generation: createdGeneration})
            .delete({ignoreNotFound: true}).catch(() => {});
      }
      log.error("BRIDGE CAMERA CLIP:", {status,
        message: status < 500 ? error.message :
          "Zapis nagrania nie powiódł się."});
      response.status(status).json({error: status < 500 ? error.message :
        "Nie udało się zapisać nagrania. Spróbuj ponownie."});
    }
  };
}

module.exports = {maximumClipBytes, inspectMp4, decodeClip,
  createClipUploadHandler};
