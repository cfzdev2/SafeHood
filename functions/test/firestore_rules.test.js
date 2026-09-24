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

const projectId = "demo-safehood-rules-test";
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

/**
 * Zwraca Firestore wskazanego użytkownika.
 * @param {string} userId Identyfikator użytkownika.
 * @param {boolean} emailVerified Stan weryfikacji e-maila.
 * @return {Object} Klient Firestore.
 */
function firestoreFor(userId, emailVerified = true) {
  return testEnvironment
      .authenticatedContext(
          userId,
          {email_verified: emailVerified},
      )
      .firestore();
}

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
      const db = firestoreFor(ownerId);

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
    "niezweryfikowany właściciel nie odczytuje kamery",
    async () => {
      const db = firestoreFor(ownerId, false);

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
    "obcy użytkownik nie odczytuje kamery",
    async () => {
      const db = firestoreFor(strangerId);

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
      const db = firestoreFor(ownerId);

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
      const db = firestoreFor(ownerId);

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
    "właściciel zapisuje poprawne ustawienia AI kamery",
    async () => {
      const db = firestoreFor(ownerId);

      const reference = doc(
          db,
          "users",
          ownerId,
          "cameras",
          cameraId,
      );

      await assertSucceeds(
          updateDoc(reference, {
            aiEnabled: true,
            aiPersonEnabled: true,
            aiVehicleEnabled: false,
            aiSensitivity: "high",
            updatedAt: serverTimestamp(),
          }),
      );

      const snapshot = await getDoc(reference);

      assert.equal(
          snapshot.data().aiEnabled,
          true,
      );

      assert.equal(
          snapshot.data().aiSensitivity,
          "high",
      );
    },
);

test(
    "kamera odrzuca nieprawidłową czułość AI",
    async () => {
      const db = firestoreFor(ownerId);

      await assertFails(
          updateDoc(
              doc(
                  db,
                  "users",
                  ownerId,
                  "cameras",
                  cameraId,
              ),
              {
                aiEnabled: true,
                aiPersonEnabled: true,
                aiVehicleEnabled: true,
                aiSensitivity: "extreme",
                updatedAt: serverTimestamp(),
              },
          ),
      );
    },
);

test(
    "kamera odrzuca AI bez typu wykrywania",
    async () => {
      const db = firestoreFor(ownerId);

      await assertFails(
          updateDoc(
              doc(
                  db,
                  "users",
                  ownerId,
                  "cameras",
                  cameraId,
              ),
              {
                aiEnabled: true,
                aiPersonEnabled: false,
                aiVehicleEnabled: false,
                aiSensitivity: "standard",
                updatedAt: serverTimestamp(),
              },
          ),
      );
    },
);

test(
    "nie można zmienić online bez czasu kontroli",
    async () => {
      const db = firestoreFor(ownerId);

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
      const db = firestoreFor(strangerId);

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
      const db = firestoreFor(ownerId);

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
      const db = firestoreFor(strangerId);

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
      const db = firestoreFor(ownerId);

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
      const db = firestoreFor(ownerId);

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
      const db = firestoreFor(ownerId);

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
      const db = firestoreFor(strangerId);

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
