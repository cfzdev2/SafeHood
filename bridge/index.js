'use strict';

const {
  initializeApp,
  deleteApp,
} = require('firebase-admin/app');

const {
  getFirestore,
  FieldValue,
} = require('firebase-admin/firestore');

const {
  OnvifCameraSession,
  connectionFingerprint,
} = require('./onvif_camera_session');

const PROJECT_ID =
  process.env.SAFEHOOD_PROJECT_ID ||
  'safehood-security-app';

const REGION =
  process.env.SAFEHOOD_REGION ||
  'europe-central2';

const FUNCTIONS_HOST =
  process.env.SAFEHOOD_FUNCTIONS_HOST ||
  '127.0.0.1';

const FUNCTIONS_PORT =
  process.env.SAFEHOOD_FUNCTIONS_PORT ||
  '5001';

const DEV_SECRET =
  process.env.SAFEHOOD_DEV_EVENT_SECRET ||
  'safehood-local-dev';

const OWNER_ID =
  process.env.SAFEHOOD_OWNER_ID ||
  '';

const BRIDGE_ID =
  process.env.SAFEHOOD_BRIDGE_ID ||
  'bridge-dev-pc';

const INGEST_ENDPOINT =
  `http://${FUNCTIONS_HOST}:${FUNCTIONS_PORT}/` +
  `${PROJECT_ID}/${REGION}/devIngestCameraEvent`;

if (!process.env.FIRESTORE_EMULATOR_HOST) {
  console.error(
    'BRIDGE: brak FIRESTORE_EMULATOR_HOST.\n' +
    'Ten wariant Bridge działa wyłącznie z emulatorem.',
  );

  process.exit(1);
}

if (!OWNER_ID) {
  console.error(
    'BRIDGE: brak SAFEHOOD_OWNER_ID.',
  );

  process.exit(1);
}

const app = initializeApp({
  projectId: PROJECT_ID,
});

const db = getFirestore(app);

const bridgeRef = db
  .collection('users')
  .doc(OWNER_ID)
  .collection('bridges')
  .doc(BRIDGE_ID);

const sessions = new Map();

const onlineCameraIds =
  new Set();

let unsubscribe = null;
let shuttingDown = false;
let syncQueue = Promise.resolve();
let heartbeatTimer = null;

function reportBridgeStatusError(error) {
  console.error(
    `[BRIDGE] zapis statusu: ${error.message}`,
  );
}

async function saveBridgeStatus({
  status,
  started = false,
  stopped = false,
}) {
  const timestamp =
    FieldValue.serverTimestamp();

  const data = {
    bridgeId: BRIDGE_ID,
    ownerId: OWNER_ID,
    name: 'SafeHood Bridge Dev PC',
    status,
    platform: process.platform,
    version: '1.0.0',
    activeCameraCount:
  onlineCameraIds.size,
    capabilities: [
      'onvif-events',
    ],
    lastSeenAt: timestamp,
    updatedAt: timestamp,
  };

  if (started) {
    data.startedAt = timestamp;
  }

  if (stopped) {
    data.stoppedAt = timestamp;
  }

  await bridgeRef.set(
    data,
    {
      merge: true,
    },
  );
}

function startBridgeHeartbeat() {
  void saveBridgeStatus({
    status: 'online',
    started: true,
  })
    .then(
      () => {
        console.log(
          '[BRIDGE] heartbeat uruchomiony',
        );
      },
    )
    .catch(
      reportBridgeStatusError,
    );

  heartbeatTimer = setInterval(
    () => {
      void saveBridgeStatus({
        status: 'online',
      }).catch(
        reportBridgeStatusError,
      );
    },
    30000,
  );
}

function shouldMonitor(camera) {
  if (
    camera.connectionType !==
    'onvif'
  ) {
    return false;
  }

  if (
    camera.motionDetectionEnabled ===
    false
  ) {
    return false;
  }

  const monitoringMode =
    typeof camera.monitoringMode ===
    'string' ?
      camera.monitoringMode.trim() :
      '';

  if (
    monitoringMode &&
    monitoringMode !== 'bridge'
  ) {
    return false;
  }

  const assignedBridgeId =
    typeof camera.bridgeId ===
    'string' ?
      camera.bridgeId.trim() :
      '';

  if (
    assignedBridgeId &&
    assignedBridgeId !== BRIDGE_ID
  ) {
    return false;
  }

  return true;
}

