'use strict';

const {isJpeg} = require('./ffmpeg_snapshot_capture');

// Jedna operacja FFmpeg/upload naraz; JPEG zostaje w pamięci na czas
// ponawiania uploadu. Kolejka i pamięć potwierdzeń mają stałe limity.
class SnapshotUploadQueue {
  constructor({
    captureSnapshot,
    uploadSnapshot,
    onSaved = () => {},
    onError = () => {},
    maximumJobs = 16,
    maximumBytes = 5 * 1024 * 1024,
    maximumCompleted = 256,
    retryDelaysMs = [2000, 5000],
    now = Date.now,
    setTimer = setTimeout,
    clearTimer = clearTimeout,
  }) {
    if (
      typeof captureSnapshot !== 'function' ||
      typeof uploadSnapshot !== 'function' ||
      typeof onSaved !== 'function' ||
      typeof onError !== 'function' ||
      !Number.isInteger(maximumJobs) || maximumJobs < 1 ||
      !Number.isInteger(maximumBytes) || maximumBytes < 4 ||
      !Number.isInteger(maximumCompleted) || maximumCompleted < 1 ||
      !Array.isArray(retryDelaysMs) ||
      retryDelaysMs.some((delay) => !Number.isInteger(delay) || delay < 1)
    ) {
      throw new TypeError('Nieprawidłowe opcje kolejki zdjęć.');
    }

    this.captureSnapshot = captureSnapshot;
    this.uploadSnapshot = uploadSnapshot;
    this.onSaved = onSaved;
    this.onError = onError;
    this.maximumJobs = maximumJobs;
    this.maximumBytes = maximumBytes;
    this.maximumCompleted = maximumCompleted;
    this.retryDelaysMs = [...retryDelaysMs];
    this.now = now;
    this.setTimer = setTimer;
    this.clearTimer = clearTimer;
    this._jobs = new Map();
    this._completed = new Set();
    this._timer = null;
    this._running = false;
    this._closed = false;
  }

  get pendingCount() {
    return this._jobs.size;
  }

  enqueue({cameraId, eventId, input}) {
    if ([cameraId, eventId, input].some((value) =>
      typeof value !== 'string' || !value.trim() || value.includes('\0'))) {
      throw new TypeError('Nieprawidłowe dane zdjęcia zdarzenia.');
    }
    if (this._closed) return 'closed';

    const key = `${cameraId}\0${eventId}`;
    if (this._jobs.has(key) || this._completed.has(key)) return 'duplicate';
    if (this._jobs.size >= this.maximumJobs) return 'full';

    this._jobs.set(key, {
      key, cameraId, eventId, input,
      attempt: 0,
      readyAt: this.now(),
      snapshot: null,
      controller: new AbortController(),
    });
    this._schedule();
    return 'queued';
  }

  cancelCamera(cameraId) {
    for (const [key, job] of this._jobs) {
      if (job.cameraId === cameraId) {
        this._jobs.delete(key);
        job.controller.abort();
      }
    }
    this._schedule();
  }

  retainCameras(cameraIds) {
    const allowed = new Set(cameraIds);
    for (const job of this._jobs.values()) {
      if (!allowed.has(job.cameraId)) this.cancelCamera(job.cameraId);
    }
  }

  close() {
    this._closed = true;
    if (this._timer !== null) this.clearTimer(this._timer);
    this._timer = null;
    for (const job of this._jobs.values()) job.controller.abort();
    this._jobs.clear();
    this._completed.clear();
  }

  _schedule() {
    if (this._timer !== null) this.clearTimer(this._timer);
    this._timer = null;
    if (this._closed || this._running || this._jobs.size === 0) return;

    const readyAt = Math.min(...[...this._jobs.values()].map((job) => job.readyAt));
    this._timer = this.setTimer(() => {
      this._timer = null;
      void this._drain();
    }, Math.max(0, readyAt - this.now()));
    this._timer?.unref?.();
  }

  async _drain() {
    if (this._closed || this._running) return;
    const job = [...this._jobs.values()].find((value) => value.readyAt <= this.now());
    if (!job) {
      this._schedule();
      return;
    }

    this._running = true;
    job.attempt += 1;
    const details = {
      cameraId: job.cameraId,
      eventId: job.eventId,
      attempt: job.attempt,
      maximumAttempts: this.retryDelaysMs.length + 1,
    };
    const stillPending = () => !this._closed && this._jobs.get(job.key) === job;

    try {
      if (!job.snapshot) {
        job.snapshot = await this.captureSnapshot({
          input: job.input,
          attempt: job.attempt,
          signal: job.controller.signal,
        });
        if (!isJpeg(job.snapshot) || job.snapshot.length > this.maximumBytes) {
          job.snapshot = null;
          const error = new Error('Nieprawidłowy JPEG lub przekroczony limit zdjęcia.');
          error.retryable = false;
          throw error;
        }
      }
      if (!stillPending()) return;

      const result = await this.uploadSnapshot({
        cameraId: job.cameraId,
        eventId: job.eventId,
        snapshot: job.snapshot,
        signal: job.controller.signal,
      });
      if (!stillPending()) return;

      this._jobs.delete(job.key);
      this._completed.add(job.key);
      while (this._completed.size > this.maximumCompleted) {
        this._completed.delete(this._completed.values().next().value);
      }
      this._notify(this.onSaved, {...details, result, size: job.snapshot.length});
    } catch (error) {
      if (!stillPending()) return;
      const status = Number(error?.statusCode);
      const permanent = error?.retryable === false ||
        (status >= 400 && status < 500 && status !== 408 && status !== 429);
      const willRetry = !permanent && job.attempt < details.maximumAttempts;
      const retryInMs = willRetry ? this.retryDelaysMs[job.attempt - 1] : null;
      if (willRetry) job.readyAt = this.now() + retryInMs;
      else this._jobs.delete(job.key);
      this._notify(this.onError, {...details, error, willRetry, retryInMs});
    } finally {
      this._running = false;
      this._schedule();
    }
  }

  _notify(callback, details) {
    try {
      callback(details);
    } catch (_) {
      // Błąd logowania nie może powtarzać udanego uploadu.
    }
  }
}

module.exports = {SnapshotUploadQueue};
