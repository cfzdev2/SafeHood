'use strict';

const classTypes = new Map([
  ['person', 'person'],
  ['bicycle', 'vehicle'],
  ['car', 'vehicle'],
  ['motorcycle', 'vehicle'],
  ['bus', 'vehicle'],
  ['truck', 'vehicle'],
]);

const supportedModelIds = new Set([
  'yolox-nano-coco-c789161e',
]);

function normalizeAiEventMetadata(value, {type, occurredAt}) {
  if (!value || typeof value !== 'object' || Array.isArray(value) ||
    value.schemaVersion !== 1) {
    throw new TypeError('Nieprawidłowe metadane zdarzenia AI.');
  }

  const className = typeof value.className === 'string'
    ? value.className.trim().toLowerCase() : '';
  const modelId = typeof value.modelId === 'string'
    ? value.modelId.trim().toLowerCase() : '';
  const firstSeenMillis = typeof value.firstSeenAt === 'string'
    ? Date.parse(value.firstSeenAt) : NaN;
  const lastSeenMillis = typeof value.lastSeenAt === 'string'
    ? Date.parse(value.lastSeenAt) : NaN;
  const occurredAtMillis = typeof occurredAt === 'string'
    ? Date.parse(occurredAt) : NaN;

  if (classTypes.get(className) !== type ||
    !supportedModelIds.has(modelId) ||
    !Number.isInteger(value.detectionCount) ||
    value.detectionCount < 1 || value.detectionCount > 1000 ||
    !Number.isFinite(firstSeenMillis) || !Number.isFinite(lastSeenMillis) ||
    !Number.isFinite(occurredAtMillis) || firstSeenMillis <= 0 ||
    lastSeenMillis < firstSeenMillis ||
    lastSeenMillis - firstSeenMillis > 60000 ||
    Math.abs(lastSeenMillis - occurredAtMillis) > 2000) {
    throw new TypeError('Nieprawidłowe metadane zdarzenia AI.');
  }

  return {
    schemaVersion: 1,
    className,
    detectionCount: value.detectionCount,
    firstSeenAt: new Date(firstSeenMillis).toISOString(),
    lastSeenAt: new Date(lastSeenMillis).toISOString(),
    modelId,
  };
}

function createAiEventMetadata(event, {occurredAtMillis, modelId}) {
  try {
    return normalizeAiEventMetadata({
      schemaVersion: 1,
      className: event?.className,
      detectionCount: event?.detectionCount,
      firstSeenAt: new Date(event?.firstSeenAtMillis).toISOString(),
      lastSeenAt: new Date(occurredAtMillis).toISOString(),
      modelId,
    }, {
      type: event?.type,
      occurredAt: new Date(occurredAtMillis).toISOString(),
    });
  } catch (_) {
    return null;
  }
}

module.exports = {
  createAiEventMetadata,
  normalizeAiEventMetadata,
};
