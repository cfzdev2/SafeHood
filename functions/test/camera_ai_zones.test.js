"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");

const {
  normalizeCameraAiZoneConfiguration,
  normalizeZoneList,
} = require("../camera_ai_zones");

test("starsza kamera bez stref analizuje cały obraz", () => {
  assert.deepEqual(normalizeCameraAiZoneConfiguration({}), {
    valid: true,
    detectionZones: [],
    ignoreZones: [],
  });
});

test("przekazuje poprawne strefy bez zmiany współrzędnych", () => {
  const detectionZone = {left: 0.1, top: 0.2, width: 0.4, height: 0.5};
  const ignoreZone = {left: 0.8, top: 0.1, width: 0.2, height: 0.2};

  assert.deepEqual(normalizeCameraAiZoneConfiguration({
    aiDetectionZones: [detectionZone],
    aiIgnoreZones: [ignoreZone],
  }), {
    valid: true,
    detectionZones: [detectionZone],
    ignoreZones: [ignoreZone],
  });
});

test("nieprawidłowa konfiguracja wyłącza strefy w trybie fail closed", () => {
  for (const camera of [
    {aiDetectionZones: null},
    {aiDetectionZones: [{left: 0, top: 0, width: 2, height: 1}]},
    {aiIgnoreZones: [{left: 0, top: 0, width: 1, height: 1, extra: true}]},
    {aiIgnoreZones: new Array(5).fill({
      left: 0,
      top: 0,
      width: 1,
      height: 1,
    })},
  ]) {
    assert.deepEqual(normalizeCameraAiZoneConfiguration(camera), {
      valid: false,
      detectionZones: [],
      ignoreZones: [],
    });
  }
});

test("odrzuca zbyt małe i nienumeryczne strefy", () => {
  assert.throws(
      () => normalizeZoneList([
        {left: 0, top: 0, width: 0.01, height: 1},
      ], "zones"),
      /poza obrazem/,
  );
  assert.throws(
      () => normalizeZoneList([
        {left: "0", top: 0, width: 1, height: 1},
      ], "zones"),
      /poza obrazem/,
  );
});
