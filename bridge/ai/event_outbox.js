'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const {randomUUID} = require('node:crypto');
const {normalizeAiEventMetadata} = require('./event_metadata');

const idPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

function normalizePayload(value) {
  if (!value || !idPattern.test(value.externalEventId) ||
    typeof value.cameraId !== 'string' || !value.cameraId.trim() ||
    value.cameraId.length > 256 || /[/\0]/.test(value.cameraId) ||
    !['person', 'vehicle'].includes(value.type) || value.source !== 'local-ai' ||
    (value.confidence !== null && (!Number.isFinite(value.confidence) ||
      value.confidence < 0 || value.confidence > 1)) ||
    typeof value.occurredAt !== 'string' || !Number.isFinite(Date.parse(value.occurredAt))) {
    throw new TypeError('Nieprawidłowe dane zdarzenia w kolejce AI.');
  }
  const aiMetadata = value.aiMetadata == null ? null :
    normalizeAiEventMetadata(value.aiMetadata, {
      type: value.type,
      occurredAt: value.occurredAt,
    });
  // Kolejka nie zapisuje konfiguracji kamery, adresu RTSP ani haseł.
  return {
    externalEventId: value.externalEventId,
    cameraId: value.cameraId,
    type: value.type,
    source: 'local-ai',
    confidence: value.confidence,
    occurredAt: value.occurredAt,
    ...(aiMetadata === null ? {} : {aiMetadata}),
  };
}

function normalizeResult(value, externalEventId) {
  if (!value || value.ok !== true || value.externalEventId !== externalEventId ||
    typeof value.eventId !== 'string' || !value.eventId ||
    !Number.isInteger(value.occurrenceCount) || value.occurrenceCount < 1) {
    const error = new Error('Backend nie potwierdził identyfikatora zdarzenia AI.');
    error.retryable = false;
    throw error;
  }
  return {
    ok: true, externalEventId, eventId: value.eventId,
    type: value.type, merged: value.merged === true,
    occurrenceCount: value.occurrenceCount,
    snapshotRequired: value.snapshotRequired === true,
    duplicate: value.duplicate === true,
  };
}

class AiEventOutbox {
  constructor({
    directory, deliver, maximumJobs = 1000,
    retryDelaysMs = [1000, 2000, 5000, 10000, 30000, 60000],
    onDelivered = () => {}, onError = () => {}, onRestored = () => {},
    now = Date.now, createId = randomUUID, fileSystem = fs,
    setTimer = setTimeout, clearTimer = clearTimeout,
    payloadNormalizer = normalizePayload, resultNormalizer = normalizeResult,
    maximumAgeMs = 0,
  }) {
    if (typeof directory !== 'string' || !directory || typeof deliver !== 'function' ||
      !Number.isInteger(maximumJobs) || maximumJobs < 1 ||
      !Array.isArray(retryDelaysMs) || !retryDelaysMs.length ||
      retryDelaysMs.some((delay) => !Number.isInteger(delay) || delay < 1) ||
      typeof payloadNormalizer !== 'function' || typeof resultNormalizer !== 'function' ||
      !Number.isSafeInteger(maximumAgeMs) || maximumAgeMs < 0) {
      throw new TypeError('Nieprawidłowe opcje trwałej kolejki AI.');
    }
    Object.assign(this, {directory, deliver, maximumJobs, retryDelaysMs,
      onDelivered, onError, onRestored, now, createId, fileSystem, setTimer, clearTimer,
      payloadNormalizer, resultNormalizer, maximumAgeMs});
    this._jobs = new Map();
    this._writes = Promise.resolve();
    this._started = null;
    this._timer = null;
    this._active = null;
    this._controller = null;
    this._closed = false;
    this._lastEnqueuedAt = 0;
    this._serverBlockedUntil = 0;
  }

  get pendingCount() { return this._jobs.size; }
  hasPending(externalEventId) { return this._jobs.has(externalEventId); }

  start() {
    if (!this._started) this._started = this._load();
    return this._started;
  }

  async _load() {
    await this.fileSystem.mkdir(this.directory, {recursive: true, mode: 0o700});
    const jobs = [];
    for (const filename of await this.fileSystem.readdir(this.directory)) {
      if (!filename.endsWith('.json')) continue;
      try {
        const data = JSON.parse(await this.fileSystem.readFile(path.join(this.directory, filename), 'utf8'));
        const payload = this.payloadNormalizer(data.payload);
        if (data.version !== 1 || filename !== `${payload.externalEventId}.json` ||
          !Number.isFinite(data.enqueuedAtMillis) || data.enqueuedAtMillis < 1 ||
          !Number.isInteger(data.attempts) || data.attempts < 0 ||
          !Number.isFinite(data.notBeforeMillis) || data.notBeforeMillis < 0) {
          throw new Error('Uszkodzony plik kolejki AI.');
        }
        const result = data.result ? this.resultNormalizer(data.result, payload.externalEventId) : null;
        jobs.push({...data, payload, result, afterDelivery: null});
      } catch (error) {
        await this.fileSystem.rename(path.join(this.directory, filename),
          path.join(this.directory, `${filename}.${randomUUID()}.invalid`));
        this._notify(this.onError, {phase: 'load', filename, error, willRetry: false});
      }
    }
    jobs.sort((a, b) => a.enqueuedAtMillis - b.enqueuedAtMillis);
    for (const job of jobs) this._jobs.set(job.payload.externalEventId, job);
    this._lastEnqueuedAt = jobs.at(-1)?.enqueuedAtMillis ?? 0;
    this._notify(this.onRestored, this._jobs.size);
    this._schedule();
  }

