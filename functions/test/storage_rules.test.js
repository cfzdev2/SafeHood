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
  deleteObject,
  getBytes,
  listAll,
  ref,
  uploadBytes,
} = require("firebase/storage");

const projectId =
    "demo-safehood-storage-rules-test";

const ownerId =
    "storage-owner";

const strangerId =
    "storage-stranger";

const eventId =
    "storage-event";

const snapshotPath =
    `users/${ownerId}/cameraEvents/` +
    `${eventId}/snapshot.jpg`;

const newSnapshotPath =
    `users/${ownerId}/cameraEvents/` +
    `${eventId}/new-snapshot.jpg`;

const eventDirectory =
    `users/${ownerId}/cameraEvents/` +
    eventId;

const clipPath = `${eventDirectory}/clip.mp4`;

const rulesPath = path.resolve(
    __dirname,
    "..",
    "..",
    "storage.rules",
);

const snapshotBytes =
    new Uint8Array([
      83,
      97,
      102,
      101,
      72,
      111,
      111,
      100,
    ]);

let testEnvironment;

/**
 * Zwraca Storage działający jako wskazany użytkownik.
 *
 * @param {string} userId Identyfikator użytkownika.
 * @param {boolean} emailVerified Stan weryfikacji e-maila.
 * @return {Object} Klient Firebase Storage.
 */
function storageFor(
    userId,
    emailVerified = true,
) {
  return testEnvironment
      .authenticatedContext(
          userId,
          {
            email_verified:
                emailVerified,
          },
      )
      .storage();
}

before(async () => {
  testEnvironment =
      await initializeTestEnvironment({
        projectId,
        storage: {
          rules: fs.readFileSync(
              rulesPath,
              "utf8",
          ),
        },
      });
});

beforeEach(async () => {
  await testEnvironment.clearStorage();

  await testEnvironment
      .withSecurityRulesDisabled(
          async (context) => {
            const storage =
                context.storage();

            await uploadBytes(
                ref(
                    storage,
                    snapshotPath,
                ),
                snapshotBytes,
                {
                  contentType:
                      "image/jpeg",
                },
            );
            await uploadBytes(ref(storage, clipPath), snapshotBytes, {
              contentType: "video/mp4",
            });
          },
      );
});

after(async () => {
  await testEnvironment.cleanup();
});

test("prywatny film pobiera wyłącznie zweryfikowany właściciel", async () => {
  await assertSucceeds(getBytes(ref(storageFor(ownerId), clipPath)));
  for (const storage of [storageFor(strangerId), storageFor(ownerId, false),
    testEnvironment.unauthenticatedContext().storage()]) {
    await assertFails(getBytes(ref(storage, clipPath)));
  }
});

test("klient nie nadpisuje i nie usuwa nagrania Bridge", async () => {
  const storage = storageFor(ownerId);
  await assertFails(uploadBytes(ref(storage, clipPath), snapshotBytes, {
    contentType: "video/mp4",
  }));
  await assertFails(deleteObject(ref(storage, clipPath)));
  await assertFails(listAll(ref(storage, eventDirectory)));
});

test(
    "zweryfikowany właściciel pobiera swoje zdjęcie",
    async () => {
      const storage =
          storageFor(ownerId);

      await assertSucceeds(
          getBytes(
              ref(
                  storage,
                  snapshotPath,
              ),
          ),
      );
    },
);

test(
    "obcy użytkownik nie pobiera zdjęcia",
    async () => {
      const storage =
          storageFor(strangerId);

      await assertFails(
          getBytes(
              ref(
                  storage,
                  snapshotPath,
              ),
          ),
      );
    },
);

test(
    "niezweryfikowany właściciel nie pobiera zdjęcia",
    async () => {
      const storage =
          storageFor(
              ownerId,
              false,
          );

      await assertFails(
          getBytes(
              ref(
                  storage,
                  snapshotPath,
              ),
          ),
      );
    },
);

test(
    "niezalogowany użytkownik nie pobiera zdjęcia",
    async () => {
      const storage =
          testEnvironment
              .unauthenticatedContext()
              .storage();

      await assertFails(
          getBytes(
              ref(
                  storage,
                  snapshotPath,
              ),
          ),
      );
    },
);

test(
    "właściciel nie wysyła pliku bezpośrednio",
    async () => {
      const storage =
          storageFor(ownerId);

      await assertFails(
          uploadBytes(
              ref(
                  storage,
                  newSnapshotPath,
              ),
              snapshotBytes,
              {
                contentType:
                    "image/jpeg",
              },
          ),
      );
    },
);

test(
    "właściciel nie usuwa pliku",
    async () => {
      const storage =
          storageFor(ownerId);

      await assertFails(
          deleteObject(
              ref(
                  storage,
                  snapshotPath,
              ),
          ),
      );
    },
);

test(
    "właściciel nie przegląda listy plików",
    async () => {
      const storage =
          storageFor(ownerId);

      await assertFails(
          listAll(
              ref(
                  storage,
                  eventDirectory,
              ),
          ),
      );
    },
);
