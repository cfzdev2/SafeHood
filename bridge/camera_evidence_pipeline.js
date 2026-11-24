'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const {createHash, randomUUID} = require('node:crypto');
const {AiEventOutbox} = require('./ai/event_outbox');

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const maximumBytes = 512 * 1024;
const permanent = () => Object.assign(new Error('Nieprawidłowe zdjęcie zdarzenia.'), {retryable: false});

function normalizeJob(job) {
  if (!job || !uuid.test(job.externalEventId) || typeof job.cameraId !== 'string' ||
      !job.cameraId || /[/\0]/.test(job.cameraId) || job.cameraId.length > 256 ||
      !Number.isSafeInteger(job.occurredAtMillis) || !Number.isSafeInteger(job.capturedAtMillis) ||
      Math.abs(job.occurredAtMillis - job.capturedAtMillis) > 5000 ||
      !Number.isSafeInteger(job.size) || job.size < 4 || job.size > maximumBytes ||
      !/^[a-f0-9]{64}$/.test(job.sha256)) throw permanent();
  return {cameraId: job.cameraId, externalEventId: job.externalEventId,
    occurredAtMillis: job.occurredAtMillis, capturedAtMillis: job.capturedAtMillis,
    size: job.size, sha256: job.sha256};
}

class DurableSnapshotQueue {
  constructor({directory, upload, maximumJobs = 16, now = Date.now, retryDelaysMs,
    onError = () => {}}) {
    Object.assign(this, {directory, upload, maximumJobs, now, onError});
    this._writes = Promise.resolve();
    this._closed = false;
    this.outbox = new AiEventOutbox({directory, now, maximumJobs,
      maximumAgeMs: 24 * 60 * 60 * 1000,
      ...(retryDelaysMs ? {retryDelaysMs} : {}),
      payloadNormalizer: normalizeJob, createId: (job) => job.externalEventId,
      resultNormalizer: (value, id) => {
        if (value?.ok !== true || value.externalEventId !== id ||
            typeof value.eventId !== 'string' || !value.eventId ||
            typeof value.snapshotPath !== 'string' ||
            !value.snapshotPath.endsWith(`/cameraEvents/${value.eventId}/snapshot.jpg`)) throw permanent();
        return value;
      },
      deliver: async (job, signal) => {
        let jpeg;
        try { jpeg = await fs.readFile(this._file(job.externalEventId)); } catch (error) {
          if (error.code === 'ENOENT') throw permanent();
          throw error;
        }
        if (jpeg.length !== job.size || createHash('sha256').update(jpeg).digest('hex') !== job.sha256) {
          throw permanent();
        }
        return this.upload({cameraId: job.cameraId, externalEventId: job.externalEventId,
          occurredAtMillis: job.occurredAtMillis, capturedAtMillis: job.capturedAtMillis,
          jpegBase64: jpeg.toString('base64')}, signal);
      },
      onDelivered: ({payload}) => void fs.rm(this._file(payload.externalEventId), {force: true})
        .catch(() => {}),
      onError: (details) => {
        if (!details.willRetry && details.payload) {
          void fs.rm(this._file(details.payload.externalEventId), {force: true}).catch(() => {});
        }
        onError(details);
      },
    });
  }

  get pendingCount() { return this.outbox.pendingCount; }
  _file(id) {
    if (!uuid.test(id)) throw permanent();
    return path.join(this.directory, `${id}.jpg`);
  }

  async start() {
    await this.outbox.start();
    for (const file of await fs.readdir(this.directory)) {
      const match = /^([a-f0-9-]{36})\.jpg$/.exec(file);
      if (match && !this.outbox.hasPending(match[1])) await fs.rm(this._file(match[1]), {force: true});
    }
  }

  enqueue({cameraId, externalEventId, occurredAtMillis, capturedAtMillis, jpeg}) {
    const write = this._writes.then(async () => {
      if (this._closed || !Buffer.isBuffer(jpeg) || jpeg[0] !== 255 || jpeg[1] !== 216 ||
          jpeg.at(-2) !== 255 || jpeg.at(-1) !== 217) throw permanent();
      const job = normalizeJob({cameraId, externalEventId, occurredAtMillis, capturedAtMillis,
        size: jpeg.length, sha256: createHash('sha256').update(jpeg).digest('hex')});
      await this.outbox.start();
      if (this.outbox.hasPending(externalEventId)) return 'duplicate';
      if (this.pendingCount >= this.maximumJobs) throw new Error('Kolejka zdjęć jest pełna.');
      const file = this._file(externalEventId);
      const temporary = `${file}.${randomUUID()}.tmp`;
      let handle;
      try {
        handle = await fs.open(temporary, 'wx', 0o600);
        await handle.writeFile(jpeg);
        await handle.sync();
        await handle.close();
        handle = null;
        await fs.rename(temporary, file);
        return await this.outbox.enqueue(job);
      } catch (error) {
        await fs.rm(file, {force: true});
        throw error;
      } finally {
        if (handle) await handle.close();
        await fs.rm(temporary, {force: true});
      }
    });
    this._writes = write.catch(() => {});
    return write;
  }

  async close() {
    this._closed = true;
    await this._writes;
    await this.outbox.close();
  }
}

class CameraEvidencePipeline {
  constructor({eventOutbox, snapshotQueue, recordingManager, frameCache, now = Date.now,
    onError = () => {}}) {
    Object.assign(this, {eventOutbox, snapshotQueue, recordingManager, frameCache, now, onError});
  }

  async ingest(camera, detection) {
    const occurredAtMillis = Number.isFinite(detection.occurredAtMillis) ? detection.occurredAtMillis :
      Number.isFinite(Date.parse(detection.occurredAt)) ? Date.parse(detection.occurredAt) : this.now();
    // Copy the event-time frame before any network wait; never fetch a later scene on retry.
    const frame = this.frameCache.read(camera.id, occurredAtMillis);
    const result = await this.eventOutbox.enqueue({cameraId: camera.id,
      type: detection.type, source: detection.source || 'onvif',
      confidence: detection.confidence ?? null, occurredAt: new Date(occurredAtMillis).toISOString(),
      ...(detection.aiMetadata ? {aiMetadata: detection.aiMetadata} : {})});
    if (camera.motionDetectionEnabled || camera.aiRecordingEnabled) {
      try {
        this.recordingManager.capture(camera.id, {externalEventId: result.externalEventId, occurredAtMillis});
      } catch (error) { this.onError({cameraId: camera.id, error}); }
    }
    if (frame) {
      try {
        await this.snapshotQueue.enqueue({cameraId: camera.id, externalEventId: result.externalEventId,
          occurredAtMillis, capturedAtMillis: frame.capturedAtMillis, jpeg: frame.jpeg});
      } catch (error) { this.onError({cameraId: camera.id, error}); }
    }
    return result;
  }
}

module.exports = {DurableSnapshotQueue, CameraEvidencePipeline};
