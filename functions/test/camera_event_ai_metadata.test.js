"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {Timestamp} = require("firebase-admin/firestore");
const {
  mergeCameraEventAiMetadata,
  normalizeBridgeAiMetadata,
  readStoredAiMetadata,
} = require("../camera_event_ai_metadata");

const occurredAtMillis = Date.parse("2026-10-09T12:00:01.000Z");
const incoming = {
  schemaVersion: 1,
  className: "bus",
  detectionCount: 3,
  firstSeenAt: "2026-10-09T12:00:00.000Z",
  lastSeenAt: "2026-10-09T12:00:01.000Z",
  modelId: "yolox-nano-coco-c789161e",
};

test("waliduje pojedynczy ślad z uwierzytelnionego Bridge", () => {
  assert.deepEqual(normalizeBridgeAiMetadata(incoming, {
    type: "vehicle",
    occurredAtMillis,
  }), {
    schemaVersion: 1,
    className: "bus",
    detectionCount: 3,
    firstSeenAtMillis: occurredAtMillis - 1000,
    lastSeenAtMillis: occurredAtMillis,
    modelId: "yolox-nano-coco-c789161e",
  });
});

test("odrzuca niespójny typ, czas, licznik i model", () => {
  for (const [value, type] of [
    [{...incoming, className: "person"}, "vehicle"],
    [{...incoming, detectionCount: 0}, "vehicle"],
    [{...incoming, lastSeenAt: "2026-10-09T12:01:01.000Z"}, "vehicle"],
    [{...incoming, modelId: "własny-model"}, "vehicle"],
    [{...incoming, modelId: "yolox-nano-coco-deadbeef"}, "vehicle"],
  ]) {
    assert.throws(() => normalizeBridgeAiMetadata(value, {
      type,
      occurredAtMillis,
    }), /metadane/);
  }
});

test("buduje i łączy liczniki klas bez utraty zakresu czasu", () => {
  const first = normalizeBridgeAiMetadata(incoming, {
    type: "vehicle",
    occurredAtMillis,
  });
  const stored = mergeCameraEventAiMetadata(null, first, {
    type: "vehicle",
    confidence: 0.82,
    Timestamp,
  });
  const person = normalizeBridgeAiMetadata({
    ...incoming,
    className: "person",
    detectionCount: 4,
    firstSeenAt: "2026-10-09T11:59:59.500Z",
  }, {
    type: "person",
    occurredAtMillis,
  });
  const merged = mergeCameraEventAiMetadata(stored, person, {
    type: "person",
    confidence: 0.94,
    Timestamp,
  });
  assert.equal(merged.totalObjects, 2);
  assert.equal(merged.personCount, 1);
  assert.equal(merged.vehicleCount, 1);
  assert.deepEqual(merged.classCounts, {bus: 1, person: 1});
  assert.equal(merged.maximumConfidence, 0.94);
  assert.equal(merged.firstSeenAt.toMillis(), occurredAtMillis - 1500);
  assert.equal(merged.lastSeenAt.toMillis(), occurredAtMillis);
  assert.equal(merged.detectionFrameCount, 7);
  assert.deepEqual(merged.modelIds, ["yolox-nano-coco-c789161e"]);
  assert.equal(readStoredAiMetadata(merged).totalObjects, 2);
});

test("uszkodzone stare podsumowanie nie zatruwa nowego wykrycia", () => {
  const normalized = normalizeBridgeAiMetadata(incoming, {
    type: "vehicle",
    occurredAtMillis,
  });
  const result = mergeCameraEventAiMetadata({
    schemaVersion: 1,
    totalObjects: 999,
    classCounts: {unknown: 999},
  }, normalized, {
    type: "vehicle",
    confidence: 0.7,
    Timestamp,
  });
  assert.equal(result.totalObjects, 1);
  assert.deepEqual(result.classCounts, {bus: 1});
});

test("brak metadanych zachowuje zgodność ze starszym Bridge", () => {
  assert.equal(normalizeBridgeAiMetadata(null, {
    type: "person",
    occurredAtMillis,
  }), null);
  assert.equal(readStoredAiMetadata(null), null);
});
