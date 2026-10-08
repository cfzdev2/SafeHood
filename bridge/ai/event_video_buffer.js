'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const {spawn} = require('node:child_process');
const {randomUUID} = require('node:crypto');

function buildBufferArguments({input, realtimeInput = true}) {
  if (typeof input !== 'string' || !input.trim() || /[\r\n\0]/.test(input)) {
    throw new TypeError('Nieprawidłowe źródło nagrania.');
  }
  const args = ['-hide_banner', '-loglevel', 'error', '-nostdin', '-y'];
  if (/^rtsps?:\/\//i.test(input)) args.push('-rtsp_transport', 'tcp');
  else if (realtimeInput) args.push('-re');
  return [...args, '-i', input, '-map', '0:v:0', '-an',
    '-vf', "fps=10,scale=w='min(1280,iw)':h='min(720,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2",
    '-c:v', 'libx264', '-preset', 'ultrafast', '-tune', 'zerolatency',
    '-pix_fmt', 'yuv420p', '-b:v', '1200k', '-maxrate', '1500k', '-bufsize', '3000k',
    '-threads', '1', '-g', '20', '-keyint_min', '20', '-sc_threshold', '0',
    '-force_key_frames', 'expr:gte(t,n_forced*2)',
    '-progress', 'pipe:1', '-nostats', '-f', 'segment', '-segment_time', '2',
    '-segment_time_delta', '0.05', '-segment_format', 'mp4', '-reset_timestamps', '1',
    '-segment_list', 'index.csv', '-segment_list_type', 'csv',
    '-segment_list_size', '12', '-segment_list_flags', '+live',
    '-segment_wrap', '16', 'segment_%02d.mp4'];
}

function parseSegmentIndex(text) {
  const result = [];
  for (const line of text.trim().split(/\r?\n/)) {
    if (!line) continue;
    const match = /^(segment_(\d{2})\.mp4),(\d+(?:\.\d+)?),(\d+(?:\.\d+)?)$/.exec(line);
    if (!match || Number(match[2]) >= 16) throw new Error('Uszkodzony indeks bufora nagrania.');
    const start = Number(match[3]);
    const end = Number(match[4]);
    if (end <= start || end - start > 2.2 ||
        (result.length && start < result.at(-1).end - 0.15)) {
      throw new Error('Nieprawidłowe czasy segmentów nagrania.');
    }
    result.push({filename: match[1], start, end});
  }
  if (result.length > 12) throw new Error('Indeks bufora przekroczył limit.');
  return result;
}

class EventVideoBuffer {
  constructor({input, directory, workDirectory, prebufferSeconds = 5,
    postbufferSeconds = 10, onCapture = () => {}, onError = () => {},
    onCancelled = () => {}, now = Date.now, ffmpegPath = process.env.FFMPEG_PATH || 'ffmpeg',
    spawnProcess = spawn, realtimeInput = true}) {
    if (!directory || !workDirectory || !Number.isFinite(prebufferSeconds) ||
        prebufferSeconds < 0 || prebufferSeconds > 5 || !Number.isFinite(postbufferSeconds) ||
        postbufferSeconds < 1 || postbufferSeconds > 10) throw new TypeError('Nieprawidłowe opcje bufora.');
    buildBufferArguments({input, realtimeInput});
    Object.assign(this, {input, directory, workDirectory, prebufferSeconds,
      postbufferSeconds, onCapture, onError, onCancelled, now, ffmpegPath, spawnProcess, realtimeInput});
    this.running = false;
    this.originMillis = null;
    this.latestMediaSeconds = 0;
    this._lastSegmentAt = 0;
    this._capture = null;
    this._io = Promise.resolve();
    this._timer = null;
    this._child = null;
    this._stopping = false;
    this._exit = null;
    this._badIndexes = 0;
  }

  async start() {
    await fs.mkdir(this.directory, {recursive: true, mode: 0o700});
    await fs.mkdir(this.workDirectory, {recursive: true, mode: 0o700});
    this.running = true;
    this._lastSegmentAt = this.now();
    const child = this.spawnProcess(this.ffmpegPath,
      buildBufferArguments(this), {cwd: this.directory,
        stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true});
    this._child = child;
    // Konsumujemy wyjście, ale nie ujawniamy adresu ani hasła ze stderr FFmpeg.
    child.stdout?.on('data', () => {});
    child.stderr?.on('data', () => {});
    this._exit = new Promise((resolve) => {
      child.once('error', () => {
        this._notify(this.onError, new Error('Nie udało się uruchomić FFmpeg nagrania.'));
        this.running = false;
        resolve();
      });
      child.once('close', (code) => {
        this.running = false;
        if (this._timer) clearInterval(this._timer);
        this._timer = null;
        if (!this._stopping) {
          this._io = this._io.then(() => this._poll(true)).catch((error) => this._cancel(error));
          if (code !== 0) this._notify(this.onError, new Error('Strumień bufora nagrania zakończył pracę.'));
        }
        resolve();
      });
    });
    this._timer = setInterval(() => {
      this._io = this._io.then(() => this._poll()).catch((error) => this._cancel(error));
    }, 250);
    this._timer.unref?.();
  }

  capture({externalEventId, occurredAtMillis}) {
    if (!this.running || this._stopping) return 'unavailable';
    if (this._capture) return 'coalesced';
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(externalEventId) || !Number.isSafeInteger(occurredAtMillis) ||
        Math.abs(this.now() - occurredAtMillis) > 5000) return 'late';
    const capture = {externalEventId, occurredAtMillis, createdAtMillis: this.now(),
      directory: path.join(this.workDirectory, randomUUID()), parts: [], copied: new Set()};
    this._capture = capture;
    this._io = this._io.then(async () => {
      await fs.mkdir(capture.directory, {recursive: true, mode: 0o700});
      await this._poll();
    }).catch((error) => this._cancel(error));
    return 'queued';
  }

  async _poll(force = false) {
    if (this._stopping) return;
    let rows;
    try {
      rows = parseSegmentIndex(await fs.readFile(path.join(this.directory, 'index.csv'), 'utf8'));
      this._badIndexes = 0;
    } catch (error) {
      if (error.code !== 'ENOENT') {
        // FFmpeg przepisuje CSV przy zamknięciu segmentu; krótki odczyt
        // podczas tej operacji nie może zniszczyć przechwytywania.
        this._badIndexes += 1;
        if (this._badIndexes < 4 && !force) return;
        this._child?.kill('SIGTERM');
        throw error;
      }
      rows = [];
    }
    if (rows.length) {
      const latest = rows.at(-1).end;
      if (this.originMillis === null) this.originMillis = this.now() - latest * 1000;
      if (latest > this.latestMediaSeconds) this._lastSegmentAt = this.now();
      this.latestMediaSeconds = latest;
    }
    const capture = this._capture;
    if (capture && this.originMillis !== null) {
      const trigger = Math.max(0, (capture.occurredAtMillis - this.originMillis) / 1000);
      const start = Math.max(0, trigger - this.prebufferSeconds);
      const end = trigger + this.postbufferSeconds;
      for (const row of rows) {
        if (row.end <= start || row.start >= end || capture.copied.has(row.start)) continue;
        const info = await fs.lstat(path.join(this.directory, row.filename));
        if (!info.isFile() || info.size < 100 || info.size > 1024 * 1024) {
          throw new Error('Nieprawidłowy segment bufora nagrania.');
        }
        const filename = `part_${capture.parts.length}.mp4`;
        await fs.copyFile(path.join(this.directory, row.filename), path.join(capture.directory, filename));
        capture.parts.push({...row, filename});
        capture.copied.add(row.start);
      }
      capture.parts.sort((a, b) => a.start - b.start);
      const last = capture.parts.at(-1);
      if (force || (last && last.end >= end - 0.05) ||
          this.now() - capture.createdAtMillis > (this.postbufferSeconds + 20) * 1000) {
        const first = capture.parts[0];
        const actualStart = first ? Math.max(start, first.start) : 0;
        const actualEnd = last ? Math.min(end, last.end) : 0;
        if (!first || actualEnd - actualStart < 1 || actualEnd <= trigger ||
            capture.parts.some((part, i) => i > 0 &&
              part.start - capture.parts[i - 1].end > 0.15)) {
          await this._cancel(new Error('Brak ciągłego obrazu wokół wykrycia.'));
        } else {
          this._capture = null;
          const ready = {externalEventId: capture.externalEventId,
            occurredAtMillis: capture.occurredAtMillis, directory: capture.directory,
            parts: capture.parts, trimStartSeconds: actualStart - first.start,
            durationSeconds: actualEnd - actualStart,
            prebufferMillis: Math.min(5000, Math.max(0, Math.round((trigger - actualStart) * 1000)))};
          try {
            Promise.resolve(this.onCapture(ready)).catch((error) => this._notify(this.onError, error));
          } catch (error) { this._notify(this.onError, error); }
        }
      }
    } else if (capture && (force ||
        this.now() - capture.createdAtMillis > (this.postbufferSeconds + 20) * 1000)) {
      await this._cancel(new Error('Bufor kamery nie dostarczył nagrania.'));
    }
    if (this.running && this.now() - this._lastSegmentAt > 45000) {
      this._notify(this.onError, new Error('Bufor nagrania nie otrzymuje obrazu.'));
      this._child?.kill('SIGTERM');
    }
  }

  async _cancel(error) {
    const capture = this._capture;
    this._capture = null;
    if (capture) {
      try {
        await fs.rm(capture.directory, {recursive: true, force: true});
      } finally {
        this._notify(this.onCancelled, capture);
      }
    }
    if (error) this._notify(this.onError, error);
  }

  async stop() {
    this._stopping = true;
    this.running = false;
    if (this._timer) clearInterval(this._timer);
    this._timer = null;
    if (this._child) {
      this._child.kill('SIGTERM');
      const kill = setTimeout(() => this._child?.kill('SIGKILL'), 2000);
      await this._exit;
      clearTimeout(kill);
    }
    await this._io;
    await this._cancel(null);
    await fs.rm(this.directory, {recursive: true, force: true});
  }

  _notify(callback, value) {
    try { callback(value); } catch (_) {}
  }
}

