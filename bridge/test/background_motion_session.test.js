'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const test = require('node:test');
const {spawnSync} = require('node:child_process');
const {setImmediate} = require('node:timers/promises');
const {BackgroundMotionSession} = require('../background_motion_session');
const {FfmpegFrameSource} = require('../ai/ffmpeg_frame_source');

test('Bridge detects a motion episode without a phone and stops accepting frames', async () => {
  const statuses = [];
  const detections = [];
  let source;
  let stops = 0;
  const session = new BackgroundMotionSession({
    camera: {id: 'camera-1'},
    resolve: async () => 'rtsp://192.168.1.9/test',
    createSource: (options) => {
      source = options;
      return {start() {}, stop: async () => { stops++; }};
    },
    onStatusChanged: (_, status) => statuses.push(status),
    onDetection: (_, data) => detections.push(data),
  });
  session.start();
  await setImmediate();
  const normal = Buffer.alloc(64 * 36, 90);
  const changed = Buffer.from(normal);
  changed.fill(180, 53, 420);
  source.onFrame(normal);
  source.onFrame(Buffer.alloc(64 * 36, 120)); // A global exposure change.
  source.onFrame(normal);
  source.onFrame(changed);
  await setImmediate();
  assert.equal(detections.length, 0);
  source.onFrame(changed);
  source.onFrame(normal);
  source.onFrame(changed);
  await setImmediate();
  assert.deepEqual(statuses, ['connecting', 'online']);
  assert.equal(detections.length, 1);
  assert.equal(detections[0].source, 'bridge-motion');
  assert.equal(detections[0].type, 'motion');
  await session.stop();
  assert.equal(stops, 1);
  assert.equal(statuses.at(-1), 'offline');
  source.onFrame(changed);
  assert.equal(detections.length, 1);
});

const ffmpeg = process.env.SAFEHOOD_FFMPEG_PATH || 'ffmpeg';
const ffmpegAvailable = spawnSync(ffmpeg, ['-version'], {stdio: 'ignore'}).status === 0;

test('the FFmpeg worker delivers real grayscale motion frames', {
  skip: !ffmpegAvailable, timeout: 5000,
}, async () => {
  const sizes = [];
  const ended = await new Promise((resolve) => {
    const source = new FfmpegFrameSource({
      input: path.resolve(__dirname, '../../tools/fake_clip.mp4'),
      width: 64, height: 36, pixelFormat: 'gray', framesPerSecond: 2,
      onFrame: (frame) => sizes.push(frame.length),
      onExit: resolve,
    });
    source.start();
  });
  assert.equal(ended.code, 0);
  assert.ok(sizes.length >= 2);
  assert.ok(sizes.every((size) => size === 64 * 36));
});
