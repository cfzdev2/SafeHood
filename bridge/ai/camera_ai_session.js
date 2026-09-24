'use strict';

const {
  FfmpegFrameSource,
} = require('./ffmpeg_frame_source');

const {
  ObjectTracker,
} = require('./object_tracker');

function defaultSourceFactory(options) {
  return new FfmpegFrameSource(options);
}

class CameraAiSession {
  constructor({
    cameraId,
    input,
    scheduler,
    onConfirmedTrack,
    onError = () => {},
    onStatus = () => {},
    personEnabled = true,
    vehicleEnabled = true,
    framesPerSecond = 2,
    realtimeInput = false,
    trackerOptions = {},
    sourceFactory =
      defaultSourceFactory,
    now = () => Date.now(),
  }) {
    if (
      typeof cameraId !== 'string' ||
      !cameraId.trim()
    ) {
      throw new TypeError(
        'cameraId jest wymagane.',
      );
    }

    if (
      typeof input !== 'string' ||
      !input.trim()
    ) {
      throw new TypeError(
        'Źródło obrazu jest wymagane.',
      );
    }

    if (
      !scheduler ||
      typeof scheduler.submit !==
        'function' ||
      typeof scheduler.cancelCamera !==
        'function'
    ) {
      throw new TypeError(
        'Scheduler AI jest nieprawidłowy.',
      );
    }

    if (
      typeof onConfirmedTrack !==
      'function'
    ) {
      throw new TypeError(
        'onConfirmedTrack musi być funkcją.',
      );
    }

    if (
      typeof onError !== 'function' ||
      typeof onStatus !== 'function'
    ) {
      throw new TypeError(
        'Callback musi być funkcją.',
      );
    }

    if (
      personEnabled !== true &&
      vehicleEnabled !== true
    ) {
      throw new Error(
        'Co najmniej jeden typ wykrywania ' +
        'musi być włączony.',
      );
    }

    if (
      !Number.isFinite(
        framesPerSecond,
      ) ||
      framesPerSecond <= 0 ||
      framesPerSecond > 30
    ) {
      throw new RangeError(
        'Nieprawidłowa liczba klatek ' +
        'na sekundę.',
      );
    }

    if (
      !trackerOptions ||
      typeof trackerOptions !==
        'object' ||
      Array.isArray(trackerOptions)
    ) {
      throw new TypeError(
        'Opcje trackera są nieprawidłowe.',
      );
    }

    if (
      typeof sourceFactory !==
        'function' ||
      typeof now !== 'function'
    ) {
      throw new TypeError(
        'Fabryka lub zegar są ' +
        'nieprawidłowe.',
      );
    }

    this.cameraId = cameraId.trim();
    this.input = input.trim();
    this.scheduler = scheduler;

    this.onConfirmedTrack =
      onConfirmedTrack;

    this.onError = onError;
    this.onStatus = onStatus;

    this.personEnabled =
      personEnabled === true;

    this.vehicleEnabled =
      vehicleEnabled === true;

    this.framesPerSecond =
      framesPerSecond;

    this.realtimeInput =
      realtimeInput === true;

    this.sourceFactory =
      sourceFactory;

    this.now = now;

    this.tracker =
      new ObjectTracker(
        trackerOptions,
      );

    this._source = null;
    this._status = 'idle';
    this._sessionToken = 0;

    this._stats =
      this._emptyStats();
  }

  get status() {
    return this._status;
  }

  get stats() {
    return {
      ...this._stats,
    };
  }

  start() {
    if (
      this._status === 'starting' ||
      this._status === 'running' ||
      this._status === 'stopping'
    ) {
      throw new Error(
        'Sesja AI jest już aktywna.',
      );
    }

    this.tracker.reset();

    this._stats =
      this._emptyStats();

    this._stats.startedAtMillis =
      this.now();

    const sessionToken =
      this._sessionToken + 1;

    this._sessionToken =
      sessionToken;

    this._status = 'starting';

    this._emitStatus({
      status: 'starting',
    });

    try {
      const source =
        this.sourceFactory({
          input: this.input,

          framesPerSecond:
            this.framesPerSecond,

          realtimeInput:
            this.realtimeInput,

          onFrame: (frame) =>
            this._handleFrame(
              frame,
              sessionToken,
            ),

          onError: (error) => {
            if (
              sessionToken ===
              this._sessionToken
            ) {
              this._reportError(error);
            }
          },

          onExit: (info) => {
            this._finishSession(
              sessionToken,
              info,
            );
          },
        });

      if (
        !source ||
        typeof source.start !==
          'function' ||
        typeof source.stop !==
          'function'
      ) {
        throw new TypeError(
          'Źródło klatek jest ' +
          'nieprawidłowe.',
        );
      }

      this._source = source;
      this._status = 'running';

      source.start();

      this._emitStatus({
        status: 'running',
      });

      return true;
    } catch (error) {
      this._source = null;
      this._status = 'stopped';

      this._stats.stoppedAtMillis =
        this.now();

      this._reportError(
        new Error(
          'Nie udało się uruchomić ' +
          'sesji AI.',
        ),
      );

      throw error;
    }
  }

