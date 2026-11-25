"use strict";

const assert = require("node:assert/strict");
const {randomUUID} = require("node:crypto");
const {readFileSync} = require("node:fs");
const {join} = require("node:path");
const test = require("node:test");
const {getFirestore} = require("firebase-admin/firestore");
const {deleteApp, getApp} = require("firebase-admin/app");
const {getMessaging} = require("firebase-admin/messaging");
const {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} = require("@firebase/rules-unit-testing");
const {
  doc,
  getDoc,
  updateDoc,
  setDoc,
  serverTimestamp,
} = require("firebase/firestore");

test(
    "vendor callbacks deliver private alerts without a phone or Bridge session",
    {
      timeout: 45000,
    },
    async (t) => {
      assert.match(
          process.env.FIRESTORE_EMULATOR_HOST || "",
          /^(127\.0\.0\.1|localhost):\d+$/,
      );
      const projectId = "demo-safehood-xm";
      process.env.GCLOUD_PROJECT = projectId;
      process.env.FIREBASE_CONFIG = JSON.stringify({projectId});
      process.env.FUNCTIONS_EMULATOR = "true";
      process.env.SAFEHOOD_XM_ENABLED = "true";
      process.env.SAFEHOOD_XM_ACCOUNT_KEY = "12".repeat(32);
      process.env.SAFEHOOD_XM_CALLBACK_BASE_URL =
      "https://callbacks.example.test/receiveXmCameraAlarm";
      const api = require("../index");
      const db = getFirestore();
      t.after(() => deleteApp(getApp()));
      const env = await initializeTestEnvironment({
        projectId,
        firestore: {
          rules: readFileSync(join(__dirname, "../../firestore.rules"), "utf8"),
        },
      });
      t.after(() => env.cleanup());
      const pushes = [];
      t.mock.method(getMessaging(), "sendEach", async (messages) => {
        pushes.push(...messages);
        return {
          successCount: messages.length,
          failureCount: 0,
          responses: messages.map(() => ({success: true})),
        };
      });
      const owner = `owner-${randomUUID()}`;
      const other = `other-${randomUUID()}`;
      const cameraId = "camera";
      const cameraRef = db.doc(`users/${owner}/cameras/${cameraId}`);
      await db.doc(`users/${owner}`).set({firstName: "Owner"});
      await db.doc(`users/${other}`).set({firstName: "Other"});
      await cameraRef.set({
        name: "Camera",
        connectionType: "onvif",
        liveMotionEnabled: true,
        motionDetectionEnabled: true,
        aiEnabled: false,
        notificationSettings: {enabled: true, motion: true, person: true},
      });
      await db
          .doc(`users/${owner}/devices/test`)
          .set({notificationsAllowed: true, fcmToken: "owner-token"});
      await db
          .doc(`users/${other}/devices/test`)
          .set({notificationsAllowed: true, fcmToken: "other-token"});
      const call = (functionName, data = {}, uid = owner) =>
        api[functionName].run({
          auth: {uid, token: {email_verified: true}},
          data,
        });
      await assert.rejects(api.provisionXmCameraAccount.run({data: {}}), {
        code: "unauthenticated",
      });
      const account = await call("provisionXmCameraAccount");
      assert.match(account.username, /^sh_[a-f0-9]{20}$/);
      assert.equal(account.needsRegistration, true);
      const storedAccount = (
        await db.doc(`xmProviderAccounts/${owner}`).get()
      ).data();
      assert.equal(
          JSON.stringify(storedAccount).includes(account.password),
          false,
      );
      assert.equal(
          JSON.stringify(storedAccount).includes(account.username),
          false,
      );
      assert.equal(
          (await call("provisionXmCameraAccount")).password,
          account.password,
      );
      await call("confirmXmCameraAccount");
      const route = await call("createXmAlarmRoute");
      assert.deepEqual(
          await call("createXmAlarmRoute"),
          route,
          "another phone reuses the same owner route",
      );
      const routeDoc = db.doc(`xmAlarmRoutes/${route.routeId}`);
      assert.equal(
          JSON.stringify((await routeDoc.get()).data()).includes(
              route.callbackUrl,
          ),
          false,
      );
      const serialNumber = "0123456789abcdef";
      const binding = {routeId: route.routeId, cameraId, serialNumber};
      await assert.rejects(call("bindXmCamera", binding, other), {
        code: "permission-denied",
      });
      await call("bindXmCamera", binding);
      await call("confirmXmAlarmSubscription", binding);
      assert.equal(
          (await cameraRef.get()).data().xmMonitoringStatus,
          "subscribed",
          "an SDK acknowledgement is not proof of a cloud callback",
      );
      const callbackPath =
      "/" +
      new URL(route.callbackUrl).pathname.split("/").slice(-2).join("/");
      const send = async (changes = {}, path = callbackPath) => {
        const reply = {};
        const response = {
          status(status) {
            reply.status = status;
            return response;
          },
          json(body) {
            reply.body = body;
          },
        };
        await api.receiveXmCameraAlarm(
            {
              method: "POST",
              path,
              body: {
                param: JSON.stringify({
                  SerialNumber: serialNumber,
                  Channel: 0,
                  AlarmID: "alarm-one",
                  AlarmEvent: "VideoMotion:1",
                  Status: "appEventStart",
                  AlarmTime: "2025-01-01 00:00:00",
                  ...changes,
                }),
              },
            },
            response,
        );
        return reply;
      };
      assert.equal(
          (await send({}, `/${route.routeId}/${"0".repeat(64)}`)).status,
          401,
      );
      assert.equal(
          (await send({SerialNumber: "fedcba9876543210"})).status,
          403,
      );
      await assert.rejects(
          call("ingestCameraEvent", {
            cameraId,
            source: "xm-cloud",
            type: "motion",
          }),
          {code: "permission-denied"},
      );
      const before = Date.now();
      assert.equal((await send()).status, 200);
      let events = await db
          .collection("cameraEvents")
          .where("ownerId", "==", owner)
          .get();
      assert.equal(events.size, 1);
      const event = events.docs[0].data();
      assert.equal(event.source, "xm-cloud");
      assert.equal(event.type, "motion");
      assert.equal(event.ownerId, owner);
      assert.ok(
          event.occurredAt.toMillis() >= before,
          "timezone-free vendor times are not treated as UTC",
      );
      assert.equal(
          event.snapshotPath ?? null,
          null,
          "a text alarm never manufactures a photo",
      );
      assert.equal(
          event.clipPath ?? null,
          null,
          "a text alarm never manufactures a clip",
      );
      assert.equal(pushes.length, 1);
      assert.equal(pushes[0].token, "owner-token");
      assert.equal(
          (await cameraRef.get()).data().xmMonitoringStatus,
          "confirmed",
      );
      await call("bindXmCamera", binding);
      assert.equal(
          (await cameraRef.get()).data().xmMonitoringStatus,
          "confirmed",
      );
      assert.equal((await send()).status, 200);
      assert.equal(
          pushes.length,
          1,
          "provider retries do not duplicate an owner alert",
      );
      events = await db
          .collection("cameraEvents")
          .where("ownerId", "==", owner)
          .get();
      assert.equal(events.docs[0].data().occurrenceCount, 1);
      const client = env
          .authenticatedContext(owner, {email_verified: true})
          .firestore();
      await assertFails(setDoc(doc(client, `users/${owner}/cameras/forged`), {
        name: "Camera", xmMonitoringStatus: "confirmed",
      }));
      await assertFails(getDoc(doc(client, `xmProviderAccounts/${owner}`)));
      await assertFails(getDoc(doc(client, `xmAlarmRoutes/${route.routeId}`)));
      await assertFails(
          updateDoc(doc(client, cameraRef.path), {
            xmMonitoringStatus: "pending",
            updatedAt: serverTimestamp(),
          }),
      );
      await cameraRef.update({
        liveMotionEnabled: false,
        motionDetectionEnabled: false,
      });
      assert.equal((await send({AlarmID: "muted"})).body.ignored, true);
      assert.equal(pushes.length, 1);
      await assertSucceeds(updateDoc(doc(client, cameraRef.path), {
        liveMotionEnabled: true, updatedAt: serverTimestamp(),
      }));
      await call("revokeXmAlarmRoute", {routeId: route.routeId});
      assert.equal(
          (await cameraRef.get()).data().xmMonitoringStatus,
          "revoked",
      );
      assert.equal((await send({AlarmID: "after-revoke"})).status, 401);
      assert.equal(pushes.length, 1);
      const {deleteAccountData} = require("../account_deletion");
      await db.doc(`xmProviderAccounts/${other}`).set({ownerId: other});
      await deleteAccountData({db, uid: owner});
      for (const collection of [
        "xmAlarmRoutes", "xmAlarmBindings", "xmProviderAccounts",
      ]) {
        assert.equal((await db.collection(collection)
            .where("ownerId", "==", owner).get()).empty, true);
      }
      assert.equal((await db.doc(`xmProviderAccounts/${other}`).get()).exists,
          true, "deletion preserves another owner's provider account");
    },
);
