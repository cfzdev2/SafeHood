'use strict';

const fs =
  require('fs');

const path =
  require('path');

const {
  OnvifCameraSession,
  connectionFingerprint,
} = require('./onvif_camera_session');

const CONFIG_PATH =
  path.join(
    __dirname,
    'config.json',
  );

const FUNCTIONS_HOST =
  process.env
    .SAFEHOOD_FUNCTIONS_HOST ||
  '127.0.0.1';

const FUNCTIONS_PORT =
  process.env
    .SAFEHOOD_FUNCTIONS_PORT ||
  '5001';

const CONFIG_POLL_INTERVAL_MS =
  10000;

const HEARTBEAT_INTERVAL_MS =
  30000;

function loadBridgeConfig() {
  if (!fs.existsSync(CONFIG_PATH)) {
    throw new Error(
      'Brak bridge/config.json. ' +
      'Najpierw sparuj Bridge.',
    );
  }

  const config =
    JSON.parse(
      fs.readFileSync(
        CONFIG_PATH,
        'utf8',
      ),
    );

  if (
    typeof config.projectId !==
      'string' ||
    typeof config.region !==
      'string' ||
    typeof config.bridgeId !==
      'string' ||
    typeof config.bridgeSecret !==
      'string'
  ) {
    throw new Error(
      'Nieprawidłowy bridge/config.json.',
    );
  }

  return config;
}

const bridgeConfig =
  loadBridgeConfig();

const functionsBaseUrl =
  (
    process.env
      .SAFEHOOD_FUNCTIONS_BASE_URL ||
    (
      `http://${FUNCTIONS_HOST}:` +
      `${FUNCTIONS_PORT}/` +
      `${bridgeConfig.projectId}/` +
      `${bridgeConfig.region}`
    )
  ).replace(
    /\/+$/,
    '',
  );

const sessions =
  new Map();

const cameraStatuses =
  new Map();

let shuttingDown = false;

let configurationTimer = null;
let heartbeatTimer = null;

let configurationQueue =
  Promise.resolve();

let stateQueue =
  Promise.resolve();

async function callBridgeEndpoint(
  functionName,
  body,
  timeoutMs = 15000,
) {
  const controller =
    new AbortController();

  const timeout =
    setTimeout(
      () => {
        controller.abort();
      },
      timeoutMs,
    );

  try {
    const response =
      await fetch(
        `${functionsBaseUrl}/${functionName}`,
        {
          method:
            'POST',

          headers: {
            'Content-Type':
              'application/json',

            'x-safehood-bridge-id':
              bridgeConfig.bridgeId,

            Authorization:
              `Bearer ${bridgeConfig.bridgeSecret}`,
          },

          body:
            JSON.stringify(
              body,
            ),

          signal:
            controller.signal,
        },
      );

    const responseText =
      await response.text();

    let result;

    try {
      result =
        JSON.parse(
          responseText,
        );
    } catch (_) {
      result = {
        error:
          responseText,
      };
    }

    if (!response.ok) {
      throw new Error(
        result.error ||
        `HTTP ${response.status}`,
      );
    }

    return result;
  } finally {
    clearTimeout(
      timeout,
    );
  }
}