  async stop() {
    if (
      this._status === 'idle' ||
      this._status === 'stopped'
    ) {
      return false;
    }

    if (this._status === 'stopping') {
      return false;
    }

    const sessionToken =
      this._sessionToken;

    this._status = 'stopping';

    this._emitStatus({
      status: 'stopping',
    });

    this.scheduler.cancelCamera(
      this.cameraId,
    );

    const source = this._source;

    if (source) {
      await source.stop();
    }

    this._finishSession(
      sessionToken,
      {
        code: null,
        signal: null,
        stopped: true,
      },
    );

    return true;
  }

  async _handleFrame(
    frame,
    sessionToken,
  ) {
    if (
      sessionToken !==
        this._sessionToken ||
      this._status !== 'running'
    ) {
      return;
    }

    this._stats.framesReceived += 1;

    let inferenceResult;

    try {
      inferenceResult =
        await this.scheduler.submit({
          cameraId: this.cameraId,
          frame,
          options: {
            scoreThreshold:
              this.tracker
                .lowScoreThreshold,
          },
        });
    } catch (_) {
      if (
        sessionToken ===
          this._sessionToken &&
        this._status === 'running'
      ) {
        this._stats.inferenceErrors += 1;

        this._reportError(
          new Error(
            'Nie udało się przeanalizować ' +
            'klatki kamery.',
          ),
        );
      }

      return;
    }

    if (
      sessionToken !==
        this._sessionToken ||
      this._status !== 'running'
    ) {
      return;
    }

    if (inferenceResult.dropped) {
      this._stats.framesDropped += 1;
      return;
    }

    this._stats.framesAnalyzed += 1;

    const enabledDetections =
      inferenceResult.detections.filter(
        (detection) => {
          if (
            detection.type ===
            'person'
          ) {
            return this.personEnabled;
          }

          if (
            detection.type ===
            'vehicle'
          ) {
            return this.vehicleEnabled;
          }

          return false;
        },
      );

    const timestampMillis =
      this.now();

    const trackingResult =
      this.tracker.update(
        enabledDetections,
        {
          timestampMillis,
        },
      );

    for (
      const track
      of trackingResult
        .newlyConfirmedTracks
    ) {
      if (
        sessionToken !==
          this._sessionToken ||
        this._status !== 'running'
      ) {
        return;
      }

      const event = {
        cameraId: this.cameraId,
        source: 'local-ai',
        type: track.type,
        className:
          track.bestClassName,
        confidence:
          track.bestScore,
        trackId: track.id,
        detectionCount:
          track.detectionCount,
        occurredAtMillis:
          track.lastSeenAtMillis,
        firstSeenAtMillis:
          track.firstSeenAtMillis,
        box: {
          ...track.box,
        },
      };

      try {
        await this.onConfirmedTrack(
          event,
        );

        this._stats.confirmedEvents += 1;
      } catch (_) {
        this._stats.eventErrors += 1;

        this._reportError(
          new Error(
            'Nie udało się obsłużyć ' +
            'potwierdzonego zdarzenia AI.',
          ),
        );
      }
    }
  }

  _finishSession(
    sessionToken,
    info,
  ) {
    if (
      sessionToken !==
        this._sessionToken ||
      this._status === 'stopped'
    ) {
      return;
    }

    this.scheduler.cancelCamera(
      this.cameraId,
    );

    this._source = null;
    this._status = 'stopped';

    this._stats.stoppedAtMillis =
      this.now();

    this._emitStatus({
      status: 'stopped',
      exit: {
        code:
          info?.code ?? null,
        signal:
          info?.signal ?? null,
        stopped:
          info?.stopped === true,
      },
    });
  }

  _emptyStats() {
    return {
      framesReceived: 0,
      framesAnalyzed: 0,
      framesDropped: 0,
      inferenceErrors: 0,
      confirmedEvents: 0,
      eventErrors: 0,
      startedAtMillis: null,
      stoppedAtMillis: null,
    };
  }

  _emitStatus(details) {
    try {
      this.onStatus({
        cameraId: this.cameraId,
        ...details,
      });
    } catch (_) {
      this._reportError(
        new Error(
          'Błąd obsługi statusu ' +
          'sesji AI.',
        ),
      );
    }
  }

  _reportError(error) {
    try {
      this.onError(error);
    } catch (_) {
      // Callback błędu nie może
      // zatrzymać sesji AI.
    }
  }
}

module.exports = {
  CameraAiSession,
};