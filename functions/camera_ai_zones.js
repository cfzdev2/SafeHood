"use strict";

const maximumZonesPerType = 4;
const minimumZoneExtent = 0.02;

/**
 * Normalizuje konfigurację stref jednej kamery.
 * Nieprawidłowe dane wyłączają AI zamiast poszerzać analizowany obszar.
 * @param {Object} camera Dane kamery.
 * @return {{valid: boolean, detectionZones: Array, ignoreZones: Array}}
 */
function normalizeCameraAiZoneConfiguration(camera) {
  const source =
      camera &&
      typeof camera === "object" ?
        camera :
        {};

  try {
    return {
      valid: true,
      detectionZones: normalizeZoneList(
          source.aiDetectionZones,
          "aiDetectionZones",
      ),
      ignoreZones: normalizeZoneList(
          source.aiIgnoreZones,
          "aiIgnoreZones",
      ),
    };
  } catch (_) {
    return {
      valid: false,
      detectionZones: [],
      ignoreZones: [],
    };
  }
}

/**
 * @param {*} value Wartość pola Firestore.
 * @param {string} fieldName Nazwa pola.
 * @return {Array<Object>} Znormalizowane strefy.
 */
function normalizeZoneList(value, fieldName) {
  if (value === undefined) {
    return [];
  }

  if (!Array.isArray(value) || value.length > maximumZonesPerType) {
    throw new TypeError(`${fieldName} ma nieprawidłowy format.`);
  }

  return value.map((zone) => normalizeZone(zone, fieldName));
}

/**
 * @param {*} value Pojedyncza strefa.
 * @param {string} fieldName Nazwa pola.
 * @return {{left: number, top: number, width: number, height: number}}
 */
function normalizeZone(value, fieldName) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError(`${fieldName} zawiera nieprawidłową strefę.`);
  }

  const keys = Object.keys(value).sort();
  const expectedKeys = ["height", "left", "top", "width"];

  if (
    keys.length !== expectedKeys.length ||
    keys.some((key, index) => key !== expectedKeys[index])
  ) {
    throw new TypeError(`${fieldName} zawiera nieprawidłową strefę.`);
  }

  const result = {
    left: value.left,
    top: value.top,
    width: value.width,
    height: value.height,
  };

  if (
    !Object.values(result).every(Number.isFinite) ||
    result.left < 0 ||
    result.top < 0 ||
    result.width < minimumZoneExtent ||
    result.height < minimumZoneExtent ||
    result.left + result.width > 1 ||
    result.top + result.height > 1
  ) {
    throw new RangeError(`${fieldName} zawiera strefę poza obrazem.`);
  }

  return result;
}

module.exports = {
  maximumZonesPerType,
  minimumZoneExtent,
  normalizeCameraAiZoneConfiguration,
  normalizeZoneList,
};
