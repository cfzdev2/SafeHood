'use strict';

class IncidentLivePublisher {
  constructor({frameCache, publish, now = Date.now, maximumSessions = 25}) {
    Object.assign(this, {frameCache, publish, now, maximumSessions});
    this.sessions = new Map();
    this.closed = false;
    this.active = 0;
  }

  sync(instructions) {
    if (this.closed || !Array.isArray(instructions)) return;
    const desired = new Set();
    for (const value of instructions.slice(0, this.maximumSessions)) {
      if (!value || !/^[a-f0-9]{32}$/.test(value.sessionId) ||
          typeof value.incidentId !== 'string' || !value.incidentId || value.incidentId.length > 256 || /[/\0]/.test(value.incidentId) ||
          typeof value.cameraId !== 'string' || !value.cameraId || value.cameraId.length > 256 || /[/\0]/.test(value.cameraId) ||
          !Number.isFinite(value.expiresAtMillis) || value.expiresAtMillis <= this.now()) continue;
      desired.add(value.sessionId);
      if (!this.sessions.has(value.sessionId)) {
        const session = {...value, controller: new AbortController(), timer: null};
        this.sessions.set(value.sessionId, session);
        void this._tick(session);
      }
    }
    for (const [id, session] of this.sessions) {
      if (!desired.has(id)) this._stop(session);
    }
  }

  async _tick(session) {
    if (this.closed || this.sessions.get(session.sessionId) !== session) return;
    if (session.expiresAtMillis <= this.now()) {
      this._stop(session);
      return;
    }
    const frame = this.frameCache.readPreview(session.cameraId);
    if (frame && this.active < 4) {
      this.active++;
      try {
        await this.publish({incidentId: session.incidentId, sessionId: session.sessionId,
          capturedAtMillis: frame.capturedAtMillis, jpegBase64: frame.jpeg.toString('base64')},
        session.controller.signal);
      } catch (error) {
        if ([400, 401, 403, 404].includes(Number(error.statusCode))) this._stop(session);
      } finally { this.active--; }
    }
    if (!this.closed && this.sessions.get(session.sessionId) === session) {
      session.timer = setTimeout(() => void this._tick(session), 1100);
      session.timer.unref?.();
    }
  }

  _stop(session) {
    this.sessions.delete(session.sessionId);
    clearTimeout(session.timer);
    session.controller.abort();
  }

  close() {
    this.closed = true;
    for (const session of this.sessions.values()) this._stop(session);
  }
}

module.exports = {IncidentLivePublisher};
