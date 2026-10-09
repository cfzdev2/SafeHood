"use strict";

const classTypes = Object.freeze({
  person: "person",
  bicycle: "vehicle",
  car: "vehicle",
  motorcycle: "vehicle",
  bus: "vehicle",
  truck: "vehicle",
});

const supportedModelIds = new Set([
  "yolox-nano-coco-c789161e",
]);

/**
 * Odczytuje czas ze znacznika Firestore albo prostej wartości.
 * @param {*} value Wartość czasu.
 * @return {number|null} Czas w milisekundach.
 */
function readMillis(value) {
  if (value && typeof value.toMillis === "function") {
    const millis = value.toMillis();
    return Number.isFinite(millis) ? millis : null;
  }
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === "string") {
    const millis = Date.parse(value);
    return Number.isFinite(millis) ? millis : null;
  }
  return null;
}

/**
 * Waliduje metadane jednego potwierdzonego śladu z Bridge.
 * @param {*} value Surowe metadane.
 * @param {{type: string, occurredAtMillis: number}} context Kontekst zdarzenia.
 * @return {Object|null} Kanoniczne metadane albo null dla starego Bridge.
 */
function normalizeBridgeAiMetadata(value, {type, occurredAtMillis}) {
  if (value == null) {
    return null;
  }
  if (!value || typeof value !== "object" || Array.isArray(value) ||
      value.schemaVersion !== 1) {
    throw new TypeError("Nieprawidłowe metadane AI.");
  }

  const className = typeof value.className === "string" ?
    value.className.trim().toLowerCase() : "";
  const modelId = typeof value.modelId === "string" ?
    value.modelId.trim().toLowerCase() : "";
  const firstSeenAtMillis = readMillis(value.firstSeenAt);
  const lastSeenAtMillis = readMillis(value.lastSeenAt);

  if (classTypes[className] !== type || !supportedModelIds.has(modelId) ||
      !Number.isInteger(value.detectionCount) ||
      value.detectionCount < 1 || value.detectionCount > 1000 ||
      firstSeenAtMillis === null || lastSeenAtMillis === null ||
      firstSeenAtMillis <= 0 || lastSeenAtMillis < firstSeenAtMillis ||
      lastSeenAtMillis - firstSeenAtMillis > 60000 ||
      !Number.isFinite(occurredAtMillis) ||
      Math.abs(lastSeenAtMillis - occurredAtMillis) > 2000) {
    throw new TypeError("Nieprawidłowe metadane AI.");
  }

  return {
    schemaVersion: 1,
    className,
    detectionCount: value.detectionCount,
    firstSeenAtMillis,
    lastSeenAtMillis,
    modelId,
  };
}

/**
 * Czyta zapisane podsumowanie. Uszkodzone starsze dane są pomijane.
 * @param {*} value Zapisane podsumowanie.
 * @return {Object|null} Kanoniczna wartość.
 */
