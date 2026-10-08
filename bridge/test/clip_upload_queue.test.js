'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const {randomUUID} = require('node:crypto');
const {ClipUploadQueue, MAX_CLIP_BYTES} = require('../ai/clip_upload_queue');

const media = Buffer.alloc(1024, 42);
const ack = (job) => ({ok: true, externalEventId: job.externalEventId,
  eventId: 'event-1', clipPath: 'users/owner-1/cameraEvents/event-1/clip.mp4',
  size: media.length, durationMillis: 15000, prebufferMillis: 5000});
const blocked = (_job, signal) => new Promise((_, reject) => {
  const abort = () => reject(new Error('Anulowano upload.'));
  if (signal.aborted) abort(); else signal.addEventListener('abort', abort, {once: true});
});

async function waitFor(predicate) {
  const deadline = Date.now() + 3000;
  while (!await predicate()) {
    if (Date.now() > deadline) assert.fail('Operacja kolejki nie zakończyła się.');
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

async function harness(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'safehood-clips-'));
  const directory = path.join(root, 'uploads');
  const filename = path.join(root, 'input.mp4');
  await fs.writeFile(filename, media);
  const queues = [];
  t.after(async () => {
    for (const queue of queues) await queue.close();
    await fs.rm(root, {recursive: true, force: true});
  });
  return {root, directory, filename,
    job: (overrides = {}) => ({filename, externalEventId: randomUUID(), cameraId: 'camera-1',
      occurredAtMillis: Date.now(), prebufferMillis: 5000, ...overrides}),
    queue: (options = {}) => {
      const queue = new ClipUploadQueue({directory, upload: blocked, retryDelaysMs: [1], ...options});
      queues.push(queue);
      return queue;
    }};
}

test('zapisuje MP4 i metadane przed potwierdzeniem kolejki, bez adresu RTSP', async (t) => {
  const h = await harness(t);
  const queue = h.queue();
  const job = h.job({input: 'rtsp://user:password@camera/live'});
  await queue.enqueue(job);
  const bytes = await fs.readFile(path.join(h.directory, `${job.externalEventId}.mp4`));
  assert.deepEqual(bytes, media);
  const metadata = await fs.readFile(path.join(h.directory, `${job.externalEventId}.json`), 'utf8');
  assert.equal(JSON.parse(metadata).payload.externalEventId, job.externalEventId);
  assert.doesNotMatch(metadata, /password|rtsp:|mp4Base64/);
  assert.equal(await queue.enqueue(job), 'duplicate');
  assert.equal(queue.pendingCount, 1);
});

test('po restarcie odtwarza ten sam plik, UUID i moment wykrycia', async (t) => {
  const h = await harness(t);
  let requests = 0;
  const first = h.queue({upload: (...args) => { requests++; return blocked(...args); }});
  const job = h.job();
  await first.enqueue(job);
  await waitFor(() => requests === 1);
  await first.close();
  await fs.rm(h.filename);
  const saved = [];
  const restored = [];
  const second = h.queue({upload: async (payload) => {
    assert.equal(payload.externalEventId, job.externalEventId);
    assert.equal(payload.occurredAtMillis, job.occurredAtMillis);
    assert.deepEqual(Buffer.from(payload.mp4Base64, 'base64'), media);
    return ack(payload);
  }, onRestored: (count) => restored.push(count), onSaved: (value) => saved.push(value)});
  await second.start();
  await waitFor(() => saved.length === 1);
  assert.deepEqual(restored, [1]);
  assert.equal(second.pendingCount, 0);
  await waitFor(async () => !(await fs.readdir(h.directory)).some((name) => name.endsWith('.mp4')));
});

test('utrata ACK ponawia te same bajty i nie tworzy drugiego filmu', async (t) => {
  const h = await harness(t);
  const requests = [];
  const files = new Map();
  const saved = [];
  const queue = h.queue({upload: async (job) => {
    requests.push(job);
    if (!files.has(job.externalEventId)) {
      files.set(job.externalEventId, job.mp4Base64);
      throw Object.assign(new Error('Utracono ACK.'), {statusCode: 503});
    }
    return {...ack(job), alreadyExists: true};
  }, onSaved: (value) => saved.push(value)});
  await queue.enqueue(h.job());
  await waitFor(() => saved.length === 1);
  assert.equal(requests.length, 2);
  assert.deepEqual(requests[0], requests[1]);
  assert.equal(files.size, 1);
  assert.equal(saved[0].attempts, 2);
});

