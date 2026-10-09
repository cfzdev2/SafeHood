'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  createAiEventMetadata,
  normalizeAiEventMetadata,
} = require('../ai/event_metadata');

const occurredAtMillis = Date.parse('2026-10-09T12:00:01.000Z');
const valid = {
  schemaVersion: 1,
  className: 'bus',
  detectionCount: 3,
  firstSeenAt: '2026-10-09T12:00:00.000Z',
  lastSeenAt: '2026-10-09T12:00:01.000Z',
  modelId: 'yolox-nano-coco-c789161e',
};

test('tworzy trwałe metadane potwierdzonego śladu AI', () => {
  const result = createAiEventMetadata({
    type: 'vehicle',
    className: 'bus',
    detectionCount: 3,
    firstSeenAtMillis: occurredAtMillis - 1000,
  }, {
    occurredAtMillis,
    modelId: 'yolox-nano-coco-c789161e',
  });
  assert.deepEqual(result, valid);
});

test('normalizuje klasę i model bez zmiany znaczenia', () => {
  const result = normalizeAiEventMetadata({
    ...valid,
    className: ' BUS ',
    modelId: ' YOLOX-NANO-COCO-C789161E ',
  }, {
    type: 'vehicle',
    occurredAt: valid.lastSeenAt,
  });
  assert.deepEqual(result, valid);
});

test('odrzuca klasę niezgodną z typem oraz nieznany model', () => {
  for (const value of [
    {...valid, className: 'person'},
    {...valid, modelId: 'custom-model'},
    {...valid, modelId: 'yolox-nano-coco-deadbeef'},
  ]) {
    assert.throws(() => normalizeAiEventMetadata(value, {
      type: 'vehicle',
      occurredAt: valid.lastSeenAt,
    }), /metadane/);
  }
});

test('odrzuca nieprawidłowy zakres czasu i liczbę potwierdzeń', () => {
  for (const value of [
    {...valid, detectionCount: 0},
    {...valid, firstSeenAt: '2026-10-09T12:00:02.000Z'},
    {...valid, lastSeenAt: '2026-10-09T12:02:00.000Z'},
  ]) {
    assert.throws(() => normalizeAiEventMetadata(value, {
      type: 'vehicle',
      occurredAt: valid.lastSeenAt,
    }), /metadane/);
  }
});

test('brak danych trackera nie blokuje samego zdarzenia', () => {
  assert.equal(createAiEventMetadata({
    type: 'person',
    className: 'person',
  }, {
    occurredAtMillis,
    modelId: 'yolox-nano-coco-c789161e',
  }), null);
});
