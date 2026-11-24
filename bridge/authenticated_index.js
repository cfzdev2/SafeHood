'use strict';

const fs =
  require('fs');

const path =
  require('path');

const {createHash} = require('node:crypto');
const {CameraEndpointRecovery} = require('./camera_endpoint_recovery');
const endpointRecovery = new CameraEndpointRecovery();

const {
  OnvifCameraSession,
  connectionFingerprint,
} = require('./onvif_camera_session');

const {
  requireSecureEndpoint,
} = require('./secure_endpoint');

const {
  CameraAiSession,
} = require('./ai/camera_ai_session');

const {
  AiInferenceScheduler,
} = require('./ai/inference_scheduler');

const {
  YoloxDetector,
  modelIdentifier,
} = require('./ai/yolox_detector');

const {createAiEventMetadata} = require('./ai/event_metadata');

const {
  resolveOnvifStreamUri,
} = require('./onvif_stream_resolver');

const {
  captureJpegSnapshot,
} = require(
  './ai/ffmpeg_snapshot_capture',
);

const {SnapshotUploadQueue} = require('./ai/snapshot_upload_queue');
const {AiEventOutbox} = require('./ai/event_outbox');
const {ClipUploadQueue} = require('./ai/clip_upload_queue');
const {EventRecordingManager} = require('./ai/event_recording_manager');
const {buildBridgeDiagnostics} = require('./ai/bridge_diagnostics');
const {BackgroundMotionSession} = require('./background_motion_session');
const {CameraFrameCache} = require('./camera_frame_cache');
const {DurableSnapshotQueue, CameraEvidencePipeline} = require('./camera_evidence_pipeline');
const {IncidentLivePublisher} = require('./incident_live_publisher');

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

const AI_DIAGNOSTICS_ENABLED =
  process.env.SAFEHOOD_AI_DEBUG === 'true';

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

requireSecureEndpoint(
  functionsBaseUrl,
  'Bazowy adres Firebase Functions',
);

const sessions =
  new Map();

const aiSessions =
  new Map();

let desiredAiSessionCount = 0;

let desiredAiSessionsFingerprint =
  null;

let desiredAiSessionsStartedAtMillis =
  null;

let aiScheduler = null;

let aiInitializationPromise =
  null;

const cameraStatuses =
  new Map();

const snapshotQueue = new SnapshotUploadQueue({
  captureSnapshot: ({input, attempt, signal}) => captureJpegSnapshot({
    input,
    // Przy ponowieniu uwzględniamy dłuższy odstęp klatek kluczowych.
    timeoutMs: attempt === 1 ? 10000 : 30000,
    signal,
  }),
  uploadSnapshot: ({cameraId, eventId, snapshot, signal}) => callBridgeEndpoint(
    'uploadBridgeCameraEventSnapshot',
    {cameraId, eventId, jpegBase64: snapshot.toString('base64')},
    30000,
    signal,
  ),
  onSaved: ({cameraId, eventId, attempt, result, size}) => {
    console.log(
      `[BRIDGE AI SNAPSHOT][${cameraId}] event=${eventId}, ` +
      `bytes=${result.size ?? size}, attempt=${attempt}`,
    );
  },
  onError: ({cameraId, eventId, attempt, maximumAttempts, error, willRetry, retryInMs}) => {
    console.error(
      `[BRIDGE AI SNAPSHOT][${cameraId}] event=${eventId}, ` +
      `próba=${attempt}/${maximumAttempts}: ${safeAiErrorMessage(error)} ` +
      (willRetry ? `Ponowienie za ${retryInMs} ms.` : 'Zakończono próby.'),
    );
  },
});

