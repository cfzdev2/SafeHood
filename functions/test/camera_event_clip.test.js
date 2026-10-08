"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const {createHash} = require("node:crypto");
const {Timestamp, FieldValue} = require("firebase-admin/firestore");
const {inspectMp4, decodeClip, maximumClipBytes,
  createClipUploadHandler} = require("../camera_event_clip");

const movie = fs.readFileSync(
    path.join(__dirname, "../../tools/fake_clip.mp4"),
);
const uuid = "b373e3a0-15e4-4fb7-a766-7a504f4c7f9d";
const cameraId = "camera-1";
const ownerId = "owner-1";
const bridgeId = "bridge-1";
const eventId = "event-1";
const occurredAtMillis = Date.parse("2026-10-07T17:00:00.000Z");

const harness = ({camera = {}, event = {}, receipt = {},
  authenticated = true, databaseFailures = 0, storageFailures = 0,
  beforeTransaction = () => {}} = {}) => {
  const documents = new Map();
  const cameraPath = `users/${ownerId}/cameras/${cameraId}`;
  const receiptPath = "bridgeCameraEventReceipts/" + createHash("sha256")
      .update(JSON.stringify([ownerId, bridgeId, cameraId, uuid]))
      .digest("hex");
  documents.set(cameraPath, {bridgeId, connectionType: "onvif",
    aiRecordingEnabled: true, ...camera});
  documents.set(`cameraEvents/${eventId}`, {ownerId, cameraId,
    source: "multiple", hasLocalAiDetection: true,
    occurrenceCount: 4, ...event});
  if (receipt !== null) {
    documents.set(receiptPath, {ownerId, bridgeId, cameraId,
      source: "local-ai", externalEventId: uuid, result: {eventId},
      occurredAt: new Date(occurredAtMillis).toISOString(), ...receipt});
  }
  const ref = (name) => ({path: name,
    collection: (part) => ({doc: (id) => ref(`${name}/${part}/${id}`)}),
    get: async () => ({exists: documents.has(name),
      data: () => documents.get(name)}),
  });
  let stored = null;
  let writes = 0;
  const file = {
    save: async (bytes, options) => {
      assert.equal(options.preconditionOpts.ifGenerationMatch, 0);
      if (storageFailures-- > 0) throw new Error("Storage offline");
      if (stored) throw Object.assign(new Error("Exists"), {code: 412});
      stored = {bytes: Buffer.from(bytes), metadata: {
        ...options.metadata, size: String(bytes.length), generation: "1"}};
      writes++;
    },
    getMetadata: async () => {
      if (!stored) throw Object.assign(new Error("Not found"), {code: 404});
      return [stored.metadata];
    },
    delete: async () => {
      stored = null;
    },
  };
  const db = {
    collection: (name) => ({doc: (id) => ref(`${name}/${id}`)}),
    getAll: (...refs) => Promise.all(refs.map((value) => value.get())),
    runTransaction: async (operation) => {
      beforeTransaction(documents, cameraPath);
      if (databaseFailures-- > 0) throw new Error("Firestore offline");
      const updates = [];
      await operation({get: (reference) => reference.get(),
        update: (reference, values) => updates.push({reference, values})});
      for (const {reference, values} of updates) {
        documents.set(reference.path, {
          ...documents.get(reference.path), ...values,
        });
      }
    },
  };
  const handler = createClipUploadHandler({db, Timestamp, FieldValue,
    authenticate: async () => authenticated ? {ownerId, bridgeId} : null,
    getBucket: () => ({file: (name, options) => {
      assert.equal(name, `users/${ownerId}/cameraEvents/${eventId}/clip.mp4`);
      if (options) assert.deepEqual(options, {generation: "1"});
      return file;
    }}), log: {error: () => {}}});
  return {documents, stored: () => stored, writes: () => writes,
    send: async (changes = {}, method = "POST") => {
      let status;
      let body;
      await handler({method, body: {cameraId, externalEventId: uuid,
        occurredAtMillis, prebufferMillis: 5000,
        mp4Base64: movie.toString("base64"), ...changes}}, {
        status: (value) => {
          status = value; return {json: (value) => {
            body = value;
          }};
        },
      });
      return {status, body};
    }};
};

test("czyta rzeczywiste MP4 H.264 i jego czas", () => {
  assert.deepEqual(inspectMp4(movie), {
    durationMillis: 10000, width: 640, height: 360,
  });
  assert.deepEqual(decodeClip(movie.toString("base64")).bytes, movie);
});

test("odrzuca dane bez filmu, urwany plik i niepoprawne Base64", () => {
  for (const value of ["", "AAAA=", "%%==",
    Buffer.alloc(200).toString("base64"),
    movie.subarray(0, movie.length - 10).toString("base64")]) {
    assert.throws(() => decodeClip(value));
  }
});