  async enqueue(input, afterDelivery = null) {
    await this.start();
    return this._serial(async () => {
      if (this._closed) throw new Error('Kolejka zdarzeń AI jest zamknięta.');
      if (this._jobs.size >= this.maximumJobs) throw new Error('Kolejka zdarzeń AI jest pełna.');
      const payload = this.payloadNormalizer({...input, externalEventId: this.createId(input)});
      if (this._jobs.has(payload.externalEventId)) throw new Error('Powtórzony identyfikator kolejki AI.');
      const job = {version: 1, payload, attempts: 0, notBeforeMillis: 0, result: null,
        enqueuedAtMillis: Math.max(this.now(), this._lastEnqueuedAt + 1), afterDelivery};
      await this._write(job);
      this._lastEnqueuedAt = job.enqueuedAtMillis;
      this._jobs.set(payload.externalEventId, job);
      this._schedule();
      return {queued: true, externalEventId: payload.externalEventId};
    });
  }

  _serial(operation) {
    const result = this._writes.then(operation);
    this._writes = result.catch(() => {});
    return result;
  }

  async _write(job) {
    const filename = path.join(this.directory, `${job.payload.externalEventId}.json`);
    const temporary = `${filename}.${randomUUID()}.tmp`;
    let handle;
    try {
      handle = await this.fileSystem.open(temporary, 'wx', 0o600);
      const {version, payload, attempts, notBeforeMillis, result, enqueuedAtMillis} = job;
      await handle.writeFile(JSON.stringify({version, payload, attempts, notBeforeMillis, result, enqueuedAtMillis}));
      await handle.sync();
      await handle.close();
      handle = null;
      await this.fileSystem.rename(temporary, filename);
    } finally {
      if (handle) await handle.close();
      await this.fileSystem.unlink(temporary).catch((error) => {
        if (error.code !== 'ENOENT') throw error;
      });
    }
  }

  _schedule() {
    if (this._timer !== null) this.clearTimer(this._timer);
    this._timer = null;
    if (this._closed || this._active || !this._jobs.size) return;
    const readyAt = Math.min(...[...this._jobs.values()].map((job) => job.notBeforeMillis));
    this._timer = this.setTimer(() => {
      this._timer = null;
      this._active = this._drain().finally(() => {
        this._active = null;
        this._schedule();
      });
    }, Math.max(0, Math.max(readyAt, this._serverBlockedUntil) - this.now()));
    this._timer?.unref?.();
  }

  async _drain() {
    const job = [...this._jobs.values()].find((value) => value.notBeforeMillis <= this.now());
    if (!job || this._closed) return;
    this._controller = new AbortController();
    try {
      if (!job.result && this.maximumAgeMs > 0 &&
          this.now() - job.enqueuedAtMillis > this.maximumAgeMs) {
        throw Object.assign(new Error('Upłynął czas przechowywania zadania.'), {retryable: false});
      }
      if (!job.result) {
        job.attempts += 1;
        await this._serial(() => this._write(job));
        if (this._closed) return;
        const response = await this.deliver(job.payload, this._controller.signal);
        job.result = this.resultNormalizer(response, job.payload.externalEventId);
        await this._serial(() => this._write(job));
      }
      await this._serial(async () => {
        await this.fileSystem.unlink(path.join(this.directory, `${job.payload.externalEventId}.json`)).catch((error) => {
          if (error.code !== 'ENOENT') throw error;
        });
        this._jobs.delete(job.payload.externalEventId);
      });
      if (job.afterDelivery) this._notify(job.afterDelivery, job.result);
      this._notify(this.onDelivered, {payload: job.payload, result: job.result, attempts: job.attempts});
    } catch (error) {
      if (this._closed) return;
      const status = Number(error?.statusCode);
      const permanent = error?.retryable === false ||
        (status >= 400 && status < 500 && ![408, 409, 429].includes(status));
      if (permanent) {
        try {
          await this._serial(async () => {
            const filename = path.join(this.directory, `${job.payload.externalEventId}.json`);
            await this.fileSystem.rename(filename, `${filename}.rejected`);
            this._jobs.delete(job.payload.externalEventId);
          });
          this._notify(this.onError, {phase: 'send', payload: job.payload, error, willRetry: false});
          return;
        } catch (diskError) {
          error = diskError;
        }
      }
      const delay = status === 409 ? 60000 :
        this.retryDelaysMs[Math.min(Math.max(job.attempts - 1, 0), this.retryDelaysMs.length - 1)];
      job.notBeforeMillis = this.now() + delay;
      if (status !== 409) this._serverBlockedUntil = job.notBeforeMillis;
      await this._serial(() => this._write(job)).catch((diskError) => {
        this._notify(this.onError, {phase: 'disk', payload: job.payload, error: diskError, willRetry: true});
      });
      this._notify(this.onError, {phase: 'send', payload: job.payload, error, willRetry: true, retryInMs: delay});
    } finally {
      this._controller = null;
    }
  }

  async close() {
    this._closed = true;
    if (this._timer !== null) this.clearTimer(this._timer);
    this._timer = null;
    this._controller?.abort();
    if (this._active) await this._active;
    await this._writes;
  }

  _notify(callback, value) {
    try { callback(value); } catch (_) { /* Logowanie nie zmienia dostarczenia. */ }
  }
}

module.exports = {AiEventOutbox};
