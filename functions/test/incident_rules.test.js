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
  query,
  setDoc,
  Timestamp,
  updateDoc,
  where,
} = require("firebase/firestore");

const projectId = "safehood-security-app";

const participantId = "rules-participant";
const strangerId = "rules-stranger";
const otherUserId = "rules-other-user";

const incidentId = "rules-incident";
const otherIncidentId = "rules-other-incident";
const responseId = "rules-response";
const messageId = "rules-message";

let testEnvironment;

/**
 * Zwraca Firestore zalogowanego użytkownika.
 * @param {string} userId Identyfikator użytkownika.
 * @return {Object} Klient Firestore.
 */
function firestoreFor(userId) {
  return testEnvironment
      .authenticatedContext(userId)
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
 * Zwraca referencję zgłoszenia.
 * @param {Object} db Klient Firestore.
 * @param {string} id Identyfikator zgłoszenia.
 * @return {Object} Referencja dokumentu.
 */
function incidentRef(db, id = incidentId) {
  return doc(db, "incidents", id);
}

/**
 * Zwraca referencję reakcji.
 * @param {Object} db Klient Firestore.
 * @param {string} id Identyfikator reakcji.
 * @return {Object} Referencja dokumentu.
 */
function responseRef(db, id = responseId) {
  return doc(
      db,
      "incidents",
      incidentId,
      "responses",
      id,
  );
}

/**
 * Zwraca referencję wiadomości.
 * @param {Object} db Klient Firestore.
 * @param {string} id Identyfikator wiadomości.
 * @return {Object} Referencja dokumentu.
 */
function messageRef(db, id = messageId) {
  return doc(
      db,
      "incidents",
      incidentId,
      "messages",
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
                incidentRef(db),
                {
                  reporterId: participantId,
                  participantIds: [
                    participantId,
                  ],
                  title: "Testowe zgłoszenie",
                  status: "active",
                  createdAt:
                    Timestamp.fromMillis(1000),
                },
            );

            await setDoc(
                incidentRef(
                    db,
                    otherIncidentId,
                ),
                {
                  reporterId: otherUserId,
                  participantIds: [
                    otherUserId,
                  ],
                  title: "Obce zgłoszenie",
                  status: "active",
                  createdAt:
                    Timestamp.fromMillis(1000),
                },
            );

            await setDoc(
                responseRef(db),
                {
                  userId: participantId,
                  status: "accepted",
                  updatedAt:
                    Timestamp.fromMillis(1000),
                },
            );

            await setDoc(
                messageRef(db),
                {
                  senderId: participantId,
                  text: "Jestem w drodze.",
                  createdAt:
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
    "uczestnik odczytuje zgłoszenie",
    async () => {
      const db = firestoreFor(
          participantId,
      );

      const snapshot = await assertSucceeds(
          getDoc(incidentRef(db)),
      );

      assert.equal(snapshot.exists(), true);
    },
);

test(
    "obcy użytkownik nie odczytuje zgłoszenia",
    async () => {
      const db = firestoreFor(strangerId);

      await assertFails(
          getDoc(incidentRef(db)),
      );
    },
);

test(
    "niezalogowany nie odczytuje zgłoszenia",
    async () => {
      const db = anonymousFirestore();

      await assertFails(
          getDoc(incidentRef(db)),
      );
    },
);

test(
    "uczestnik pobiera tylko swoje zgłoszenia",
    async () => {
      const db = firestoreFor(
          participantId,
      );

      const incidentsQuery = query(
          collection(db, "incidents"),
          where(
              "participantIds",
              "array-contains",
              participantId,
          ),
      );

      const snapshot = await assertSucceeds(
          getDocs(incidentsQuery),
      );

      assert.equal(snapshot.size, 1);
      assert.equal(
          snapshot.docs[0].id,
          incidentId,
      );
    },
);

test(
    "uczestnik nie pobiera całej kolekcji",
    async () => {
      const db = firestoreFor(
          participantId,
      );

      await assertFails(
          getDocs(
              collection(db, "incidents"),
          ),
      );
    },
);

test(
    "klient nie tworzy zgłoszenia",
    async () => {
      const db = firestoreFor(
          participantId,
      );

      await assertFails(
          setDoc(
              incidentRef(
                  db,
                  "client-incident",
              ),
              {
                reporterId: participantId,
                participantIds: [
                  participantId,
                ],
                title: "Nowe zgłoszenie",
                status: "active",
                createdAt:
                  Timestamp.fromMillis(2000),
              },
          ),
      );
    },
);

test(
    "uczestnik nie modyfikuje zgłoszenia",
    async () => {
      const db = firestoreFor(
          participantId,
      );

      await assertFails(
          updateDoc(
              incidentRef(db),
              {
                title: "Zmieniony tytuł",
              },
          ),
      );
    },
);

test(
    "uczestnik nie usuwa zgłoszenia",
    async () => {
      const db = firestoreFor(
          participantId,
      );

      await assertFails(
          deleteDoc(incidentRef(db)),
      );
    },
);

test(
    "uczestnik odczytuje reakcję",
    async () => {
      const db = firestoreFor(
          participantId,
      );

      const snapshot = await assertSucceeds(
          getDoc(responseRef(db)),
      );

      assert.equal(snapshot.exists(), true);
    },
);

test(
    "obcy użytkownik nie odczytuje reakcji",
    async () => {
      const db = firestoreFor(strangerId);

      await assertFails(
          getDoc(responseRef(db)),
      );
    },
);

test(
    "niezalogowany nie odczytuje reakcji",
    async () => {
      const db = anonymousFirestore();

      await assertFails(
          getDoc(responseRef(db)),
      );
    },
);

test(
    "uczestnik nie tworzy reakcji",
    async () => {
      const db = firestoreFor(
          participantId,
      );

      await assertFails(
          setDoc(
              responseRef(
                  db,
                  "client-response",
              ),
              {
                userId: participantId,
                status: "accepted",
              },
          ),
      );
    },
);

test(
    "uczestnik nie modyfikuje reakcji",
    async () => {
      const db = firestoreFor(
          participantId,
      );

      await assertFails(
          updateDoc(
              responseRef(db),
              {
                status: "declined",
              },
          ),
      );
    },
);

test(
    "uczestnik nie usuwa reakcji",
    async () => {
      const db = firestoreFor(
          participantId,
      );

      await assertFails(
          deleteDoc(responseRef(db)),
      );
    },
);

test(
    "uczestnik odczytuje wiadomość",
    async () => {
      const db = firestoreFor(
          participantId,
      );

      const snapshot = await assertSucceeds(
          getDoc(messageRef(db)),
      );

      assert.equal(snapshot.exists(), true);
    },
);

test(
    "obcy użytkownik nie odczytuje wiadomości",
    async () => {
      const db = firestoreFor(strangerId);

      await assertFails(
          getDoc(messageRef(db)),
      );
    },
);

test(
    "niezalogowany nie odczytuje wiadomości",
    async () => {
      const db = anonymousFirestore();

      await assertFails(
          getDoc(messageRef(db)),
      );
    },
);

test(
    "uczestnik nie tworzy wiadomości",
    async () => {
      const db = firestoreFor(
          participantId,
      );

      await assertFails(
          setDoc(
              messageRef(
                  db,
                  "client-message",
              ),
              {
                senderId: participantId,
                text: "Nowa wiadomość",
                createdAt:
                  Timestamp.fromMillis(2000),
              },
          ),
      );
    },
);

test(
    "uczestnik nie modyfikuje wiadomości",
    async () => {
      const db = firestoreFor(
          participantId,
      );

      await assertFails(
          updateDoc(
              messageRef(db),
              {
                text: "Zmieniona wiadomość",
              },
          ),
      );
    },
);

test(
    "uczestnik nie usuwa wiadomości",
    async () => {
      const db = firestoreFor(
          participantId,
      );

      await assertFails(
          deleteDoc(messageRef(db)),
      );
    },
);
