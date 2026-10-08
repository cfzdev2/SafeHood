'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const {createHash, randomUUID} = require('node:crypto');
const {AiEventOutbox} = require('./event_outbox');

const MAX_CLIP_BYTES = 6 * 1024 * 1024;
const MAX_CLIP_AGE_MS = 24 * 60 * 60 * 1000;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const permanent = (message) => Object.assign(new Error(message), {retryable: false});

function normalizeJob(value) {
  if (!value || !uuid.test(value.externalEventId) ||
      typeof value.cameraId !== 'string' || !value.cameraId ||
      /[/\0]/.test(value.cameraId) || value.cameraId.length > 256 ||
      !/^[0-9a-f]{64}$/.test(value.sha256) ||
      !Number.isSafeInteger(value.size) || value.size < 100 || value.size > MAX_CLIP_BYTES ||
      !Number.isSafeInteger(value.occurredAtMillis) ||
      !Number.isSafeInteger(value.prebufferMillis) ||
      value.prebufferMillis < 0 || value.prebufferMillis > 5000) {
    throw permanent('Uszkodzone zadanie wysyłki nagrania.');
  }
  return {externalEventId: value.externalEventId, cameraId: value.cameraId,
    sha256: value.sha256, size: value.size,
    occurredAtMillis: value.occurredAtMillis, prebufferMillis: value.prebufferMillis};
}

function normalizeAcknowledgement(value, externalEventId) {
  if (!value || value.ok !== true || value.externalEventId !== externalEventId ||
      typeof value.eventId !== 'string' || /[/\0]/.test(value.eventId) || !value.eventId ||
      typeof value.clipPath !== 'string' ||
      !/^users\/[^/]+\/cameraEvents\/[^/]+\/clip\.mp4$/.test(value.clipPath) ||
      !value.clipPath.endsWith(`/cameraEvents/${value.eventId}/clip.mp4`) ||
      !Number.isSafeInteger(value.size) || value.size < 100 || value.size > MAX_CLIP_BYTES ||
      !Number.isSafeInteger(value.durationMillis) || value.durationMillis < 1000 ||
      value.durationMillis > 30000 || !Number.isSafeInteger(value.prebufferMillis) ||
      value.prebufferMillis < 0 || value.prebufferMillis > 5000 ||
      value.prebufferMillis >= value.durationMillis) {
    throw permanent('Backend nie potwierdził zapisu nagrania.');
  }
  return {ok: true, externalEventId, eventId: value.eventId, clipPath: value.clipPath,
    size: value.size, durationMillis: value.durationMillis,
    prebufferMillis: value.prebufferMillis, alreadyExists: value.alreadyExists === true};
}

class ClipUploadQueue {
  constructor({directory, upload, maximumJobs = 16,
    onSaved = () => {}, onError = () => {}, onRestored = () => {},
    retryDelaysMs, now = Date.now, maximumAgeMs = MAX_CLIP_AGE_MS}) {
    if (typeof upload !== 'function') throw new TypeError('Brak uploadu nagrania.');
    Object.assign(this, {directory, upload, maximumJobs, onSaved, onError, now, maximumAgeMs});
    this._closed = false;
    this._copies = Promise.resolve();
    this._copying = new Set();
    this._started = null;
    this._cleanupTimer = null;
    this.outbox = new AiEventOutbox({directory, maximumJobs, maximumAgeMs, now,
      ...(retryDelaysMs ? {retryDelaysMs} : {}),
      createId: (job) => job.externalEventId,
      payloadNormalizer: normalizeJob, resultNormalizer: normalizeAcknowledgement,
      deliver: (job, signal) => this._upload(job, signal), onRestored,
      onDelivered: ({payload, result, attempts}) => {
        void this._removeMedia(payload.externalEventId).catch((error) => this._report(error));
        try { this.onSaved({cameraId: payload.cameraId, result, attempts}); } catch (_) {}
      },
      onError: (details) => {
        if (!details.willRetry && details.payload) {
          void this._removeMedia(details.payload.externalEventId).catch((error) => this._report(error));
        }
        try { this.onError(details); } catch (_) {}
      },
    });
  }

  get pendingCount() { return this.outbox.pendingCount; }

  start() {
    if (!this._started) this._started = this._start();
    return this._started;
  }

