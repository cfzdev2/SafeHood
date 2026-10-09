'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const {AiEventOutbox} = require('../ai/event_outbox');
const {spawn} = require('node:child_process');
const {once} = require('node:events');

const payload = {cameraId: 'camera-1', type: 'person', source: 'local-ai',
  confidence: 0.9, occurredAt: '2026-10-06T19:00:00.000Z'};
const aiMetadata = {schemaVersion: 1, className: 'person', detectionCount: 3,
  firstSeenAt: '2026-10-06T18:59:59.000Z',
  lastSeenAt: '2026-10-06T19:00:00.000Z',
  modelId: 'yolox-nano-coco-c789161e'};
const acknowledgement = (event) => ({ok: true, externalEventId: event.externalEventId,
  eventId: 'backend-event', type: event.type, merged: false, occurrenceCount: 1,
  duplicate: false, snapshotRequired: true});
const nextTurn = () => new Promise((resolve) => setImmediate(resolve));

async function createHarness(t, options = {}) {
  const directory = options.directory ?? await fs.mkdtemp(path.join(os.tmpdir(), 'safehood-outbox-'));
  let time = Date.now();
  let timerId = 0;
  const timers = new Map();
  const sent = [];
  const errors = [];
  const completed = [];
  const restored = [];
  const queue = new AiEventOutbox({
    directory,
    deliver: async (event) => { sent.push(event); return acknowledgement(event); },
    now: () => time,
    setTimer: (callback, delay) => {
      const id = ++timerId;
      timers.set(id, {callback, time: time + delay});
      return id;
    },
    clearTimer: (id) => timers.delete(id),
    onError: (details) => errors.push(details),
    onDelivered: (details) => completed.push(details),
    onRestored: (count) => restored.push(count),
    ...options,
  });
  t.after(async () => { await queue.close(); await fs.rm(directory, {recursive: true, force: true}); });
  await queue.start();
  return {queue, directory, sent, errors, completed, restored,
    async tick(milliseconds = 0) {
      time += milliseconds;
      for (let count = 0; count < 100; count += 1) {
        await nextTurn();
        const ready = [...timers].find(([, timer]) => timer.time <= time);
        if (!ready) return;
        timers.delete(ready[0]);
        ready[1].callback();
        // Operacje dyskowe kończą się przed oceną następnego timera.
        if (queue._active) await queue._active;
      }
      assert.fail('Nieskończona pętla natychmiastowych prób.');
    },
  };
}

test('zapis na dysku kończy się przed potwierdzeniem enqueue', async (t) => {
  const h = await createHarness(t);
  const result = await h.queue.enqueue({...payload, input: 'rtsp://user:secret@camera/live'});
  const files = await fs.readdir(h.directory);
  assert.deepEqual(files, [`${result.externalEventId}.json`]);
  const contents = await fs.readFile(path.join(h.directory, files[0]), 'utf8');
  assert.doesNotMatch(contents, /rtsp|secret|user:/);
  assert.equal(h.sent.length, 0);
  await h.tick();
  assert.equal(h.sent.length, 1);
  assert.equal(h.queue.pendingCount, 0);
  assert.deepEqual(await fs.readdir(h.directory), []);
});

test('restart odtwarza ten sam identyfikator i czas zdarzenia', async (t) => {
  const first = await createHarness(t);
  const original = await first.queue.enqueue(payload);
  await first.queue.close();
  const second = await createHarness(t, {directory: first.directory});
  assert.deepEqual(second.restored, [1]);
  await second.tick();
  assert.equal(second.sent[0].externalEventId, original.externalEventId);
  assert.equal(second.sent[0].occurredAt, payload.occurredAt);
});

test('restart zachowuje zweryfikowane metadane AI', async (t) => {
  const first = await createHarness(t);
  await first.queue.enqueue({...payload, aiMetadata});
  await first.queue.close();
  const second = await createHarness(t, {directory: first.directory});
  await second.tick();
  assert.deepEqual(second.sent[0].aiMetadata, aiMetadata);
});

test('kolejka odrzuca obcą klasę i fałszywy model', async (t) => {
  const h = await createHarness(t);
  await assert.rejects(h.queue.enqueue({...payload, aiMetadata: {
    ...aiMetadata,
    className: 'truck',
  }}), /metadane/);
  await assert.rejects(h.queue.enqueue({...payload, aiMetadata: {
    ...aiMetadata,
    modelId: 'unknown-model',
  }}), /metadane/);
});

test('awaria backendu zachowuje plik i ponawia niezmieniony payload', async (t) => {
  const sent = [];
  const h = await createHarness(t, {deliver: async (event) => {
    sent.push({...event});
    if (sent.length === 1) throw new Error('Backend offline.');
    return acknowledgement(event);
  }});
  await h.queue.enqueue(payload);
  await h.tick();
  assert.equal((await fs.readdir(h.directory)).length, 1);
  assert.equal(h.errors[0].willRetry, true);
  await h.tick(1000);
  assert.deepEqual(sent[0], sent[1]);
  assert.equal(h.queue.pendingCount, 0);
});