const eventOutbox = new AiEventOutbox({
  directory: path.join(__dirname, 'data', 'ai-events', createHash('sha256')
    .update(JSON.stringify([bridgeConfig.projectId, bridgeConfig.region,
      bridgeConfig.bridgeId, functionsBaseUrl])).digest('hex')),
  deliver: (payload, signal) => callBridgeEndpoint('ingestBridgeCameraEvent', payload, 20000, signal),
  onRestored: (count) => {
    if (count > 0 || AI_DIAGNOSTICS_ENABLED) {
      console.log(`[BRIDGE AI OUTBOX] odtworzono zdarzeń = ${count}`);
    }
  },
  onDelivered: ({payload, result, attempts}) => {
    console.log(`[BRIDGE INGEST][${payload.cameraId}] id=${result.eventId}, ` +
      `type=${result.type}, merged=${result.merged}, count=${result.occurrenceCount}, ` +
      `externalEventId=${payload.externalEventId}, duplicate=${result.duplicate}, attempt=${attempts}`);
  },
  onError: ({phase, payload, error, willRetry, retryInMs}) => {
    console.error(`[BRIDGE AI OUTBOX] ${payload?.externalEventId ?? phase}: ` +
      `${safeAiErrorMessage(error)} ` + (willRetry ? `Ponowienie za ${retryInMs ?? '-'} ms.` :
        'Plik zachowano do sprawdzenia; nie będzie automatycznie wysyłany.'));
  },
});

const recordingDirectory = path.join(__dirname, 'data', 'ai-clips', createHash('sha256')
  .update(JSON.stringify([bridgeConfig.projectId, bridgeConfig.region,
    bridgeConfig.bridgeId, functionsBaseUrl])).digest('hex'));

const clipQueue = new ClipUploadQueue({
  directory: path.join(recordingDirectory, 'uploads'),
  upload: (payload, signal) => callBridgeEndpoint('uploadBridgeCameraEventClip', payload, 60000, signal),
  onRestored: (count) => {
    if (count || AI_DIAGNOSTICS_ENABLED) console.log(`[BRIDGE AI CLIP] odtworzono nagrań = ${count}`);
  },
  onSaved: ({cameraId, result, attempts}) => {
    console.log(`[BRIDGE AI CLIP][${cameraId}] event=${result.eventId}, bytes=${result.size}, ` +
      `durationMs=${result.durationMillis}, prebufferMs=${result.prebufferMillis}, attempt=${attempts}`);
  },
  onError: ({payload, error, willRetry, retryInMs}) => {
    console.error(`[BRIDGE AI CLIP][${payload?.cameraId ?? '-'}] ${safeAiErrorMessage(error)} ` +
      (willRetry ? `Ponowienie za ${retryInMs ?? '-'} ms.` : 'Zakończono wysyłkę tego zadania.'));
  },
});

const frameCache = new CameraFrameCache();
const recordingManager = new EventRecordingManager({directory: recordingDirectory, uploadQueue: clipQueue,
  onSample: (id, frame) => frameCache.sample(id, frame),
  onSnapshot: (id, jpeg) => frameCache.snapshot(id, jpeg),
  onPreview: (id, jpeg) => frameCache.preview(id, jpeg),
  onSourceExit: (id) => frameCache.lost(id),
  onStatus: ({cameraId, status}) => console.log(`[BRIDGE AI BUFFER][${cameraId}] status=${status}`),
  onError: ({cameraId, error}) => console.error(`[BRIDGE AI BUFFER][${cameraId}] ${safeAiErrorMessage(error)}`),
});

const evidenceSnapshots = new DurableSnapshotQueue({
  directory: path.join(recordingDirectory, 'snapshots'),
  upload: (payload, signal) => callBridgeEndpoint('uploadBridgeCameraEventSnapshot', payload, 30000, signal),
  onError: ({payload, error}) => console.error(
    `[BRIDGE SNAPSHOT][${payload?.cameraId ?? '-'}] ${safeAiErrorMessage(error)}`),
});
const evidencePipeline = new CameraEvidencePipeline({eventOutbox, frameCache,
  snapshotQueue: evidenceSnapshots, recordingManager,
  onError: ({cameraId, error}) => console.error(`[BRIDGE MEDIA][${cameraId}] ${safeAiErrorMessage(error)}`),
});
const incidentLive = new IncidentLivePublisher({frameCache,
  publish: (payload, signal) => callBridgeEndpoint('publishBridgeIncidentLive', payload, 8000, signal),
});

let shuttingDown = false;

let configurationTimer = null;
let heartbeatTimer = null;

let configurationQueue =
  Promise.resolve();

let stateQueue =
  Promise.resolve();

