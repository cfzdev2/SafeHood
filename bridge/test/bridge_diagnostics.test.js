'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');

const {
  buildBridgeDiagnostics,
} = require('../ai/bridge_diagnostics');

function session({
  status = 'running',
  startedAtMillis = 1000,
  lastFrameAtMillis = 90000,
  framesReceived = 20,
  framesAnalyzed = 18,
  framesDropped = 1,
  inferenceErrors = 1,
  eventErrors = 0,
} = {}) {
  return {
    status,
    get stats() {
      return {
        startedAtMillis,
        lastFrameAtMillis,
        framesReceived,
        framesAnalyzed,
        framesDropped,
        inferenceErrors,
        eventErrors,
      };
    },
  };
}

test('agreguje bezpieczne statystyki Bridge i AI', () => {
  const diagnostics = buildBridgeDiagnostics({
    sessions: new Map([
      ['camera-1', {session: session()}],
      ['camera-2', {session: session({
        startedAtMillis: 5000,
        lastFrameAtMillis: 95000,
        framesReceived: 10,
        framesAnalyzed: 10,
        framesDropped: 0,
        inferenceErrors: 0,
        eventErrors: 2,
      })}],
    ]),
    scheduler: {isRunning: true, pendingCount: 1},
    eventOutbox: {pendingCount: 2},
    snapshotQueue: {pendingCount: 3},
    clipQueue: {pendingCount: 4},
    recordingManager: {bufferCount: 2, activeCaptureCount: 1},
    expectedSessions: 2,
    nowMillis: 100000,
    uptimeSeconds: 120.8,
    memoryUsage: {rss: 200000000, heapUsed: 75000000},
  });

  assert.deepEqual(diagnostics, {
    schemaVersion: 1,
    uptimeSeconds: 120,
    rssBytes: 200000000,
    heapUsedBytes: 75000000,
    aiExpectedSessions: 2,
    aiActiveSessions: 2,
    aiRunningSessions: 2,
    aiStalledSessions: 0,
    framesReceived: 30,
    framesAnalyzed: 28,
    framesDropped: 1,
    inferenceErrors: 1,
    eventErrors: 2,
    oldestSessionAgeSeconds: 99,
    lastFrameAgeSeconds: 5,
    schedulerBusy: true,
    pendingInference: 1,
    pendingEvents: 2,
    pendingSnapshots: 3,
    pendingClips: 4,
    recordingBuffers: 2,
    activeRecordings: 1,
  });
});

test('zachowuje oczekiwaną liczbę sesji mimo ich awarii', () => {
  const diagnostics = buildBridgeDiagnostics({
    sessions: [],
    expectedSessions: 2,
    nowMillis: 100000,
    memoryUsage: {rss: 100, heapUsed: 50},
  });

  assert.equal(diagnostics.aiExpectedSessions, 2);
  assert.equal(diagnostics.aiActiveSessions, 0);
  assert.equal(diagnostics.aiRunningSessions, 0);
});

test('rozpoznaje sesję bez klatek jako zatrzymaną po 30 sekundach', () => {
  const diagnostics = buildBridgeDiagnostics({
    sessions: [session({
      startedAtMillis: 1000,
      lastFrameAtMillis: null,
      framesReceived: 0,
      framesAnalyzed: 0,
      framesDropped: 0,
      inferenceErrors: 0,
    })],
    nowMillis: 40000,
    uptimeSeconds: 40,
    memoryUsage: {rss: 100, heapUsed: 50},
  });

  assert.equal(diagnostics.aiStalledSessions, 1);
  assert.equal(diagnostics.lastFrameAgeSeconds, null);
  assert.equal(diagnostics.oldestSessionAgeSeconds, 39);
});

test('sesja startująca nie zgłasza przedwcześnie awarii', () => {
  const diagnostics = buildBridgeDiagnostics({
    sessions: [session({
      startedAtMillis: 1000,
      lastFrameAtMillis: null,
      framesReceived: 0,
      framesAnalyzed: 0,
      framesDropped: 0,
      inferenceErrors: 0,
    })],
    nowMillis: 20000,
    memoryUsage: {rss: 100, heapUsed: 50},
  });

  assert.equal(diagnostics.aiStalledSessions, 0);
});

test('ponowne starty nie resetują czasu oczekiwania na pierwszą klatkę', () => {
  const diagnostics = buildBridgeDiagnostics({
    sessions: [session({
      startedAtMillis: 35000,
      lastFrameAtMillis: null,
      framesReceived: 0,
      framesAnalyzed: 0,
      framesDropped: 0,
      inferenceErrors: 0,
    })],
    expectedSessions: 1,
    expectedSessionsStartedAtMillis: 1000,
    nowMillis: 40000,
    memoryUsage: {rss: 100, heapUsed: 50},
  });

  assert.equal(diagnostics.aiRunningSessions, 1);
  assert.equal(diagnostics.aiStalledSessions, 1);
  assert.equal(diagnostics.oldestSessionAgeSeconds, 5);
  assert.equal(diagnostics.lastFrameAgeSeconds, null);
});

test('nie umieszcza źródeł kamer ani danych poufnych w raporcie', () => {
  const value = session();
  value.input = 'rtsp://admin:secret@camera.local/live';

  const diagnostics = buildBridgeDiagnostics({
    sessions: [{
      camera: {id: 'private-camera', password: 'secret'},
      input: value.input,
      session: value,
    }],
    nowMillis: 100000,
    memoryUsage: {rss: 100, heapUsed: 50},
  });

  const serialized = JSON.stringify(diagnostics);

  assert.equal(serialized.includes('private-camera'), false);
  assert.equal(serialized.includes('secret'), false);
  assert.equal(serialized.includes('rtsp'), false);
});
