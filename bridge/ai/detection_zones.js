'use strict';

const MAXIMUM_ZONES_PER_TYPE = 4;
const MINIMUM_ZONE_EXTENT = 0.02;
const AI_FRAME_SIZE = 416;

function normalizeZoneList(value, fieldName = 'zones') {
  if (value === undefined || value === null) {
    return [];
  }

  if (!Array.isArray(value) || value.length > MAXIMUM_ZONES_PER_TYPE) {
    throw new TypeError(`${fieldName} ma nieprawidłowy format.`);
  }

  return value.map((zone) => normalizeZone(zone, fieldName));
}

function normalizeZone(value, fieldName) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new TypeError(`${fieldName} zawiera nieprawidłową strefę.`);
  }

  const keys = Object.keys(value).sort();
  const expectedKeys = ['height', 'left', 'top', 'width'];

  if (
    keys.length !== expectedKeys.length ||
    keys.some((key, index) => key !== expectedKeys[index])
  ) {
    throw new TypeError(`${fieldName} zawiera nieprawidłową strefę.`);
  }

  const zone = {
    left: value.left,
    top: value.top,
    width: value.width,
    height: value.height,
  };

  if (
    !Object.values(zone).every(Number.isFinite) ||
    zone.left < 0 ||
    zone.top < 0 ||
    zone.width < MINIMUM_ZONE_EXTENT ||
    zone.height < MINIMUM_ZONE_EXTENT ||
    zone.left + zone.width > 1 ||
    zone.top + zone.height > 1
  ) {
    throw new RangeError(`${fieldName} zawiera strefę poza obrazem.`);
  }

  return Object.freeze(zone);
}

function detectionAnchor(detection, frameWidth, frameHeight) {
  const box = detection?.box;

  if (
    !box ||
    !Number.isFinite(box.left) ||
    !Number.isFinite(box.right) ||
    !Number.isFinite(box.bottom) ||
    !Number.isFinite(frameWidth) ||
    !Number.isFinite(frameHeight) ||
    frameWidth <= 0 ||
    frameHeight <= 0 ||
    box.right < box.left
  ) {
    return null;
  }

  const anchor = {
    x: ((box.left + box.right) / 2) / frameWidth,
    y: box.bottom / frameHeight,
  };

  if (
    anchor.x < 0 ||
    anchor.x > 1 ||
    anchor.y < 0 ||
    anchor.y > 1
  ) {
    return null;
  }

  return anchor;
}

function containsPoint(zone, point) {
  return point.x >= zone.left &&
    point.x <= zone.left + zone.width &&
    point.y >= zone.top &&
    point.y <= zone.top + zone.height;
}

function partitionDetectionsByZones(
  detections,
  {
    detectionZones = [],
    ignoreZones = [],
    frameWidth = AI_FRAME_SIZE,
    frameHeight = AI_FRAME_SIZE,
  } = {},
) {
  if (!Array.isArray(detections)) {
    throw new TypeError('Detekcje muszą być listą.');
  }

  const normalizedDetectionZones = normalizeZoneList(
    detectionZones,
    'detectionZones',
  );
  const normalizedIgnoreZones = normalizeZoneList(ignoreZones, 'ignoreZones');
  const accepted = [];
  const rejected = [];

  for (const detection of detections) {
    const anchor = detectionAnchor(detection, frameWidth, frameHeight);
    const ignored = anchor !== null && normalizedIgnoreZones.some(
      (zone) => containsPoint(zone, anchor),
    );
    const active = anchor !== null && (
      normalizedDetectionZones.length === 0 ||
      normalizedDetectionZones.some((zone) => containsPoint(zone, anchor))
    );

    (active && !ignored ? accepted : rejected).push(detection);
  }

  return {accepted, rejected};
}

module.exports = {
  AI_FRAME_SIZE,
  MAXIMUM_ZONES_PER_TYPE,
  MINIMUM_ZONE_EXTENT,
  detectionAnchor,
  normalizeZoneList,
  partitionDetectionsByZones,
};
