"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const {createHash} = require("node:crypto");
const {Timestamp, FieldValue} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");
const snapshotHelpers = require("../camera_event_snapshot");

const source = fs.readFileSync(path.join(__dirname, "..", "index.js"), "utf8");
const readBlock = (startMarker, endMarker = "\n/**") => {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start);
  assert.ok(start >= 0 && end > start);
  return source.slice(start, end);
};
const uploadCode = readBlock(
    "exports.uploadBridgeCameraEventSnapshot =",
    "\nexports.ingestCameraEvent =",
);
const aggregationCode = [
  readBlock(
      "const allowedCameraEventTypes =",
      "\nconst allowedBridgeMonitoringStatuses",
  ),
  readBlock("const cameraEventPriority =", "\nconst bridgePairingLifetimeMs"),
  ...[
    "normalizeCameraEventType", "normalizeCameraEventSource",
    "normalizeConfidence",
    "normalizeOptionalUrl", "normalizeOccurredAt", "isDetectionCameraEvent",
    "selectCameraEventType", "mergeConfidence",
    "normalizeBridgeExternalEventId",
    "ingestCameraEventInternal",
  ].map((name) => {
    const prefix = name === "ingestCameraEventInternal" ? "async " : "";
    return readBlock(`${prefix}function ${name}(`);
  }),
  "ingestCameraEventInternal;",
].join("\n");

const ownerId = "test-owner";
const cameraId = "test-camera";
const eventId = "test-event";
const cameraPath = `users/${ownerId}/cameras/${cameraId}`;
const eventPath = `cameraEvents/${eventId}`;
const jpeg = Buffer.from([0xff, 0xd8, 1, 2, 0xff, 0xd9]);
const anotherJpeg = Buffer.from([0xff, 0xd8, 3, 0xff, 0xd9]);

const createHarness = ({
  camera = {}, event = {}, authenticated = true,
  updateFailures = 0, storageFailures = 0,
  receiptWriteFailures = 0,
} = {}) => {
  const documents = new Map();
  documents.set(cameraPath, {
    bridgeId: "test-bridge", connectionType: "onvif", name: "Kamera",
    motionDetectionEnabled: false, aiEnabled: true, ...camera,
  });
  if (event !== null) {
    documents.set(eventPath, {ownerId, cameraId, source: "local-ai", ...event});
  }
  let nextId = 0;
  let stored = null;
  const saves = [];
  const updates = [];
  const notifications = [];
  let transactionTail = Promise.resolve();
  const makeRef = (documentPath) => ({
    path: documentPath,
    id: documentPath.split("/").pop(),
    collection: (name) => makeCollection(`${documentPath}/${name}`),
    get: async () => ({
      exists: documents.has(documentPath),
      ref: makeRef(documentPath),
      data: () => ({...documents.get(documentPath)}),
    }),
    update: async (data) => {
      updates.push(data);
      if (updateFailures > 0) {
        updateFailures -= 1;
        throw new Error("Firestore niedostępny.");
      }
      documents.set(documentPath, {...documents.get(documentPath), ...data});
    },
  });
  const makeCollection = (collectionPath) => ({
    doc: (id) => makeRef(`${collectionPath}/${id || `auto-${++nextId}`}`),
  });
  const db = {
    collection: makeCollection,
    getAll: (...refs) => Promise.all(refs.map((ref) => ref.get())),
    runTransaction: (handler) => {
      const operation = transactionTail.then(async () => {
        const writes = [];
        const result = await handler({
          get: (ref) => {
            assert.equal(writes.length, 0, "Odczyt po zapisie transakcji.");
            return ref.get();
          },
          update: (ref, data) => writes.push({ref, data, merge: true}),
          set: (ref, data, options) => {
            if (ref.path.startsWith("bridgeCameraEventReceipts/") &&
                receiptWriteFailures > 0) {
              receiptWriteFailures -= 1;
              throw new Error("Błąd potwierdzenia.");
            }
            writes.push({ref, data, merge: options && options.merge});
          },
        });
        for (const {ref, data, merge} of writes) {
          const previous = merge ? documents.get(ref.path) : {};
          documents.set(ref.path, {...previous, ...data});
        }
        return result;
      });
      transactionTail = operation.catch(() => {});
      return operation;
    },
  };
  const file = {
    save: async (buffer, options) => {
      saves.push(options);
      assert.equal(options.preconditionOpts.ifGenerationMatch, 0);
      if (storageFailures > 0) {
        storageFailures -= 1;
        throw Object.assign(new Error("Storage niedostępny."), {code: 500});
      }
      if (stored) {
        throw Object.assign(new Error("Precondition failed."), {code: 412});
      }
      stored = {
        buffer: Buffer.from(buffer),
        metadata: {...options.metadata, size: String(buffer.length)},
      };
    },
    getMetadata: async () => [stored.metadata],
  };
  const exported = {};
  vm.runInNewContext(uploadCode, {
    ...snapshotHelpers,
    exports: exported, db, FieldValue,
    onRequest: (_options, handler) => handler,
    authenticateBridgeRequest: async () => authenticated ?
      {ownerId, bridgeId: "test-bridge"} : null,
    getStorage: () => ({bucket: () => ({
      file: (filePath) => {
        assert.equal(
            filePath, snapshotHelpers.buildSnapshotPath(ownerId, eventId),
        );
        return file;
      },
    })}),
    console: {log: () => {}, error: () => {}},
  });
  const aggregate = vm.runInNewContext(aggregationCode, {
    db, Timestamp, HttpsError, createHash,
    sendCameraEventNotification: async (data) => notifications.push(data),
    console: {error: () => {}},
  });

  return {
    documents, saves, updates, notifications,
    stored: () => stored,
    aggregate: (input = {}) => aggregate({
      ownerId, cameraId, source: "local-ai", type: "person", ...input,
    }),
    send: async (buffer = jpeg, method = "POST") => {
      const response = {
        statusCode: null, body: null,
        status: (code) => {
          response.statusCode = code; return response;
        },
        json: (body) => {
          response.body = body; return response;
        },
      };
      await exported.uploadBridgeCameraEventSnapshot({
        method,
        body: {cameraId, eventId, jpegBase64: buffer.toString("base64")},
      }, response);
      return response;
    },
  };
};

