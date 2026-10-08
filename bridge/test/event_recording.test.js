'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const {EventEmitter} = require('node:events');
const {PassThrough} = require('node:stream');
const {randomUUID} = require('node:crypto');
const {EventVideoBuffer, buildBufferArguments, parseSegmentIndex} = require('../ai/event_video_buffer');
const {EventRecordingManager} = require('../ai/event_recording_manager');

test('RTSP używa TCP, ma ograniczony bufor, H.264 i nie nagrywa audio', () => {
  const args = buildBufferArguments({input: 'rtsp://camera/live'});
  assert.equal(args[args.indexOf('-rtsp_transport') + 1], 'tcp');
  assert.equal(args[args.indexOf('-segment_wrap') + 1], '16');
  assert.equal(args[args.indexOf('-segment_list_size') + 1], '12');
  assert.equal(args[args.indexOf('-c:v') + 1], 'libx264');
  assert.ok(args.includes('-an'));
  assert.ok(!args.includes('-re'));
  assert.ok(buildBufferArguments({input: 'sample.mp4'}).includes('-re'));
  assert.throws(() => buildBufferArguments({input: 'bad\nsource'}));
});

test('indeks obsługuje zawinięcie bufora i blokuje ścieżki poza nim', () => {
  const rows = parseSegmentIndex('segment_15.mp4,30.0,32.0\nsegment_00.mp4,32.0,34.0\n');
  assert.equal(rows[1].start, 32);
  for (const invalid of ['../secret,0,2', 'segment_16.mp4,0,2',
    'segment_00.mp4,0,999', 'segment_00.mp4,4,6\nsegment_01.mp4,2,4']) {
    assert.throws(() => parseSegmentIndex(invalid));
  }
});

async function bufferHarness(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'safehood-buffer-'));
  let now = 1000000;
  const captures = [];
  const cancellations = [];
  const errors = [];
  const child = new EventEmitter();
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();
  child.kill = () => { queueMicrotask(() => child.emit('close', 0)); return true; };
  const buffer = new EventVideoBuffer({input: 'rtsp://user:secret@camera/live',
    directory: path.join(root, 'buffer'), workDirectory: path.join(root, 'work'),
    postbufferSeconds: 2, now: () => now, spawnProcess: () => child,
    onCapture: (capture) => captures.push(capture),
    onCancelled: (capture) => cancellations.push(capture), onError: (error) => errors.push(error)});
  t.after(async () => { await buffer.stop(); await fs.rm(root, {recursive: true, force: true}); });
  await buffer.start();
  clearInterval(buffer._timer);
  buffer._timer = null;
  return {root, buffer, captures, cancellations, errors, advance: (ms) => { now += ms; },
    trigger: () => buffer.capture({externalEventId: randomUUID(), occurredAtMillis: now}),
    async segments(ranges) {
      for (const [start, end] of ranges) {
        const name = `segment_${String((start / 2) % 16).padStart(2, '0')}.mp4`;
        await fs.writeFile(path.join(buffer.directory, name), Buffer.alloc(256, start));
      }
      await fs.writeFile(path.join(buffer.directory, 'index.csv'), ranges.map(([start, end]) =>
        `segment_${String((start / 2) % 16).padStart(2, '0')}.mp4,${start},${end}\n`).join(''));
      await buffer._poll();
    }};
}

test('nowa sesja zapisuje krótszy prebufor zamiast deklarować brakujące 5 sekund', async (t) => {
  const h = await bufferHarness(t);
  await h.segments([[0, 2]]);
  assert.equal(h.trigger(), 'queued');
  assert.equal(h.trigger(), 'coalesced');
  await h.buffer._io;
  h.advance(2000);
  await h.segments([[0, 2], [2, 4]]);
  assert.equal(h.captures.length, 1);
  assert.equal(h.captures[0].prebufferMillis, 2000);
  assert.equal(h.captures[0].durationSeconds, 4);
});

