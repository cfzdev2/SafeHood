"use strict";

const assert = require("node:assert/strict");
const {readFileSync} = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const {assertFails, assertSucceeds, initializeTestEnvironment} =
  require("@firebase/rules-unit-testing");
const {doc, getDoc, setDoc, Timestamp: ClientTimestamp} =
  require("firebase/firestore");
const {initializeApp, deleteApp} = require("firebase-admin/app");
const {getFirestore, Timestamp} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");
const {createIncidentLiveHandler} = require("../incident_live");

const projectId = "demo-safehood-incident-live";
const preview = "incidents/report/live/current";
const jpeg = readFileSync(
    path.join(__dirname, "fixtures/incident_live_frame.jpg.b64"), "utf8",
).trim();

test("incident frames are visible only to participants during the share",
    async (t) => {
      const app = initializeApp({projectId}, projectId);
      t.after(() => deleteApp(app));
      const db = getFirestore(app);
      const env = await initializeTestEnvironment({projectId,
        firestore: {rules: readFileSync(
            path.join(__dirname, "../../firestore.rules"), "utf8",
        )}});
      t.after(() => env.cleanup());

      let now = Date.now();
      const reportRef = db.doc("incidents/report");
      await reportRef.set({
        reporterId: "owner", cameraId: "camera", status: "active",
        participantIds: ["owner", "neighbor"],
        expiresAt: Timestamp.fromMillis(now + 60000),
      });
      const handle = createIncidentLiveHandler({
        db, Timestamp, HttpsError, now: () => now,
      });
      const send = (uid, data) => handle({
        auth: {uid, token: {email_verified: true}},
        data: {incidentId: "report", ...data},
      });
      const ref = (uid) => doc(env.authenticatedContext(uid, {
        email_verified: true,
      }).firestore(), preview);

      assert.equal((await assertSucceeds(getDoc(ref("neighbor")))).exists(),
          false);
      await assertFails(getDoc(ref("outsider")));
      await assert.rejects(send("neighbor", {action: "start"}),
          {code: "permission-denied"});
      const {sessionId} = await send("owner", {action: "start"});
      await assert.rejects(send("owner", {action: "frame", sessionId,
        jpeg: Buffer.from([255, 216, 1, 2, 255, 217]).toString("base64"),
      }), {code: "invalid-argument"});
      const frame = {action: "frame", sessionId, jpeg};
      assert.equal((await send("owner", frame)).accepted, true);
      assert.equal((await send("owner", frame)).accepted, false);
      const snapshot = await assertSucceeds(getDoc(ref("neighbor")));
      assert.equal(snapshot.data().jpeg.toBase64(), jpeg);
      assert.ok(snapshot.data().leaseUntil instanceof ClientTimestamp);
      await assertFails(getDoc(ref("outsider")));
      await assertFails(setDoc(ref("neighbor"), {sessionId, jpeg}));

      await reportRef.update({participantIds: ["owner"]});
      await assertFails(getDoc(ref("neighbor")));
      await reportRef.update({participantIds: ["owner", "neighbor"]});
      await db.doc(preview).update({
        leaseUntil: Timestamp.fromMillis(Math.min(now, Date.now()) - 1000),
      });
      await assertFails(getDoc(ref("neighbor")));
      await assert.rejects(send("owner", frame), {code: "failed-precondition"});

      now += 1000;
      const fresh = await send("owner", {action: "start"});
      await send("owner", {action: "stop", sessionId});
      await send("owner", {...frame, sessionId: fresh.sessionId});
      assert.equal((await getDoc(ref("neighbor"))).data().jpeg.toBase64(),
          jpeg);
      await send("owner", {action: "stop", sessionId: fresh.sessionId});
      assert.equal((await getDoc(ref("neighbor"))).exists(), false);
      const lateFrame = {...frame, sessionId: fresh.sessionId};
      await assert.rejects(send("owner", lateFrame),
          {code: "failed-precondition"});
      await reportRef.update({status: "resolved"});
      await assertFails(getDoc(ref("neighbor")));
      await assert.rejects(send("owner", {action: "start"}),
          {code: "failed-precondition"});
    });

