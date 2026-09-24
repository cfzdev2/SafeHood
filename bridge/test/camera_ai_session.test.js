'use strict';

const assert =
  require('node:assert/strict');

const test =
  require('node:test');

const {
  CameraAiSession,
} = require(
  '../ai/camera_ai_session',
);

class FakeFrameSource {
  constructor(options) {
    this.options = options;
    this.started = false;
    this.stopped = false;
  }

  start() {
    this.started = true;
  }

  async stop() {
    if (this.stopped) {
      return;
    }

    this.stopped = true;

    this.options.onExit({
      code: null,
      signal: 'SIGTERM',
      stopped: true,
    });
  }

  emitFrame(frame) {
    return this.options.onFrame(frame);
  }
}

function createSourceHarness() {
  let source = null;

  return {
    sourceFactory(options) {
      source =
        new FakeFrameSource(options);

      return source;
    },

    getSource() {
      return source;
    },
  };
}

function detection({
  type = 'person',
  className = 'person',
  classId = 0,
  score = 0.9,
  left = 100,
  top = 50,
  right = 200,
  bottom = 250,
} = {}) {
  return {
    type,
    className,
    classId,
    score,
    box: {
      left,
      top,
      right,
      bottom,
      width: right - left,
      height: bottom - top,
    },
  };
}

function deferred() {
  let resolve;

  const promise =
    new Promise((promiseResolve) => {
      resolve = promiseResolve;
    });

  return {
    promise,
    resolve,
  };
}

function nextTurn() {
  return new Promise((resolve) => {
    setImmediate(resolve);
  });
}

test(
  'tworzy jedno zdarzenie po potwierdzeniu śladu',
  async () => {
    const harness =
      createSourceHarness();

    const events = [];
    const statuses = [];

    let detectionCall = 0;
    let time = 1000;

    const scheduler = {
      async submit() {
        detectionCall += 1;

        const offset =
          detectionCall * 2;

        return {
          dropped: false,
          reason: null,
          detections: [
            detection({
              left: 100 + offset,
              right: 200 + offset,
            }),
          ],
        };
      },

      cancelCamera() {
        return false;
      },
    };

    const session =
      new CameraAiSession({
        cameraId: 'camera-1',
        input: 'test-video.mp4',
        scheduler,

        onConfirmedTrack: async (
          event,
        ) => {
          events.push(event);
        },

        onStatus: (status) => {
          statuses.push(status);
        },

        sourceFactory:
          harness.sourceFactory,

        now: () => {
          time += 500;
          return time;
        },
      });

    assert.equal(
      session.start(),
      true,
    );

    const source =
      harness.getSource();

    assert.equal(
      source.started,
      true,
    );

    await source.emitFrame(
      Buffer.from([1]),
    );

    await source.emitFrame(
      Buffer.from([2]),
    );

    assert.equal(
      events.length,
      0,
    );

    await source.emitFrame(
      Buffer.from([3]),
    );

    assert.equal(
      events.length,
      1,
    );

    assert.equal(
      events[0].cameraId,
      'camera-1',
    );

    assert.equal(
      events[0].source,
      'local-ai',
    );

    assert.equal(
      events[0].type,
      'person',
    );

    assert.equal(
      events[0].detectionCount,
      3,
    );

    assert.equal(
      session.stats.framesReceived,
      3,
    );

    assert.equal(
      session.stats.framesAnalyzed,
      3,
    );

    assert.equal(
      session.stats.confirmedEvents,
      1,
    );

    await session.stop();

    assert.equal(
      session.status,
      'stopped',
    );

    assert.equal(
      source.stopped,
      true,
    );

    assert.deepEqual(
      statuses.map(
        (status) => status.status,
      ),
      [
        'starting',
        'running',
        'stopping',
        'stopped',
      ],
    );
  },
);

