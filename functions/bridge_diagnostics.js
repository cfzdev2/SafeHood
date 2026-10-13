"use strict";

const maximumCounter =
    Number.MAX_SAFE_INTEGER;

const fields = Object.freeze([
  "schemaVersion",
  "uptimeSeconds",
  "rssBytes",
  "heapUsedBytes",
  "aiExpectedSessions",
  "aiActiveSessions",
  "aiRunningSessions",
  "aiStalledSessions",
  "framesReceived",
  "framesAnalyzed",
  "framesDropped",
  "inferenceErrors",
  "eventErrors",
  "oldestSessionAgeSeconds",
  "lastFrameAgeSeconds",
  "schedulerBusy",
  "pendingInference",
  "pendingEvents",
  "pendingSnapshots",
  "pendingClips",
  "recordingBuffers",
  "activeRecordings",
]);

/** Błąd walidacji raportu diagnostycznego. */
class BridgeDiagnosticsError extends Error {
  /** Tworzy bezpieczny błąd bez danych raportu. */
  constructor() {
    super(
        "Nieprawidłowa diagnostyka Bridge.",
    );

    this.name =
        "BridgeDiagnosticsError";
  }
}

/**
 * Sprawdza ograniczoną liczbę całkowitą.
 *
 * @param {unknown} value Wartość do sprawdzenia.
 * @param {number} maximum Największa wartość.
 * @return {boolean} Czy wartość jest poprawna.
 */
function isIntegerInRange(
    value,
    maximum,
) {
  return Number.isSafeInteger(value) &&
      value >= 0 &&
      value <= maximum;
}

/**
 * Sprawdza wiek albo brak pomiaru.
 *
 * @param {unknown} value Wiek w sekundach.
 * @return {boolean} Czy wartość jest poprawna.
 */
function isOptionalAge(value) {
  return value === null ||
      isIntegerInRange(
          value,
          30 * 24 * 60 * 60,
      );
}

/**
 * Wyznacza czytelny stan diagnostyczny.
 *
 * @param {Object} value Znormalizowane liczniki.
 * @return {string} Stan dla aplikacji mobilnej.
 */
function classifyBridgeDiagnostics(value) {
  if (value.aiExpectedSessions === 0) {
    return "idle";
  }

  if (
    value.aiActiveSessions !==
      value.aiExpectedSessions ||
    value.aiRunningSessions !==
      value.aiExpectedSessions ||
    value.aiStalledSessions > 0 ||
    value.pendingEvents >= 1000 ||
    value.pendingSnapshots >= 16 ||
    value.pendingClips >= 16 ||
    value.pendingInference >= 32
  ) {
    return "problem";
  }

  const highDropRate =
      value.framesReceived >= 20 &&
      value.framesDropped >
        value.framesReceived / 2;

  const highErrorRate =
      value.framesReceived >= 20 &&
      value.inferenceErrors >= 5 &&
      value.inferenceErrors >
        value.framesReceived / 10;

  if (
    highDropRate ||
    highErrorRate ||
    value.pendingEvents >= 100 ||
    value.pendingSnapshots >= 8 ||
    value.pendingClips >= 8 ||
    value.pendingInference >= 8
  ) {
    return "degraded";
  }

  return "healthy";
}

/**
 * Waliduje raport uwierzytelnionego Bridge.
 * Raport nie zawiera identyfikatorów kamer,
 * adresów strumieni ani danych logowania.
 *
 * @param {unknown} input Dane odebrane z Bridge.
 * @return {Object} Bezpieczny raport do Firestore.
 */
function normalizeBridgeDiagnostics(input) {
  if (
    !input ||
    typeof input !== "object" ||
    Array.isArray(input)
  ) {
    throw new BridgeDiagnosticsError();
  }

  const inputKeys =
      Object.keys(input).sort();

  const expectedKeys =
      [...fields].sort();

  if (
    inputKeys.length !==
      expectedKeys.length ||
    inputKeys.some(
        (key, index) =>
          key !== expectedKeys[index],
    )
  ) {
    throw new BridgeDiagnosticsError();
  }

  if (
    input.schemaVersion !== 1 ||
    !isIntegerInRange(
        input.uptimeSeconds,
        10 * 365 * 24 * 60 * 60,
    ) ||
    !isIntegerInRange(
        input.rssBytes,
        1024 * 1024 * 1024 * 1024,
    ) ||
    !isIntegerInRange(
        input.heapUsedBytes,
        input.rssBytes,
    ) ||
    !isIntegerInRange(
        input.aiExpectedSessions,
        100,
    ) ||
    !isIntegerInRange(
        input.aiActiveSessions,
        100,
    ) ||
    !isIntegerInRange(
        input.aiRunningSessions,
        input.aiActiveSessions,
    ) ||
    !isIntegerInRange(
        input.aiStalledSessions,
        input.aiActiveSessions,
    ) ||
    !isIntegerInRange(
        input.framesReceived,
        maximumCounter,
    ) ||
    !isIntegerInRange(
        input.framesAnalyzed,
        input.framesReceived,
    ) ||
    !isIntegerInRange(
        input.framesDropped,
        input.framesReceived,
    ) ||
    !isIntegerInRange(
        input.inferenceErrors,
        input.framesReceived,
    ) ||
    input.framesAnalyzed >
      input.framesReceived -
        input.framesDropped -
        input.inferenceErrors ||
    !isIntegerInRange(
        input.eventErrors,
        maximumCounter,
    ) ||
    !isOptionalAge(
        input.oldestSessionAgeSeconds,
    ) ||
    !isOptionalAge(
        input.lastFrameAgeSeconds,
    ) ||
    typeof input.schedulerBusy !==
      "boolean" ||
    !isIntegerInRange(
        input.pendingInference,
        1000,
    ) ||
    !isIntegerInRange(
        input.pendingEvents,
        10000,
    ) ||
    !isIntegerInRange(
        input.pendingSnapshots,
        1000,
    ) ||
    !isIntegerInRange(
        input.pendingClips,
        1000,
    ) ||
    !isIntegerInRange(
        input.recordingBuffers,
        100,
    ) ||
    !isIntegerInRange(
        input.activeRecordings,
        100,
    )
  ) {
    throw new BridgeDiagnosticsError();
  }

  const normalized = {};

  for (const field of fields) {
    normalized[field] =
        input[field];
  }

  return {
    ...normalized,
    health:
        classifyBridgeDiagnostics(
            normalized,
        ),
  };
}

module.exports = {
  BridgeDiagnosticsError,
  classifyBridgeDiagnostics,
  normalizeBridgeDiagnostics,
};