function encodeEventClip({capture, ffmpegPath = process.env.FFMPEG_PATH || 'ffmpeg',
  signal, spawnProcess = spawn}) {
  return (async () => {
    if (signal?.aborted) throw new Error('Anulowano tworzenie nagrania.');
    const list = capture.parts.map((part) => {
      if (!/^part_\d+\.mp4$/.test(part.filename)) throw new Error('Nieprawidłowa część nagrania.');
      return `file '${part.filename}'\n`;
    }).join('');
    await fs.writeFile(path.join(capture.directory, 'parts.ffconcat'), list, {mode: 0o600});
    const filename = path.join(capture.directory, 'clip.mp4');
    await new Promise((resolve, reject) => {
      const args = ['-hide_banner', '-loglevel', 'error', '-nostdin', '-y',
        '-f', 'concat', '-safe', '1', '-i', 'parts.ffconcat',
        '-ss', capture.trimStartSeconds.toFixed(3), '-t', capture.durationSeconds.toFixed(3),
        '-map', '0:v:0', '-an', '-c:v', 'libx264', '-preset', 'veryfast',
        '-crf', '25', '-maxrate', '1500k', '-bufsize', '3000k', '-threads', '1',
        '-pix_fmt', 'yuv420p', '-movflags', '+faststart', 'clip.mp4'];
      const child = spawnProcess(ffmpegPath, args, {cwd: capture.directory,
        stdio: ['ignore', 'ignore', 'pipe'], windowsHide: true});
      child.stderr?.on('data', () => {});
      let settled = false;
      const finish = (error) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        signal?.removeEventListener('abort', abort);
        if (error) reject(error); else resolve();
      };
      const abort = () => {
        child.kill('SIGKILL');
        finish(new Error('Anulowano tworzenie nagrania.'));
      };
      const timer = setTimeout(() => {
        child.kill('SIGKILL');
        finish(new Error('Przekroczono czas tworzenia nagrania.'));
      }, 30000);
      signal?.addEventListener('abort', abort, {once: true});
      if (signal?.aborted) abort();
      child.once('error', () => finish(new Error('Nie udało się uruchomić FFmpeg nagrania.')));
      child.once('close', (code) => finish(code === 0 ? null : new Error('Nie udało się utworzyć MP4.')));
    });
    const info = await fs.stat(filename);
    if (info.size < 100 || info.size > 6 * 1024 * 1024) throw new Error('Nagranie przekroczyło limit rozmiaru.');
    return filename;
  })();
}

module.exports = {EventVideoBuffer, buildBufferArguments, parseSegmentIndex, encodeEventClip};