test("the receiver shares only an authorized report after the owner leaves",
    async (t) => {
      const app = initializeApp({projectId}, "independent-live");
      const db = getFirestore(app);
      t.after(() => deleteApp(app));
      const env = await initializeTestEnvironment({projectId,
        firestore: {rules: readFileSync(
            path.join(__dirname, "../../firestore.rules"), "utf8",
        )}});
      t.after(() => env.cleanup());
      const {createBridgeIncidentLiveApi} = require("../bridge_incident_live");
      let now = Date.now();
      const report = db.doc("incidents/bridge-report");
      const camera = db.doc("users/bridge-owner/cameras/live-camera");
      await Promise.all([
        report.set({reporterId: "bridge-owner", cameraId: "live-camera",
          status: "active", participantIds: ["bridge-owner", "neighbor"],
          expiresAt: Timestamp.fromMillis(now + 30 * 60 * 1000)}),
        camera.set({bridgeId: "receiver", monitoringMode: "bridge",
          motionDetectionEnabled: true, bridgeMonitoringStatus: "online",
          bridgeMonitoringUpdatedAt: Timestamp.fromMillis(now)}),
        db.doc("users/bridge-owner/bridges/receiver").set({status: "online",
          lastSeenAt: Timestamp.fromMillis(now)}),
        db.doc("bridgeCredentials/receiver").set({ownerId: "bridge-owner",
          status: "active"}),
      ]);
      const handle = createIncidentLiveHandler({
        db, Timestamp, HttpsError, now: () => now,
      });
      const control = (data) => handle({
        auth: {uid: "bridge-owner", token: {email_verified: true}},
        data: {incidentId: "bridge-report", ...data},
      });
      const api = createBridgeIncidentLiveApi({db, Timestamp, now: () => now,
        authenticate: async (request) => request.identity});
      const identity = {ownerId: "bridge-owner", bridgeId: "receiver"};
      const send = async (handler, body = {}, who = identity) => {
        const reply = {};
        const response = {status: (status) => {
          reply.status = status; return response;
        }, json: (body) => {
          reply.body = body;
        }};
        await handler({method: "POST", body, identity: who}, response);
        return reply;
      };
      const session = await control({action: "start"});
      assert.equal(session.publisher, "bridge");
      assert.equal(session.expiresAtMillis, now + 10 * 60 * 1000);
      const list = await send(api.list);
      assert.equal(list.body.sessions[0].sessionId, session.sessionId);
      assert.equal(JSON.stringify(list.body).includes("rtsp"), false);
      const foreign = await send(api.list, {}, {ownerId: "another",
        bridgeId: "receiver"});
      assert.deepEqual(foreign.body.sessions, []);
      const frame = {incidentId: "bridge-report", sessionId: session.sessionId,
        jpegBase64: jpeg, capturedAtMillis: now};
      assert.equal((await send(api.publish, frame, {ownerId: "bridge-owner",
        bridgeId: "another"})).status, 403);
      assert.equal((await send(api.publish, frame, null)).status, 401);
      assert.equal((await send(api.publish, {...frame,
        capturedAtMillis: now - 9000})).status, 400);
      assert.equal((await send(api.publish, frame)).body.accepted, true);
      assert.equal((await send(api.publish, frame)).body.accepted, false);
      await assert.rejects(control({action: "frame",
        sessionId: session.sessionId, jpeg}), {code: "failed-precondition"});
      const neighbor = env.authenticatedContext("neighbor", {
        email_verified: true,
      }).firestore();
      const liveRef = doc(neighbor, "incidents/bridge-report/live/current");
      assert.equal((await assertSucceeds(getDoc(liveRef)))
          .data().jpeg.toBase64(), jpeg);
      await assertFails(getDoc(doc(neighbor,
          `incidentLiveGrants/${session.sessionId}`)));
      // No owner-phone calls are needed while publishing continues.
      now += 15000;
      assert.equal((await send(api.publish, {...frame, capturedAtMillis: now}))
          .body.accepted, true);
      assert.equal((await control({action: "status"})).sessionId,
          session.sessionId);
      await control({action: "stop", sessionId: session.sessionId});
      assert.equal((await send(api.publish, {...frame, capturedAtMillis: now}))
          .status, 403);
      assert.equal((await control({action: "status"})).sessionId, null);
      const renewed = await control({action: "start"});
      now = renewed.expiresAtMillis + 1;
      assert.equal((await send(api.publish, {...frame,
        sessionId: renewed.sessionId, capturedAtMillis: now})).status, 403);
      assert.deepEqual((await send(api.list)).body.sessions, []);
      await db.doc("incidents/bridge-report/live/current").update({
        leaseUntil: Timestamp.fromMillis(Date.now() - 1000),
      });
      await assertFails(getDoc(liveRef));
    });

test("only the assigned receiver can change the address of the same device",
    async (t) => {
      const app = initializeApp({projectId}, "endpoint-recovery");
      const db = getFirestore(app);
      t.after(() => deleteApp(app));
      const {createCameraEndpointRecoveryHandler} =
        require("../camera_endpoint_recovery");
      const id = "12345678-1234-1234-1234-123456789abc";
      const camera = db.doc("users/recovery-owner/cameras/robot");
      await camera.set({onvifDeviceId: `urn:uuid:${id}`,
        ipAddress: "192.168.1.9", bridgeId: "receiver",
        monitoringMode: "bridge", connectionType: "onvif"});
      const handler = createCameraEndpointRecoveryHandler({db, Timestamp,
        authenticate: async (request) => request.identity});
      const send = async (data = {}, bridgeId = "receiver") => {
        const reply = {};
        const response = {status: (status) => {
          reply.status = status; return response;
        }, json: (body) => {
          reply.body = body;
        }};
        await handler({method: "POST", identity: {ownerId: "recovery-owner",
          bridgeId}, body: {cameraId: "robot", onvifDeviceId: id,
          previousIpAddress: "192.168.1.9",
          onvifServiceUrl: "http://192.168.1.12:8899/onvif/device_service",
          ...data}}, response);
        return reply;
      };
      assert.equal((await send({}, "foreign-receiver")).status, 409);
      assert.equal((await send({onvifDeviceId:
        "aaaaaaaa-1234-1234-1234-123456789abc"})).status, 409);
      assert.equal((await send({onvifServiceUrl:
        "https://outside.example/onvif"})).status, 400);
      assert.equal((await send()).status, 200);
      assert.equal((await camera.get()).data().ipAddress, "192.168.1.12");
      // A delayed old discovery cannot replace a newer saved address.
      assert.equal((await send()).status, 409);
    });
