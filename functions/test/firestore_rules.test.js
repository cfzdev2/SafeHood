"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const {
  after,
  before,
  beforeEach,
  test,
} = require("node:test");

const {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} = require("@firebase/rules-unit-testing");

const {
  doc,
  getDoc,
  serverTimestamp,
  setDoc,
  Timestamp,
  updateDoc,
} = require("firebase/firestore");

const projectId = "safehood-security-app";
const ownerId = "rules-owner";
const strangerId = "rules-stranger";
const cameraId = "rules-camera";
const eventId = "rules-event";

const rulesPath = path.resolve(
    __dirname,
    "..",
    "..",
    "firestore.rules",
);

const initialTimestamp = Timestamp.fromMillis(
    1700000000000,
);

let testEnvironment;

before(async () => {
  testEnvironment =
      await initializeTestEnvironment({
        projectId,
        firestore: {
          rules: fs.readFileSync(
              rulesPath,
              "utf8",
          ),
        },
      });
});

beforeEach(async () => {
  await testEnvironment.clearFirestore();

  await testEnvironment.withSecurityRulesDisabled(
      async (context) => {
        const db = context.firestore();

        await setDoc(
            doc(
                db,
                "users",
                ownerId,
                "cameras",
                cameraId,
            ),
            {
              name: "Kamera testowa",
              locationName: "Podjazd",
              motionDetectionEnabled: true,
              notificationSettings: {},
              isOnline: true,
              availabilityCheckedAt:
                  initialTimestamp,
              updatedAt: initialTimestamp,
            },
        );

        await setDoc(
            doc(
                db,
                "cameraEvents",
                eventId,
            ),
            {
              ownerId,
              cameraId,
              status: "new",
              updatedAt: initialTimestamp,
            },
        );
      },
  );
});

after(async () => {
  if (testEnvironment != null) {
    await testEnvironment.cleanup();
  }
});

test(
    "właściciel odczytuje swoją kamerę",
    async () => {
      const db = testEnvironment
          .authenticatedContext(ownerId)
          .firestore();

      await assertSucceeds(
          getDoc(
              doc(
                  db,
                  "users",
                  ownerId,
                  "cameras",
                  cameraId,
              ),
          ),
      );
    },
);

test(
    "obcy użytkownik nie odczytuje kamery",
    async () => {
      const db = testEnvironment
          .authenticatedContext(strangerId)
          .firestore();

      await assertFails(
          getDoc(
              doc(
                  db,
                  "users",
                  ownerId,
                  "cameras",
                  cameraId,
              ),
          ),
      );
    },
);

test(
    "niezalogowany nie odczytuje kamery",
    async () => {
      const db = testEnvironment
          .unauthenticatedContext()
          .firestore();

      await assertFails(
          getDoc(
              doc(
                  db,
                  "users",
                  ownerId,
                  "cameras",
                  cameraId,
              ),
          ),
      );
    },
);

test(
    "właściciel odświeża dostępność kamery",
    async () => {
      const db = testEnvironment
          .authenticatedContext(ownerId)
          .firestore();

      const reference = doc(
          db,
          "users",
          ownerId,
          "cameras",
          cameraId,
      );

      await assertSucceeds(
          updateDoc(reference, {
            isOnline: true,
            availabilityCheckedAt:
                serverTimestamp(),
            updatedAt: serverTimestamp(),
          }),
      );

      const snapshot = await getDoc(reference);

      assert.equal(
          snapshot.data().isOnline,
          true,
      );
    },
);

test(
    "właściciel zmienia dostępność kamery",
    async () => {
      const db = testEnvironment
          .authenticatedContext(ownerId)
          .firestore();

      const reference = doc(
          db,
          "users",
          ownerId,
          "cameras",
          cameraId,
      );

      await assertSucceeds(
          updateDoc(reference, {
            isOnline: false,
            availabilityCheckedAt:
                serverTimestamp(),
            updatedAt: serverTimestamp(),
          }),
      );

      const snapshot = await getDoc(reference);

      assert.equal(
          snapshot.data().isOnline,
          false,
      );
    },
);

test(
    "nie można zmienić online bez czasu kontroli",
    async () => {
      const db = testEnvironment
          .authenticatedContext(ownerId)
          .firestore();

      const reference = doc(
          db,
          "users",
          ownerId,
          "cameras",
          cameraId,
      );

      await assertFails(
          updateDoc(reference, {
            isOnline: false,
            updatedAt: serverTimestamp(),
          }),
      );
    },
);

test(
    "obcy użytkownik nie zmienia kamery",
    async () => {
      const db = testEnvironment
          .authenticatedContext(strangerId)
          .firestore();

      const reference = doc(
          db,
          "users",
          ownerId,
          "cameras",
          cameraId,
      );

      await assertFails(
          updateDoc(reference, {
            isOnline: false,
            availabilityCheckedAt:
                serverTimestamp(),
            updatedAt: serverTimestamp(),
          }),
      );
    },
);

test(
    "właściciel odczytuje swoje wykrycie",
    async () => {
      const db = testEnvironment
          .authenticatedContext(ownerId)
          .firestore();

      await assertSucceeds(
          getDoc(
              doc(
                  db,
                  "cameraEvents",
                  eventId,
              ),
          ),
      );
    },
);

test(
    "obcy użytkownik nie odczytuje wykrycia",
    async () => {
      const db = testEnvironment
          .authenticatedContext(strangerId)
          .firestore();

      await assertFails(
          getDoc(
              doc(
                  db,
                  "cameraEvents",
                  eventId,
              ),
          ),
      );
    },
);

test(
    "właściciel zmienia new na viewed",
    async () => {
      const db = testEnvironment
          .authenticatedContext(ownerId)
          .firestore();

      const reference = doc(
          db,
          "cameraEvents",
          eventId,
      );

      await assertSucceeds(
          updateDoc(reference, {
            status: "viewed",
            updatedAt: serverTimestamp(),
          }),
      );

      const snapshot = await getDoc(reference);

      assert.equal(
          snapshot.data().status,
          "viewed",
      );
    },
);

test(
    "właściciel zmienia viewed na dismissed",
    async () => {
      const db = testEnvironment
          .authenticatedContext(ownerId)
          .firestore();

      const reference = doc(
          db,
          "cameraEvents",
          eventId,
      );

      await assertSucceeds(
          updateDoc(reference, {
            status: "viewed",
            updatedAt: serverTimestamp(),
          }),
      );

      await assertSucceeds(
          updateDoc(reference, {
            status: "dismissed",
            updatedAt: serverTimestamp(),
          }),
      );

      const snapshot = await getDoc(reference);

      assert.equal(
          snapshot.data().status,
          "dismissed",
      );
    },
);

test(
    "klient nie może ustawić escalated",
    async () => {
      const db = testEnvironment
          .authenticatedContext(ownerId)
          .firestore();

      const reference = doc(
          db,
          "cameraEvents",
          eventId,
      );

      await assertFails(
          updateDoc(reference, {
            status: "escalated",
            updatedAt: serverTimestamp(),
          }),
      );
    },
);

test(
    "obcy użytkownik nie zmienia wykrycia",
    async () => {
      const db = testEnvironment
          .authenticatedContext(strangerId)
          .firestore();

      const reference = doc(
          db,
          "cameraEvents",
          eventId,
      );

      await assertFails(
          updateDoc(reference, {
            status: "viewed",
            updatedAt: serverTimestamp(),
          }),
      );
    },
);
