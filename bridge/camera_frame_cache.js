'use strict';

// One bounded JPEG and small motion samples from the same camera connection.
class CameraFrameCache {
  constructor({now = Date.now, maximumBytes = 512 * 1024} = {}) {
    this.now = now;
    this.maximumBytes = maximumBytes;
    this.frames = new Map();
    this.previews = new Map();
    this.listeners = new Map();
  }

  snapshot(cameraId, jpeg) {
    if (!Buffer.isBuffer(jpeg) || jpeg.length < 4 || jpeg.length > this.maximumBytes ||
        jpeg[0] !== 255 || jpeg[1] !== 216 || jpeg.at(-2) !== 255 || jpeg.at(-1) !== 217) return;
    this.frames.set(cameraId, {jpeg: Buffer.from(jpeg), capturedAtMillis: this.now()});
  }

  read(cameraId, atMillis = this.now()) {
    const frame = this.frames.get(cameraId);
    return frame && Math.abs(frame.capturedAtMillis - atMillis) <= 3000 &&
      this.now() - frame.capturedAtMillis <= 3000 ? frame : null;
  }

  preview(cameraId, jpeg) {
    if (Buffer.isBuffer(jpeg) && jpeg.length >= 4 && jpeg.length <= 96 * 1024) {
      this.previews.set(cameraId, {jpeg: Buffer.from(jpeg), capturedAtMillis: this.now()});
    }
  }

  readPreview(cameraId) {
    const frame = this.previews.get(cameraId);
    return frame && this.now() - frame.capturedAtMillis <= 3000 ? frame : null;
  }

  sample(cameraId, frame) {
    for (const listener of this.listeners.get(cameraId) || []) listener.onFrame(frame);
  }

  lost(cameraId) {
    this.frames.delete(cameraId);
    this.previews.delete(cameraId);
    for (const listener of this.listeners.get(cameraId) || []) listener.onExit();
  }

  motionSource(cameraId, input, callbacks, ensure) {
    let closed = false;
    return {
      start: () => {
        if (closed) return;
        const listeners = this.listeners.get(cameraId) || new Set();
        listeners.add(callbacks);
        this.listeners.set(cameraId, listeners);
        Promise.resolve().then(() => ensure(input)).catch(() => {
          if (!closed) callbacks.onExit();
        });
      },
      stop: async () => {
        closed = true;
        this.listeners.get(cameraId)?.delete(callbacks);
        if (!this.listeners.get(cameraId)?.size) this.listeners.delete(cameraId);
      },
    };
  }
}

class JpegFrameParser {
  constructor(onFrame, maximumBytes = 96 * 1024) {
    this.onFrame = onFrame;
    this.maximumBytes = maximumBytes;
    this.pending = Buffer.alloc(0);
  }

  add(bytes) {
    this.pending = Buffer.concat([this.pending, bytes]);
    for (;;) {
      const start = this.pending.indexOf(Buffer.from([255, 216]));
      if (start < 0) {
        this.pending = this.pending.subarray(-1);
        return;
      }
      if (start) this.pending = this.pending.subarray(start);
      const end = this.pending.indexOf(Buffer.from([255, 217]), 2);
      if (end < 0) break;
      if (end + 2 <= this.maximumBytes) this.onFrame(Buffer.from(this.pending.subarray(0, end + 2)));
      this.pending = this.pending.subarray(end + 2);
    }
    if (this.pending.length > this.maximumBytes) this.pending = Buffer.alloc(0);
  }
}

module.exports = {CameraFrameCache, JpegFrameParser};