test("ponowny upload zachowuje pierwszy JPEG i czas jego zapisu", async () => {
  const harness = createHarness();
  const first = await harness.send();
  assert.equal(first.statusCode, 200);
  assert.equal(first.body.alreadyExists, false);
  const savedTimestamp = harness.documents.get(eventPath).snapshotUpdatedAt;
  const repeated = await harness.send(anotherJpeg);
  assert.equal(repeated.statusCode, 200);
  assert.equal(repeated.body.alreadyExists, true);
  assert.equal(repeated.body.size, jpeg.length);
  assert.deepEqual(harness.stored().buffer, jpeg);
  assert.strictEqual(
      harness.documents.get(eventPath).snapshotUpdatedAt, savedTimestamp,
  );
  assert.equal(harness.updates.length, 1);
  assert.equal(
      harness.stored().metadata.cacheControl, "private, max-age=3600",
  );
});

test("retry naprawia ścieżkę po błędzie Firestore", async () => {
  const harness = createHarness({updateFailures: 1});
  assert.equal((await harness.send()).statusCode, 500);
  assert.deepEqual(harness.stored().buffer, jpeg);
  assert.equal(harness.documents.get(eventPath).snapshotPath, undefined);
  const retry = await harness.send(anotherJpeg);
  assert.equal(retry.statusCode, 200);
  assert.equal(retry.body.alreadyExists, true);
  assert.deepEqual(harness.stored().buffer, jpeg);
  assert.equal(
      harness.documents.get(eventPath).snapshotPath, retry.body.snapshotPath,
  );
});

test("równoległe uploady tworzą jeden JPEG", async () => {
  const harness = createHarness();
  const results = await Promise.all([
    harness.send(jpeg), harness.send(anotherJpeg),
  ]);
  assert.equal(results[0].statusCode, 200);
  assert.equal(results[1].statusCode, 200);
  assert.equal(
      results.filter((result) => !result.body.alreadyExists).length, 1,
  );
  assert.deepEqual(harness.stored().buffer, jpeg);
});

test("błąd Storage nie zapisuje nieistniejącej ścieżki", async () => {
  const harness = createHarness({storageFailures: 1});
  assert.equal((await harness.send()).statusCode, 500);
  assert.equal(harness.documents.get(eventPath).snapshotPath, undefined);
  assert.equal(harness.stored(), null);
  assert.equal((await harness.send()).statusCode, 200);
});

test("mieszane zdarzenie z potwierdzonym AI przyjmuje zdjęcie", async () => {
  const harness = createHarness({
    event: {source: "multiple", hasLocalAiDetection: true},
  });
  assert.equal((await harness.send()).statusCode, 200);
});

for (const scenario of [
  {label: "czyste ONVIF", event: {source: "onvif"}},
  {label: "multiple bez potwierdzonego AI", event: {source: "multiple"}},
  {label: "zdarzenie innego użytkownika", event: {ownerId: "someone-else"}},
  {label: "zdarzenie innej kamery", event: {cameraId: "another-camera"}},
  {label: "kamera innego Bridge", camera: {bridgeId: "another-bridge"}},
]) {
  test(`upload odrzuca ${scenario.label}`, async () => {
    const harness = createHarness(scenario);
    assert.equal((await harness.send()).statusCode, 403);
    assert.equal(harness.saves.length, 0);
  });
}