test("odrzuca nagranie przekraczające limit przed dekodowaniem", () => {
  const oversized = "A".repeat(4 * Math.ceil(maximumClipBytes / 3) + 4);
  assert.throws(() => decodeClip(oversized));
});

test("odrzuca zbyt długi film i inny kodek", () => {
  const tooLong = Buffer.from(movie);
  tooLong.writeUInt32BE(0x7fffffff, tooLong.indexOf("mvhd") + 20);
  assert.throws(() => inspectMp4(tooLong));
  const codec = Buffer.from(movie);
  Buffer.from("hvc1").copy(codec, codec.indexOf("avc1", 64));
  assert.throws(() => inspectMp4(codec));
});

test("upload wymaga POST, Bridge i poprawnego UUID", async () => {
  assert.equal((await harness().send({}, "GET")).status, 405);
  assert.equal((await harness({authenticated: false}).send()).status, 401);
  assert.equal((await harness().send({externalEventId: "wrong"})).status, 400);
});

test("upload czeka na receipt właściwego zdarzenia", async () => {
  const h = harness({receipt: null});
  assert.equal((await h.send()).status, 409);
  assert.equal(h.writes(), 0);
});

test("upload wymaga włączonego nagrywania i właściwego Bridge", async () => {
  for (const camera of [{aiRecordingEnabled: false}, {bridgeId: "other"},
    {connectionType: "rtsp"}, {deletionPending: true}]) {
    const h = harness({camera});
    assert.equal((await h.send()).status, 403);
    assert.equal(h.writes(), 0);
  }
});

test("odrzuca receipt obcego właściciela i sygnał ONVIF", async () => {
  for (const receipt of [{ownerId: "other"}, {bridgeId: "other"},
    {cameraId: "other"}, {source: "onvif"}]) {
    assert.equal((await harness({receipt}).send()).status, 403);
  }
});

test("odrzuca obce zdarzenie i czyste ONVIF", async () => {
  for (const event of [{ownerId: "other"}, {cameraId: "other"},
    {source: "onvif", hasLocalAiDetection: false}]) {
    assert.equal((await harness({event}).send()).status, 403);
  }
});

test("waliduje oryginalny czas wykrycia i prebuffer", async () => {
  for (const changes of [{occurredAtMillis: occurredAtMillis + 1},
    {prebufferMillis: -1}, {prebufferMillis: 5001}, {prebufferMillis: "5"}]) {
    assert.equal((await harness().send(changes)).status, 400);
  }
});

test("prywatny film mieszanego zdarzenia zachowuje licznik", async () => {
  const h = harness();
  const result = await h.send();
  assert.equal(result.status, 200);
  assert.equal(result.body.durationMillis, 10000);
  assert.equal(result.body.prebufferMillis, 5000);
  const data = h.documents.get(`cameraEvents/${eventId}`);
  assert.equal(data.occurrenceCount, 4);
  assert.equal(data.clipStartedAt.toMillis(), occurredAtMillis - 5000);
  assert.equal(data.clipEndedAt.toMillis(), occurredAtMillis + 5000);
  assert.equal(h.stored().metadata.contentType, "video/mp4");
  assert.equal(
      h.stored().metadata.metadata.firebaseStorageDownloadTokens, undefined,
  );
});

test("retry i równoległe uploady zachowują pierwszy film", async () => {
  const h = harness();
  const results = await Promise.all([h.send(), h.send(), h.send()]);
  assert.ok(results.every((value) => value.status === 200));
  assert.equal(h.writes(), 1);
  const changed = Buffer.from(movie);
  changed[changed.length - 1] ^= 1;
  const repeated = await h.send({mp4Base64: changed.toString("base64")});
  assert.equal(repeated.status, 200);
  assert.deepEqual(h.stored().bytes, movie);
});

test("retry naprawia Firestore po udanym zapisie Storage", async () => {
  const h = harness({databaseFailures: 1});
  assert.equal((await h.send()).status, 500);
  assert.equal(h.documents.get(`cameraEvents/${eventId}`).clipPath, undefined);
  assert.equal((await h.send()).status, 200);
  assert.equal(h.writes(), 1);
});

test("awaria Storage nie zapisuje nieistniejącej ścieżki", async () => {
  const h = harness({storageFailures: 1});
  assert.equal((await h.send()).status, 500);
  assert.equal(h.documents.get(`cameraEvents/${eventId}`).clipPath, undefined);
});

test("nie podpina istniejącego pliku z obcymi metadanymi", async () => {
  const h = harness();
  await h.send();
  h.stored().metadata.metadata.ownerId = "other";
  assert.equal((await h.send()).status, 500);
});

test("ponownie kontroluje uprawnienia przed podpięciem filmu", async () => {
  const h = harness({beforeTransaction: (documents, name) => {
    documents.get(name).deletionPending = true;
  }});
  assert.equal((await h.send()).status, 403);
  assert.equal(h.stored(), null);
  assert.equal(h.documents.get(`cameraEvents/${eventId}`).clipPath, undefined);
});
