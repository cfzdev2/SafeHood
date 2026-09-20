"use strict";

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
  deleteDoc,
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
const deviceId = "rules-device";

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
 * Zwraca bazę działającą jako wskazany użytkownik.
 *
 * @param {string} userId Identyfikator użytkownika.
 * @return {Object} Klient Firestore.
 */
function firestoreFor(userId) {
  return testEnvironment
      .authenticatedContext(userId)
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

        await Promise.all([
          setDoc(
              doc(db, "users", ownerId),
              {
                firstName: "Maciej",
                phoneNumber: "123456789",
                address: "Adres testowy",
                latitude: 50,
                longitude: 20,
                notificationsEnabled: true,
                email: "owner@example.com",
                geo: {
                  geohash: "test",
                },
                updatedAt: initialTimestamp,
              },
          ),
          setDoc(
              doc(
                  db,
                  "communityProfiles",
                  ownerId,
              ),
              {
                firstName: "Maciej",
                notificationsEnabled: true,
                updatedAt: initialTimestamp,
              },
          ),
          setDoc(
              doc(
                  db,
                  "users",
                  ownerId,
                  "devices",
                  deviceId,
              ),
              {
                fid: deviceId,
                fcmToken: "test-token",
                platform: "android",
                notificationsAllowed: true,
                updatedAt: initialTimestamp,
              },
          ),
        ]);
      },
  );
});

after(async () => {
  if (testEnvironment != null) {
    await testEnvironment.cleanup();
  }
});

test(
    "właściciel odczytuje swój profil",
    async () => {
      const db = firestoreFor(ownerId);

      await assertSucceeds(
          getDoc(
              doc(db, "users", ownerId),
          ),
      );
    },
);

test(
    "obcy użytkownik nie odczytuje profilu",
    async () => {
      const db = firestoreFor(strangerId);

      await assertFails(
          getDoc(
              doc(db, "users", ownerId),
          ),
      );
    },
);

test(
    "użytkownik tworzy poprawny profil",
    async () => {
      const newUserId = "rules-new-user";

      const db = firestoreFor(newUserId);

      await assertSucceeds(
          setDoc(
              doc(db, "users", newUserId),
              {
                firstName: "Nowy",
                phoneNumber: "",
                address: "",
                latitude: null,
                longitude: null,
                notificationsEnabled: true,
                email: null,
                geo: null,
                updatedAt: serverTimestamp(),
              },
          ),
      );
    },
);

test(
    "właściciel aktualizuje swój profil",
    async () => {
      const db = firestoreFor(ownerId);

      await assertSucceeds(
          updateDoc(
              doc(db, "users", ownerId),
              {
                firstName: "Karol",
                updatedAt: serverTimestamp(),
              },
          ),
      );
    },
);

test(
    "właściciel nie zapisuje pola backendu",
    async () => {
      const db = firestoreFor(ownerId);

      await assertFails(
          updateDoc(
              doc(db, "users", ownerId),
              {
                activeBridgeId: "bridge-1",
                updatedAt: serverTimestamp(),
              },
          ),
      );
    },
);

test(
    "właściciel nie usuwa profilu bez backendu",
    async () => {
      const db = firestoreFor(ownerId);

      await assertFails(
          deleteDoc(
              doc(db, "users", ownerId),
          ),
      );
    },
);

test(
    "właściciel odczytuje profil społecznościowy",
    async () => {
      const db = firestoreFor(ownerId);

      await assertSucceeds(
          getDoc(
              doc(
                  db,
                  "communityProfiles",
                  ownerId,
              ),
          ),
      );
    },
);

test(
    "obcy nie odczytuje profilu społecznościowego",
    async () => {
      const db = firestoreFor(strangerId);

      await assertFails(
          getDoc(
              doc(
                  db,
                  "communityProfiles",
                  ownerId,
              ),
          ),
      );
    },
);

test(
    "użytkownik tworzy profil społecznościowy",
    async () => {
      const newUserId = "rules-community-user";

      const db = firestoreFor(newUserId);

      await assertSucceeds(
          setDoc(
              doc(
                  db,
                  "communityProfiles",
                  newUserId,
              ),
              {
                firstName: "Nowy",
                notificationsEnabled: true,
                updatedAt: serverTimestamp(),
              },
          ),
      );
    },
);

