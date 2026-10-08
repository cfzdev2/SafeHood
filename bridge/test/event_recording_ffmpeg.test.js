'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const {execFileSync} = require('node:child_process');
const {EventVideoBuffer, encodeEventClip} = require('../ai/event_video_buffer');
const {inspectMp4} = require('../../functions/camera_event_clip');

const executable = process.env.FFMPEG_PATH || 'ffmpeg';
const waitFor = async (condition, timeout = 20000) => {
  const deadline = Date.now() + timeout;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error('Brak klatek bufora w wyznaczonym czasie.');
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
};

test('rzeczywisty FFmpeg zachowuje obraz sprzed wykrycia i tworzy mobilne MP4',
  {timeout: 45000}, async (t) => {
    try { execFileSync(executable, ['-version'], {stdio: 'ignore'}); }
    catch (_) { t.skip('Do testu integracyjnego jest potrzebny FFmpeg.'); return; }
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'safehood-video-test-'));
    let buffer;
    t.after(async () => {
      if (buffer) await buffer.stop();
      await fs.rm(directory, {recursive: true, force: true,
        maxRetries: 5, retryDelay: 100});
    });
    const input = path.join(directory, 'source.mp4');
    execFileSync(executable, ['-hide_banner', '-loglevel', 'error', '-y',
      '-f', 'lavfi', '-i', 'color=c=red:s=320x240:r=10:d=8',
      '-f', 'lavfi', '-i', 'color=c=blue:s=320x240:r=10:d=12',
      '-filter_complex', '[0:v][1:v]concat=n=2:v=1:a=0[v]', '-map', '[v]',
      '-c:v', 'libx264', '-preset', 'ultrafast', '-g', '10', '-pix_fmt', 'yuv420p', input]);
    let resolveCapture;
    const captured = new Promise((resolve) => { resolveCapture = resolve; });
    const errors = [];
    buffer = new EventVideoBuffer({input,
      directory: path.join(directory, 'buffer'), workDirectory: path.join(directory, 'work'),
      ffmpegPath: executable,
      onCapture: resolveCapture, onError: (error) => errors.push(error)});
    await buffer.start();
    await waitFor(() => buffer.latestMediaSeconds >= 6);
    assert.equal(buffer.capture({externalEventId: '497c843d-9fdb-4fde-9c08-fca465877ae9',
      occurredAtMillis: Date.now()}), 'queued');
    const capture = await captured;
    const filename = await encodeEventClip({capture, ffmpegPath: executable});
    const info = inspectMp4(await fs.readFile(filename));
    assert.ok(Math.abs(info.durationMillis - 15000) <= 150);
    assert.equal(capture.prebufferMillis, 5000);
    assert.equal(info.width, 320);
    const pixel = (seconds) => execFileSync(executable, ['-hide_banner', '-loglevel', 'error',
      '-ss', String(seconds), '-i', filename, '-frames:v', '1', '-vf', 'scale=1:1',
      '-pix_fmt', 'rgb24', '-f', 'rawvideo', 'pipe:1']);
    const first = pixel(0);
    const last = pixel(14.5);
    assert.ok(first[0] > 200 && first[2] < 50, 'Początek musi pochodzić ze starego czerwonego obrazu.');
    assert.ok(last[2] > 200 && last[0] < 50, 'Koniec musi zawierać późniejszy niebieski obraz.');
    assert.deepEqual(errors, []);
    assert.ok((await fs.readdir(path.join(directory, 'buffer'))).filter((f) => f.endsWith('.mp4')).length <= 16);
  });