test('kolejne zdarzenie trafia na dysk podczas zablokowanej wysyłki', async (t) => {
  let rejectSend;
  const h = await createHarness(t, {deliver: (_event, signal) => new Promise((_, reject) => {
    rejectSend = reject;
    signal.addEventListener('abort', () => reject(new Error('Anulowano.')));
  })});
  await h.queue.enqueue(payload);
  // Uruchamiamy drain bez oczekiwania na zatrzymane żądanie HTTP.
  void h.tick();
  while (!rejectSend) await nextTurn();
  await h.queue.enqueue({...payload, type: 'vehicle'});
  assert.equal(h.queue.pendingCount, 2);
  assert.equal((await fs.readdir(h.directory)).length, 2);
  await h.queue.close();
});

test('potwierdzone zdarzenie nie jest wysyłane ponownie po błędzie unlink', async (t) => {
  let fail = true;
  const fileSystem = {...fs, unlink: async (filename) => {
    if (filename.endsWith('.json') && fail) {
      fail = false;
      throw Object.assign(new Error('Dysk zajęty.'), {code: 'EBUSY'});
    }
    return fs.unlink(filename);
  }};
  const h = await createHarness(t, {fileSystem});
  await h.queue.enqueue(payload);
  await h.tick();
  assert.equal(h.sent.length, 1);
  await h.queue.close();
  const restarted = await createHarness(t, {directory: h.directory});
  await restarted.tick(1000);
  assert.equal(restarted.sent.length, 0);
  assert.equal(restarted.completed.length, 1);
});

test('błąd zapisu nie potwierdza enqueue i nie wysyła zdarzenia', async (t) => {
  const h = await createHarness(t, {fileSystem: {...fs, rename: async () => {
    throw Object.assign(new Error('Dysk pełny.'), {code: 'ENOSPC'});
  }}});
  await assert.rejects(h.queue.enqueue(payload), /Dysk pełny/);
  assert.equal(h.queue.pendingCount, 0);
  assert.equal(h.sent.length, 0);
});

test('HTTP 403 odkłada plik do kontroli, a HTTP 409 zachowuje retry', async (t) => {
  for (const statusCode of [403, 409]) {
    const h = await createHarness(t, {deliver: async () => {
      throw Object.assign(new Error('Odmowa.'), {statusCode});
    }});
    await h.queue.enqueue(payload);
    await h.tick();
    assert.equal(h.queue.pendingCount, statusCode === 409 ? 1 : 0);
    const files = await fs.readdir(h.directory);
    assert.equal(files.length, 1);
    assert.equal(files[0].endsWith('.rejected'), statusCode === 403);
  }
});

test('uszkodzony plik zostaje zachowany i nie blokuje poprawnych zdarzeń', async (t) => {
  const h = await createHarness(t);
  await h.queue.enqueue(payload);
  await h.queue.close();
  await fs.writeFile(path.join(h.directory, 'broken.json'), '{');
  const restored = await createHarness(t, {directory: h.directory});
  assert.equal(restored.queue.pendingCount, 1);
  assert.equal(restored.errors[0].phase, 'load');
  await restored.tick();
  assert.equal(restored.sent.length, 1);
  assert.ok((await fs.readdir(h.directory)).some((file) => file.endsWith('.invalid')));
});

test('wyłączone AI jednej kamery nie blokuje kolejki drugiej', async (t) => {
  const h = await createHarness(t, {deliver: async (event) => {
    if (event.cameraId === 'camera-1') {
      throw Object.assign(new Error('AI wyłączone.'), {statusCode: 409});
    }
    return acknowledgement(event);
  }});
  await h.queue.enqueue(payload);
  await h.queue.enqueue({...payload, cameraId: 'camera-2'});
  await h.tick();
  assert.equal(h.queue.pendingCount, 1);
  assert.equal(h.completed[0].payload.cameraId, 'camera-2');
});

test('kolejka ogranicza nowe wpisy i zachowuje kolejność po restarcie', async (t) => {
  const h = await createHarness(t, {maximumJobs: 2});
  await h.queue.enqueue(payload);
  await h.queue.enqueue({...payload, type: 'vehicle'});
  await assert.rejects(h.queue.enqueue(payload), /pełna/);
  await h.queue.close();
  const restored = await createHarness(t, {directory: h.directory});
  await restored.tick();
  assert.deepEqual(restored.sent.map((event) => event.type), ['person', 'vehicle']);
});

test('nagłe zabicie procesu zachowuje zatwierdzony wpis kolejki', {timeout: 5000}, async (t) => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'safehood-killed-outbox-'));
  const script = `
    setInterval(() => {}, 1000);
    const {AiEventOutbox} = require(process.argv[2]);
    const queue = new AiEventOutbox({directory: process.argv[1],
      deliver: () => new Promise(() => {})});
    queue.enqueue(${JSON.stringify(payload)}).then((result) => process.send(result));
  `;
  const child = spawn(process.execPath, ['-e', script, directory,
    require.resolve('../ai/event_outbox')], {stdio: ['ignore', 'ignore', 'inherit', 'ipc']});
  t.after(async () => {
    child.kill('SIGKILL');
    await fs.rm(directory, {recursive: true, force: true});
  });
  const [message] = await once(child, 'message');
  const exited = once(child, 'exit');
  child.kill('SIGKILL');
  await exited;
  const restored = await createHarness(t, {directory});
  await restored.tick();
  assert.equal(restored.sent[0].externalEventId, message.externalEventId);
});