test('segment skopiowany do zdarzenia przetrwa nadpisanie pierścienia', async (t) => {
  const h = await bufferHarness(t);
  await h.segments([[0, 2], [2, 4], [4, 6]]);
  h.trigger();
  await h.buffer._io;
  const capture = h.buffer._capture;
  const copied = await fs.readFile(path.join(capture.directory, 'part_0.mp4'));
  await fs.writeFile(path.join(h.buffer.directory, 'segment_00.mp4'), Buffer.alloc(256, 99));
  assert.deepEqual(await fs.readFile(path.join(capture.directory, 'part_0.mp4')), copied);
  h.advance(2000);
  await h.segments([[2, 4], [4, 6], [6, 8]]);
  assert.equal(h.captures[0].prebufferMillis, 5000);
  assert.equal(h.captures[0].durationSeconds, 7);
});

test('krótki odczyt CSV nie anuluje nagrania, brak ciągłego obrazu je odrzuca', async (t) => {
  const h = await bufferHarness(t);
  await h.segments([[0, 2]]);
  h.trigger();
  await h.buffer._io;
  await fs.writeFile(path.join(h.buffer.directory, 'index.csv'), 'segment_');
  await h.buffer._poll();
  assert.ok(h.buffer._capture);
  h.advance(4000);
  await h.segments([[0, 2], [4, 6]]);
  await h.buffer._poll(true);
  assert.equal(h.captures.length, 0);
  assert.equal(h.cancellations.length, 1);
  assert.match(h.errors[0].message, /ciągłego obrazu/);
});

test('wyłączenie kamery usuwa niedokończony bufor i przechwytywanie', async (t) => {
  const h = await bufferHarness(t);
  await h.segments([[0, 2]]);
  h.trigger();
  await h.buffer._io;
  const directory = h.buffer._capture.directory;
  await h.buffer.stop();
  assert.equal(h.cancellations.length, 1);
  await assert.rejects(fs.stat(directory), {code: 'ENOENT'});
  await assert.rejects(fs.stat(h.buffer.directory), {code: 'ENOENT'});
});

async function managerHarness(t, options = {}) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'safehood-recorder-'));
  const buffers = [];
  const queued = [];
  const errors = [];
  const uploadQueue = {pendingCount: 0, maximumJobs: 16,
    enqueue: async (job) => queued.push(job)};
  const manager = new EventRecordingManager({directory, uploadQueue,
    onError: (error) => errors.push(error),
    bufferFactory: (settings) => {
      const buffer = {input: settings.input, running: false, settings, pending: null,
        start: async () => { buffer.running = true; },
        stop: async () => {
          buffer.running = false;
          if (buffer.pending) { settings.onCancelled(buffer.pending); buffer.pending = null; }
        },
        capture: (job) => {
          if (buffer.pending) return 'coalesced';
          buffer.pending = job;
          return 'queued';
        }};
      buffers.push(buffer);
      return buffer;
    },
    encode: async ({capture}) => path.join(capture.directory, 'clip.mp4'), ...options});
  t.after(async () => { await manager.close(); await fs.rm(directory, {recursive: true, force: true}); });
  return {directory, manager, buffers, queued, errors, uploadQueue,
    async finish(buffer) {
      const capture = {...buffer.pending, directory: path.join(directory, randomUUID()),
        parts: [], prebufferMillis: 5000};
      await fs.mkdir(capture.directory);
      buffer.pending = null;
      return buffer.settings.onCapture(capture);
    }};
}

