"use strict";

const assert = require("node:assert/strict");
const {createHash, randomUUID} = require("node:crypto");
const test = require("node:test");
const {deleteApp, getApp} = require("firebase-admin/app");
const {getFirestore, Timestamp} = require("firebase-admin/firestore");
const {getMessaging} = require("firebase-admin/messaging");

const projectId = "demo-safehood-incident-live";

test("the assigned Bridge can create a private motion alert without the app",
    {timeout: 30000}, async (t) => {
      assert.match(process.env.FIRESTORE_EMULATOR_HOST || "",
          /^(127\.0\.0\.1|localhost):\d+$/);
      process.env.FIREBASE_CONFIG = JSON.stringify({projectId});
      process.env.GCLOUD_PROJECT = projectId;
      const functions = require("../index");
      const db = getFirestore();
      t.after(() => deleteApp(getApp()));
      const pushes = [];
      t.mock.method(getMessaging(), "sendEach", async (messages) => {
        pushes.push(...messages);
        return {successCount: messages.length, failureCount: 0,
          responses: messages.map(() => ({success: true}))};
      });

      const uid = `owner-${randomUUID()}`;
      const bridgeId = `bridge-${randomUUID()}`;
      const cameraId = "onvif-camera";
      const bridgeSecret = randomUUID();
      const owner = db.doc(`users/${uid}`);
      const camera = owner.collection("cameras").doc(cameraId);
      const seed = db.batch();
      seed.set(owner, {activeBridgeId: bridgeId, localAiEnabled: false});
      seed.set(owner.collection("bridges").doc(bridgeId), {
        status: "online", lastSeenAt: Timestamp.now(),
      });
      seed.set(owner.collection("devices").doc("phone"), {
        notificationsAllowed: true, fcmToken: "owner-test-token",
      });
      seed.set(db.doc(`bridgeCredentials/${bridgeId}`), {
        ownerId: uid, status: "active",
        secretHash: createHash("sha256").update(bridgeSecret).digest("hex"),
      });
      seed.set(camera, {name: "Robot", ipAddress: "192.168.1.9",
        connectionType: "onvif", motionDetectionEnabled: true,
        liveMotionEnabled: false, notificationSettings: {motionAlert: true}});
      await seed.commit();

      const auth = {uid, token: {email_verified: true}};
      const chooseBridge = () => functions.assignCameraToOnlineBridge.run({
        auth, data: {cameraId},
      });
      await assert.rejects(chooseBridge(), {code: "failed-precondition"});
      await camera.update({liveMotionEnabled: true});
      assert.deepEqual(await chooseBridge(), {bridgeId});

      const send = async (handler, body, secret = bridgeSecret) => {
        const reply = {};
        const response = {
          status: (status) => {
            reply.status = status;
            return response;
          },
          json: (body) => {
            reply.body = body;
          },
        };
        await handler({method: "POST", body, headers: {
          "authorization": `Bearer ${secret}`,
          "x-safehood-bridge-id": bridgeId,
        }}, response);
        return reply;
      };
      const {body: configuration} = await send(
          functions.getBridgeConfiguration, {},
      );
      assert.equal(configuration.localAiEnabled, false);
      assert.equal(configuration.cameras[0].id, cameraId);
      assert.equal(configuration.cameras[0].frameMotionEnabled, true);

      const event = {cameraId, type: "motion", source: "bridge-motion",
        occurredAt: new Date().toISOString()};
      await assert.rejects(functions.ingestCameraEvent.run({auth, data: event}),
          {code: "invalid-argument"});
      assert.equal((await send(functions.ingestBridgeCameraEvent,
          event, "wrong-secret")).status, 401);
      const reply = await send(functions.ingestBridgeCameraEvent, event);
      assert.equal(reply.status, 200);
      const {eventId} = reply.body;
      const saved = (await db.doc(`cameraEvents/${eventId}`).get()).data();
      assert.equal(saved.ownerId, uid);
      assert.equal(saved.source, "bridge-motion");
      assert.deepEqual(pushes.map(({token, data}) => [
        token, data.eventId, data.cameraEventType,
      ]), [["owner-test-token", eventId, "motion"]]);
    });
