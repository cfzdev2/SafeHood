'use strict';

const MAX_COUNTER =
  Number.MAX_SAFE_INTEGER;

const MAX_AGE_SECONDS =
  30 * 24 * 60 * 60;

function boundedInteger(
  value,
  maximum = MAX_COUNTER,
) {
  if (
    !Number.isFinite(value) ||
    value <= 0
  ) {
    return 0;
  }

  return Math.min(
    Math.floor(value),
    maximum,
  );
}

function addCounter(
  current,
  value,
) {
  return Math.min(
    current + boundedInteger(value),
    MAX_COUNTER,
  );
}

function ageInSeconds(
  nowMillis,
  timestampMillis,
) {
  if (
    !Number.isFinite(timestampMillis) ||
    timestampMillis <= 0
  ) {
    return null;
  }

  return boundedInteger(
    Math.max(
      0,
      nowMillis - timestampMillis,
    ) / 1000,
    MAX_AGE_SECONDS,
  );
}

function sessionValues(sessions) {
  if (sessions instanceof Map) {
    return sessions.values();
  }

  if (
    sessions &&
    typeof sessions[Symbol.iterator] ===
      'function'
  ) {
    return sessions;
  }

  return [];
}

function buildBridgeDiagnostics({
  sessions,
  scheduler,
  eventOutbox,
  snapshotQueue,
  clipQueue,
  recordingManager,
  expectedSessions,
  expectedSessionsStartedAtMillis,
  nowMillis = Date.now(),
  uptimeSeconds = process.uptime(),
  memoryUsage = process.memoryUsage(),
} = {}) {
  const now =
    Number.isFinite(nowMillis) ?
      nowMillis :
      Date.now();

  const expectedSessionsAgeSeconds =
    ageInSeconds(
      now,
      expectedSessionsStartedAtMillis,
    );

  const totals = {
    framesReceived: 0,
    framesAnalyzed: 0,
    framesDropped: 0,
    inferenceErrors: 0,
    eventErrors: 0,
  };

  let activeSessions = 0;
  let runningSessions = 0;
  let stalledSessions = 0;
  let oldestStartedAtMillis = null;
  let newestFrameAtMillis = null;

  for (const value of sessionValues(sessions)) {
    const session =
      value?.session || value;

    if (!session) {
      continue;
    }

    activeSessions += 1;

    if (session.status === 'running') {
      runningSessions += 1;
    }

    const stats =
      session.stats || {};

    for (const key of Object.keys(totals)) {
      totals[key] = addCounter(
        totals[key],
        stats[key],
      );
    }

    const startedAtMillis =
      Number(stats.startedAtMillis);

    if (
      Number.isFinite(startedAtMillis) &&
      startedAtMillis > 0 &&
      (
        oldestStartedAtMillis === null ||
        startedAtMillis <
          oldestStartedAtMillis
      )
    ) {
      oldestStartedAtMillis =
        startedAtMillis;
    }

    const lastFrameAtMillis =
      Number(stats.lastFrameAtMillis);

    if (
      Number.isFinite(lastFrameAtMillis) &&
      lastFrameAtMillis > 0 &&
      (
        newestFrameAtMillis === null ||
        lastFrameAtMillis >
          newestFrameAtMillis
      )
    ) {
      newestFrameAtMillis =
        lastFrameAtMillis;
    }

    const sessionAgeSeconds =
      ageInSeconds(
        now,
        startedAtMillis,
      );

    const frameAgeSeconds =
      ageInSeconds(
        now,
        lastFrameAtMillis,
      );

    const startupAgeSeconds =
      expectedSessionsAgeSeconds ??
      sessionAgeSeconds;

    if (
      session.status !== 'running' ||
      (
        startupAgeSeconds !== null &&
        startupAgeSeconds >= 30 &&
        (
          frameAgeSeconds === null ||
          frameAgeSeconds >= 30
        )
      )
    ) {
      stalledSessions += 1;
    }
  }

  const rssBytes =
    boundedInteger(
      memoryUsage?.rss,
    );

  const heapUsedBytes =
    Math.min(
      boundedInteger(
        memoryUsage?.heapUsed,
      ),
      rssBytes,
    );

  const normalizedExpectedSessions =
    expectedSessions == null ?
      activeSessions :
      boundedInteger(
        expectedSessions,
        100,
      );

  return {
    schemaVersion: 1,
    uptimeSeconds:
      boundedInteger(
        uptimeSeconds,
        10 * 365 * 24 * 60 * 60,
      ),
    rssBytes,
    heapUsedBytes,
    aiExpectedSessions:
      normalizedExpectedSessions,
    aiActiveSessions:
      boundedInteger(
        activeSessions,
        100,
      ),
    aiRunningSessions:
      boundedInteger(
        runningSessions,
        100,
      ),
    aiStalledSessions:
      boundedInteger(
        stalledSessions,
        100,
      ),
    ...totals,
    oldestSessionAgeSeconds:
      ageInSeconds(
        now,
        oldestStartedAtMillis,
      ),
    lastFrameAgeSeconds:
      ageInSeconds(
        now,
        newestFrameAtMillis,
      ),
    schedulerBusy:
      scheduler?.isRunning === true,
    pendingInference:
      boundedInteger(
        scheduler?.pendingCount,
        1000,
      ),
    pendingEvents:
      boundedInteger(
        eventOutbox?.pendingCount,
        10000,
      ),
    pendingSnapshots:
      boundedInteger(
        snapshotQueue?.pendingCount,
        1000,
      ),
    pendingClips:
      boundedInteger(
        clipQueue?.pendingCount,
        1000,
      ),
    recordingBuffers:
      boundedInteger(
        recordingManager?.bufferCount,
        100,
      ),
    activeRecordings:
      boundedInteger(
        recordingManager?.activeCaptureCount,
        100,
      ),
  };
}

module.exports = {
  buildBridgeDiagnostics,
};
