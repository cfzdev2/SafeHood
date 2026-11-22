'use strict';

const {FfmpegFrameSource} = require('./ai/ffmpeg_frame_source');
const {resolveOnvifStreamUri} = require('./onvif_stream_resolver');

const width = 64;
const height = 36;
const count = width * height;

// Same luminance comparison and episode rules as the phone preview.
class MotionDetector {
  constructor() {
    this.reset();
  }

  reset() {
    this.baseline = null;
    this.changedFrames = 0;
    this.quietFrames = 0;
    this.inMotion = false;
  }

  add(frame) {
    if (frame.length !== count) return false;
    let low = 255;
    let high = 0;
    for (const value of frame) {
      low = Math.min(low, value);
      high = Math.max(high, value);
    }
    if ((high < 6 || low > 249) && high - low <= 3) {
      this.reset();
      return false;
    }
    if (this.baseline == null) {
      this.baseline = frame;
      return false;
    }
    let total = 0;
    for (let i = 0; i < count; i++) total += frame[i] - this.baseline[i];
    const exposure = Math.trunc(total / count);
    let changed = 0;
    for (let i = 0; i < count; i++) {
      if (Math.abs(frame[i] - this.baseline[i] - exposure) >= 24) changed++;
    }
    const moving = changed * 100 >= count * 7;
    if (this.inMotion) {
      this.baseline = frame;
      this.quietFrames = moving ? 0 : this.quietFrames + 1;
      if (this.quietFrames >= 3) {
        this.quietFrames = 0;
        this.inMotion = false;
      }
      return false;
    }
    if (!moving) {
      this.baseline = frame;
      this.changedFrames = 0;
      return false;
    }
    if (++this.changedFrames < 2) return false;
    this.baseline = frame;
    this.changedFrames = 0;
    this.inMotion = true;
    return true;
  }
}

class BackgroundMotionSession {
  constructor({camera, onDetection, onStatusChanged, now = Date.now,
    resolve = resolveOnvifStreamUri, createSource = (args) => new FfmpegFrameSource(args),
    idleMillis = 12000, retryMillis = [2000, 4000, 8000, 15000, 30000]}) {
    this.camera = camera;
    this.onDetection = onDetection;
    this.onStatusChanged = onStatusChanged;
    this.now = now;
    this.resolve = resolve;
    this.createSource = createSource;
    this.idleMillis = idleMillis;
    this.retryMillis = retryMillis;
    this.motion = new MotionDetector();
    this.running = false;
    this.session = null;
    this.finishWait = null;
    this.abort = null;
    this.lastEvent = null;
    this.pendingEvent = false;
    this.status = null;
    this.retryIndex = 0;
  }

  _status(status) {
    if (this.status === status) return;
    this.status = status;
    this.onStatusChanged(this.camera, status);
  }

  start() {
    if (this.session) return;
    this.running = true;
    this.abort = new AbortController();
    this.session = this._run();
  }

  async _run() {
    this._status('connecting');
    while (this.running) {
      try {
        const input = await this.resolve(this.camera, {
          timeoutMs: 3500,
          signal: this.abort.signal,
        });
        if (!this.running) break;
        await this._watch(input);
      } catch (_) {
        if (this.running) {
          console.warn(`[BRIDGE MOTION][${this.camera.id}] brak obrazu z kamery.`);
        }
      }
      if (!this.running) break;
      this._status('reconnecting');
      const delay = this.retryMillis[this.retryIndex];
      this.retryIndex = Math.min(this.retryIndex + 1, this.retryMillis.length - 1);
      await new Promise((resolve) => {
        const timer = setTimeout(() => this.finishWait(), delay);
        this.finishWait = () => {
          clearTimeout(timer);
          this.finishWait = null;
          resolve();
        };
      });
    }
  }

  async _watch(input) {
    this.motion.reset();
    let source;
    let idle;
    try {
      await new Promise((resolve, reject) => {
        const finish = () => {
          if (this.finishWait !== finish) return;
          clearTimeout(idle);
          this.finishWait = null;
          resolve();
        };
        this.finishWait = finish;
        const resetIdle = () => {
          clearTimeout(idle);
          idle = setTimeout(finish, this.idleMillis);
        };
        source = this.createSource({
          input, width, height, pixelFormat: 'gray', framesPerSecond: 2,
          onFrame: (frame) => {
            if (!this.running || this.finishWait !== finish) return;
            resetIdle();
            this.retryIndex = 0;
            this._status('online');
            this._sample(frame);
          },
          onExit: finish,
        });
        resetIdle();
        try {
          source.start();
        } catch (error) {
          clearTimeout(idle);
          this.finishWait = null;
          reject(error);
        }
      });
    } finally {
      clearTimeout(idle);
      await source?.stop();
    }
  }

  _sample(frame) {
    if (!this.motion.add(frame)) return;
    const now = this.now();
    if (this.pendingEvent || (this.lastEvent != null && now - this.lastEvent < 30000)) {
      return;
    }
    this.lastEvent = now;
    this.pendingEvent = true;
    Promise.resolve().then(() => {
      if (!this.running) return;
      return this.onDetection(this.camera, {
        type: 'motion', source: 'bridge-motion',
        occurredAt: new Date(now).toISOString(),
      }, this.abort.signal);
    }).catch(() => {
      if (this.running) console.warn(`[BRIDGE MOTION][${this.camera.id}] błąd zapisu.`);
    }).finally(() => {
      this.pendingEvent = false;
    });
  }

  async stop() {
    this.running = false;
    this.abort?.abort();
    this.finishWait?.();
    await this.session;
    this.session = null;
    this._status('offline');
  }
}

module.exports = {BackgroundMotionSession, MotionDetector};