function trackerOptionsForSensitivity(
  sensitivity,
) {
  switch (sensitivity) {
    case 'low':
      return {
        highScoreThreshold: 0.65,
        lowScoreThreshold: 0.25,
        minimumConfirmedFrames: 4,
      };

    case 'high':
      return {
        highScoreThreshold: 0.4,
        lowScoreThreshold: 0.1,
        minimumConfirmedFrames: 2,
      };

    case 'standard':
    default:
      return {
        highScoreThreshold: 0.5,
        lowScoreThreshold: 0.15,
        minimumConfirmedFrames: 3,
      };
  }
}

async function getAiScheduler() {
  if (aiScheduler) {
    return aiScheduler;
  }

  if (!aiInitializationPromise) {
    aiInitializationPromise =
      (async () => {
        console.log(
          '[BRIDGE AI] ładuję model YOLOX...',
        );

        const detector =
          new YoloxDetector();

        await detector.initialize();

        const scheduler =
          new AiInferenceScheduler({
            detector,
          });

        aiScheduler =
          scheduler;

        console.log(
          '[BRIDGE AI] model YOLOX gotowy',
        );

        return scheduler;
      })();
  }

  try {
    return await aiInitializationPromise;
  } catch (error) {
    aiInitializationPromise = null;
    aiScheduler = null;

    throw error;
  }
}

async function callBridgeEndpoint(
  functionName,
  body,
  timeoutMs = 15000,
  signal,
) {
  const controller =
    new AbortController();

  const onAbort = () => controller.abort();
  signal?.addEventListener('abort', onAbort, {once: true});
  if (signal?.aborted) controller.abort();

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
      const error = new Error(
        result.error ||
        `HTTP ${response.status}`,
      );
      error.statusCode = response.status;
      if (result.retryable === false) error.retryable = false;
      throw error;
    }

    return result;
  } finally {
    signal?.removeEventListener('abort', onAbort);
    clearTimeout(
      timeout,
    );
  }
}

const cameraHealth = new Map();

