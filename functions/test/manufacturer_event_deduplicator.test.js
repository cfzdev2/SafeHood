"use strict";

const test =
    require("node:test");

const assert =
    require("node:assert/strict");

const {
  Timestamp,
} = require(
    "firebase-admin/firestore",
);

const {
  HttpsError,
} = require(
    "firebase-functions/v2/https",
);

const {
  runManufacturerEventOnce,
} = require(
    "../manufacturer_event_deduplicator",
);

const createHarness = (
    initialReceipt = null,
) => {
  let receipt =
      initialReceipt === null ?
        null :
        {
          ...initialReceipt,
        };

  const mergeReceipt = (
      data,
      options,
  ) => {
    if (
      options &&
      options.merge === true
    ) {
      receipt = {
        ...(receipt || {}),
        ...data,
      };

      return;
    }

    receipt = {
      ...data,
    };
  };

  const receiptRef = {
    set: async (data, options) => {
      mergeReceipt(
          data,
          options,
      );
    },
  };

  const db = {
    collection: (name) => {
      assert.equal(
          name,
          "manufacturerCameraEventReceipts",
      );

      return {
        doc: (receiptId) => {
          assert.ok(receiptId);

          return receiptRef;
        },
      };
    },

    runTransaction: async (
        callback,
    ) => {
      const transaction = {
        get: async (reference) => {
          assert.equal(
              reference,
              receiptRef,
          );

          return {
            exists:
                receipt !== null,
            data: () =>
              receipt || {},
          };
        },

        set: (
            reference,
            data,
            options,
        ) => {
          assert.equal(
              reference,
              receiptRef,
          );

          mergeReceipt(
              data,
              options,
          );
        },
      };

      return callback(transaction);
    },
  };

  return {
    db,
    getReceipt: () => receipt,
  };
};

const runEvent = ({
  harness,
  externalEventId = "event-1",
  handler,
}) => {
  return runManufacturerEventOnce({
    db: harness.db,
    Timestamp,
    HttpsError,
    provider: "safeArk",
    cloudDeviceId:
        "debug-dekco-l5p-1",
    externalEventId,
    handler,
  });
};

test(
    "odrzuca nieprawidłowy externalEventId",
    async () => {
      const invalidIds = [
        "   ",
        "x".repeat(257),
      ];

      for (
        const externalEventId of
        invalidIds
      ) {
        const harness =
            createHarness();

        await assert.rejects(
            () => runEvent({
              harness,
              externalEventId,
              handler: async () => ({}),
            }),
            (error) => {
              assert.equal(
                  error.code,
                  "invalid-argument",
              );

              return true;
            },
        );
      }
    },
);

test(
    "wykonuje handler tylko dla pierwszego zdarzenia",
    async () => {
      const harness =
          createHarness();

      let handlerCalls = 0;

      const firstResult =
          await runEvent({
            harness,
            externalEventId:
                "event-duplicate",
            handler: async () => {
              handlerCalls += 1;

              return {
                eventId: "camera-event-1",
                cameraId: "camera-1",
                merged: false,
                type: "person",
                occurrenceCount: 2,
                cameraName: "Podjazd",
              };
            },
          });

      const duplicateResult =
          await runEvent({
            harness,
            externalEventId:
                "event-duplicate",
            handler: async () => {
              throw new Error(
                  "Handler duplikatu " +
                  "nie powinien działać.",
              );
            },
          });

      assert.equal(
          handlerCalls,
          1,
      );

      assert.equal(
          firstResult.duplicate,
          false,
      );

      assert.equal(
          duplicateResult.duplicate,
          true,
      );

      assert.equal(
          duplicateResult.eventId,
          "camera-event-1",
      );

      assert.equal(
          duplicateResult.cameraId,
          "camera-1",
      );

      assert.equal(
          duplicateResult.type,
          "person",
      );

      assert.equal(
          duplicateResult
              .occurrenceCount,
          2,
      );
    },
);

test(
    "blokuje aktywnie przetwarzane zdarzenie",
    async () => {
      const harness =
          createHarness({
            status: "processing",
            attemptCount: 1,
            updatedAt:
                Timestamp.fromMillis(
                    Date.now(),
                ),
          });

      let handlerCalls = 0;

      await assert.rejects(
          () => runEvent({
            harness,
            handler: async () => {
              handlerCalls += 1;

              return {};
            },
          }),
          (error) => {
            assert.equal(
                error.code,
                "aborted",
            );

            return true;
          },
      );

      assert.equal(
          handlerCalls,
          0,
      );
    },
);

test(
    "ponawia wygasłe przetwarzanie",
    async () => {
      const harness =
          createHarness({
            status: "processing",
            attemptCount: 2,
            updatedAt:
                Timestamp.fromMillis(
                    Date.now() -
                    3 * 60 * 1000,
                ),
          });

      const result =
          await runEvent({
            harness,
            handler: async () => ({
              eventId: "camera-event-2",
              cameraId: "camera-2",
              merged: true,
              type: "vehicle",
              occurrenceCount: 3,
              cameraName: "Garaż",
            }),
          });

      const receipt =
          harness.getReceipt();

      assert.equal(
          result.duplicate,
          false,
      );

      assert.equal(
          receipt.status,
          "completed",
      );

      assert.equal(
          receipt.attemptCount,
          3,
      );
    },
);

test(
    "zapisuje błąd handlera i przekazuje go dalej",
    async () => {
      const harness =
          createHarness();

      await assert.rejects(
          () => runEvent({
            harness,
            handler: async () => {
              throw new Error(
                  "Testowy błąd handlera",
              );
            },
          }),
          /Testowy błąd handlera/,
      );

      const receipt =
          harness.getReceipt();

      assert.equal(
          receipt.status,
          "failed",
      );

      assert.equal(
          receipt.lastError,
          "Testowy błąd handlera",
      );
    },
);

test(
    "odrzuca uszkodzone zapisane potwierdzenie",
    async () => {
      const harness =
          createHarness({
            status: "completed",
            eventId: "camera-event-3",
            cameraId: "   ",
          });

      await assert.rejects(
          () => runEvent({
            harness,
            handler: async () => {
              throw new Error(
                  "Handler nie powinien działać.",
              );
            },
          }),
          (error) => {
            assert.equal(
                error.code,
                "internal",
            );

            return true;
          },
      );
    },
);