test("upload wymaga uwierzytelnienia i POST", async () => {
  const harness = createHarness({authenticated: false});
  assert.equal((await harness.send()).statusCode, 401);
  assert.equal((await harness.send(jpeg, "GET")).statusCode, 405);
  assert.equal(harness.saves.length, 0);
});

test("nie podpina istniejącego pliku z cudzymi metadanymi", async () => {
  const harness = createHarness({updateFailures: 1});
  await harness.send();
  harness.stored().metadata.metadata.ownerId = "someone-else";
  assert.equal((await harness.send()).statusCode, 500);
  assert.equal(harness.documents.get(eventPath).snapshotPath, undefined);
});

test("nowe i scalone AI wymagają zdjęcia do jego zapisu", async () => {
  const harness = createHarness({event: null});
  const created = await harness.aggregate();
  assert.equal(created.merged, false);
  assert.equal(created.snapshotRequired, true);
  const merged = await harness.aggregate();
  assert.equal(merged.merged, true);
  assert.equal(merged.snapshotRequired, true);
  const document = harness.documents.get(`cameraEvents/${created.eventId}`);
  document.snapshotPath = snapshotHelpers.buildSnapshotPath(
      ownerId, created.eventId,
  );
  assert.equal((await harness.aggregate()).snapshotRequired, false);
});

test("scalenie ONVIF i AI zachowuje możliwość uploadu", async () => {
  const harness = createHarness({event: null});
  const initial = await harness.aggregate({source: "onvif", type: "motion"});
  assert.equal(initial.snapshotRequired, false);
  const mixed = await harness.aggregate();
  const document = harness.documents.get(`cameraEvents/${mixed.eventId}`);
  assert.equal(mixed.eventId, initial.eventId);
  assert.equal(mixed.snapshotRequired, true);
  assert.equal(document.source, "multiple");
  assert.equal(document.hasLocalAiDetection, true);
  const subsequent = await harness.aggregate({source: "onvif", type: "motion"});
  assert.equal(subsequent.snapshotRequired, false);
  const afterOnvif = harness.documents.get(`cameraEvents/${mixed.eventId}`);
  assert.equal(afterOnvif.hasLocalAiDetection, true);
});

test("starsze AI nadal przyjmuje zdjęcie po scaleniu", async () => {
  const harness = createHarness({event: {type: "person", status: "new"}});
  harness.documents.set(`cameraEventStates/${ownerId}_${cameraId}_detection`, {
    activeEventId: eventId, lastReceivedAt: Timestamp.now(),
  });
  const result = await harness.aggregate({source: "onvif", type: "motion"});
  assert.equal(result.merged, true);
  assert.equal(harness.documents.get(eventPath).hasLocalAiDetection, true);
  assert.equal((await harness.send()).statusCode, 200);
});

const receipt = {
  bridgeId: "test-bridge",
  externalEventId: "11111111-1111-4111-8111-111111111111",
};
const receiptInput = {bridgeReceipt: receipt,
  occurredAt: "2026-10-06T19:00:00.000Z"};
const eventDocuments = (harness) => [...harness.documents]
    .filter(([name]) => name.startsWith("cameraEvents/"));

test("receipt AI zachowuje czas i źródło do powiązania prywatnego filmu",
    async () => {
      const h = createHarness({event: null});
      const result = await h.aggregate(receiptInput);
      const receipts = [...h.documents]
          .filter(([name]) => name.startsWith("bridgeCameraEventReceipts/"));
      assert.equal(receipts.length, 1);
      assert.equal(receipts[0][1].source, "local-ai");
      assert.equal(receipts[0][1].occurredAt, receiptInput.occurredAt);
      assert.equal(receipts[0][1].result.eventId, result.eventId);
    });

test("retry po utracie odpowiedzi nie powiela wykryć ani push", async () => {
  const h = createHarness({event: null});
  const first = await h.aggregate(receiptInput);
  const retry = await h.aggregate(receiptInput);
  assert.equal(first.eventId, retry.eventId);
  assert.equal(retry.duplicate, true);
  assert.equal(retry.externalEventId, receipt.externalEventId);
  assert.equal(eventDocuments(h).length, 1);
  assert.equal(eventDocuments(h)[0][1].occurrenceCount, 1);
  assert.equal(h.notifications.length, 1);
});

