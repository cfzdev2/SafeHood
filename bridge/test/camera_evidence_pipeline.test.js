'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const {randomUUID} = require('node:crypto');
const {execFileSync} = require('node:child_process');
const {CameraFrameCache, JpegFrameParser} = require('../camera_frame_cache');
const {CameraEvidencePipeline, DurableSnapshotQueue} = require('../camera_evidence_pipeline');
const {EventVideoBuffer} = require('../ai/event_video_buffer');

const jpeg = Buffer.from([255, 216, 1, 2, 255, 217]);
const waitFor = async (condition, timeout = 7000) => {
  const end = Date.now() + timeout;
  while (!condition()) {
    if (Date.now() > end) throw new Error('Oczekiwany wynik nie nadszedł.');
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
};

test('a bounded parser and cache discard old or broken camera frames', () => {
  const output = [];
  const parser = new JpegFrameParser((frame) => output.push(frame), 20);
  parser.add(jpeg.subarray(0, 3));
  parser.add(Buffer.concat([jpeg.subarray(3), jpeg]));
  assert.deepEqual(output, [jpeg, jpeg]);
  parser.add(Buffer.concat([Buffer.from([255, 216]), Buffer.alloc(21)]));
  assert.equal(parser.pending.length, 0);
  let now = 10000;
  const cache = new CameraFrameCache({now: () => now});
  cache.snapshot('camera', jpeg);
  assert.deepEqual(cache.read('camera').jpeg, jpeg);
  now += 4000;
  assert.equal(cache.read('camera'), null);
  cache.lost('camera');
  assert.equal(cache.read('camera', 10000), null);
});

test('ordinary motion shares a durable id for its original frame and video', async () => {
  const calls = [];
  const id = randomUUID();
  const cache = new CameraFrameCache({now: () => 10000});
  cache.snapshot('robot', jpeg);
  const pipeline = new CameraEvidencePipeline({frameCache: cache, now: () => 10000,
    eventOutbox: {enqueue: async (event) => {
      calls.push(event);
      cache.snapshot('robot', Buffer.from([255, 216, 9, 255, 217]));
      return {externalEventId: id};
    }},
    snapshotQueue: {enqueue: async (photo) => calls.push(photo)},
    recordingManager: {capture: (camera, clip) => calls.push({camera, ...clip})}});
  await pipeline.ingest({id: 'robot', motionDetectionEnabled: true},
    {type: 'motion', source: 'bridge-motion'});
  assert.equal(calls[0].source, 'bridge-motion');
  assert.equal(calls[1].externalEventId, id);
  assert.equal(calls[2].externalEventId, id);
  assert.deepEqual(calls[2].jpeg, jpeg);
  assert.ok(!JSON.stringify(calls).includes('rtsp'));
});

test('a photo survives a receiver restart and retry without recapturing', async (t) => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'safehood-photo-'));
  t.after(() => fs.rm(directory, {recursive: true, force: true}));
  let failed = false;
  let uploaded;
  const eventId = 'event-1';
  const externalEventId = randomUUID();
  const first = new DurableSnapshotQueue({directory, retryDelaysMs: [10000],
    upload: async () => { failed = true; throw new Error('offline'); }});
  await first.start();
  await first.enqueue({cameraId: 'robot', externalEventId,
    occurredAtMillis: Date.now(), capturedAtMillis: Date.now(), jpeg});
  await waitFor(() => failed);
  await first.close();
  const second = new DurableSnapshotQueue({directory, now: () => Date.now() + 20000,
    upload: async (payload) => {
      uploaded = payload;
      return {ok: true, eventId, externalEventId,
        snapshotPath: `users/owner/cameraEvents/${eventId}/snapshot.jpg`};
    }});
  t.after(() => second.close());
  await second.start();
  await waitFor(() => second.pendingCount === 0);
  assert.deepEqual(Buffer.from(uploaded.jpegBase64, 'base64'), jpeg);
  assert.equal(uploaded.externalEventId, externalEventId);
});

test('one real FFmpeg connection provides motion samples, JPEGs and recording segments',
  {timeout: 18000}, async (t) => {
    const root = await fs.mkdtemp(path.join(os.tmpdir(), 'safehood-media-worker-'));
    const input = path.join(root, 'input.mp4');
    execFileSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y',
      '-f', 'lavfi', '-i', 'testsrc2=size=320x240:rate=10:duration=5',
      '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', input]);
    const samples = [];
    const images = [];
    const errors = [];
    const buffer = new EventVideoBuffer({input, directory: path.join(root, 'buffer'),
      workDirectory: path.join(root, 'work'), emitFrames: true,
      onSample: (frame) => samples.push(frame), onSnapshot: (photo) => images.push(photo),
      onError: (error) => errors.push(error)});
    t.after(async () => { await buffer.stop(); await fs.rm(root, {recursive: true, force: true}); });
    await buffer.start();
    await waitFor(() => samples.length >= 2 && images.length >= 2 && buffer.latestMediaSeconds >= 2);
    assert.equal(samples[0].length, 64 * 36);
    assert.equal(images[0].readUInt16BE(0), 0xffd8);
    assert.notDeepEqual(images[0], images[1]);
    assert.deepEqual(errors, []);
  });

test('concurrent camera consumers start only one buffer and closing cancels a pending start', async (t) => {
  const {EventRecordingManager} = require('../ai/event_recording_manager');
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'safehood-concurrent-buffer-'));
  t.after(() => fs.rm(directory, {recursive: true, force: true}));
  let starts = 0;
  let stops = 0;
  let release;
  const wait = new Promise((resolve) => { release = resolve; });
  const manager = new EventRecordingManager({directory,
    uploadQueue: {pendingCount: 0}, bufferFactory: ({input}) => ({
      input, running: true,
      start: async () => { starts++; await wait; },
      stop: async () => { stops++; },
    })});
  const first = manager.syncCamera('camera', 'one-input', true);
  const second = manager.syncCamera('camera', 'one-input', true);
  await new Promise((resolve) => setTimeout(resolve, 20));
  const closing = manager.close();
  release();
  await Promise.all([first, second, closing]);
  assert.equal(starts, 1);
  assert.equal(stops, 1);
  assert.equal(manager.bufferCount, 0);
});
