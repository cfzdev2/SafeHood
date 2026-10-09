'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const fsPromises = require('node:fs/promises');
const os = require('node:os');
const {AiEventOutbox} = require('../ai/event_outbox');
const {CameraAiSession} = require('../ai/camera_ai_session');
const {SnapshotUploadQueue} = require('../ai/snapshot_upload_queue');
const {createAiEventMetadata} = require('../ai/event_metadata');
const {modelIdentifier} = require('../ai/yolox_detector');

const source = fs.readFileSync(path.join(__dirname, '..', 'authenticated_index.js'), 'utf8');
const start = source.indexOf('async function ingestAiDetection(');
const end = source.indexOf('\nfunction safeAiErrorMessage(', start);
assert.ok(start >= 0 && end > start);
const handlerCode = source.slice(start, end) + '\ningestAiDetection;';
const endpointStart = source.indexOf('async function callBridgeEndpoint(');
const endpointEnd = source.indexOf('\nfunction isFakeCamera(', endpointStart);
assert.ok(endpointStart >= 0 && endpointEnd > endpointStart);
const endpointCode = source.slice(endpointStart, endpointEnd) + '\ncallBridgeEndpoint;';
const camera = {id: 'camera-1'};
const input = 'rtsp://camera.local/live';
const event = {type: 'person', confidence: 0.9, occurredAtMillis: 1000};
const nextTurn = () => new Promise((resolve) => setImmediate(resolve));

function createHandler(ingestDetection, snapshotQueue, outbox = null, recordingManager = null) {
  return vm.runInNewContext(handlerCode, {
    snapshotQueue, recordingManager, AI_DIAGNOSTICS_ENABLED: false,
    createAiEventMetadata, modelIdentifier,
    eventOutbox: outbox ?? {enqueue: async (payload, afterDelivery) => {
      const result = await ingestDetection(payload);
      afterDelivery(result);
      return result;
    }},
    safeAiErrorMessage: (error) => error.message,
    console: {error: () => {}},
  });
}

function createEndpoint(fetch) {
  return vm.runInNewContext(endpointCode, {
    fetch, AbortController, setTimeout, clearTimeout,
    functionsBaseUrl: 'http://localhost/test',
    bridgeConfig: {bridgeId: 'test-bridge', bridgeSecret: 'test-secret'},
  });
}

test('rzeczywisty klient API przekazuje HTTP 403 do decyzji o retry', async () => {
  const endpoint = createEndpoint(async () => ({
    ok: false, status: 403, text: async () => '{"error":"Forbidden"}',
  }));
  await assert.rejects(endpoint('uploadBridgeCameraEventSnapshot', {}), (error) => {
    assert.equal(error.statusCode, 403);
    return true;
  });
});

test('anulowanie zadania przerywa wysyłkę klienta API', async () => {
  let requestSignal;
  const endpoint = createEndpoint((_url, {signal}) => {
    requestSignal = signal;
    return new Promise((_, reject) => {
      signal.addEventListener('abort', () => reject(new Error('Anulowano.')), {once: true});
    });
  });
  const controller = new AbortController();
  const request = endpoint('uploadBridgeCameraEventSnapshot', {}, 30000, controller.signal);
  controller.abort();
  await assert.rejects(request, /Anulowano/);
  assert.equal(requestSignal.aborted, true);
});

test('zdarzenie scalone bez zdjęcia trafia do kolejki', async () => {
  const calls = [];
  const result = {eventId: 'event-1', merged: true, snapshotRequired: true};
  const ingest = createHandler(async () => result, {
    enqueue: (details) => { calls.push(details); return 'queued'; },
  });
  assert.strictEqual(await ingest(camera, input, event), result);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].cameraId, camera.id);
  assert.equal(calls[0].eventId, result.eventId);
  assert.equal(calls[0].input, input);
});

test('zapisuje klasę, zakres czasu i model razem ze zdarzeniem', async () => {
  let saved;
  const ingest = createHandler(null, null, {
    enqueue: async (payload) => {
      saved = payload;
      return {queued: true, externalEventId: '497c843d-9fdb-4fde-9c08-fca465877ae9'};
    },
  });
  await ingest(camera, input, {
    type: 'vehicle',
    className: 'bus',
    confidence: 0.91,
    detectionCount: 3,
    firstSeenAtMillis: 500,
    occurredAtMillis: 1000,
  });
  assert.deepEqual(saved.aiMetadata, {
    schemaVersion: 1,
    className: 'bus',
    detectionCount: 3,
    firstSeenAt: '1970-01-01T00:00:00.500Z',
    lastSeenAt: '1970-01-01T00:00:01.000Z',
    modelId: modelIdentifier,
  });
});

test('wskazanie istniejącego zdjęcia nie uruchamia pobierania', async () => {
  const ingest = createHandler(async () => ({merged: false, snapshotRequired: false}), {
    enqueue: () => assert.fail('Zdjęcie już istnieje.'),
  });
  await ingest(camera, input, event);
});

test('zachowuje obsługę backendu bez pola snapshotRequired', async () => {
  let calls = 0;
  let merged = false;
  const ingest = createHandler(async () => ({id: 'event-1', merged}), {
    enqueue: () => { calls += 1; return 'queued'; },
  });
  await ingest(camera, input, event);
  merged = true;
  await ingest(camera, input, event);
  assert.equal(calls, 1);
});

test('błąd zapisu zdarzenia do kolejki nie tworzy zadania zdjęcia', async () => {
  const ingest = createHandler(async () => { throw new Error('Dysk niedostępny.'); }, {
    enqueue: () => assert.fail('Zdarzenie nie zostało zapisane.'),
  });
  await assert.rejects(ingest(camera, input, event), /Dysk niedostępny/);
});

