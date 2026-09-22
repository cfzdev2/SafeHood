const assert = require("node:assert/strict");
const {
  after,
  before,
  beforeEach,
  test,
} = require("node:test");
const {readFileSync} = require("node:fs");
const {join} = require("node:path");

const {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} = require("@firebase/rules-unit-testing");

const {
  collection,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  setDoc,
  Timestamp,
  updateDoc,
} = require("firebase/firestore");

const projectId = "demo-safehood-rules-test";
const ownerId = "rules-bridge-owner";
const strangerId = "rules-bridge-stranger";
const bridgeId = "rules-bridge";

let testEnvironment;

/**
 * Zwraca Firestore zalogowanego użytkownika.
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

/**
 * Zwraca Firestore bez zalogowanego użytkownika.
 * @return {Object} Klient Firestore.
 */
function anonymousFirestore() {
  return testEnvironment
      .unauthenticatedContext()
      .firestore();
}

/**
 * Zwraca kolekcję Bridge właściciela.
 * @param {Object} db Klient Firestore.
 * @return {Object} Referencja kolekcji.
 */
function bridgesCollection(db) {
  return collection(
      db,
      "users",
      ownerId,
      "bridges",
  );
}

/**
 * Zwraca referencję Bridge.
 * @param {Object} db Klient Firestore.
 * @param {string} id Identyfikator Bridge.
 * @return {Object} Referencja dokumentu.
 */
function bridgeRef(db, id = bridgeId) {
  return doc(
      db,
      "users",
      ownerId,
      "bridges",
      id,
  );
}

before(async () => {
  const rulesPath = join(
      __dirname,
      "..",
      "..",
      "firestore.rules",
  );

  testEnvironment =
      await initializeTestEnvironment({
        projectId,
        firestore: {
          rules: readFileSync(
              rulesPath,
              "utf8",
          ),
        },
      });
});

beforeEach(async () => {
  await testEnvironment.clearFirestore();

  await testEnvironment
      .withSecurityRulesDisabled(
          async (context) => {
            const db = context.firestore();

            await setDoc(
                bridgeRef(db),
                {
                  ownerId,
                  name: "Bridge testowy",
                  status: "online",
                  updatedAt:
                    Timestamp.fromMillis(1000),
                },
            );
          },
      );
});

after(async () => {
  await testEnvironment.cleanup();
});

test(
    "niezweryfikowany właściciel nie odczytuje Bridge",
    async () => {
      const db = firestoreFor(ownerId, false);

      await assertFails(
          getDoc(bridgeRef(db)),
      );
    },
);

test(
    "właściciel odczytuje swój Bridge",
    async () => {
      const db = firestoreFor(ownerId);

      const snapshot = await assertSucceeds(
          getDoc(bridgeRef(db)),
      );

      assert.equal(snapshot.exists(), true);
    },
);

test(
    "obcy użytkownik nie odczytuje Bridge",
    async () => {
      const db = firestoreFor(strangerId);

      await assertFails(
          getDoc(bridgeRef(db)),
      );
    },
);

test(
    "niezalogowany nie odczytuje Bridge",
    async () => {
      const db = anonymousFirestore();

      await assertFails(
          getDoc(bridgeRef(db)),
      );
    },
);

test(
    "właściciel odczytuje listę swoich Bridge",
    async () => {
      const db = firestoreFor(ownerId);

      const snapshot = await assertSucceeds(
          getDocs(bridgesCollection(db)),
      );

      assert.equal(snapshot.size, 1);
      assert.equal(
          snapshot.docs[0].id,
          bridgeId,
      );
    },
);

test(
    "obcy użytkownik nie odczytuje listy Bridge",
    async () => {
      const db = firestoreFor(strangerId);

      await assertFails(
          getDocs(bridgesCollection(db)),
      );
    },
);

test(
    "właściciel nie tworzy Bridge bez backendu",
    async () => {
      const db = firestoreFor(ownerId);

      await assertFails(
          setDoc(
              bridgeRef(db, "client-bridge"),
              {
                ownerId,
                status: "online",
              },
          ),
      );
    },
);

test(
    "właściciel nie aktualizuje Bridge",
    async () => {
      const db = firestoreFor(ownerId);

      await assertFails(
          updateDoc(
              bridgeRef(db),
              {
                status: "offline",
              },
          ),
      );
    },
);

test(
    "właściciel nie usuwa Bridge",
    async () => {
      const db = firestoreFor(ownerId);

      await assertFails(
          deleteDoc(bridgeRef(db)),
      );
    },
);