async function claimCameraForBridge(
  camera,
) {
  const currentBridgeId =
    typeof camera.bridgeId ===
    'string' ?
      camera.bridgeId.trim() :
      '';

  if (
    currentBridgeId === BRIDGE_ID &&
    camera.monitoringMode === 'bridge'
  ) {
    return camera;
  }

  const cameraRef = db
    .collection('users')
    .doc(OWNER_ID)
    .collection('cameras')
    .doc(camera.id);

  const result =
    await db.runTransaction(
      async (transaction) => {
        const snapshot =
          await transaction.get(
            cameraRef,
          );

        if (!snapshot.exists) {
          return {
            camera: null,
            claimed: false,
          };
        }

        const latestCamera = {
          ...snapshot.data(),
          id: snapshot.id,
        };

        if (
          !shouldMonitor(
            latestCamera,
          )
        ) {
          return {
            camera: null,
            claimed: false,
          };
        }

        const latestBridgeId =
          typeof latestCamera
              .bridgeId ===
          'string' ?
            latestCamera
              .bridgeId
              .trim() :
            '';

        const alreadyAssigned =
          latestBridgeId ===
            BRIDGE_ID &&
          latestCamera
              .monitoringMode ===
            'bridge';

        if (!alreadyAssigned) {
          transaction.set(
            cameraRef,
            {
              bridgeId:
                BRIDGE_ID,
              monitoringMode:
                'bridge',
              bridgeAssignedAt:
                FieldValue
                    .serverTimestamp(),
              updatedAt:
                FieldValue
                    .serverTimestamp(),
            },
            {
              merge: true,
            },
          );
        }

        return {
          camera: {
            ...latestCamera,
            bridgeId:
              BRIDGE_ID,
            monitoringMode:
              'bridge',
          },
          claimed:
            !alreadyAssigned,
        };
      },
    );

  if (result.claimed) {
    console.log(
      `[BRIDGE] przypisano kamerę ` +
      `${camera.id} do ${BRIDGE_ID}`,
    );
  }

  return result.camera;
}

function isFakeCamera(camera) {
  const brand =
    typeof camera.brand === 'string' ?
      camera.brand.toLowerCase() :
      '';

  const sources =
    Array.isArray(
      camera.discoverySources,
    ) ?
      camera.discoverySources :
      [];

  return (
    brand.includes('safehood fake') ||
    sources.some(
      (source) =>
        String(source)
          .toLowerCase() ===
        'fake',
    )
  );
}

function buildFakeMediaUrls(camera) {
  if (!isFakeCamera(camera)) {
    return {};
  }

  const serviceUrl =
    typeof camera.onvifServiceUrl ===
    'string' ?
      camera.onvifServiceUrl.trim() :
      '';

  if (!serviceUrl) {
    return {};
  }

  try {
    const snapshotUrl =
      new URL(
        '/snapshot.png',
        serviceUrl,
      );

    snapshotUrl.searchParams.set(
      'event',
      String(Date.now()),
    );

    const clipUrl =
      new URL(
        '/clip.mp4',
        serviceUrl,
      );

    return {
      snapshotUrl:
        snapshotUrl.toString(),
      clipUrl:
        clipUrl.toString(),
    };
  } catch (_) {
    return {};
  }
}

async function ingestDetection(
  camera,
  detection,
) {
  const mediaUrls =
    buildFakeMediaUrls(camera);

  const payload = {
    ownerId: OWNER_ID,
    cameraId: camera.id,
    type: detection.type,
    source:
      detection.source ||
      'onvif',
    confidence:
      detection.confidence ??
      null,
    occurredAt:
      detection.occurredAt ||
      new Date().toISOString(),
    ...mediaUrls,
  };

  const response = await fetch(
    INGEST_ENDPOINT,
    {
      method: 'POST',

      headers: {
        'Content-Type':
          'application/json',
        'x-safehood-dev-secret':
          DEV_SECRET,
      },

      body:
        JSON.stringify(payload),
    },
  );

  const responseText =
    await response.text();

  let result;

  try {
    result =
      JSON.parse(responseText);
  } catch (_) {
    result = {
      raw: responseText,
    };
  }

  if (!response.ok) {
    throw new Error(
      `backend HTTP ${response.status}: ` +
      `${JSON.stringify(result)}`,
    );
  }

  console.log(
    `[BRIDGE INGEST][${camera.id}] ` +
    `id=${result.eventId ?? result.id ?? '-'}, ` +
    `type=${result.type ?? detection.type}, ` +
    `merged=${result.merged ?? false}, ` +
    `count=${result.occurrenceCount ?? 1}`,
  );
}

async function updateCameraMonitoringStatus(
  camera,
  status,
) {
  if (status === 'online') {
    onlineCameraIds.add(
      camera.id,
    );
  } else {
    onlineCameraIds.delete(
      camera.id,
    );
  }

  await Promise.all([
    db
      .collection('users')
      .doc(OWNER_ID)
      .collection('cameras')
      .doc(camera.id)
      .update({
        bridgeMonitoringStatus:
          status,
        bridgeMonitoringUpdatedAt:
          FieldValue.serverTimestamp(),
      }),

    saveBridgeStatus({
      status:
        shuttingDown ?
          'offline' :
          'online',
    }),
  ]);

  console.log(
    `[BRIDGE CAMERA][${camera.id}] ` +
    `monitoring = ${status}`,
  );

  console.log(
    '[BRIDGE] aktywnych kamer = ' +
    `${onlineCameraIds.size}`,
  );
}

