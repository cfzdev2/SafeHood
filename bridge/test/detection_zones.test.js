'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');

const {
  detectionAnchor,
  normalizeZoneList,
  partitionDetectionsByZones,
} = require('../ai/detection_zones');

function detection(left, top, right, bottom) {
  return {box: {left, top, right, bottom}};
}

test('pusta lista stref zachowuje analizę całego obrazu', () => {
  const item = detection(100, 40, 200, 300);
  const result = partitionDetectionsByZones([item]);

  assert.deepEqual(result.accepted, [item]);
  assert.deepEqual(result.rejected, []);
});

test('sprawdza dolny środek ramki obiektu', () => {
  assert.deepEqual(detectionAnchor(
    detection(104, 20, 312, 208),
    416,
    416,
  ), {x: 0.5, y: 0.5});

  const inside = detection(120, 0, 212, 390);
  const outside = detection(280, 300, 360, 390);
  const result = partitionDetectionsByZones([inside, outside], {
    detectionZones: [{left: 0.2, top: 0.8, width: 0.4, height: 0.2}],
  });

  assert.deepEqual(result.accepted, [inside]);
  assert.deepEqual(result.rejected, [outside]);
});

test('obszar ignorowany ma pierwszeństwo przed aktywnym', () => {
  const item = detection(150, 100, 250, 300);
  const result = partitionDetectionsByZones([item], {
    detectionZones: [{left: 0, top: 0, width: 1, height: 1}],
    ignoreZones: [{left: 0.4, top: 0.6, width: 0.2, height: 0.2}],
  });

  assert.deepEqual(result.accepted, []);
  assert.deepEqual(result.rejected, [item]);
});

test('obszar ignorowany działa bez aktywnych stref', () => {
  const ignored = detection(150, 100, 250, 300);
  const accepted = detection(0, 0, 40, 40);
  const result = partitionDetectionsByZones([ignored, accepted], {
    ignoreZones: [{left: 0.4, top: 0.6, width: 0.2, height: 0.2}],
  });

  assert.deepEqual(result.accepted, [accepted]);
  assert.deepEqual(result.rejected, [ignored]);
});

test('odrzuca uszkodzone ramki detekcji', () => {
  const invalid = {box: {left: 10, right: 20}};
  const result = partitionDetectionsByZones([invalid]);

  assert.deepEqual(result.accepted, []);
  assert.deepEqual(result.rejected, [invalid]);
});

test('waliduje format, rozmiar i liczbę stref', () => {
  assert.deepEqual(normalizeZoneList(null), []);
  assert.throws(
    () => normalizeZoneList(new Array(5).fill({
      left: 0,
      top: 0,
      width: 1,
      height: 1,
    })),
    /format/,
  );
  assert.throws(
    () => normalizeZoneList([{left: 0, top: 0, width: 1.1, height: 1}]),
    /poza obrazem/,
  );
  assert.throws(
    () => normalizeZoneList([{
      left: 0,
      top: 0,
      width: 1,
      height: 1,
      extra: true,
    }]),
    /nieprawidłową strefę/,
  );
});
