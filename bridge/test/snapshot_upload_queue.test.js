'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const {SnapshotUploadQueue} = require('../ai/snapshot_upload_queue');

const jpeg = Buffer.from([0xff, 0xd8, 1, 2, 0xff, 0xd9]);
const nextTurn = () => new Promise((resolve) => setImmediate(resolve));
const job = (eventId = 'event-1', cameraId = 'camera-1') => ({
  cameraId, eventId, input: 'rtsp://camera.local/live',
});

function createHarness(t, overrides = {}) {
  let time = 1000;
  let nextTimer = 0;
  const timers = new Map();
  const captures = [];
  const uploads = [];
  const errors = [];
  const saved = [];
  const queue = new SnapshotUploadQueue({
    captureSnapshot: async (request) => {
      captures.push(request);
      return jpeg;
    },
    uploadSnapshot: async (request) => {
      uploads.push(request);
      return {size: request.snapshot.length};
    },
    onSaved: (details) => saved.push(details),
    onError: (details) => errors.push(details),
    now: () => time,
    setTimer: (callback, delay) => {
      const id = ++nextTimer;
      timers.set(id, {callback, at: time + delay});
      return id;
    },
    clearTimer: (id) => timers.delete(id),
    ...overrides,
  });
  t.after(() => queue.close());

  return {
    queue, captures, uploads, errors, saved, timers,
    async tick(milliseconds = 0) {
      time += milliseconds;
      await nextTurn();
      for (let count = 0; count < 100; count += 1) {
        const ready = [...timers].find(([, timer]) => timer.at <= time);
        if (!ready) return;
        timers.delete(ready[0]);
        ready[1].callback();
        await nextTurn();
      }
      throw new Error('Kolejka nie przestaje planować natychmiastowych prób.');
    },
  };
}

test('ponawia pobranie JPEG po timeout i kończy jednym uploadem', async (t) => {
  let attempts = 0;
  const harness = createHarness(t, {
    captureSnapshot: async ({attempt}) => {
      attempts += 1;
      assert.equal(attempt, attempts);
      if (attempt === 1) throw new Error('Przekroczono czas.');
      return jpeg;
    },
  });
  harness.queue.enqueue(job());
  await harness.tick();
  assert.equal(harness.errors[0].willRetry, true);
  assert.equal(harness.errors[0].retryInMs, 2000);
  assert.equal(harness.uploads.length, 0);
  await harness.tick(1999);
  assert.equal(attempts, 1);
  await harness.tick(1);
  assert.equal(attempts, 2);
  assert.equal(harness.uploads.length, 1);
  assert.equal(harness.saved[0].attempt, 2);
  assert.equal(harness.queue.pendingCount, 0);
});

test('ponawia upload tego samego JPEG bez ponownego pobierania', async (t) => {
  const sent = [];
  const harness = createHarness(t, {
    uploadSnapshot: async ({snapshot}) => {
      sent.push(snapshot);
      if (sent.length === 1) throw new Error('Połączenie zerwane.');
      return {size: snapshot.length};
    },
  });
  harness.queue.enqueue(job());
  await harness.tick();
  await harness.tick(2000);
  assert.equal(harness.captures.length, 1);
  assert.equal(sent.length, 2);
  assert.strictEqual(sent[0], sent[1]);
  assert.equal(harness.saved.length, 1);
});

test('nie duplikuje zdjęcia po scaleniu ani po udanym zapisie', async (t) => {
  const harness = createHarness(t);
  assert.equal(harness.queue.enqueue(job()), 'queued');
  assert.equal(harness.queue.enqueue(job()), 'duplicate');
  await harness.tick();
  assert.equal(harness.queue.enqueue(job()), 'duplicate');
  await harness.tick(10000);
  assert.equal(harness.captures.length, 1);
  assert.equal(harness.uploads.length, 1);
});

test('oczekiwanie na retry nie blokuje zdjęcia innej kamery', async (t) => {
  const order = [];
  const harness = createHarness(t, {
    uploadSnapshot: async ({cameraId}) => {
      order.push(cameraId);
      if (order.length === 1) throw new Error('Chwilowy błąd.');
      return {};
    },
  });
  harness.queue.enqueue(job());
  harness.queue.enqueue(job('event-2', 'camera-2'));
  await harness.tick();
  assert.deepEqual(order, ['camera-1', 'camera-2']);
  await harness.tick(2000);
  assert.deepEqual(order, ['camera-1', 'camera-2', 'camera-1']);
});

test('wykonuje tylko jedną operację zdjęcia naraz', async (t) => {
  let release;
  let captures = 0;
  const pending = new Promise((resolve) => { release = resolve; });
  const harness = createHarness(t, {
    captureSnapshot: async () => {
      captures += 1;
      return captures === 1 ? pending : jpeg;
    },
  });
  harness.queue.enqueue(job());
  harness.queue.enqueue(job('event-2', 'camera-2'));
  await harness.tick();
  assert.equal(captures, 1);
  assert.equal(harness.uploads.length, 0);
  release(jpeg);
  await harness.tick();
  assert.equal(captures, 2);
  assert.equal(harness.uploads.length, 2);
});

