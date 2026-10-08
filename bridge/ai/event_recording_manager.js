'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const {createHash, randomUUID} = require('node:crypto');
const {EventVideoBuffer, encodeEventClip} = require('./event_video_buffer');

class EventRecordingManager {
  constructor({directory, uploadQueue, maximumCaptures = 16,
    onError = () => {}, onStatus = () => {},
    bufferFactory = (options) => new EventVideoBuffer(options), encode = encodeEventClip}) {
    Object.assign(this, {directory, uploadQueue, maximumCaptures,
      onError, onStatus, bufferFactory, encode});
    this._recorders = new Map();
    this._started = null;
    this._closed = false;
    this._captures = 0;
    this._encoding = Promise.resolve();
    this._controller = new AbortController();
  }

  start() {
    if (!this._started) this._started = this._start();
    return this._started;
  }

  async _start() {
    // Bufor i niedokończone przechwytywania są tymczasowe.
    // Gotowe, zatwierdzone filmy pozostają w osobnej trwałej kolejce.
    for (const name of ['buffers', 'work']) {
      const directory = path.join(this.directory, name);
      await fs.rm(directory, {recursive: true, force: true});
      await fs.mkdir(directory, {recursive: true, mode: 0o700});
    }
  }

  async syncCamera(cameraId, input, enabled) {
    try { await this.start(); } catch (error) {
      this._notify(this.onError, {cameraId, error});
      return;
    }
    if (this._closed) return;
    const existing = this._recorders.get(cameraId);
    if (enabled && existing?.running && existing.input === input) return;
    if (existing) await this.stopCamera(cameraId);
    if (!enabled) return;
    const name = createHash('sha256').update(cameraId).digest('hex');
    let recorder;
    try {
      recorder = this.bufferFactory({input,
        directory: path.join(this.directory, 'buffers', name, randomUUID()),
        workDirectory: path.join(this.directory, 'work'),
        onCapture: (capture) => this._ready(cameraId, capture),
        onCancelled: () => { this._captures = Math.max(0, this._captures - 1); },
        onError: (error) => this._notify(this.onError, {cameraId, error}),
      });
      this._recorders.set(cameraId, recorder);
      await recorder.start();
      this._notify(this.onStatus, {cameraId, status: 'buffering'});
    } catch (error) {
      this._recorders.delete(cameraId);
      if (recorder) await recorder.stop().catch(() => {});
      this._notify(this.onError, {cameraId, error});
    }
  }

  capture(cameraId, detection) {
    if (this._closed) return 'closed';
    if (this._captures >= this.maximumCaptures ||
        this.uploadQueue.pendingCount >= this.uploadQueue.maximumJobs) {
      this._notify(this.onError, {cameraId, error: new Error('Kolejka nagrań jest pełna.')});
      return 'full';
    }
    const recorder = this._recorders.get(cameraId);
    if (!recorder) return 'unavailable';
    const result = recorder.capture(detection);
    if (result === 'queued') {
      this._captures += 1;
      this._notify(this.onStatus, {cameraId, status: 'recording'});
    } else if (result !== 'coalesced') {
      this._notify(this.onError, {cameraId, error: new Error('Bufor nagrania nie jest gotowy.')});
    }
    return result;
  }

  _ready(cameraId, capture) {
    const operation = this._encoding.then(async () => {
      try {
        if (this._closed) return;
        const filename = await this.encode({capture, signal: this._controller.signal});
        await this.uploadQueue.enqueue({filename, cameraId,
          externalEventId: capture.externalEventId, occurredAtMillis: capture.occurredAtMillis,
          prebufferMillis: capture.prebufferMillis});
        this._notify(this.onStatus, {cameraId, status: 'queued'});
      } catch (error) {
        this._notify(this.onError, {cameraId, error});
      } finally {
        this._captures = Math.max(0, this._captures - 1);
        await fs.rm(capture.directory, {recursive: true, force: true});
      }
    });
    this._encoding = operation.catch((error) => this._notify(this.onError, {cameraId, error}));
    return operation;
  }

  async stopCamera(cameraId) {
    const recorder = this._recorders.get(cameraId);
    this._recorders.delete(cameraId);
    if (recorder) {
      try { await recorder.stop(); } catch (error) {
        this._notify(this.onError, {cameraId, error});
      }
    }
  }

  async close() {
    this._closed = true;
    this._controller.abort();
    for (const cameraId of [...this._recorders.keys()]) await this.stopCamera(cameraId);
    await this._encoding;
  }

  _notify(callback, value) { try { callback(value); } catch (_) {} }
}

module.exports = {EventRecordingManager};
