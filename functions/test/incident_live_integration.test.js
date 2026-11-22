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