test('nagrywanie jest opt-in; zmiana ustawienia uruchamia i zatrzymuje bufor', async (t) => {
  const h = await managerHarness(t);
  await h.manager.syncCamera('camera-1', 'rtsp://camera/live', false);
  assert.equal(h.buffers.length, 0);
  await h.manager.syncCamera('camera-1', 'rtsp://camera/live', true);
  await h.manager.syncCamera('camera-1', 'rtsp://camera/live', true);
  assert.equal(h.buffers.length, 1);
  await h.manager.syncCamera('camera-1', 'rtsp://camera/changed', true);
  assert.equal(h.buffers[0].running, false);
  assert.equal(h.buffers.length, 2);
  await h.manager.syncCamera('camera-1', 'rtsp://camera/changed', false);
  assert.equal(h.buffers[1].running, false);
});

test('gotowy film trafia do trwałej kolejki z UUID wykrycia', async (t) => {
  const h = await managerHarness(t);
  await h.manager.syncCamera('camera-1', 'source', true);
  const job = {externalEventId: randomUUID(), occurredAtMillis: Date.now()};
  assert.equal(h.manager.capture('camera-1', job), 'queued');
  assert.equal(h.manager.capture('camera-1', job), 'coalesced');
  await h.finish(h.buffers[0]);
  assert.equal(h.queued.length, 1);
  assert.equal(h.queued[0].externalEventId, job.externalEventId);
  assert.equal(h.manager._captures, 0);
  await assert.rejects(fs.stat(path.dirname(h.queued[0].filename)), {code: 'ENOENT'});
});

test('wolne kodowanie nie blokuje następnego przechwytywania i koduje jeden film naraz', async (t) => {
  let release;
  let started;
  let encodings = 0;
  const gate = new Promise((resolve) => { release = resolve; });
  const firstStarted = new Promise((resolve) => { started = resolve; });
  const h = await managerHarness(t, {encode: async ({capture}) => {
    encodings++;
    started();
    await gate;
    return path.join(capture.directory, 'clip.mp4');
  }});
  await h.manager.syncCamera('camera-1', 'source', true);
  h.manager.capture('camera-1', {externalEventId: randomUUID(), occurredAtMillis: Date.now()});
  const first = h.finish(h.buffers[0]);
  await firstStarted;
  assert.equal(encodings, 1);
  assert.equal(h.manager.capture('camera-1',
    {externalEventId: randomUUID(), occurredAtMillis: Date.now()}), 'queued');
  const second = h.finish(h.buffers[0]);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(encodings, 1);
  release();
  await Promise.all([first, second]);
  assert.equal(encodings, 2);
  assert.equal(h.queued.length, 2);
});

test('pełna kolejka ogranicza liczbę przechwytywań', async (t) => {
  const h = await managerHarness(t, {maximumCaptures: 1});
  await h.manager.syncCamera('camera-1', 'source', true);
  await h.manager.syncCamera('camera-2', 'source', true);
  const job = {externalEventId: randomUUID(), occurredAtMillis: Date.now()};
  assert.equal(h.manager.capture('camera-1', job), 'queued');
  assert.equal(h.manager.capture('camera-2', job), 'full');
  await h.manager.stopCamera('camera-1');
  assert.equal(h.manager.capture('camera-2', job), 'queued');
});

test('błąd FFmpeg nie blokuje sesji AI; zamknięcie anuluje kodowanie', async (t) => {
  const failed = await managerHarness(t, {bufferFactory: () => { throw new Error('Brak FFmpeg.'); }});
  await failed.manager.syncCamera('camera-1', 'source', true);
  assert.equal(failed.errors.length, 1);
  const h = await managerHarness(t, {encode: ({signal}) => new Promise((_, reject) => {
    signal.addEventListener('abort', () => reject(new Error('Anulowano.')), {once: true});
  })});
  await h.manager.syncCamera('camera-1', 'source', true);
  h.manager.capture('camera-1', {externalEventId: randomUUID(), occurredAtMillis: Date.now()});
  const encoding = h.finish(h.buffers[0]);
  await new Promise((resolve) => setImmediate(resolve));
  await h.manager.close();
  await encoding;
  assert.equal(h.queued.length, 0);
  assert.equal(h.manager._captures, 0);
});
