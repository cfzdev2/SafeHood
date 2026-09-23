"use strict";

const assert = require("node:assert/strict");

const {
  after,
  before,
  test,
} = require("node:test");

const {
  deleteApp,
  initializeApp,
} = require("firebase-admin/app");

const {
  getFirestore,
} = require("firebase-admin/firestore");

const {
  deleteAccountData,
} = require("../account_deletion");

const projectId =
    "demo-safehood-rules-test";

const deletedUid =
    "account-to-delete";

const otherUid =
    "other-account";

let app;
let db;

/**
 * Czyści wyłącznie izolowany Firestore używany przez test.
 *
 * @return {Promise<void>}
 */
async function clearFirestore() {
  const host =
      process.env.FIRESTORE_EMULATOR_HOST;

  assert.ok(
      host,
      "Test wymaga Firestore Emulator.",
  );

  const endpoint =
      `http://${host}/emulator/v1/` +
      `projects/${projectId}/databases/` +
      "(default)/documents";

  const response =
      await fetch(
          endpoint,
          {
            method: "DELETE",
          },
      );

  assert.equal(
      response.ok,
      true,
      await response.text(),
  );
}

/**
 * Zapisuje dokument testowy.
 *
 * @param {string} path Ścieżka dokumentu.
 * @param {Object} data Dane dokumentu.
 * @return {Promise<void>}
 */
async function seedDocument(path, data) {
  await db.doc(path).set(data);
}

/**
 * Sprawdza istnienie dokumentu.
 *
 * @param {string} path Ścieżka dokumentu.
 * @return {Promise<boolean>}
 */
async function documentExists(path) {
  const snapshot =
      await db.doc(path).get();

  return snapshot.exists;
}

before(async () => {
  app = initializeApp(
      {
        projectId,
      },
      "account-deletion-test",
  );

  db = getFirestore(app);

  await clearFirestore();
});

after(async () => {
  await clearFirestore();
  await deleteApp(app);
});

test(
    "usuwa dane konta i zachowuje dane innych użytkowników",
    async () => {
      await Promise.all([
        seedDocument(
            `users/${deletedUid}`,
            {
              firstName: "Test",
            },
        ),
        seedDocument(
            `users/${deletedUid}/cameras/camera-1`,
            {
              cameraId: "camera-1",
              ownerId: deletedUid,
            },
        ),
        seedDocument(
            `users/${deletedUid}/bridges/bridge-1`,
            {
              ownerId: deletedUid,
            },
        ),
        seedDocument(
            `users/${deletedUid}/devices/device-1`,
            {
              ownerId: deletedUid,
            },
        ),
        seedDocument(
            `communityProfiles/${deletedUid}`,
            {
              firstName: "Test",
            },
        ),
        seedDocument(
            "bridgeCredentials/bridge-1",
            {
              ownerId: deletedUid,
            },
        ),
        seedDocument(
            "bridgePairingCodes/pairing-1",
            {
              ownerId: deletedUid,
            },
        ),
        seedDocument(
            `cameraEventStates/` +
            `${deletedUid}_camera-1_detection`,
            {
              ownerId: deletedUid,
            },
        ),
        seedDocument(
            "cameraEvents/event-1",
            {
              ownerId: deletedUid,
            },
        ),
        seedDocument(
            "incidents/owned-incident",
            {
              reporterId: deletedUid,
              participantIds: [
                deletedUid,
                otherUid,
              ],
            },
        ),
        seedDocument(
            "incidents/owned-incident/" +
            `responses/${deletedUid}`,
            {
              responderId: deletedUid,
            },
        ),
        seedDocument(
            "incidents/owned-incident/" +
            "messages/owned-message",
            {
              senderId: deletedUid,
            },
        ),
        seedDocument(
            "incidents/shared-incident",
            {
              reporterId: otherUid,
              participantIds: [
                otherUid,
                deletedUid,
              ],
            },
        ),
        seedDocument(
            "incidents/shared-incident/" +
            `responses/${deletedUid}`,
            {
              responderId: deletedUid,
            },
        ),
        seedDocument(
            "incidents/shared-incident/" +
            `responses/${otherUid}`,
            {
              responderId: otherUid,
            },
        ),
        seedDocument(
            "incidents/shared-incident/" +
            "messages/deleted-message",
            {
              senderId: deletedUid,
            },
        ),
        seedDocument(
            "incidents/shared-incident/" +
            "messages/other-message",
            {
              senderId: otherUid,
            },
        ),
        seedDocument(
            "bridgeCredentials/bridge-other",
            {
              ownerId: otherUid,
            },
        ),
        seedDocument(
            "bridgePairingCodes/pairing-other",
            {
              ownerId: otherUid,
            },
        ),
        seedDocument(
            "cameraEvents/event-other",
            {
              ownerId: otherUid,
            },
        ),
      ]);

      const result =
          await deleteAccountData({
            db,
            uid: deletedUid,
          });

      const expectedCounts = {
        deletedBridgeCredentialCount: 1,
        deletedPairingCodeCount: 1,
        deletedStateCount: 1,
        deletedCameraEventCount: 1,
        deletedIncidentCount: 1,
        updatedIncidentCount: 1,
        deletedMessageCount: 1,
      };

      for (
        const [name, expected] of
        Object.entries(expectedCounts)
      ) {
        assert.equal(
            result[name],
            expected,
            name,
        );
      }

      const deletedPaths = [
        `users/${deletedUid}`,
        `users/${deletedUid}/cameras/camera-1`,
        `users/${deletedUid}/bridges/bridge-1`,
        `users/${deletedUid}/devices/device-1`,
        `communityProfiles/${deletedUid}`,
        "bridgeCredentials/bridge-1",
        "bridgePairingCodes/pairing-1",
        `cameraEventStates/` +
        `${deletedUid}_camera-1_detection`,
        "cameraEvents/event-1",
        "incidents/owned-incident",
        "incidents/owned-incident/" +
        `responses/${deletedUid}`,
        "incidents/owned-incident/" +
        "messages/owned-message",
        "incidents/shared-incident/" +
        `responses/${deletedUid}`,
        "incidents/shared-incident/" +
        "messages/deleted-message",
      ];

      for (const path of deletedPaths) {
        assert.equal(
            await documentExists(path),
            false,
            path,
        );
      }

      const preservedPaths = [
        "bridgeCredentials/bridge-other",
        "bridgePairingCodes/pairing-other",
        "cameraEvents/event-other",
        "incidents/shared-incident",
        "incidents/shared-incident/" +
        `responses/${otherUid}`,
        "incidents/shared-incident/" +
        "messages/other-message",
      ];

      for (const path of preservedPaths) {
        assert.equal(
            await documentExists(path),
            true,
            path,
        );
      }

      const sharedIncident =
          await db
              .doc(
                  "incidents/" +
                  "shared-incident",
              )
              .get();

      assert.deepEqual(
          sharedIncident.get(
              "participantIds",
          ),
          [otherUid],
      );
    },
);