test("równoległe żądania jednego UUID otrzymują jedno zdarzenie", async () => {
  const h = createHarness({event: null});
  const results = await Promise.all([
    h.aggregate(receiptInput), h.aggregate(receiptInput),
  ]);
  assert.equal(results.filter((result) => result.duplicate).length, 1);
  assert.equal(eventDocuments(h).length, 1);
  assert.equal(eventDocuments(h)[0][1].occurrenceCount, 1);
});

test("kolejne UUID zwiększa licznik, a retry wcześniejszego nie", async () => {
  const h = createHarness({event: null});
  const first = await h.aggregate(receiptInput);
  await h.aggregate({...receiptInput, bridgeReceipt: {
    ...receipt, externalEventId: "22222222-2222-4222-8222-222222222222",
  }});
  const replay = await h.aggregate(receiptInput);
  assert.equal(replay.eventId, first.eventId);
  assert.equal(replay.occurrenceCount, 1);
  assert.equal(eventDocuments(h)[0][1].occurrenceCount, 2);
});

test("UUID nie może zostać ponownie użyte z innym payloadem", async () => {
  const h = createHarness({event: null});
  await h.aggregate(receiptInput);
  await assert.rejects(h.aggregate({...receiptInput, confidence: 0.6}), {
    code: "invalid-argument",
  });
  assert.equal(eventDocuments(h)[0][1].occurrenceCount, 1);
});

test("błąd zapisu receipt wycofuje także zapis zdarzenia", async () => {
  const h = createHarness({event: null, receiptWriteFailures: 1});
  await assert.rejects(h.aggregate(receiptInput), /Błąd potwierdzenia/);
  assert.equal(eventDocuments(h).length, 0);
  assert.equal(h.notifications.length, 0);
  await h.aggregate(receiptInput);
  assert.equal(eventDocuments(h).length, 1);
  assert.equal(eventDocuments(h)[0][1].occurrenceCount, 1);
});

test("kolejka zachowuje dawny czas i rozdziela odległe wykrycia", async () => {
  const h = createHarness({event: null});
  const original = Date.now() - 60 * 60 * 1000;
  const first = await h.aggregate({...receiptInput,
    occurredAt: new Date(original).toISOString()});
  const second = await h.aggregate({
    bridgeReceipt: {...receipt,
      externalEventId: "22222222-2222-4222-8222-222222222222"},
    occurredAt: new Date(original + 30000).toISOString(),
  });
  assert.notEqual(first.eventId, second.eventId);
  assert.equal(eventDocuments(h).length, 2);
  assert.equal(h.documents.get(`cameraEvents/${first.eventId}`)
      .occurredAt.toMillis(), original);
});

test("replay po usunięciu zdarzenia nie odtwarza jego danych", async () => {
  const h = createHarness({event: null});
  const original = await h.aggregate(receiptInput);
  h.documents.delete(`cameraEvents/${original.eventId}`);
  const retry = await h.aggregate(receiptInput);
  assert.equal(retry.duplicate, true);
  assert.equal(retry.snapshotRequired, false);
  assert.equal(eventDocuments(h).length, 0);
});

test("UUID jest oddzielone dla każdej kamery Bridge", async () => {
  const h = createHarness({event: null});
  h.documents.set(
      `users/${ownerId}/cameras/second-camera`, {name: "Druga"},
  );
  const first = await h.aggregate(receiptInput);
  const second = await h.aggregate({
    ...receiptInput, cameraId: "second-camera",
  });
  assert.notEqual(first.eventId, second.eventId);
  assert.equal(eventDocuments(h).length, 2);
});

test("bieżące ONVIF nie scala się ze starym zdarzeniem z kolejki", async () => {
  const h = createHarness({event: null});
  await h.aggregate({...receiptInput,
    occurredAt: new Date(Date.now() - 60 * 60 * 1000).toISOString()});
  const current = await h.aggregate({source: "onvif", type: "motion"});
  assert.equal(current.merged, false);
  assert.equal(eventDocuments(h).length, 2);
});

test("opóźnione wykrycie zachowuje zakres czasu zdarzenia", async () => {
  const h = createHarness({event: null});
  const earlier = Date.now() - 10000;
  const later = earlier + 5000;
  const first = await h.aggregate({...receiptInput,
    occurredAt: new Date(later).toISOString()});
  await h.aggregate({
    bridgeReceipt: {...receipt,
      externalEventId: "22222222-2222-4222-8222-222222222222"},
    occurredAt: new Date(earlier).toISOString(),
  });
  const data = h.documents.get(`cameraEvents/${first.eventId}`);
  assert.equal(data.occurredAt.toMillis(), earlier);
  assert.equal(data.lastOccurredAt.toMillis(), later);
  assert.equal(data.occurrenceCount, 2);
});