  async _start() {
    await this.outbox.start();
    await this._cleanup();
    if (this._closed) return;
    this._cleanupTimer = setInterval(() => {
      void this._cleanup().catch((error) => this._report(error));
    }, 60000);
    this._cleanupTimer.unref?.();
  }

  async enqueue({filename, externalEventId, cameraId, occurredAtMillis, prebufferMillis}) {
    if (this._closed) throw new Error('Kolejka nagrań jest zamknięta.');
    await this.start();
    const operation = this._copies.then(async () => {
      if (this._closed) throw new Error('Kolejka nagrań jest zamknięta.');
      if (!uuid.test(externalEventId)) throw permanent('Nieprawidłowe UUID nagrania.');
      if (this.outbox.hasPending(externalEventId)) return 'duplicate';
      if (this.pendingCount >= this.maximumJobs) throw new Error('Kolejka nagrań jest pełna.');
      this._copying.add(externalEventId);
      const destination = this._filename(externalEventId);
      const temporary = `${destination}.${randomUUID()}.tmp`;
      let handle;
      try {
        const info = await fs.lstat(filename);
        if (!info.isFile() || info.size < 100 || info.size > MAX_CLIP_BYTES) {
          throw permanent('Nieprawidłowy plik nagrania.');
        }
        const bytes = await fs.readFile(filename);
        const job = normalizeJob({externalEventId, cameraId, occurredAtMillis, prebufferMillis,
          size: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex')});
        handle = await fs.open(temporary, 'wx', 0o600);
        await handle.writeFile(bytes);
        await handle.sync();
        await handle.close();
        handle = null;
        await fs.rename(temporary, destination);
        const result = await this.outbox.enqueue(job);
        return result;
      } catch (error) {
        await fs.rm(destination, {force: true});
        throw error;
      } finally {
        if (handle) await handle.close();
        await fs.rm(temporary, {force: true});
        this._copying.delete(externalEventId);
      }
    });
    this._copies = operation.catch(() => {});
    return operation;
  }

  _filename(externalEventId) {
    if (!uuid.test(externalEventId)) throw permanent('Nieprawidłowe UUID pliku.');
    return path.join(this.directory, `${externalEventId}.mp4`);
  }

  async _upload(job, signal) {
    let bytes;
    try {
      const info = await fs.lstat(this._filename(job.externalEventId));
      if (!info.isFile() || info.size !== job.size) throw permanent('Nagranie zmieniło rozmiar.');
      bytes = await fs.readFile(this._filename(job.externalEventId));
    } catch (error) {
      if (error.code === 'ENOENT') throw permanent('Brak zapisanego nagrania.');
      throw error;
    }
    if (createHash('sha256').update(bytes).digest('hex') !== job.sha256) {
      throw permanent('Nagranie zostało uszkodzone na dysku.');
    }
    return this.upload({cameraId: job.cameraId, externalEventId: job.externalEventId,
      occurredAtMillis: job.occurredAtMillis, prebufferMillis: job.prebufferMillis,
      mp4Base64: bytes.toString('base64')}, signal);
  }

  async _removeMedia(externalEventId) {
    await fs.rm(this._filename(externalEventId), {force: true});
  }

  async _cleanup() {
    const files = await fs.readdir(this.directory).catch((error) => {
      if (error.code === 'ENOENT') return [];
      throw error;
    });
    for (const filename of files) {
      const externalEventId = filename.slice(0, 36);
      if (!uuid.test(externalEventId) || this._copying.has(externalEventId)) continue;
      const full = path.join(this.directory, filename);
      if (filename === `${externalEventId}.mp4`) {
        if (!this.outbox.hasPending(externalEventId)) await fs.rm(full, {force: true});
      } else if (!filename.endsWith('.json')) {
        const info = await fs.lstat(full).catch((error) => {
          if (error.code === 'ENOENT') return null;
          throw error;
        });
        if (info && this.now() - info.mtimeMs > this.maximumAgeMs) {
          await fs.rm(full, {force: true});
        }
      }
    }
  }

  _report(error) {
    try { this.onError({phase: 'disk', error, willRetry: false}); } catch (_) {}
  }

  async close() {
    this._closed = true;
    if (this._cleanupTimer) clearInterval(this._cleanupTimer);
    await this._copies;
    await this.outbox.close();
    await this._cleanup().catch((error) => this._report(error));
  }
}

module.exports = {ClipUploadQueue, MAX_CLIP_BYTES, MAX_CLIP_AGE_MS};
