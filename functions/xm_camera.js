"use strict";

const {
  createHash,
  createHmac,
  randomBytes,
  timingSafeEqual,
  createCipheriv,
  createDecipheriv,
} = require("node:crypto");

const hash = (value) => createHash("sha256").update(value).digest("hex");
const serialPattern = /^[a-zA-Z0-9_-]{8,64}$/;
const routePattern = /^[a-f0-9]{32}$/;

/**
 * Parse documented camera alarms, ignoring media URLs and owner IDs.
 * @param {Object} body Form body.
 * @return {Object} Validated alarm.
 */
function parseXmAlarm(body) {
  if (
    !body ||
    typeof body.param !== "string" ||
    Buffer.byteLength(body.param) > 16384
  ) {
    throw new TypeError("invalid-alarm");
  }
  const data = JSON.parse(body.param);
  if (
    !data ||
    typeof data !== "object" ||
    Array.isArray(data) ||
    typeof data.SerialNumber !== "string" ||
    !serialPattern.test(data.SerialNumber) ||
    !["string", "number"].includes(typeof data.AlarmID) ||
    String(data.AlarmID).length < 1 ||
    String(data.AlarmID).length > 128 ||
    !Number.isInteger(data.Channel) ||
    data.Channel !== 0 ||
    typeof data.AlarmEvent !== "string" ||
    data.AlarmEvent.length > 100
  ) {
    throw new TypeError("invalid-alarm");
  }
  const event = data.AlarmEvent.split(":")[0].toLowerCase();
  const type = {
    motiondetect: "motion",
    motion_detection: "motion",
    videomotion: "motion",
    appeventhumandetectalarm: "person",
  }[event];
  const started = ["start", "appeventstart"].includes(
    typeof data.Status === "string" ? data.Status.toLowerCase() : "",
  );
  return {
    serial: data.SerialNumber.toLowerCase(),
    // Some firmware reuses a counter after reboot or across alarm classes.
    // The timezone-free time is an opaque deduplication value, not UTC.
    externalEventId: hash(JSON.stringify([
      String(data.AlarmID), event, data.Channel,
      typeof data.AlarmTime === "string" ? data.AlarmTime : null,
    ])),
    type: started ? type : null,
  };
}

/**
 * Owner-bound FunSDK routes; a device serial number is not authentication.
 * @param {Object} dependencies Firestore and event pipeline.
 * @return {Object} Account, subscription and callback handlers.
 */
