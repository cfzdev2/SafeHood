"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");

const {
  BridgeDiagnosticsError,
  normalizeBridgeDiagnostics,
} = require("../bridge_diagnostics");

/**
 * Buduje poprawny raport testowy.
 *
 * @param {Object} overrides Nadpisywane pola.
 * @return {Object} Raport diagnostyczny.
 */
function report(overrides = {}) {
  return {
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
    eventErrors: 0,
    oldestSessionAgeSeconds: 99,
    lastFrameAgeSeconds: 5,
    schedulerBusy: true,
    pendingInference: 1,
    pendingEvents: 2,
    pendingSnapshots: 1,
    pendingClips: 1,
    recordingBuffers: 2,
    activeRecordings: 1,
    ...overrides,
  };
}

test("waliduje raport i wylicza zdrowy stan", () => {
  const normalized =
      normalizeBridgeDiagnostics(
          report(),
      );

  assert.equal(
      normalized.health,
      "healthy",
  );

  assert.deepEqual(
      Object.keys(normalized).sort(),
      [
        ...Object.keys(report()),
        "health",
      ].sort(),
  );
});

test("brak aktywnego AI jest stanem bezczynnym", () => {
  const normalized =
      normalizeBridgeDiagnostics(
          report({
            aiActiveSessions: 0,
            aiExpectedSessions: 0,
            aiRunningSessions: 0,
            framesReceived: 0,
            framesAnalyzed: 0,
            framesDropped: 0,
            inferenceErrors: 0,
            oldestSessionAgeSeconds: null,
            lastFrameAgeSeconds: null,
            recordingBuffers: 0,
            activeRecordings: 0,
          }),
      );

  assert.equal(normalized.health, "idle");
});

test("brak wymaganej sesji AI jest problemem", () => {
  const normalized =
      normalizeBridgeDiagnostics(
          report({
            aiActiveSessions: 1,
            aiRunningSessions: 1,
          }),
      );

  assert.equal(normalized.health, "problem");
});

test("wykrywa zatrzymaną sesję AI", () => {
  const normalized =
      normalizeBridgeDiagnostics(
          report({
            aiRunningSessions: 1,
            aiStalledSessions: 1,
            lastFrameAgeSeconds: 45,
          }),
      );

  assert.equal(normalized.health, "problem");
});

test("wykrywa przeciążenie bez oznaczania awarii", () => {
  const normalized =
      normalizeBridgeDiagnostics(
          report({
            framesReceived: 100,
            framesAnalyzed: 40,
            framesDropped: 60,
            inferenceErrors: 0,
          }),
      );

  assert.equal(normalized.health, "degraded");
});

test("odrzuca nadmiarowe pola i dane tekstowe", () => {
  for (const value of [
    report({source: "rtsp://admin:secret@camera/live"}),
    report({framesReceived: "30"}),
    report({schemaVersion: 2}),
  ]) {
    assert.throws(
        () => normalizeBridgeDiagnostics(value),
        BridgeDiagnosticsError,
    );
  }
});

test("odrzuca niespójne liczniki i pamięć", () => {
  for (const value of [
    report({framesAnalyzed: 31}),
    report({framesAnalyzed: 29}),
    report({heapUsedBytes: 300000000}),
    report({aiRunningSessions: 3}),
    report({activeRecordings: -1}),
  ]) {
    assert.throws(
        () => normalizeBridgeDiagnostics(value),
        BridgeDiagnosticsError,
    );
  }
});
