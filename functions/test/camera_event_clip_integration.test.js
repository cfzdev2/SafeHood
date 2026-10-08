"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const {createHash, randomUUID, generateKeyPairSync} = require("node:crypto");
const {initializeApp, deleteApp, cert} = require("firebase-admin/app");
const {getFirestore, Timestamp, FieldValue} =
    require("firebase-admin/firestore");
const {getStorage} = require("firebase-admin/storage");
const {createClipUploadHandler} = require("../camera_event_clip");

test("rzeczywisty Firestore i Storage zachowują pierwszy prywatny MP4",
    {timeout: 30000}, async (t) => {
      assert.ok(process.env.FIRESTORE_EMULATOR_HOST,
          "Uruchom npm run test:clips:backend.");
      assert.ok(process.env.FIREBASE_STORAGE_EMULATOR_HOST);
      const localEmulator = /^(127\.0\.0\.1|localhost):\d+$/;
      assert.match(process.env.FIRESTORE_EMULATOR_HOST, localEmulator);
      assert.match(process.env.FIREBASE_STORAGE_EMULATOR_HOST, localEmulator);
      const projectId = "demo-safehood-clips-test";
      const {privateKey} = generateKeyPairSync("rsa", {modulusLength: 2048});
      const app = initializeApp({projectId,
        storageBucket: `${projectId}.appspot.com`,
        // Wygenerowany klucz testowy nie ma uprawnień w Google Cloud.
        // Jawny projekt i emulatory eliminują wyszukiwanie poświadczeń ADC.
        credential: cert({projectId,
          clientEmail: `test-only@${projectId}.iam.gserviceaccount.com`,
          privateKey: privateKey.export({type: "pkcs8", format: "pem"})
              .toString(),
        }),
      }, randomUUID());
      const db = getFirestore(app);
      const bucket = getStorage(app).bucket();
      const ownerId = `clip-owner-${randomUUID()}`;
      const cameraId = "camera-1";
      const bridgeId = "bridge-1";
      const eventId = `event-${randomUUID()}`;
      const externalEventId = randomUUID();
      const occurredAtMillis = Date.now();
      const receiptId = createHash("sha256").update(JSON.stringify([
        ownerId, bridgeId, cameraId, externalEventId,
      ])).digest("hex");
      const camera = db.doc(`users/${ownerId}/cameras/${cameraId}`);
      const event = db.doc(`cameraEvents/${eventId}`);
      const receipt = db.doc(`bridgeCameraEventReceipts/${receiptId}`);
      const clipPath = `users/${ownerId}/cameraEvents/${eventId}/clip.mp4`;
      t.after(async () => {
        await bucket.deleteFiles({prefix: `users/${ownerId}/`});
        await Promise.all([camera.delete(), event.delete(), receipt.delete()]);
        await deleteApp(app);
      });
      await Promise.all([
        camera.set({bridgeId, connectionType: "onvif",
          aiRecordingEnabled: true}),
        event.set({ownerId, cameraId, source: "local-ai", occurrenceCount: 4}),
        receipt.set({ownerId, cameraId, bridgeId, externalEventId,
          source: "local-ai", occurredAt:
            new Date(occurredAtMillis).toISOString(), result: {eventId}}),
      ]);
      const movie = fs.readFileSync(
          path.join(__dirname, "../../tools/fake_clip.mp4"),
      );
      let failTransaction = true;
      const handler = createClipUploadHandler({db: {
        collection: db.collection.bind(db), getAll: db.getAll.bind(db),
        runTransaction: (operation) => {
          if (failTransaction) {
            failTransaction = false;
            return Promise.reject(new Error("Kontrolowana awaria Firestore."));
          }
          return db.runTransaction(operation);
        },
      }, Timestamp, FieldValue, authenticate: async () => ({ownerId, bridgeId}),
      getBucket: () => bucket, log: {error: () => {}}});
      const send = async (bytes) => {
        let status;
        let body;
        const response = {status: (value) => {
          status = value; return response;
        }, json: (value) => {
          body = value;
        }};
        await handler({method: "POST", body: {
          cameraId, externalEventId, occurredAtMillis,
          prebufferMillis: 5000, mp4Base64: bytes.toString("base64"),
        }}, response);
        return {status, body};
      };
      assert.equal((await send(movie)).status, 500);
      assert.equal((await event.get()).data().clipPath, undefined);
      const changed = Buffer.from(movie);
      changed[changed.length - 1] ^= 1;
      const responses = await Promise.all([send(changed), send(changed)]);
      assert.ok(responses.every((value) => value.status === 200));
      const file = bucket.file(clipPath);
      const [stored] = await file.download();
      const [metadata] = await file.getMetadata();
      assert.deepEqual(stored, movie);
      assert.equal(metadata.contentType, "video/mp4");
      assert.equal(metadata.metadata.firebaseStorageDownloadTokens, undefined);
      assert.equal((await event.get()).data().occurrenceCount, 4);
      assert.equal((await event.get()).data().clipPrebufferMillis, 5000);
      assert.equal((await event.get()).data().clipPath, clipPath);
    });
