"use strict";

const claimTimeoutMs =
    2 * 60 * 1000;

const receiptLifetimeMs =
    7 * 24 * 60 * 60 * 1000;

/**
 * Sprawdza identyfikator zdarzenia
 * nadany przez producenta.
 *
 * @param {*} value Surowa wartość.
 * @param {Function} HttpsError Klasa błędu.
 * @return {string} Poprawny identyfikator.
 */
function normalizeExternalEventId(
    value,
    HttpsError,
) {
  const normalized =
      typeof value === "string" ?
        value.trim() :
        "";

  if (
    !normalized ||
    normalized.length > 256
  ) {
    throw new HttpsError(
        "invalid-argument",
        "Nieprawidłowy externalEventId.",
    );
  }

  return normalized;
}

/**
 * Buduje bezpieczny identyfikator
 * dokumentu potwierdzenia.
 *
 * @param {Object} input Dane zdarzenia.
 * @param {string} input.provider Dostawca.
 * @param {string} input.cloudDeviceId ID urządzenia.
 * @param {string} input.externalEventId ID zdarzenia.
 * @param {Function} input.HttpsError Klasa błędu.
 * @return {string} ID dokumentu Firestore.
 */
function createReceiptId({
  provider,
  cloudDeviceId,
  externalEventId,
  HttpsError,
}) {
  const encoded =
      encodeURIComponent(
          JSON.stringify([
            provider,
            cloudDeviceId,
            externalEventId,
          ]),
      );

  if (
    Buffer.byteLength(
        encoded,
        "utf8",
    ) > 1400
  ) {
    throw new HttpsError(
        "invalid-argument",
        "Identyfikator zdarzenia jest zbyt długi.",
    );
  }

  return encoded;
}

/**
 * Odtwarza wynik wcześniej
 * przetworzonego zdarzenia.
 *
 * @param {Object} data Dane potwierdzenia.
 * @param {string} externalEventId ID producenta.
 * @param {Function} HttpsError Klasa błędu.
 * @return {Object} Wynik przetwarzania.
 */
function readCompletedResult(
    data,
    externalEventId,
    HttpsError,
) {
  const eventId =
      typeof data.eventId === "string" ?
        data.eventId.trim() :
        "";

  const cameraId =
      typeof data.cameraId === "string" ?
        data.cameraId.trim() :
        "";

  if (!eventId || !cameraId) {
    throw new HttpsError(
        "internal",
        "Uszkodzone potwierdzenie zdarzenia.",
    );
  }

  return {
    eventId,
    cameraId,
    merged:
        data.merged === true,
    duplicate: true,
    externalEventId,
    type:
        typeof data.type === "string" ?
          data.type :
          "unknown",
    occurrenceCount:
        typeof data.occurrenceCount ===
        "number" ?
          data.occurrenceCount :
          1,
    cameraName:
        typeof data.cameraName ===
        "string" ?
          data.cameraName :
          "Kamera",
  };
}

/**
 * Wykonuje obsługę zdarzenia producenta
 * tylko jeden raz.
 *
 * @param {Object} input Zależności i dane.
 * @return {Promise<Object>} Wynik zdarzenia.
 */
async function runManufacturerEventOnce(
    input,
) {
  const {
    db,
    Timestamp,
    HttpsError,
    provider,
    cloudDeviceId,
    handler,
  } = input;

  if (typeof handler !== "function") {
    throw new HttpsError(
        "internal",
        "Brak funkcji obsługi zdarzenia.",
    );
  }

  const externalEventId =
      normalizeExternalEventId(
          input.externalEventId,
          HttpsError,
      );

  const receiptId =
      createReceiptId({
        provider,
        cloudDeviceId,
        externalEventId,
        HttpsError,
      });

  const receiptRef =
      db
          .collection(
              "manufacturerCameraEventReceipts",
          )
          .doc(receiptId);

  const claim =
      await db.runTransaction(
          async (transaction) => {
            const snapshot =
                await transaction.get(
                    receiptRef,
                );

            const nowMillis =
                Date.now();

            if (snapshot.exists) {
              const receipt =
                  snapshot.data();

              if (
                receipt.status ===
                "completed"
              ) {
                return {
                  completedResult:
                      readCompletedResult(
                          receipt,
                          externalEventId,
                          HttpsError,
                      ),
                };
              }

              const updatedAt =
                  receipt.updatedAt;

              const updatedAtMillis =
                  updatedAt instanceof
                  Timestamp ?
                    updatedAt.toMillis() :
                    0;

              const claimIsActive =
                  receipt.status ===
                    "processing" &&
                  nowMillis -
                    updatedAtMillis <
                    claimTimeoutMs;

              if (claimIsActive) {
                return {
                  processing: true,
                };
              }
            }

            const previous =
                snapshot.exists ?
                  snapshot.data() :
                  {};

            const previousAttempts =
                typeof previous
                    .attemptCount ===
                "number" ?
                  previous.attemptCount :
                  0;

            const timestamp =
                Timestamp.fromMillis(
                    nowMillis,
                );

            const receiptData = {
              provider,
              cloudDeviceId,
              externalEventId,
              status: "processing",
              attemptCount:
                  previousAttempts + 1,
              updatedAt: timestamp,
              expiresAt:
                  Timestamp.fromMillis(
                      nowMillis +
                        receiptLifetimeMs,
                  ),
            };

            if (!snapshot.exists) {
              receiptData.createdAt =
                  timestamp;
            }

            transaction.set(
                receiptRef,
                receiptData,
                {
                  merge: true,
                },
            );

            return {
              claimed: true,
            };
          },
      );

  if (claim.completedResult) {
    return claim.completedResult;
  }

  if (claim.processing) {
    throw new HttpsError(
        "aborted",
        "Zdarzenie jest już przetwarzane.",
    );
  }

  try {
    const result =
        await handler();

    if (
      typeof result.eventId !== "string" ||
      typeof result.cameraId !== "string"
    ) {
      throw new HttpsError(
          "internal",
          "Obsługa zdarzenia nie zwróciła identyfikatorów.",
      );
    }

    const nowMillis =
        Date.now();

    await receiptRef.set(
        {
          status: "completed",
          cameraId: result.cameraId,
          eventId: result.eventId,
          merged:
              result.merged === true,
          type:
              result.type || "unknown",
          occurrenceCount:
              result.occurrenceCount || 1,
          cameraName:
              result.cameraName || "Kamera",
          updatedAt:
              Timestamp.fromMillis(
                  nowMillis,
              ),
          expiresAt:
              Timestamp.fromMillis(
                  nowMillis +
                    receiptLifetimeMs,
              ),
        },
        {
          merge: true,
        },
    );

    return {
      ...result,
      duplicate: false,
      externalEventId,
    };
  } catch (error) {
    const message =
        error &&
        typeof error.message === "string" ?
          error.message.substring(0, 500) :
          "Unknown error";

    await receiptRef
        .set(
            {
              status: "failed",
              lastError: message,
              updatedAt:
                  Timestamp.fromMillis(
                      Date.now(),
                  ),
            },
            {
              merge: true,
            },
        )
        .catch(
            (receiptError) => {
              console.error(
                  "MANUFACTURER RECEIPT ERROR:",
                  receiptError,
              );
            },
        );

    throw error;
  }
}

module.exports = {
  runManufacturerEventOnce,
};
