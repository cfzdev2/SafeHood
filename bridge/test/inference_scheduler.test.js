'use strict';

const assert =
  require('node:assert/strict');

const test =
  require('node:test');

const {
  AiInferenceScheduler,
} = require(
  '../ai/inference_scheduler',
);

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
  'wykonuje tylko jedną inferencję jednocześnie',
  async () => {
    let activeCount = 0;
    let maximumActiveCount = 0;

    const processedFrames = [];

    const detector = {
      async detectBgrFrame(frame) {
        activeCount += 1;

        maximumActiveCount =
          Math.max(
            maximumActiveCount,
            activeCount,
          );

        processedFrames.push(
          frame[0],
        );

        await new Promise((resolve) => {
          setTimeout(resolve, 5);
        });

        activeCount -= 1;

        return [
          {
            value: frame[0],
          },
        ];
      },
    };

    const scheduler =
      new AiInferenceScheduler({
        detector,
      });

    const results = await Promise.all([
      scheduler.submit({
        cameraId: 'camera-1',
        frame: Buffer.from([1]),
      }),
      scheduler.submit({
        cameraId: 'camera-2',
        frame: Buffer.from([2]),
      }),
      scheduler.submit({
        cameraId: 'camera-3',
        frame: Buffer.from([3]),
      }),
    ]);

    assert.equal(
      maximumActiveCount,
      1,
    );

    assert.deepEqual(
      processedFrames,
      [
        1,
        2,
        3,
      ],
    );

    assert.equal(
      results.every(
        (result) =>
          result.dropped === false,
      ),
      true,
    );

    scheduler.close();
  },
);

test(
  'zastępuje oczekującą klatkę nowszą',
  async () => {
    const firstFrameGate =
      deferred();

    const processedFrames = [];

    const detector = {
      async detectBgrFrame(frame) {
        processedFrames.push(
          frame[0],
        );

        if (frame[0] === 1) {
          await firstFrameGate.promise;
        }

        return [];
      },
    };

    const scheduler =
      new AiInferenceScheduler({
        detector,
      });

    const firstRequest =
      scheduler.submit({
        cameraId: 'camera-1',
        frame: Buffer.from([1]),
      });

    await nextTurn();

    const secondRequest =
      scheduler.submit({
        cameraId: 'camera-1',
        frame: Buffer.from([2]),
      });

    const thirdRequest =
      scheduler.submit({
        cameraId: 'camera-1',
        frame: Buffer.from([3]),
      });

    const secondResult =
      await secondRequest;

    assert.equal(
      secondResult.dropped,
      true,
    );

    assert.equal(
      secondResult.reason,
      'superseded',
    );

    firstFrameGate.resolve();

    const [
      firstResult,
      thirdResult,
    ] = await Promise.all([
      firstRequest,
      thirdRequest,
    ]);

    assert.equal(
      firstResult.dropped,
      false,
    );

    assert.equal(
      thirdResult.dropped,
      false,
    );

    assert.deepEqual(
      processedFrames,
      [
        1,
        3,
      ],
    );

    scheduler.close();
  },
);

test(
  'kontynuuje pracę po błędzie detektora',
  async () => {
    const detector = {
      async detectBgrFrame(frame) {
        if (frame[0] === 1) {
          throw new Error(
            'test detector error',
          );
        }

        return [
          {
            value: frame[0],
          },
        ];
      },
    };

    const scheduler =
      new AiInferenceScheduler({
        detector,
      });

    const firstRequest =
      scheduler.submit({
        cameraId: 'camera-1',
        frame: Buffer.from([1]),
      });

    const secondRequest =
      scheduler.submit({
        cameraId: 'camera-2',
        frame: Buffer.from([2]),
      });

    await assert.rejects(
      firstRequest,
      /test detector error/,
    );

    const secondResult =
      await secondRequest;

    assert.equal(
      secondResult.dropped,
      false,
    );

    assert.equal(
      secondResult.detections[0]
        .value,
      2,
    );

    scheduler.close();
  },
);

test(
  'ogranicza liczbę oczekujących kamer',
  async () => {
    const firstFrameGate =
      deferred();

    const detector = {
      async detectBgrFrame(frame) {
        if (frame[0] === 1) {
          await firstFrameGate.promise;
        }

        return [];
      },
    };

    const scheduler =
      new AiInferenceScheduler({
        detector,
        maximumPendingCameras: 1,
      });

    const firstRequest =
      scheduler.submit({
        cameraId: 'camera-1',
        frame: Buffer.from([1]),
      });

    await nextTurn();

    const pendingRequest =
      scheduler.submit({
        cameraId: 'camera-2',
        frame: Buffer.from([2]),
      });

    const overflowResult =
      await scheduler.submit({
        cameraId: 'camera-3',
        frame: Buffer.from([3]),
      });

    assert.equal(
      overflowResult.dropped,
      true,
    );

    assert.equal(
      overflowResult.reason,
      'capacity',
    );

    firstFrameGate.resolve();

    await firstRequest;
    await pendingRequest;

    scheduler.close();
  },
);

test(
  'anuluje oczekującą klatkę kamery',
  async () => {
    const firstFrameGate =
      deferred();

    const detector = {
      async detectBgrFrame(frame) {
        if (frame[0] === 1) {
          await firstFrameGate.promise;
        }

        return [];
      },
    };

    const scheduler =
      new AiInferenceScheduler({
        detector,
      });

    const firstRequest =
      scheduler.submit({
        cameraId: 'camera-1',
        frame: Buffer.from([1]),
      });

    await nextTurn();

    const pendingRequest =
      scheduler.submit({
        cameraId: 'camera-2',
        frame: Buffer.from([2]),
      });

    assert.equal(
      scheduler.cancelCamera(
        'camera-2',
      ),
      true,
    );

    const pendingResult =
      await pendingRequest;

    assert.equal(
      pendingResult.dropped,
      true,
    );

    assert.equal(
      pendingResult.reason,
      'cancelled',
    );

    firstFrameGate.resolve();
    await firstRequest;

    scheduler.close();
  },
);

test(
  'odrzuca zadania po zamknięciu',
  async () => {
    const scheduler =
      new AiInferenceScheduler({
        detector: {
          async detectBgrFrame() {
            return [];
          },
        },
      });

    scheduler.close();

    await assert.rejects(
      scheduler.submit({
        cameraId: 'camera-1',
        frame: Buffer.from([1]),
      }),
      /został zamknięty/,
    );
  },
);