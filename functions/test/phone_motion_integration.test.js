const assert = require("node:assert/strict");
const {randomUUID} = require("node:crypto");
const {readFileSync} = require("node:fs");
const {join} = require("node:path");
const test = require("node:test");
const {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} = require("@firebase/rules-unit-testing");
const {doc, getDoc, serverTimestamp, updateDoc} = require("firebase/firestore");
const {getBytes, ref} = require("firebase/storage");
const {deleteApp, getApp} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");
const {getMessaging} = require("firebase-admin/messaging");

const projectId = "demo-safehood-phone-motion";
const bucket = `${projectId}.appspot.com`;
const jpeg = Buffer.from([
  "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBUO",
  "DAsLDBkSEw8VHhsgHx4bHR0hJTApISMtJB0dKjkqLTEzNjY2ICg7Pzo0",
  "PjA1NjP/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAAAv/EABQQ",
  "AQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AL//Z",
].join(""), "base64");

test("phone motion is opt-in and keeps the event private", {
  timeout: 45000,
}, async (t) => {
  const loopback = /^(127\.0\.0\.1|localhost):\d+$/;
  const storageHost = process.env.FIREBASE_STORAGE_EMULATOR_HOST || "";
  assert.match(storageHost, loopback);
  assert.match(process.env.FIRESTORE_EMULATOR_HOST || "", loopback);
  process.env.FIREBASE_CONFIG = JSON.stringify({
    projectId, storageBucket: bucket,
  });
  process.env.GCLOUD_PROJECT = projectId;
  process.env.STORAGE_EMULATOR_HOST = `http://${storageHost}`;

  const {ingestCameraEvent} = require("../index");
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
  const rules = (name) =>
    readFileSync(join(__dirname, "..", "..", name), "utf8");
  const env = await initializeTestEnvironment({
    projectId,
    firestore: {rules: rules("firestore.rules")},
    storage: {rules: rules("storage.rules")},
  });
  t.after(() => env.cleanup());

  const ownerId = `owner-${randomUUID()}`;
  const neighborId = `neighbor-${randomUUID()}`;
  const cameraId = "phone-camera";
  const cameraPath = `users/${ownerId}/cameras/${cameraId}`;
  const commonCamera = {
    name: "Robot",
    connectionType: "onvif",
    motionDetectionEnabled: false,
    notificationSettings: {enabled: false, motion: true},
  };
  const batch = db.batch();
  batch.set(db.doc(`users/${ownerId}`), {firstName: "Owner"});
  batch.set(db.doc(`users/${neighborId}`), {firstName: "Neighbor"});
  for (const id of [ownerId, neighborId]) {
    batch.set(db.doc(`users/${id}/devices/phone`), {
      notificationsAllowed: true,
      fcmToken: `token-${id}`,
    });
  }
  batch.set(db.doc(cameraPath), commonCamera);
  batch.set(db.doc(`users/${ownerId}/cameras/muted`), {
    ...commonCamera,
    connectionType: "rtsp",
    liveMotionEnabled: true,
    notificationSettings: {enabled: true, motion: true, motionAlert: false},
  });
  await batch.commit();

  const identity = (uid) => ({uid, token: {email_verified: true}});
  const signedIn = (uid) =>
    env.authenticatedContext(uid, {email_verified: true});
  const owner = signedIn(ownerId);
  const neighbor = signedIn(neighborId);
  const camera = doc(owner.firestore(), cameraPath);
  const eventData = {
    cameraId, type: "motion", source: "phone-motion",
    occurredAt: new Date().toISOString(),
    phoneSnapshot: jpeg.toString("base64"),
  };
  const send = (data = eventData, uid = ownerId) =>
    ingestCameraEvent.run({auth: identity(uid), data});

  await assert.rejects(send(), {code: "failed-precondition"});
  await assertFails(updateDoc(doc(neighbor.firestore(), cameraPath), {
    liveMotionEnabled: true, updatedAt: serverTimestamp(),
  }));
  await assertFails(updateDoc(camera, {
    liveMotionEnabled: "true", updatedAt: serverTimestamp(),
  }));
  const alertOnlyForMotion = {
    enabled: false, motion: true, person: true, vehicle: true, sound: true,
    motionAlert: true,
  };
  await assertFails(updateDoc(camera, {
    notificationSettings: {...alertOnlyForMotion, motionAlert: "true"},
    updatedAt: serverTimestamp(),
  }));
  await assertSucceeds(updateDoc(camera, {
    liveMotionEnabled: true,
    motionDetectionEnabled: true,
    notificationSettings: alertOnlyForMotion,
    updatedAt: serverTimestamp(),
  }));
  await assert.rejects(send(eventData, neighborId), {code: "not-found"});
  await assert.rejects(send({...eventData, type: "person"}), {
    code: "invalid-argument",
  });
  await assert.rejects(send({...eventData, phoneSnapshot: "invalid"}), {
    code: "invalid-argument",
  });

  const opened = await send({
    ...eventData,
    snapshotUrl: "https://example.test/not-an-upload.jpg",
  });
  const repeated = await send();
  assert.equal(opened.id, repeated.id);
  assert.equal(repeated.merged, true);
  assert.deepEqual(pushes.map((item) => [item.token, item.data.eventId]), [
    [`token-${ownerId}`, opened.id],
  ]);
  assert.equal(pushes[0].data.cameraEventType, "motion");
  assert.equal((await db.collection("incidents")
      .where("reporterId", "==", ownerId).get()).size, 0);

  const event = (await getDoc(
      doc(owner.firestore(), "cameraEvents", opened.id))).data();
  assert.equal(event.source, "phone-motion");
  assert.equal(event.snapshotUrl, null);
  assert.equal(event.snapshotPath,
      `users/${ownerId}/cameraEvents/${opened.id}/snapshot.jpg`);
  assert.deepEqual(Buffer.from(await getBytes(
      ref(owner.storage(`gs://${bucket}`), event.snapshotPath))), jpeg);
  const neighborEvent = doc(neighbor.firestore(), "cameraEvents", opened.id);
  await assertFails(getDoc(neighborEvent));
  await assertFails(getBytes(
      ref(neighbor.storage(`gs://${bucket}`), event.snapshotPath)));

  const muted = await send({
    ...eventData, cameraId: "muted", phoneSnapshot: null,
  });
  assert.equal(muted.type, "motion");
  await send({
    ...eventData, source: "onvif", type: "sound", phoneSnapshot: null,
  });
  assert.equal(pushes.length, 1);

  await assertSucceeds(updateDoc(camera, {
    liveMotionEnabled: false,
    motionDetectionEnabled: false,
    notificationSettings: {...alertOnlyForMotion, motionAlert: false},
    updatedAt: serverTimestamp(),
  }));
  await assert.rejects(send(), {code: "failed-precondition"});
  await assert.rejects(
      send({...eventData, source: "onvif", phoneSnapshot: null}),
      {code: "failed-precondition"},
  );
});