async function stopSession(cameraId) {
  const entry =
    sessions.get(cameraId);

  if (!entry) {
    return;
  }

  sessions.delete(cameraId);

onlineCameraIds.delete(
  cameraId,
);

await entry.session.stop();

await saveBridgeStatus({
  status:
    shuttingDown ?
      'offline' :
      'online',
});
}

function startSession(camera) {
  const fingerprint =
    connectionFingerprint(camera);

    const session =
    new OnvifCameraSession({
      camera,
      onDetection:
        ingestDetection,
      onStatusChanged:
        updateCameraMonitoringStatus,
    });

  sessions.set(
    camera.id,
    {
      camera,
      fingerprint,
      session,
    },
  );

  session.start();
}

async function syncCameras(snapshot) {
  if (shuttingDown) {
    return;
  }

  const desired = new Map();

  for (const document of snapshot.docs) {
    const camera = {
      ...document.data(),
      id: document.id,
    };

        if (!shouldMonitor(camera)) {
      continue;
    }

    try {
      const claimedCamera =
        await claimCameraForBridge(
          camera,
        );

      if (claimedCamera) {
        desired.set(
          claimedCamera.id,
          claimedCamera,
        );
      }
    } catch (error) {
      console.error(
        `[BRIDGE] przypisanie kamery ` +
        `${camera.id}: ${error.message}`,
      );

      const existing =
        sessions.get(camera.id);

      if (existing) {
        desired.set(
          camera.id,
          existing.camera,
        );
      }
    }
  }

  for (
    const cameraId of
    [...sessions.keys()]
  ) {
    if (!desired.has(cameraId)) {
      console.log(
        `[BRIDGE] usuwam kamerę ${cameraId}`,
      );

      await stopSession(cameraId);
    }
  }

  for (
    const [cameraId, camera] of
    desired.entries()
  ) {
    const existing =
      sessions.get(cameraId);

    if (!existing) {
      console.log(
        `[BRIDGE] dodaję kamerę ${cameraId}`,
      );

      startSession(camera);

      continue;
    }

    const nextFingerprint =
      connectionFingerprint(camera);

    if (
      existing.fingerprint !==
      nextFingerprint
    ) {
      console.log(
        `[BRIDGE] zmieniono konfigurację ${cameraId} — restart`,
      );

      await stopSession(cameraId);
      startSession(camera);
    }
  }

    console.log(
    `[BRIDGE] aktywnych kamer = ${sessions.size}`,
  );

  void saveBridgeStatus({
    status: 'online',
  }).catch(
    reportBridgeStatusError,
  );
}

function queueCameraSync(snapshot) {
  syncQueue = syncQueue
    .then(
      () => syncCameras(snapshot),
    )
    .catch(
      (error) => {
        console.error(
          `[BRIDGE] synchronizacja kamer: ${error.message}`,
        );
      },
    );
}

async function shutdown(signal) {
  if (shuttingDown) {
    return;
  }

    shuttingDown = true;

  if (heartbeatTimer) {
    clearInterval(
      heartbeatTimer,
    );

    heartbeatTimer = null;
  }

  console.log(
    `\n[BRIDGE] zatrzymywanie: ${signal}`,
  );

  if (unsubscribe) {
    unsubscribe();
    unsubscribe = null;
  }

  await syncQueue;

  for (
    const cameraId of
    [...sessions.keys()]
  ) {
    await stopSession(cameraId);
  }

    try {
    await saveBridgeStatus({
      status: 'offline',
      stopped: true,
    });
  } catch (error) {
    reportBridgeStatusError(error);
  }

  await deleteApp(app);

  console.log(
    '[BRIDGE] zatrzymano',
  );

  process.exit(0);
}

function main() {
  console.log('');

  console.log(
    '════════ SAFEHOOD BRIDGE ════════',
  );

  console.log(
    `Owner:  ${OWNER_ID}`,
  );

  console.log(
    `Bridge: ${BRIDGE_ID}`,
  );

  console.log(
    `Firestore emulator: ${process.env.FIRESTORE_EMULATOR_HOST}`,
  );

  console.log(
    `Ingest: ${INGEST_ENDPOINT}`,
  );

    console.log(
    '═════════════════════════════════',
  );

  console.log('');

  startBridgeHeartbeat();

  const camerasRef = db
    .collection('users')
    .doc(OWNER_ID)
    .collection('cameras');

  unsubscribe = camerasRef.onSnapshot(
    queueCameraSync,
    (error) => {
      console.error(
        `[BRIDGE] Firestore listener: ${error.message}`,
      );
    },
  );
}

process.on(
  'SIGINT',
  () => {
    void shutdown('SIGINT');
  },
);

process.on(
  'SIGTERM',
  () => {
    void shutdown('SIGTERM');
  },
);

main();