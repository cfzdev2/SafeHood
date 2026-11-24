'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const {createHash, randomUUID} = require('node:crypto');
const {EventVideoBuffer, encodeEventClip} = require('./event_video_buffer');

class EventRecordingManager {
  constructor({directory, uploadQueue, maximumCaptures = 16,
    onError = () => {}, onStatus = () => {},
    onSample = null, onSnapshot = null, onPreview = null, onSourceExit = () => {},
    bufferFactory = (options) => new EventVideoBuffer(options), encode = encodeEventClip}) {
    Object.assign(this, {directory, uploadQueue, maximumCaptures,
      onError, onStatus, bufferFactory, encode, onSample, onSnapshot, onPreview, onSourceExit});
    this._recorders = new Map();
    this._operations = new Map();
    this._started = null;
    this._closed = false;
    this._captures = 0;
    this._encoding = Promise.resolve();
    this._controller = new AbortController();
  }

  get bufferCount() {
    return this._recorders.size;
  }

  get activeCaptureCount() {
    return this._captures;
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

  _serialize(cameraId, operation) {
    const pending = (this._operations.get(cameraId) || Promise.resolve())
      .catch(() => {}).then(operation);
    this._operations.set(cameraId, pending);
    void pending.finally(() => {
      if (this._operations.get(cameraId) === pending) this._operations.delete(cameraId);
    }).catch(() => {});
    return pending;
  }

  syncCamera(cameraId, input, enabled) {
    return this._serialize(cameraId, () => this._syncCamera(cameraId, input, enabled));
  }

  async _syncCamera(cameraId, input, enabled) {
    try { await this.start(); } catch (error) {
      this._notify(this.onError, {cameraId, error});
      return;
    }
    if (this._closed) return;
    const existing = this._recorders.get(cameraId);
    if (enabled && existing?.running && existing.input === input) return;
    if (existing) await this._stopCamera(cameraId);
    if (!enabled) return;
    const name = createHash('sha256').update(cameraId).digest('hex');
    let recorder;
    try {
      recorder = this.bufferFactory({input,
        emitFrames: this.onSample !== null || this.onSnapshot !== null,
        onSample: (frame) => {
          if (this._recorders.get(cameraId) === recorder) this.onSample?.(cameraId, frame);
        },
        onPreview: (jpeg) => {
          if (this._recorders.get(cameraId) === recorder) this.onPreview?.(cameraId, jpeg);
        },
        onSnapshot: (jpeg) => {
          if (this._recorders.get(cameraId) === recorder) this.onSnapshot?.(cameraId, jpeg);
        },
        onSourceExit: () => {
          if (this._recorders.get(cameraId) === recorder) this.onSourceExit(cameraId);
        },
        directory: path.join(this.directory, 'buffers', name, randomUUID()),
        workDirectory: path.join(this.directory, 'work'),
        onCapture: (capture) => this._ready(cameraId, capture),
        onCancelled: () => { this._captures = Math.max(0, this._captures - 1); },
        onError: (error) => this._notify(this.onError, {cameraId, error}),
      });
      this._recorders.set(cameraId, recorder);
      await recorder.start();
      if (this._closed) {
        await this._stopCamera(cameraId);
        return;
      }
      this._notify(this.onStatus, {cameraId, status: 'buffering'});
    } catch (error) {
      this._recorders.delete(cameraId);
      if (recorder) await recorder.stop().catch(() => {});
      this._notify(this.onSourceExit, cameraId);
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

  stopCamera(cameraId) {
    return this._serialize(cameraId, () => this._stopCamera(cameraId));
  }

  async _stopCamera(cameraId) {
    const recorder = this._recorders.get(cameraId);
    this._recorders.delete(cameraId);
    if (recorder) {
      this._notify(this.onSourceExit, cameraId);
      try { await recorder.stop(); } catch (error) {
        this._notify(this.onError, {cameraId, error});
      }
    }
  }

  async close() {
    this._closed = true;
    this._controller.abort();
    await Promise.allSettled([...this._operations.values()]);
    for (const cameraId of [...this._recorders.keys()]) await this._stopCamera(cameraId);
    await this._encoding;
  }

  _notify(callback, value) { try { callback(value); } catch (_) {} }
}

module.exports = {EventRecordingManager};