function createXmCameraApi({
  db,
  Timestamp,
  HttpsError,
  ingest,
  runOnce,
  callbackBaseUrl = () => process.env.SAFEHOOD_XM_CALLBACK_BASE_URL,
  accountKey = () => process.env.SAFEHOOD_XM_ACCOUNT_KEY,
  now = Date.now,
}) {
  const routes = db.collection("xmAlarmRoutes");
  const bindings = db.collection("xmAlarmBindings");
  const identity = (request) => {
    if (!request.auth?.uid || request.auth.token?.email_verified !== true) {
      throw new HttpsError(
          "unauthenticated",
          "Zaloguj się i potwierdź e-mail.",
      );
    }
    return request.auth.uid;
  };
  const key = (input) => {
    if (
      typeof input !== "string" ||
      !input ||
      input.length > 150 ||
      input.includes("/") ||
      [".", ".."].includes(input)
    ) {
      throw new HttpsError("invalid-argument", "Nieprawidłowe dane kamery.");
    }
    return input;
  };
  const bindingRef = (routeId, serial) =>
    bindings.doc(hash(`${routeId}:${serial}`));
  const cameraRef = (owner, camera) =>
    db.collection("users").doc(owner).collection("cameras").doc(camera);
  const ownerActive = async (owner) => {
    const snapshot = await db.collection("users").doc(owner).get();
    if (!snapshot.exists || snapshot.data().deletionPending) {
      throw new HttpsError("failed-precondition", "Konto nie jest aktywne.");
    }
  };

  const provisionAccount = async (request) => {
    const ownerId = identity(request);
    await ownerActive(ownerId);
    const secret = accountKey();
    if (!/^[a-f0-9]{64}$/i.test(secret || "")) {
      throw new HttpsError(
          "failed-precondition",
          "Usługa kamery nie jest jeszcze skonfigurowana.",
      );
    }
    const reference = db.collection("xmProviderAccounts").doc(ownerId);
    return db.runTransaction(async (transaction) => {
      const previous = (await transaction.get(reference)).data();
      if (previous) {
        try {
          const cipher = createDecipheriv(
              "aes-256-gcm",
              Buffer.from(secret, "hex"),
              Buffer.from(previous.iv, "hex"),
          );
          cipher.setAAD(Buffer.from(ownerId));
          cipher.setAuthTag(Buffer.from(previous.tag, "hex"));
          const data = JSON.parse(
              Buffer.concat([
                cipher.update(Buffer.from(previous.encrypted, "hex")),
                cipher.final(),
              ]).toString("utf8"),
          );
          return {...data, needsRegistration: previous.registered !== true};
        } catch (_) {
          throw new HttpsError(
              "failed-precondition",
              "Nie można odczytać połączenia z usługą kamery.",
          );
        }
      }
      const data = {
        username: `sh_${randomBytes(10).toString("hex")}`,
        password: randomBytes(12).toString("hex"),
      };
      const iv = randomBytes(12);
      const cipher = createCipheriv(
          "aes-256-gcm",
          Buffer.from(secret, "hex"),
          iv,
      );
      cipher.setAAD(Buffer.from(ownerId));
      const encrypted = Buffer.concat([
        cipher.update(JSON.stringify(data), "utf8"),
        cipher.final(),
      ]);
      transaction.set(reference, {
        ownerId,
        iv: iv.toString("hex"),
        encrypted: encrypted.toString("hex"),
        tag: cipher.getAuthTag().toString("hex"),
        registered: false,
        createdAt: Timestamp.fromMillis(now()),
      });
      return {...data, needsRegistration: true};
    });
  };

  const accountLinked = async (request) => {
    const ownerId = identity(request);
    await ownerActive(ownerId);
    const reference = db.collection("xmProviderAccounts").doc(ownerId);
    if (!(await reference.get()).exists) {
      throw new HttpsError("not-found", "Brak połączenia.");
    }
    await reference.update({registered: true});
    return {ok: true};
  };

  const createRoute = async (request) => {
    const ownerId = identity(request);
    await ownerActive(ownerId);
    const base = callbackBaseUrl();
    let url;
    try {
      url = new URL(base);
    } catch (_) {
      /* Configuration is server-owned. */
    }
    const loopback =
      process.env.FUNCTIONS_EMULATOR === "true" &&
      url?.protocol === "http:" &&
      ["127.0.0.1", "localhost"].includes(url.hostname);
    if (
      !url ||
      (!loopback && url.protocol !== "https:") ||
      url.search ||
      url.hash ||
      url.username ||
      url.password
    ) {
      throw new HttpsError(
          "failed-precondition",
          "Integracja kamery nie jest uruchomiona na serwerze SafeHood.",
      );
    }
    const key = accountKey();
    if (!/^[a-f0-9]{64}$/i.test(key || "")) {
      throw new HttpsError(
          "failed-precondition",
          "Usługa kamery nie jest skonfigurowana.",
      );
    }
    const account = db.collection("xmProviderAccounts").doc(ownerId);
    return db.runTransaction(async (transaction) => {
      const saved = (await transaction.get(account)).data();
      if (!saved?.registered) {
        throw new HttpsError("failed-precondition", "Połącz usługę kamery.");
      }
      let routeId = saved.routeId;
      let existing;
      if (routePattern.test(routeId || "")) {
        existing = (await transaction.get(routes.doc(routeId))).data();
      }
      const reuse =
        existing?.ownerId === ownerId &&
        existing.state !== "revoked" &&
        (existing.state === "active" ||
          existing.pendingUntil?.toMillis() > now());
      if (!reuse) routeId = randomBytes(16).toString("hex");
      const secret = createHmac("sha256", Buffer.from(key, "hex"))
          .update(`xm-route:${ownerId}:${routeId}`)
          .digest("hex");
      if (!reuse) {
        transaction.set(routes.doc(routeId), {
          ownerId,
          secretHash: hash(secret),
          state: "pending",
          createdAt: Timestamp.fromMillis(now()),
          pendingUntil: Timestamp.fromMillis(now() + 15 * 60 * 1000),
        });
        transaction.update(account, {routeId});
      }
      return {
        routeId,
        callbackUrl: [url.toString().replace(/\/$/, ""), routeId, secret]
            .join("/"),
      };
    });
  };

  const bind = async (request) => {
    const ownerId = identity(request);
    const {routeId, serialNumber} = request.data || {};
    const cameraId = key(request.data?.cameraId);
    if (
      !routePattern.test(routeId || "") ||
      typeof serialNumber !== "string" ||
      !serialPattern.test(serialNumber)
    ) {
      throw new HttpsError(
          "invalid-argument",
          "Nieprawidłowe dane połączenia.",
      );
    }
    const serial = serialNumber.toLowerCase();
    await ownerActive(ownerId);
    await db.runTransaction(async (transaction) => {
      const route = (await transaction.get(routes.doc(routeId))).data();
      const camera = (
        await transaction.get(cameraRef(ownerId, cameraId))
      ).data();
      const previous = (
        await transaction.get(bindingRef(routeId, serial))
      ).data();
      if (
        !route ||
        route.ownerId !== ownerId ||
        route.state === "revoked" ||
        (route.state === "pending" && route.pendingUntil?.toMillis() <= now())
      ) {
        throw new HttpsError("permission-denied", "Połączenie wygasło.");
      }
      if (
        !camera ||
        camera.deletionPending ||
        !["onvif", "rtsp"].includes(camera.connectionType) ||
        (previous && previous.cameraId !== cameraId)
      ) {
        throw new HttpsError(
            "failed-precondition",
            "Nie można powiązać kamery.",
        );
      }
      transaction.set(bindingRef(routeId, serial), {
        ownerId,
        cameraId,
        routeId,
        serial,
        createdAt: Timestamp.fromMillis(now()),
      });
      transaction.update(routes.doc(routeId), {state: "active"});
      if (
        camera.xmAlarmRouteId !== routeId ||
        camera.xmSerialNumber !== serial ||
        camera.xmMonitoringStatus !== "confirmed"
      ) {
        transaction.update(cameraRef(ownerId, cameraId), {
          xmAlarmRouteId: routeId,
          xmSerialNumber: serial,
          xmMonitoringStatus: "pending",
          xmMonitoringConfirmedAt: null,
        });
      }
    });
    return {ok: true};
  };

  const subscribed = async (request) => {
    const ownerId = identity(request);
    const routeId = request.data?.routeId;
    const cameraId = key(request.data?.cameraId);
    if (!routePattern.test(routeId || "")) {
      throw new HttpsError("invalid-argument", "Brak połączenia.");
    }
    await db.runTransaction(async (transaction) => {
      const camera = (
        await transaction.get(cameraRef(ownerId, cameraId))
      ).data();
      const route = (await transaction.get(routes.doc(routeId))).data();
      if (
        !route ||
        route.ownerId !== ownerId ||
        route.state !== "active" ||
        !camera ||
        camera.deletionPending ||
        camera.xmAlarmRouteId !== routeId
      ) {
        throw new HttpsError(
            "permission-denied",
            "Połączenie jest nieaktywne.",
        );
      }
      if (camera.xmMonitoringStatus !== "confirmed") {
        transaction.update(cameraRef(ownerId, cameraId), {
          xmMonitoringStatus: "subscribed",
        });
      }
    });
    return {ok: true};
  };

  const revoke = async (request) => {
    const ownerId = identity(request);
    const routeId = request.data?.routeId;
    if (!routePattern.test(routeId || "")) {
      throw new HttpsError("invalid-argument", "Brak połączenia.");
    }
    await db.runTransaction(async (transaction) => {
      const route = (await transaction.get(routes.doc(routeId))).data();
      if (!route || route.ownerId !== ownerId) {
        throw new HttpsError("permission-denied", "Brak dostępu.");
      }
      transaction.update(routes.doc(routeId), {
        state: "revoked",
        secretHash: "",
      });
    });
    const linked = await bindings.where("routeId", "==", routeId).get();
    for (const entry of linked.docs) {
      const camera = cameraRef(ownerId, entry.data().cameraId);
      await db.runTransaction(async (transaction) => {
        const data = (await transaction.get(camera)).data();
        if (data?.xmAlarmRouteId === routeId) {
          transaction.update(camera, {xmMonitoringStatus: "revoked"});
        }
      });
    }
    return {ok: true};
  };

  const receive = async (request, response) => {
    if (request.method !== "POST") {
      return response.status(405).json({ok: false});
    }
    const parts = (request.path || "").split("/").filter(Boolean);
    if (
      parts.length !== 2 ||
      !routePattern.test(parts[0]) ||
      !/^[a-f0-9]{64}$/.test(parts[1])
    ) {
      return response.status(401).json({ok: false});
    }
    try {
      const routeId = parts[0];
      const route = (await routes.doc(routeId).get()).data();
      const received = hash(parts[1]);
      if (
        !route ||
        route.state !== "active" ||
        !/^[a-f0-9]{64}$/.test(route.secretHash || "") ||
        !timingSafeEqual(
            Buffer.from(received, "hex"),
            Buffer.from(route.secretHash, "hex"),
        )
      ) {
        return response.status(401).json({ok: false});
      }
      const alarm = parseXmAlarm(request.body);
      if (!alarm.type) {
        return response.status(200).json({ok: true, ignored: true});
      }
      const binding = (await bindingRef(routeId, alarm.serial).get()).data();
      if (!binding || binding.ownerId !== route.ownerId) {
        return response.status(403).json({ok: false});
      }
      await ownerActive(binding.ownerId);
      const reference = cameraRef(binding.ownerId, binding.cameraId);
      const camera = (await reference.get()).data();
      if (
        !camera ||
        camera.deletionPending ||
        camera.xmAlarmRouteId !== routeId ||
        camera.xmSerialNumber !== alarm.serial
      ) {
        return response.status(403).json({ok: false});
      }
      if (
        camera.motionDetectionEnabled !== true &&
        camera.liveMotionEnabled !== true
      ) {
        return response.status(200).json({ok: true, ignored: true});
      }
      await runOnce({
        db,
        Timestamp,
        HttpsError,
        provider: "xm-cloud",
        cloudDeviceId: hash(`${binding.ownerId}:${binding.cameraId}`),
        externalEventId: alarm.externalEventId,
        handler: async () => {
          const event = await ingest({
            ownerId: binding.ownerId,
            cameraId: binding.cameraId,
            type: alarm.type,
            source: "xm-cloud",
            fromXmCloud: true,
            xmRouteId: routeId,
            xmSerial: alarm.serial,
            // The vendor's timezone-free AlarmTime is not an ISO UTC timestamp.
            occurredAt: new Date(now()).toISOString(),
          });
          return {...event, cameraId: binding.cameraId};
        },
      });
      // An SDK ACK alone does not confirm the cloud callback path.
      await db.runTransaction(async (transaction) => {
        const latestRoute = (
          await transaction.get(routes.doc(routeId))
        ).data();
        const latest = (await transaction.get(reference)).data();
        if (
          latestRoute?.state === "active" &&
          latest?.xmAlarmRouteId === routeId &&
          latest.xmSerialNumber === alarm.serial &&
          !latest.deletionPending
        ) {
          transaction.update(reference, {
            xmMonitoringStatus: "confirmed",
            monitoringMode: "cloud",
            xmMonitoringConfirmedAt: Timestamp.fromMillis(now()),
          });
        }
      });
      return response.status(200).json({ok: true});
    } catch (error) {
      const code = error?.code;
      const status =
        error instanceof SyntaxError || error instanceof TypeError ?
          400 :
          [
            "permission-denied",
            "not-found",
            "failed-precondition",
          ].includes(code) ?
            403 :
            503;
      // Never log request paths: the scoped callback token is part of the URL.
      return response.status(status).json({ok: false});
    }
  };
  return {
    provisionAccount,
    accountLinked,
    createRoute,
    bind,
    subscribed,
    revoke,
    receive,
  };
}

module.exports = {createXmCameraApi, parseXmAlarm};