test(
  'filtruje wyłączone typy wykryć',
  async () => {
    const harness =
      createSourceHarness();

    const events = [];

    const scheduler = {
      async submit() {
        return {
          dropped: false,
          detections: [
            detection({
              type: 'person',
              className: 'person',
              classId: 0,
            }),
            detection({
              type: 'vehicle',
              className: 'car',
              classId: 2,
            }),
          ],
        };
      },

      cancelCamera() {
        return false;
      },
    };

    const session =
      new CameraAiSession({
        cameraId: 'camera-2',
        input: 'test-video.mp4',
        scheduler,
        personEnabled: false,
        vehicleEnabled: true,

        onConfirmedTrack: async (
          event,
        ) => {
          events.push(event);
        },

        sourceFactory:
          harness.sourceFactory,
      });

    session.start();

    const source =
      harness.getSource();

    await source.emitFrame(
      Buffer.from([1]),
    );

    await source.emitFrame(
      Buffer.from([2]),
    );

    await source.emitFrame(
      Buffer.from([3]),
    );

    assert.equal(
      events.length,
      1,
    );

    assert.equal(
      events[0].type,
      'vehicle',
    );

    assert.equal(
      events[0].className,
      'car',
    );

    await session.stop();
  },
);

test(
  'liczy pominięte klatki i błędy inferencji',
  async () => {
    const harness =
      createSourceHarness();

    const errors = [];

    let callCount = 0;

    const scheduler = {
      async submit() {
        callCount += 1;

        if (callCount === 1) {
          return {
            dropped: true,
            reason: 'capacity',
            detections: [],
          };
        }

        throw new Error(
          'raw detector error',
        );
      },

      cancelCamera() {
        return false;
      },
    };

    const session =
      new CameraAiSession({
        cameraId: 'camera-3',
        input: 'test-video.mp4',
        scheduler,

        onConfirmedTrack:
          async () => {},

        onError: (error) => {
          errors.push(error);
        },

        sourceFactory:
          harness.sourceFactory,
      });

    session.start();

    const source =
      harness.getSource();

    await source.emitFrame(
      Buffer.from([1]),
    );

    await source.emitFrame(
      Buffer.from([2]),
    );

    assert.equal(
      session.stats.framesReceived,
      2,
    );

    assert.equal(
      session.stats.framesDropped,
      1,
    );

    assert.equal(
      session.stats.inferenceErrors,
      1,
    );

    assert.equal(
      session.stats.framesAnalyzed,
      0,
    );

    assert.equal(
      errors.length,
      1,
    );

    assert.equal(
      errors[0].message,
      'Nie udało się przeanalizować ' +
        'klatki kamery.',
    );

    await session.stop();
  },
);

test(
  'ignoruje wynik inferencji po zatrzymaniu',
  async () => {
    const harness =
      createSourceHarness();

    const inferenceGate =
      deferred();

    const events = [];

    const scheduler = {
      submit() {
        return inferenceGate.promise;
      },

      cancelCamera() {
        return true;
      },
    };

    const session =
      new CameraAiSession({
        cameraId: 'camera-4',
        input: 'test-video.mp4',
        scheduler,

        onConfirmedTrack: async (
          event,
        ) => {
          events.push(event);
        },

        sourceFactory:
          harness.sourceFactory,

        trackerOptions: {
          minimumConfirmedFrames: 1,
        },
      });

    session.start();

    const processing =
      harness
        .getSource()
        .emitFrame(
          Buffer.from([1]),
        );

    await nextTurn();
    await session.stop();

    inferenceGate.resolve({
      dropped: false,
      detections: [
        detection(),
      ],
    });

    await processing;

    assert.equal(
      events.length,
      0,
    );

    assert.equal(
      session.stats.framesAnalyzed,
      0,
    );
  },
);

test(
  'obsługuje błąd zapisu zdarzenia',
  async () => {
    const harness =
      createSourceHarness();

    const errors = [];

    const scheduler = {
      async submit() {
        return {
          dropped: false,
          detections: [
            detection(),
          ],
        };
      },

      cancelCamera() {
        return false;
      },
    };

    const session =
      new CameraAiSession({
        cameraId: 'camera-5',
        input: 'test-video.mp4',
        scheduler,

        trackerOptions: {
          minimumConfirmedFrames: 1,
        },

        onConfirmedTrack:
          async () => {
            throw new Error(
              'raw backend error',
            );
          },

        onError: (error) => {
          errors.push(error);
        },

        sourceFactory:
          harness.sourceFactory,
      });

    session.start();

    await harness
      .getSource()
      .emitFrame(
        Buffer.from([1]),
      );

    assert.equal(
      session.stats.confirmedEvents,
      0,
    );

    assert.equal(
      session.stats.eventErrors,
      1,
    );

    assert.equal(
      errors[0].message,
      'Nie udało się obsłużyć ' +
        'potwierdzonego zdarzenia AI.',
    );

    await session.stop();
  },
);