function readStoredAiMetadata(value) {
  if (!value || typeof value !== "object" || Array.isArray(value) ||
      value.schemaVersion !== 1) {
    return null;
  }
  const integers = [
    value.totalObjects,
    value.personCount,
    value.vehicleCount,
    value.detectionFrameCount,
  ];
  if (integers.some((item) => !Number.isInteger(item) || item < 0) ||
      value.totalObjects < 1 || value.totalObjects > 10000 ||
      value.detectionFrameCount < value.totalObjects ||
      value.detectionFrameCount > 1000000 ||
      value.personCount + value.vehicleCount !== value.totalObjects) {
    return null;
  }

  const classCounts = {};
  if (!value.classCounts || typeof value.classCounts !== "object" ||
      Array.isArray(value.classCounts)) {
    return null;
  }
  for (const [className, count] of Object.entries(value.classCounts)) {
    if (!Object.hasOwn(classTypes, className) || !Number.isInteger(count) ||
        count < 1 || count > value.totalObjects) {
      return null;
    }
    classCounts[className] = count;
  }
  const classTotal = Object.values(classCounts)
      .reduce((sum, count) => sum + count, 0);
  const personTotal = Object.entries(classCounts)
      .filter(([name]) => classTypes[name] === "person")
      .reduce((sum, [, count]) => sum + count, 0);
  if (classTotal !== value.totalObjects || personTotal !== value.personCount) {
    return null;
  }

  const maximumConfidence = value.maximumConfidence;
  if (maximumConfidence !== null &&
      (!Number.isFinite(maximumConfidence) || maximumConfidence < 0 ||
       maximumConfidence > 1)) {
    return null;
  }
  const firstSeenAtMillis = readMillis(value.firstSeenAt);
  const lastSeenAtMillis = readMillis(value.lastSeenAt);
  if (firstSeenAtMillis === null || lastSeenAtMillis === null ||
      firstSeenAtMillis <= 0 || lastSeenAtMillis < firstSeenAtMillis) {
    return null;
  }
  if (!Array.isArray(value.modelIds) || value.modelIds.length < 1 ||
      value.modelIds.length > 4 ||
      value.modelIds.some((id) => typeof id !== "string" ||
        !supportedModelIds.has(id))) {
    return null;
  }

  return {
    schemaVersion: 1,
    totalObjects: value.totalObjects,
    personCount: value.personCount,
    vehicleCount: value.vehicleCount,
    classCounts,
    maximumConfidence,
    firstSeenAtMillis,
    lastSeenAtMillis,
    detectionFrameCount: value.detectionFrameCount,
    modelIds: [...new Set(value.modelIds)].sort(),
  };
}

/**
 * Łączy kolejny unikalny obiekt AI z podsumowaniem zdarzenia.
 * @param {*} current Obecne podsumowanie zdarzenia.
 * @param {Object} incoming Zweryfikowany ślad Bridge.
 * @param {Object} context Kontekst zapisu zdarzenia.
 * @return {Object} Podsumowanie gotowe do Firestore.
 */
function mergeCameraEventAiMetadata(
    current,
    incoming,
    {type, confidence, Timestamp},
) {
  const previous = readStoredAiMetadata(current);
  const classCounts = previous ? {...previous.classCounts} : {};
  classCounts[incoming.className] = (classCounts[incoming.className] || 0) + 1;
  const personIncrement = type === "person" ? 1 : 0;
  const vehicleIncrement = type === "vehicle" ? 1 : 0;
  const previousConfidence = previous ? previous.maximumConfidence : null;
  let maximumConfidence = previousConfidence;
  if (Number.isFinite(confidence)) {
    maximumConfidence = maximumConfidence === null ?
      confidence : Math.max(maximumConfidence, confidence);
  }
  const modelIds = [...new Set([
    ...(previous ? previous.modelIds : []),
    incoming.modelId,
  ])].sort().slice(0, 4);
  const firstSeenAtMillis = previous ?
    Math.min(previous.firstSeenAtMillis, incoming.firstSeenAtMillis) :
    incoming.firstSeenAtMillis;
  const lastSeenAtMillis = previous ?
    Math.max(previous.lastSeenAtMillis, incoming.lastSeenAtMillis) :
    incoming.lastSeenAtMillis;

  return {
    schemaVersion: 1,
    totalObjects: (previous ? previous.totalObjects : 0) + 1,
    personCount: (previous ? previous.personCount : 0) + personIncrement,
    vehicleCount: (previous ? previous.vehicleCount : 0) + vehicleIncrement,
    classCounts,
    maximumConfidence,
    firstSeenAt: Timestamp.fromMillis(firstSeenAtMillis),
    lastSeenAt: Timestamp.fromMillis(lastSeenAtMillis),
    detectionFrameCount:
      (previous ? previous.detectionFrameCount : 0) + incoming.detectionCount,
    modelIds,
  };
}

module.exports = {
  mergeCameraEventAiMetadata,
  normalizeBridgeAiMetadata,
  readStoredAiMetadata,
};