test('nagranie uruchamia się dopiero po trwałym zapisie wykrycia, bez czekania na ingest', async () => {
  const calls = [];
  let release;
  const saved = new Promise((resolve) => { release = resolve; });
  const handler = createHandler(null, null, {enqueue: () => saved}, {
    capture: (cameraId, detection) => calls.push({cameraId, detection}),
  });
  const operation = handler({...camera, aiRecordingEnabled: true}, input, event);
  await nextTurn();
  assert.equal(calls.length, 0);
  release({queued: true, externalEventId: '497c843d-9fdb-4fde-9c08-fca465877ae9'});
  await operation;
  assert.equal(calls.length, 1);
  assert.equal(calls[0].detection.externalEventId, '497c843d-9fdb-4fde-9c08-fca465877ae9');
  assert.equal(calls[0].detection.occurredAtMillis, event.occurredAtMillis);
});

test('awaria nagrania zachowuje już zapisane zdarzenie AI', async () => {
  const result = {queued: true, externalEventId: '497c843d-9fdb-4fde-9c08-fca465877ae9'};
  const handler = createHandler(null, null, {enqueue: async () => result}, {
    capture: () => { throw new Error('Dysk nagrania jest pełny.'); },
  });
  assert.strictEqual(await handler({...camera, aiRecordingEnabled: true}, input, event), result);
});

test('wolne pobieranie zdjęcia nie zatrzymuje analizy następnej klatki', async (t) => {
  let releaseCapture;
  let runQueue;
  let sourceOptions;
  let captures = 0;
  let uploads = 0;
  let eventWrites = 0;
  const pendingCapture = new Promise((resolve) => { releaseCapture = resolve; });
  const queue = new SnapshotUploadQueue({
    captureSnapshot: () => { captures += 1; return pendingCapture; },
    uploadSnapshot: async () => { uploads += 1; return {}; },
    setTimer: (callback) => { runQueue = callback; return 1; },
    clearTimer: () => { runQueue = null; },
  });
  t.after(() => queue.close());
  const ingest = createHandler(async () => {
    eventWrites += 1;
    return {eventId: 'event-1', merged: false, snapshotRequired: true};
  }, queue);
  const session = new CameraAiSession({
    cameraId: camera.id, input,
    trackerOptions: {minimumConfirmedFrames: 1},
    scheduler: {
      submit: async () => ({dropped: false, detections: [{
        type: 'person', className: 'person', classId: 0, score: 0.9,
        box: {left: 10, top: 10, right: 100, bottom: 200, width: 90, height: 190},
      }]}),
      cancelCamera: () => {},
    },
    onConfirmedTrack: (track) => ingest(camera, input, track),
    sourceFactory: (options) => {
      sourceOptions = options;
      return {start: () => {}, stop: async () => {}};
    },
  });
  t.after(() => session.stop());
  session.start();
  await sourceOptions.onFrame(Buffer.from([1]));
  runQueue();
  await nextTurn();
  assert.equal(captures, 1);
  assert.equal(uploads, 0);
  await sourceOptions.onFrame(Buffer.from([2]));
  assert.equal(session.stats.framesAnalyzed, 2);
  assert.equal(eventWrites, 1);
  releaseCapture(Buffer.from([0xff, 0xd8, 0xff, 0xd9]));
  await nextTurn();
  assert.equal(uploads, 1);
});

test('awaria ingestu nie blokuje zapisu następnego wykrycia ani analizy', async (t) => {
  const directory = await fsPromises.mkdtemp(path.join(os.tmpdir(), 'safehood-session-outbox-'));
  let drain;
  let sending = false;
  let frame = 0;
  let sourceOptions;
  const outbox = new AiEventOutbox({
    directory,
    deliver: (_payload, signal) => {
      sending = true;
      return new Promise((_, reject) => {
        signal.addEventListener('abort', () => reject(new Error('Anulowano.')));
      });
    },
    setTimer: (callback) => { drain = callback; return 1; },
    clearTimer: () => {},
  });
  const ingest = createHandler(null, {
    enqueue: () => assert.fail('Nie było potwierdzenia backendu.'),
  }, outbox);
  const session = new CameraAiSession({
    cameraId: camera.id, input, trackerOptions: {minimumConfirmedFrames: 1},
    scheduler: {
      submit: async () => {
        const left = ++frame === 1 ? 10 : 200;
        return {dropped: false, detections: [{
          type: 'person', classId: 0, className: 'person', score: 0.9,
          box: {left, top: 10, right: left + 90, bottom: 200, width: 90, height: 190},
        }]};
      },
      cancelCamera: () => {},
    },
    onConfirmedTrack: (track) => ingest(camera, input, track),
    sourceFactory: (options) => {
      sourceOptions = options;
      return {start: () => {}, stop: async () => {}};
    },
  });
  t.after(async () => {
    await outbox.close(); await session.stop();
    await fsPromises.rm(directory, {recursive: true, force: true});
  });
  session.start();
  await sourceOptions.onFrame(Buffer.from([1]));
  drain();
  while (!sending) await nextTurn();
  await sourceOptions.onFrame(Buffer.from([2]));
  assert.equal(session.stats.framesAnalyzed, 2);
  assert.equal(session.stats.confirmedEvents, 2);
  assert.equal(session.stats.eventErrors, 0);
  assert.equal(outbox.pendingCount, 2);
  assert.equal((await fsPromises.readdir(directory)).length, 2);
});