test(
    "właściciel aktualizuje profil społecznościowy",
    async () => {
      const db = firestoreFor(ownerId);

      await assertSucceeds(
          updateDoc(
              doc(
                  db,
                  "communityProfiles",
                  ownerId,
              ),
              {
                notificationsEnabled: false,
                updatedAt: serverTimestamp(),
              },
          ),
      );
    },
);

test(
    "profil społecznościowy odrzuca prywatne pole",
    async () => {
      const db = firestoreFor(ownerId);

      await assertFails(
          updateDoc(
              doc(
                  db,
                  "communityProfiles",
                  ownerId,
              ),
              {
                phoneNumber: "123456789",
                updatedAt: serverTimestamp(),
              },
          ),
      );
    },
);

test(
    "właściciel nie usuwa profilu społecznościowego",
    async () => {
      const db = firestoreFor(ownerId);

      await assertFails(
          deleteDoc(
              doc(
                  db,
                  "communityProfiles",
                  ownerId,
              ),
          ),
      );
    },
);

test(
    "właściciel odczytuje swoje urządzenie",
    async () => {
      const db = firestoreFor(ownerId);

      await assertSucceeds(
          getDoc(
              doc(
                  db,
                  "users",
                  ownerId,
                  "devices",
                  deviceId,
              ),
          ),
      );
    },
);

test(
    "obcy użytkownik nie odczytuje urządzenia",
    async () => {
      const db = firestoreFor(strangerId);

      await assertFails(
          getDoc(
              doc(
                  db,
                  "users",
                  ownerId,
                  "devices",
                  deviceId,
              ),
          ),
      );
    },
);

test(
    "właściciel rejestruje nowe urządzenie",
    async () => {
      const newDeviceId = "rules-new-device";

      const db = firestoreFor(ownerId);

      await assertSucceeds(
          setDoc(
              doc(
                  db,
                  "users",
                  ownerId,
                  "devices",
                  newDeviceId,
              ),
              {
                fid: newDeviceId,
                fcmToken: "new-token",
                platform: "android",
                notificationsAllowed: true,
                updatedAt: serverTimestamp(),
              },
          ),
      );
    },
);

test(
    "właściciel aktualizuje token urządzenia",
    async () => {
      const db = firestoreFor(ownerId);

      await assertSucceeds(
          updateDoc(
              doc(
                  db,
                  "users",
                  ownerId,
                  "devices",
                  deviceId,
              ),
              {
                fcmToken: "updated-token",
                updatedAt: serverTimestamp(),
              },
          ),
      );
    },
);

test(
    "urządzenie odrzuca nieobsługiwaną platformę",
    async () => {
      const db = firestoreFor(ownerId);

      await assertFails(
          updateDoc(
              doc(
                  db,
                  "users",
                  ownerId,
                  "devices",
                  deviceId,
              ),
              {
                platform: "windows",
                updatedAt: serverTimestamp(),
              },
          ),
      );
    },
);

test(
    "urządzenie odrzuca niezgodny fid",
    async () => {
      const db = firestoreFor(ownerId);

      await assertFails(
          updateDoc(
              doc(
                  db,
                  "users",
                  ownerId,
                  "devices",
                  deviceId,
              ),
              {
                fid: "inne-urzadzenie",
                updatedAt: serverTimestamp(),
              },
          ),
      );
    },
);

test(
    "obcy użytkownik nie usuwa urządzenia",
    async () => {
      const db = firestoreFor(strangerId);

      await assertFails(
          deleteDoc(
              doc(
                  db,
                  "users",
                  ownerId,
                  "devices",
                  deviceId,
              ),
          ),
      );
    },
);

test(
    "właściciel usuwa swoje urządzenie",
    async () => {
      const db = firestoreFor(ownerId);

      await assertSucceeds(
          deleteDoc(
              doc(
                  db,
                  "users",
                  ownerId,
                  "devices",
                  deviceId,
              ),
          ),
      );
    },
);
