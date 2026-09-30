"use strict";

const maximumSnapshotBytes =
    5 * 1024 * 1024;

/**
 * Błąd walidacji zdjęcia zdarzenia.
 */
class CameraEventSnapshotError extends Error {
  /**
   * @param {string} code Kod błędu.
   * @param {string} message Opis błędu.
   */
  constructor(code, message) {
    super(message);

    this.name =
        "CameraEventSnapshotError";

    this.code = code;
  }
}

/**
 * Waliduje identyfikator dokumentu.
 *
 * @param {*} value Wartość identyfikatora.
 * @param {string} label Nazwa pola.
 * @return {string} Poprawny identyfikator.
 */
function normalizeDocumentId(
    value,
    label,
) {
  if (typeof value !== "string") {
    throw new CameraEventSnapshotError(
        "invalid-id",
        `${label} musi być tekstem.`,
    );
  }

  const normalized = value.trim();

  if (
    normalized.length === 0 ||
    normalized.length > 256 ||
    normalized.includes("/") ||
    normalized.includes("\0")
  ) {
    throw new CameraEventSnapshotError(
        "invalid-id",
        `${label} jest nieprawidłowe.`,
    );
  }

  return normalized;
}

/**
 * Sprawdza nagłówek i zakończenie JPEG.
 *
 * @param {Buffer} value Dane obrazu.
 * @return {boolean} Czy dane wyglądają jak JPEG.
 */
function isJpeg(value) {
  return (
    Buffer.isBuffer(value) &&
    value.length >= 4 &&
    value[0] === 0xff &&
    value[1] === 0xd8 &&
    value[value.length - 2] === 0xff &&
    value[value.length - 1] === 0xd9
  );
}

/**
 * Dekoduje i waliduje zdjęcie JPEG przesłane jako Base64.
 *
 * @param {*} value Zakodowane zdjęcie.
 * @param {Object} options Opcje walidacji.
 * @param {number} options.maximumBytes Maksymalny rozmiar.
 * @return {Buffer} Dane JPEG.
 */
function decodeJpegBase64(
    value,
    {
      maximumBytes =
      maximumSnapshotBytes,
    } = {},
) {
  if (
    !Number.isInteger(maximumBytes) ||
    maximumBytes < 4
  ) {
    throw new TypeError(
        "maximumBytes musi być liczbą całkowitą >= 4.",
    );
  }

  if (typeof value !== "string") {
    throw new CameraEventSnapshotError(
        "invalid-base64",
        "Brak zdjęcia JPEG.",
    );
  }

  const normalized = value.trim();

  const maximumEncodedLength =
      4 * Math.ceil(maximumBytes / 3);

  if (normalized.length > maximumEncodedLength) {
    throw new CameraEventSnapshotError(
        "too-large",
        "Zdjęcie przekracza dozwolony rozmiar.",
    );
  }

  const base64Pattern = /^[A-Za-z0-9+/]+={0,2}$/;

  if (
    normalized.length === 0 ||
    normalized.length % 4 !== 0 ||
    !base64Pattern.test(normalized)
  ) {
    throw new CameraEventSnapshotError(
        "invalid-base64",
        "Zdjęcie nie jest poprawnym Base64.",
    );
  }

  const snapshot =
      Buffer.from(normalized, "base64");

  if (snapshot.length > maximumBytes) {
    throw new CameraEventSnapshotError(
        "too-large",
        "Zdjęcie przekracza dozwolony rozmiar.",
    );
  }

  if (!isJpeg(snapshot)) {
    throw new CameraEventSnapshotError(
        "invalid-jpeg",
        "Przesłany plik nie jest poprawnym JPEG.",
    );
  }

  return snapshot;
}

/**
 * Buduje prywatną ścieżkę zdjęcia zdarzenia.
 *
 * @param {*} ownerId Identyfikator właściciela.
 * @param {*} eventId Identyfikator zdarzenia.
 * @return {string} Ścieżka Firebase Storage.
 */
function buildSnapshotPath(
    ownerId,
    eventId,
) {
  const normalizedOwnerId =
      normalizeDocumentId(
          ownerId,
          "ownerId",
      );

  const normalizedEventId =
      normalizeDocumentId(
          eventId,
          "eventId",
      );

  return (
    `users/${normalizedOwnerId}/` +
    `cameraEvents/${normalizedEventId}/` +
    "snapshot.jpg"
  );
}

module.exports = {
  CameraEventSnapshotError,
  buildSnapshotPath,
  decodeJpegBase64,
  isJpeg,
  maximumSnapshotBytes,
  normalizeDocumentId,
};