for (const statusCode of [408, 429, 500]) {
  test(`ponawia przejściowy błąd HTTP ${statusCode}`, async (t) => {
    let attempts = 0;
    const harness = createHarness(t, {
      uploadSnapshot: async () => {
        if (++attempts === 1) throw Object.assign(new Error('HTTP'), {statusCode});
        return {};
      },
    });
    harness.queue.enqueue(job());
    await harness.tick();
    await harness.tick(2000);
    assert.equal(attempts, 2);
    assert.equal(harness.saved.length, 1);
  });
}

test('nie ponawia odmowy uprawnień HTTP 403', async (t) => {
  let attempts = 0;
  const harness = createHarness(t, {
    uploadSnapshot: async () => {
      attempts += 1;
      throw Object.assign(new Error('Forbidden'), {statusCode: 403});
    },
  });
  harness.queue.enqueue(job());
  await harness.tick();
  await harness.tick(10000);
  assert.equal(attempts, 1);
  assert.equal(harness.errors[0].willRetry, false);
  assert.equal(harness.queue.pendingCount, 0);
});

test('kończy po trzech nieudanych próbach i zwalnia miejsce', async (t) => {
  let attempts = 0;
  const harness = createHarness(t, {
    captureSnapshot: async () => {
      attempts += 1;
      throw new Error('Kamera niedostępna.');
    },
  });
  harness.queue.enqueue(job());
  await harness.tick();
  await harness.tick(2000);
  await harness.tick(5000);
  await harness.tick(10000);
  assert.equal(attempts, 3);
  assert.equal(harness.errors[2].willRetry, false);
  assert.equal(harness.queue.pendingCount, 0);
  assert.equal(harness.timers.size, 0);
});

test('odrzuca uszkodzony lub za duży JPEG przed uploadem', async (t) => {
  for (const snapshot of [Buffer.from('not jpeg'), jpeg]) {
    const harness = createHarness(t, {
      maximumBytes: 4,
      captureSnapshot: async () => snapshot,
    });
    harness.queue.enqueue(job());
    await harness.tick();
    await harness.tick(10000);
    assert.equal(harness.uploads.length, 0);
    assert.equal(harness.errors.length, 1);
    assert.equal(harness.errors[0].willRetry, false);
  }
});

test('anulowanie kamery przerywa aktywne pobieranie i usuwa retry', async (t) => {
  let activeSignal;
  let rejectCapture;
  const pending = new Promise((_, reject) => { rejectCapture = reject; });
  const harness = createHarness(t, {
    captureSnapshot: ({signal}) => {
      activeSignal = signal;
      signal.addEventListener('abort', () => rejectCapture(new Error('Anulowano.')));
      return pending;
    },
  });
  harness.queue.enqueue(job());
  harness.queue.enqueue(job('event-2'));
  await harness.tick();
  harness.queue.cancelCamera('camera-1');
  await harness.tick(10000);
  assert.equal(activeSignal.aborted, true);
  assert.equal(harness.uploads.length, 0);
  assert.equal(harness.errors.length, 0);
  assert.equal(harness.queue.pendingCount, 0);
});

test('zamknięcie przerywa upload i nie planuje ponownych prób', async (t) => {
  let signal;
  let rejectUpload;
  const harness = createHarness(t, {
    uploadSnapshot: (request) => {
      signal = request.signal;
      return new Promise((_, reject) => { rejectUpload = reject; });
    },
  });
  harness.queue.enqueue(job());
  await harness.tick();
  harness.queue.close();
  rejectUpload(new Error('Anulowano.'));
  await harness.tick(10000);
  assert.equal(signal.aborted, true);
  assert.equal(harness.errors.length, 0);
  assert.equal(harness.queue.pendingCount, 0);
  assert.equal(harness.queue.enqueue(job()), 'closed');
});

test('odrzuca nadmiar zadań i usuwa wyłączone kamery', async (t) => {
  const harness = createHarness(t, {maximumJobs: 2});
  harness.queue.enqueue(job());
  harness.queue.enqueue(job('event-2', 'camera-2'));
  assert.equal(harness.queue.enqueue(job('event-3', 'camera-3')), 'full');
  harness.queue.retainCameras(['camera-2']);
  await harness.tick();
  assert.equal(harness.uploads.length, 1);
  assert.equal(harness.uploads[0].cameraId, 'camera-2');
});

test('błąd logowania po sukcesie nie powtarza uploadu', async (t) => {
  const harness = createHarness(t, {
    onSaved: () => { throw new Error('Logger failed.'); },
  });
  harness.queue.enqueue(job());
  await harness.tick(10000);
  assert.equal(harness.uploads.length, 1);
  assert.equal(harness.queue.enqueue(job()), 'duplicate');
  assert.equal(harness.errors.length, 0);
});