function cameraStatusPayload() {
  return [
    ...cameraStatuses.entries(),
  ].map(
    ([cameraId, status]) => {
      return {
        cameraId,
        status,
        ...(cameraHealth.get(cameraId) || {}),
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
              ...(status === 'online' ? {
                diagnostics:
                  buildBridgeDiagnostics({
                    sessions: aiSessions,
                    expectedSessions:
                      desiredAiSessionCount,
                    expectedSessionsStartedAtMillis:
                      desiredAiSessionsStartedAtMillis,
                    scheduler: aiScheduler,
                    eventOutbox,
                    snapshotQueue: {pendingCount:
                      snapshotQueue.pendingCount + evidenceSnapshots.pendingCount},
                    clipQueue,
                    recordingManager,
                  }),
              } : {}),
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
  signal,
) {
  signal?.throwIfAborted();
  return evidencePipeline.ingest(camera, detection);
}

function aiSessionFingerprint(camera) {
  return JSON.stringify({
    connection:
      connectionFingerprint(camera),

    person:
      camera.aiPersonEnabled === true,

    vehicle:
      camera.aiVehicleEnabled === true,

    sensitivity:
      camera.aiSensitivity || 'standard',

    detectionZones:
      camera.aiDetectionZones || [],

    ignoreZones:
      camera.aiIgnoreZones || [],
  });
}

async function ingestAiDetection(
  camera,
  input,
  event,
) {
  const occurredAtMillis =
    Number.isFinite(
      event.occurredAtMillis,
    ) ?
      event.occurredAtMillis :
      Date.now();

  const snapshotDeadline = Date.now() + 30000;
  const aiMetadata = createAiEventMetadata(event, {
    occurredAtMillis,
    modelId: modelIdentifier,
  });
  const result = await eventOutbox.enqueue({
    cameraId: camera.id,
    type: event.type,
    source: 'local-ai',
    confidence: event.confidence ?? null,
    occurredAt: new Date(occurredAtMillis).toISOString(),
    ...(aiMetadata === null ? {} : {aiMetadata}),
  }, (acknowledgement) => {
    // Po długiej awarii nie przypisujemy bieżącego obrazu do starego zdarzenia.
    if (Date.now() <= snapshotDeadline) queueAiSnapshot(camera.id, input, acknowledgement);
  });
  if (camera.aiRecordingEnabled === true) {
    try {
      recordingManager.capture(camera.id, {externalEventId: result.externalEventId, occurredAtMillis});
    } catch (error) {
      console.error(`[BRIDGE AI BUFFER][${camera.id}] ${safeAiErrorMessage(error)}`);
    }
  }
  if (AI_DIAGNOSTICS_ENABLED) {
    console.log(`[BRIDGE AI OUTBOX][${camera.id}] zapisano ${result.externalEventId}, ` +
      `oczekuje=${eventOutbox.pendingCount}`);
  }
  return result;
}

function queueAiSnapshot(cameraId, input, result) {
  const needsSnapshot = typeof result.snapshotRequired === 'boolean'
    ? result.snapshotRequired : result.merged === false;
  if (!needsSnapshot) {
    return result;
  }

  const eventId =
    typeof result.eventId === 'string' ?
      result.eventId :
      (
        typeof result.id === 'string' ?
          result.id :
          ''
      );

  try {
    if (!eventId) {
      throw new Error(
        'Backend nie zwrócił eventId.',
      );
    }

    const queued = snapshotQueue.enqueue({cameraId, eventId, input});
    if (queued === 'full') {
      console.error(
        `[BRIDGE AI SNAPSHOT][${cameraId}] event=${eventId}: kolejka zdjęć jest pełna.`,
      );
    }
  } catch (error) {
    console.error(
      `[BRIDGE AI SNAPSHOT][${cameraId}] ` +
      safeAiErrorMessage(error),
    );
  }
  return result;
}

function safeAiErrorMessage(error) {
  const message =
    error instanceof Error &&
    typeof error.message === 'string' ?
      error.message :
      'nieznany błąd';

  return message
    .replace(
      /\brtsps?:\/\/[^\s'"]+/gi,
      '[adres RTSP ukryty]',
    )
    .replace(
      /([a-z][a-z0-9+.-]*:\/\/)[^/\s@]+@/gi,
      '$1***@',
    )
    .replace(
      /\b(Bearer|Basic)\s+\S+/gi,
      '$1 ***',
    );
}

async function stopAiSession(
  cameraId,
) {
  snapshotQueue.cancelCamera(cameraId);
  if (!sessions.has(cameraId)) await recordingManager.stopCamera(cameraId);
  const entry =
    aiSessions.get(cameraId);

  if (!entry) {
    return false;
  }

  aiSessions.delete(cameraId);

  await entry.session.stop();

  console.log(
    `[BRIDGE AI][${cameraId}] zatrzymano`,
  );

  return true;
}

async function startAiSession(camera) {
  const input =
    await resolveOnvifStreamUri(
      camera,
    );

  if (shuttingDown) {
    return false;
  }

  await recordingManager.syncCamera(camera.id, input,
    camera.aiRecordingEnabled === true || camera.motionDetectionEnabled === true);

  let scheduler;
  try {
    scheduler = await getAiScheduler();
  } catch (error) {
    if (!sessions.has(camera.id)) await recordingManager.stopCamera(camera.id);
    throw error;
  }

  if (shuttingDown) {
    return false;
  }

  const entry = {
    camera,
    input,
    fingerprint:
      aiSessionFingerprint(camera),
    session: null,
  };

  let session;

  session =
    new CameraAiSession({
      cameraId:
        camera.id,

      input,

      scheduler,

      personEnabled:
        camera.aiPersonEnabled === true,

      vehicleEnabled:
        camera.aiVehicleEnabled === true,

      detectionZones:
        camera.aiDetectionZones || [],

      ignoreZones:
        camera.aiIgnoreZones || [],

      framesPerSecond: 2,

      realtimeInput: true,

      trackerOptions:
        trackerOptionsForSensitivity(
          camera.aiSensitivity,
        ),

        onConfirmedTrack:
          (event) =>
            ingestAiDetection(
              entry.camera,
              input,
              event,
            ).catch((error) => {
              if (AI_DIAGNOSTICS_ENABLED) {
                console.error(
                  `[BRIDGE AI INGEST][${camera.id}] ` +
                  safeAiErrorMessage(error),
                );
              }

              throw error;
            }),

      onError: (error) => {
        const message =
          safeAiErrorMessage(error);

        console.error(
          `[BRIDGE AI][${camera.id}] ${message}`,
        );
      },

      onStatus: ({status}) => {
        console.log(
          `[BRIDGE AI][${camera.id}] ` +
          `status = ${status}`,
        );

        if (status !== 'stopped') {
          return;
        }

        const current =
          aiSessions.get(camera.id);

        if (
          current?.session ===
          session
        ) {
          aiSessions.delete(
            camera.id,
          );
        }
      },
    });

  entry.session =
    session;

  aiSessions.set(
    camera.id,
    entry,
  );

  try {
    session.start();
  } catch (error) {
    aiSessions.delete(
      camera.id,
    );

    throw error;
  }

  console.log(
    `[BRIDGE AI][${camera.id}] uruchomiono`,
  );

  return true;
}

async function syncAiSessions(
  cameras,
  localAiEnabled,
) {
  const desired =
    new Map();

  if (localAiEnabled === true) {
    for (const camera of cameras) {
      if (
        !camera ||
        typeof camera.id !==
          'string'
      ) {
        continue;
      }

      const personEnabled =
        camera.aiPersonEnabled === true;

      const vehicleEnabled =
        camera.aiVehicleEnabled === true;

      if (
        camera.aiEnabled !== true ||
        (
          !personEnabled &&
          !vehicleEnabled
        )
      ) {
        continue;
      }

      desired.set(
        camera.id,
        camera,
      );
    }
  }

  snapshotQueue.retainCameras(desired.keys());

  const desiredFingerprint =
    JSON.stringify(
      [...desired.entries()]
        .map(
          ([cameraId, camera]) => [
            cameraId,
            aiSessionFingerprint(camera),
          ],
        )
        .sort(
          ([firstCameraId], [secondCameraId]) =>
            firstCameraId.localeCompare(
              secondCameraId,
            ),
        ),
    );

  if (
    desiredFingerprint !==
      desiredAiSessionsFingerprint
  ) {
    desiredAiSessionsFingerprint =
      desiredFingerprint;

    desiredAiSessionsStartedAtMillis =
      desired.size > 0 ?
        Date.now() :
        null;
  }

  desiredAiSessionCount =
    desired.size;

  for (
    const cameraId of
    [...aiSessions.keys()]
  ) {
    if (!desired.has(cameraId)) {
      await stopAiSession(
        cameraId,
      );
    }
  }

  for (
    const [cameraId, camera] of
    desired.entries()
  ) {
    const existing =
      aiSessions.get(cameraId);

    const fingerprint =
      aiSessionFingerprint(camera);

    if (
      existing &&
      existing.fingerprint ===
        fingerprint
    ) {
      existing.camera =
        camera;

      await recordingManager.syncCamera(cameraId, existing.input,
        camera.aiRecordingEnabled === true || camera.motionDetectionEnabled === true);

      continue;
    }

    if (existing) {
      await stopAiSession(
        cameraId,
      );
    }

    try {
      await startAiSession(
        camera,
      );
    } catch (error) {
      const message =
        safeAiErrorMessage(error);

      console.error(
        `[BRIDGE AI][${cameraId}] ` +
        `nie udało się uruchomić: ${message}`,
      );
    }
  }

  console.log(
    '[BRIDGE AI] aktywnych sesji = ' +
    `${aiSessions.size}`,
  );

  if (AI_DIAGNOSTICS_ENABLED) {
    for (const [cameraId, entry] of aiSessions) {
      console.log(
        `[BRIDGE AI STATS][${cameraId}] ` +
        JSON.stringify(entry.session.stats),
      );
    }
  }
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

  if (!aiSessions.has(cameraId)) await recordingManager.stopCamera(cameraId);

  if (!shuttingDown) {
    await queueStateReport(
      'online',
    );
  }

  if (removeStatus) {
    cameraStatuses.delete(
      cameraId,
    );
    cameraHealth.delete(cameraId);
  }

  console.log(
    `[BRIDGE] zatrzymano kamerę ${cameraId}`,
  );
}

function monitoringFingerprint(camera) {
  return JSON.stringify([connectionFingerprint(camera), camera.frameMotionEnabled === true,
    camera.onvifDeviceId ?? null]);
}

async function resolveMonitoredCamera(camera, options) {
  try { return await resolveOnvifStreamUri(camera, options); } catch (error) {
    if (/HTTP (401|403)\b/.test(error.message)) throw error;
    const endpoint = await endpointRecovery.recover(camera, options.signal);
    if (!endpoint) throw error;
    // Confirm ONVIF returns a stream before saving the same device's new address.
    const input = await resolveOnvifStreamUri({...camera, ...endpoint}, options);
    options.signal?.throwIfAborted();
    await callBridgeEndpoint('reportBridgeCameraEndpoint', {
      cameraId: camera.id, onvifDeviceId: camera.onvifDeviceId,
      previousIpAddress: camera.ipAddress, ...endpoint,
    }, 5000, options.signal);
    return input;
  }
}

function startSession(camera) {
  const fingerprint = monitoringFingerprint(camera);
  cameraStatuses.set(camera.id, 'connecting');
  cameraHealth.set(camera.id, {reason: 'connecting', source: 'none'});
  let eventStatus = 'connecting';
  let frameStatus = camera.frameMotionEnabled === true ? 'connecting' : 'offline';
  let frameReason = 'connecting';
  const report = () => {
    if (sessions.get(camera.id)?.session !== session) return;
    const statuses = [eventStatus, frameStatus];
    const status = ['online', 'connecting', 'reconnecting'].find((s) => statuses.includes(s)) ||
      'offline';
    const health = {
      source: frameStatus === 'online' ? (eventStatus === 'online' ? 'events_and_frames' : 'frames') :
        (eventStatus === 'online' ? 'events' : 'none'),
      reason: frameStatus === 'online' ? 'receiving_frames' :
        (eventStatus === 'online' ? 'receiving_events' : frameReason),
    };
    const changed = JSON.stringify(health) !== JSON.stringify(cameraHealth.get(camera.id));
    cameraHealth.set(camera.id, health);
    if (status !== cameraStatuses.get(camera.id) || changed) {
      updateCameraMonitoringStatus(camera, status);
    }
  };

  const events = new OnvifCameraSession({
    camera, onDetection: ingestDetection,
    onStatusChanged: (_, status) => {
      eventStatus = status;
      report();
    },
  });
  const motion = camera.frameMotionEnabled === true ? new BackgroundMotionSession({
    camera, onDetection: ingestDetection, resolve: resolveMonitoredCamera,
    onReason: (reason) => { frameReason = reason; },
    createSource: ({input, onFrame, onExit}) => frameCache.motionSource(
      camera.id, input, {onFrame, onExit},
      () => recordingManager.syncCamera(camera.id, input, true)),
    onStatusChanged: (_, status) => {
      frameStatus = status;
      report();
    },
  }) : null;
  const session = {
    start() {
      events.start();
      motion?.start();
    },
    async stop() {
      await Promise.all([events.stop(), motion?.stop()]);
    },
  };

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

async function syncCameras(
  cameras,
  localAiEnabled,
) {
  if (shuttingDown) {
    return;
  }

  const desired =
    new Map();

  for (const camera of cameras) {
    if (
      !camera ||
      typeof camera.id !==
        'string' ||
      camera.motionDetectionEnabled !==
        true
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

    const nextFingerprint = monitoringFingerprint(camera);

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

  await syncAiSessions(
    cameras,
    localAiEnabled,
  );

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
    result.localAiEnabled === true,
  );
  try {
    const live = await callBridgeEndpoint('getBridgeIncidentLive', {});
    incidentLive.sync(live.sessions);
  } catch (_) {
    // A temporarily unavailable API cannot interrupt camera monitoring.
  }
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
  incidentLive.close();

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

  for (
    const cameraId of
    [...aiSessions.keys()]
  ) {
    await stopAiSession(
      cameraId,
    );
  }

  if (aiScheduler) {
    aiScheduler.close();
    aiScheduler = null;
  }

  aiInitializationPromise = null;

  snapshotQueue.close();
  await recordingManager.close();
  await clipQueue.close();
  await eventOutbox.close();
  await evidenceSnapshots.close();

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

  await eventOutbox.start();
  await evidenceSnapshots.start();
  try {
    await clipQueue.start();
    await recordingManager.start();
  } catch (error) {
    console.error(`[BRIDGE AI CLIP] ${safeAiErrorMessage(error)}`);
  }
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
