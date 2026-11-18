"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const {readFileSync} = require("node:fs");
const {join} = require("node:path");
const {createHash, randomUUID} = require("node:crypto");
const {deleteApp, getApp} = require("firebase-admin/app");
const {getFirestore, GeoPoint} = require("firebase-admin/firestore");
const {getMessaging} = require("firebase-admin/messaging");
const {initializeTestEnvironment, assertFails} =
  require("@firebase/rules-unit-testing");
const {doc, getDoc, serverTimestamp, updateDoc} =
  require("firebase/firestore");
const {ref, getBytes} = require("firebase/storage");
const {geohashForLocation} = require("geofire-common");

const projectId = "demo-safehood-neighbor-flow";
const bucket = `${projectId}.appspot.com`;
// JPEG szarego kwadratu 4 × 4, wygenerowany do tego testu.
const jpeg = Buffer.from([
  "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkS",
  "Ew8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAAE",
  "AAQBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAAAv/EABQQAQAAAAAAAAAAAAAAAAAA",
  "AAD/2gAIAQEAAD8AL//Z",
].join(""), "base64");

test("prywatne wykrycie i jedno zgłoszenie do sąsiada", {
  timeout: 45000,
}, async (t) => {
  const firestoreHost = process.env.FIRESTORE_EMULATOR_HOST || "";
  const storageHost = process.env.FIREBASE_STORAGE_EMULATOR_HOST || "";
  const loopback = /^(127\.0\.0\.1|localhost):\d+$/;
  for (const host of [firestoreHost, storageHost]) {
    assert.match(host, loopback, "Uruchom npm run test:free-flow.");
  }
  process.env.FIREBASE_CONFIG = JSON.stringify({
    projectId, storageBucket: bucket,
  });
  process.env.GCLOUD_PROJECT = projectId;
  process.env.STORAGE_EMULATOR_HOST = `http://${storageHost}`;

  const functions = require("../index");
  const db = getFirestore();
  t.after(() => deleteApp(getApp()));
  const pushes = [];
  t.mock.method(getMessaging(), "sendEach", async (messages) => {
    pushes.push(...messages);
    return {
      successCount: messages.length,
      failureCount: 0,
      responses: messages.map(() => ({success: true})),
    };
  });

  const readRules = (file) =>
    readFileSync(join(__dirname, "..", "..", file), "utf8");
  const environment = await initializeTestEnvironment({
    projectId,
    firestore: {rules: readRules("firestore.rules")},
    storage: {rules: readRules("storage.rules")},
  });
  t.after(() => environment.cleanup());

  const runId = randomUUID();
  const ownerId = `owner-${runId}`;
  const neighborId = `neighbor-${runId}`;
  const mutedId = `muted-${runId}`;
  const farId = `far-${runId}`;
  const cameraId = "camera";
  const bridgeId = `bridge-${runId}`;
  const testSecret = randomUUID();
  const tokenFor = (uid) => `token-${uid}`;
  const batch = db.batch();
  for (const [uid, latitude] of [
    [ownerId, 52], [neighborId, 52.0005], [mutedId, 52.001], [farId, 53],
  ]) {
    batch.set(db.doc(`users/${uid}`), {
      firstName: "Test",
      localAiEnabled: uid === ownerId,
      geo: {
        geopoint: new GeoPoint(latitude, 19),
        geohash: geohashForLocation([latitude, 19]),
      },
    });
    batch.set(db.doc(`communityProfiles/${uid}`), {
      firstName: "Test",
      notificationsEnabled: uid !== mutedId,
    });
    batch.set(db.doc(`users/${uid}/devices/phone`), {
      notificationsAllowed: true,
      fcmToken: tokenFor(uid),
    });
  }
  batch.set(db.doc(`users/${ownerId}/cameras/${cameraId}`), {
    name: "Kamera testowa",
    bridgeId,
    connectionType: "onvif",
    aiEnabled: true,
    aiPersonEnabled: true,
    notificationSettings: {enabled: true, personEnabled: true},
  });
  batch.set(db.doc(`bridgeCredentials/${bridgeId}`), {
    ownerId,
    status: "active",
    secretHash: createHash("sha256").update(testSecret).digest("hex"),
  });
  await batch.commit();

  const sendFromBridge = async (handler, body) => {
    let status;
    let result;
    const response = {
      status: (value) => {
        status = value;
        return response;
      },
      json: (value) => {
        result = value;
      },
    };
    await handler({
      method: "POST",
      headers: {
        "x-safehood-bridge-id": bridgeId,
        "authorization": `Bearer ${testSecret}`,
      },
      body,
    }, response);
    assert.equal(status, 200, JSON.stringify(result));
    return result;
  };

  const detection = {
    cameraId, type: "person", source: "local-ai",
    externalEventId: randomUUID(), occurredAt: new Date().toISOString(),
  };
  const {eventId} = await sendFromBridge(
      functions.ingestBridgeCameraEvent, detection);
  assert.deepEqual(pushes.map((p) => [p.token, p.data.type, p.data.eventId]),
      [[tokenFor(ownerId), "camera_event", eventId]]);
  assert.equal(pushes[0].data.cameraEventType, "person");
  assert.equal((await db.collection("incidents")
      .where("reporterId", "==", ownerId).get()).size, 0);

  const snapshot = await sendFromBridge(
      functions.uploadBridgeCameraEventSnapshot,
      {cameraId, eventId, jpegBase64: jpeg.toString("base64")});
  const retry = await sendFromBridge(
      functions.ingestBridgeCameraEvent, detection);
  assert.equal(retry.duplicate, true);
  assert.equal(pushes.length, 1);

  const signedIn = (uid) =>
    environment.authenticatedContext(uid, {email_verified: true});
  const owner = signedIn(ownerId);
  const neighbor = signedIn(neighborId);
  const ownerEvent = doc(owner.firestore(), "cameraEvents", eventId);
  const photoFor = (user) =>
    ref(user.storage(`gs://${bucket}`), snapshot.snapshotPath);
  assert.equal((await getDoc(ownerEvent)).data().snapshotPath,
      snapshot.snapshotPath);
  assert.deepEqual(Buffer.from(await getBytes(photoFor(owner))), jpeg);
  await updateDoc(ownerEvent, {status: "viewed", updatedAt: serverTimestamp()});
  assert.equal(pushes.length, 1);

  const escalate = (uid) => functions.escalateCameraEvent.run({
    auth: {uid, token: {email_verified: true}},
    data: {eventId, title: "Nietypowa aktywność", description: "Test."},
  });
  await assert.rejects(escalate(neighborId), {code: "permission-denied"});
  const reports = await Promise.all([escalate(ownerId), escalate(ownerId)]);
  const incidentId = reports[0].id;
  assert.equal(reports[1].id, incidentId);
  assert.equal(reports.filter((item) => !item.alreadyEscalated).length, 1);
  assert.deepEqual(pushes.slice(1).map((p) => [
    p.token, p.data.type, p.data.incidentId,
  ]), [[tokenFor(neighborId), "incident", incidentId]]);

  const incidentRef = (user) => doc(user.firestore(), "incidents", incidentId);
  const incident = (await getDoc(incidentRef(neighbor))).data();
  assert.deepEqual(new Set(incident.participantIds),
      new Set([ownerId, neighborId, mutedId]));
  assert.equal((await getDoc(incidentRef(signedIn(mutedId)))).exists(), true);
  await assertFails(getDoc(incidentRef(signedIn(farId))));
  await assertFails(getDoc(doc(neighbor.firestore(), "cameraEvents", eventId)));
  await assertFails(getBytes(photoFor(neighbor)));
});