test('HTTP 403 kończy zadanie i usuwa lokalny film', async (t) => {
  const h = await harness(t);
  const errors = [];
  let uploads = 0;
  const queue = h.queue({upload: async () => {
    uploads++;
    throw Object.assign(new Error('Forbidden'), {statusCode: 403});
  }, onError: (value) => errors.push(value)});
  const job = h.job();
  await queue.enqueue(job);
  await waitFor(() => queue.pendingCount === 0);
  await waitFor(async () => !(await fs.readdir(h.directory)).includes(`${job.externalEventId}.mp4`));
  assert.equal(uploads, 1);
  assert.equal(errors[0].willRetry, false);
});

test('upływ retencji po restarcie usuwa film bez uploadu', async (t) => {
  const h = await harness(t);
  let now = Date.now();
  const first = h.queue({now: () => now, maximumAgeMs: 1000});
  await first.enqueue(h.job());
  await first.close();
  now += 1001;
  const errors = [];
  const second = h.queue({now: () => now, maximumAgeMs: 1000,
    upload: () => assert.fail('Film wygasł.'), onError: (value) => errors.push(value)});
  await second.start();
  await waitFor(() => second.pendingCount === 0);
  assert.match(errors[0].error.message, /czas przechowywania/);
});

for (const corruption of ['missing', 'changed']) {
  test(`uszkodzenie lokalnego filmu (${corruption}) nie wysyła obcych bajtów`, async (t) => {
    const h = await harness(t);
    const first = h.queue();
    const job = h.job();
    await first.enqueue(job);
    await first.close();
    const filename = path.join(h.directory, `${job.externalEventId}.mp4`);
    if (corruption === 'missing') await fs.rm(filename);
    else await fs.writeFile(filename, Buffer.alloc(media.length, 99));
    const second = h.queue({upload: () => assert.fail('Film jest uszkodzony.')});
    await second.start();
    await waitFor(() => second.pendingCount === 0);
  });
}

test('limit dysku odrzuca nadmiar filmów i za duży plik', async (t) => {
  const h = await harness(t);
  const queue = h.queue({maximumJobs: 1});
  const first = h.job();
  await queue.enqueue(first);
  assert.equal(await queue.enqueue(first), 'duplicate');
  await assert.rejects(queue.enqueue(h.job()), /pełna/);
  assert.equal((await fs.readdir(h.directory)).filter((name) => name.endsWith('.mp4')).length, 1);
  await queue.close();
  const large = path.join(h.root, 'large.mp4');
  await fs.writeFile(large, Buffer.alloc(MAX_CLIP_BYTES + 1));
  const other = h.queue({directory: path.join(h.root, 'other')});
  await assert.rejects(other.enqueue(h.job({filename: large})), /Nieprawidłowy plik/);
  assert.deepEqual(await fs.readdir(other.directory), []);
});

test('usuwa osierocony film, zachowując gotowe zadania do wysłania', async (t) => {
  const h = await harness(t);
  await fs.mkdir(h.directory);
  await fs.writeFile(path.join(h.directory, `${randomUUID()}.mp4`), media);
  const queue = h.queue();
  await queue.start();
  assert.deepEqual(await fs.readdir(h.directory), []);
});

test('zamknięcie przerywa upload i pozostawia zadanie na dysku', async (t) => {
  const h = await harness(t);
  let signal;
  const queue = h.queue({upload: (job, value) => { signal = value; return blocked(job, value); }});
  const job = h.job();
  await queue.enqueue(job);
  await waitFor(() => signal !== undefined);
  await queue.close();
  assert.equal(signal.aborted, true);
  assert.equal(queue.pendingCount, 1);
  assert.ok((await fs.readdir(h.directory)).includes(`${job.externalEventId}.mp4`));
});

test('nieprawidłowe ACK nie usuwa zadania jako udanego uploadu', async (t) => {
  const h = await harness(t);
  const errors = [];
  const queue = h.queue({upload: async (job) => ({...ack(job), externalEventId: randomUUID()}),
    onSaved: () => assert.fail('Nieprawidłowe ACK.'), onError: (value) => errors.push(value)});
  await queue.enqueue(h.job());
  await waitFor(() => queue.pendingCount === 0);
  assert.match(errors[0].error.message, /Backend nie potwierdził/);
});

test('zamknięcie nieuruchomionej kolejki nie wymaga istniejącego katalogu', async (t) => {
  const h = await harness(t);
  const queue = h.queue();
  await queue.close();
  await assert.rejects(queue.enqueue(h.job()), /zamknięta/);
  await assert.rejects(fs.stat(h.directory), {code: 'ENOENT'});
});