function isFakeCamera(camera) {
  const brand =
    typeof camera.brand ===
      'string' ?
      camera.brand.toLowerCase() :
      '';

  const sources =
    Array.isArray(
      camera.discoverySources,
    ) ?
      camera.discoverySources :
      [];

  return (
    brand.includes(
      'safehood fake',
    ) ||
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

function cameraStatusPayload() {
  return [
    ...cameraStatuses.entries(),
  ].map(
    ([cameraId, status]) => {
      return {
        cameraId,
        status,
      };
    },
  );
}

function queueStateReport(
  status = 'online',
) {
  stateQueue = stateQueue
    .catch(
      () => {},
    )
    .then(
      async () => {
        if (
          shuttingDown &&
          status !== 'offline'
        ) {
          return;
        }

        const result =
          await callBridgeEndpoint(
            'reportBridgeState',
            {
              status,
              cameraStatuses:
                cameraStatusPayload(),
            },
          );

        console.log(
          '[BRIDGE API] heartbeat: ' +
          `${result.status}, ` +
          `aktywnych kamer = ` +
          `${result.activeCameraCount}`,
        );
      },
    )
    .catch(
      (error) => {
        console.error(
          '[BRIDGE API] heartbeat: ' +
          `${error.message}`,
        );
      },
    );

  return stateQueue;
}

function updateCameraMonitoringStatus(
  camera,
  status,
) {
  cameraStatuses.set(
    camera.id,
    status,
  );

  console.log(
    `[BRIDGE CAMERA][${camera.id}] ` +
    `monitoring = ${status}`,
  );

  if (!shuttingDown) {
    void queueStateReport(
      'online',
    );
  }
}

async function ingestDetection(
  camera,
  detection,
) {
  const mediaUrls =
    buildFakeMediaUrls(
      camera,
    );

  const result =
    await callBridgeEndpoint(
      'ingestBridgeCameraEvent',
      {
        cameraId:
          camera.id,

        type:
          detection.type,

        source:
          detection.source ||
          'onvif',

        confidence:
          detection.confidence ??
          null,

        occurredAt:
          detection.occurredAt ||
          new Date()
            .toISOString(),

        ...mediaUrls,
      },
      20000,
    );

  console.log(
    `[BRIDGE INGEST][${camera.id}] ` +
    `id=${result.eventId ?? result.id ?? '-'}, ` +
    `type=${result.type ?? detection.type}, ` +
    `merged=${result.merged ?? false}, ` +
    `count=${result.occurrenceCount ?? 1}`,
  );
}

async function stopSession(
  cameraId,
  {
    removeStatus = true,
  } = {},
) {
  const entry =
    sessions.get(
      cameraId,
    );

  if (!entry) {
    return;
  }

  sessions.delete(
    cameraId,
  );

  cameraStatuses.set(
    cameraId,
    'offline',
  );

  await entry.session.stop();

  if (!shuttingDown) {
    await queueStateReport(
      'online',
    );
  }

  if (removeStatus) {
    cameraStatuses.delete(
      cameraId,
    );
  }

  console.log(
    `[BRIDGE] zatrzymano kamerę ${cameraId}`,
  );
}

function startSession(camera) {
  const fingerprint =
    connectionFingerprint(
      camera,
    );

  cameraStatuses.set(
    camera.id,
    'connecting',
  );

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

  console.log(
    `[BRIDGE] dodaję kamerę ${camera.id}`,
  );

  session.start();
}

async function syncCameras(cameras) {
  if (shuttingDown) {
    return;
  }

  const desired =
    new Map();

  for (const camera of cameras) {
    if (
      !camera ||
      typeof camera.id !==
        'string'
    ) {
      continue;
    }

    desired.set(
      camera.id,
      camera,
    );
  }

  for (
    const cameraId of
    [...sessions.keys()]
  ) {
    if (!desired.has(cameraId)) {
      await stopSession(
        cameraId,
      );
    }
  }

  for (
    const [cameraId, camera] of
    desired.entries()
  ) {
    const existing =
      sessions.get(
        cameraId,
      );

    if (!existing) {
      startSession(
        camera,
      );

      continue;
    }

    const nextFingerprint =
      connectionFingerprint(
        camera,
      );

    if (
      existing.fingerprint !==
      nextFingerprint
    ) {
      console.log(
        `[BRIDGE] konfiguracja kamery ` +
        `${cameraId} zmieniona`,
      );

      await stopSession(
        cameraId,
      );

      startSession(
        camera,
      );

      continue;
    }

    existing.camera =
      camera;
  }

  console.log(
    '[BRIDGE] skonfigurowanych kamer = ' +
    `${sessions.size}`,
  );

  await queueStateReport(
    'online',
  );
}

async function fetchConfiguration() {
  const result =
    await callBridgeEndpoint(
      'getBridgeConfiguration',
      {},
    );

  if (!Array.isArray(result.cameras)) {
    throw new Error(
      'Backend zwrócił nieprawidłową ' +
      'konfigurację kamer.',
    );
  }

  console.log(
    '[BRIDGE API] pobrano konfigurację: ' +
    `${result.cameras.length} kamer`,
  );

  await syncCameras(
    result.cameras,
  );
}

function queueConfigurationSync() {
  configurationQueue =
    configurationQueue
      .then(
        () => fetchConfiguration(),
      )
      .catch(
        (error) => {
          console.error(
            '[BRIDGE API] konfiguracja: ' +
            `${error.message}`,
          );
        },
      );

  return configurationQueue;
}

async function shutdown(signal) {
  if (shuttingDown) {
    return;
  }

  shuttingDown = true;

  if (configurationTimer) {
    clearInterval(
      configurationTimer,
    );

    configurationTimer = null;
  }

  if (heartbeatTimer) {
    clearInterval(
      heartbeatTimer,
    );

    heartbeatTimer = null;
  }

  console.log(
    `\n[BRIDGE] zatrzymywanie: ${signal}`,
  );

  await configurationQueue;
  await stateQueue;

  for (
    const cameraId of
    [...sessions.keys()]
  ) {
    await stopSession(
      cameraId,
      {
        removeStatus:
          false,
      },
    );
  }

  try {
    await callBridgeEndpoint(
      'reportBridgeState',
      {
        status:
          'offline',

        cameraStatuses:
          cameraStatusPayload(),
      },
    );
  } catch (error) {
    console.error(
      '[BRIDGE API] zapis offline: ' +
      `${error.message}`,
    );
  }

  console.log(
    '[BRIDGE] zatrzymano',
  );

  process.exit(0);
}

async function main() {
  console.log('');

  console.log(
    '════════ SAFEHOOD AUTHENTICATED BRIDGE ════════',
  );

  console.log(
    `Bridge: ${bridgeConfig.bridgeId}`,
  );

  console.log(
    `Backend: ${functionsBaseUrl}`,
  );

  console.log(
    'Tryb: bezpieczne API',
  );

  console.log(
    '═══════════════════════════════════════════════',
  );

  console.log('');

  await queueConfigurationSync();

  await queueStateReport(
    'online',
  );

  configurationTimer =
    setInterval(
      () => {
        void queueConfigurationSync();
      },
      CONFIG_POLL_INTERVAL_MS,
    );

  heartbeatTimer =
    setInterval(
      () => {
        void queueStateReport(
          'online',
        );
      },
      HEARTBEAT_INTERVAL_MS,
    );
}

process.on(
  'SIGINT',
  () => {
    void shutdown(
      'SIGINT',
    );
  },
);

process.on(
  'SIGTERM',
  () => {
    void shutdown(
      'SIGTERM',
    );
  },
);

main().catch(
  (error) => {
    console.error(
      `[BRIDGE START ERROR] ${error.message}`,
    );

    process.exit(1);
  },
);