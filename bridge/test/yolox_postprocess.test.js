'use strict';

const assert =
  require('node:assert/strict');

const {
  test,
} = require('node:test');

const {
  decodeYoloxOutput,
  intersectionOverUnion,
} = require(
  '../ai/yolox_postprocess',
);

const predictionCount = 3549;
const predictionSize = 85;

/**
 * Tworzy puste wyjście YOLOX.
 *
 * @return {Float32Array} Wyjście testowe.
 */
function createOutput() {
  return new Float32Array(
    predictionCount * predictionSize,
  );
}

/**
 * Ustawia predykcję z pierwszej siatki stride 8.
 *
 * @param {Float32Array} output Wyjście YOLOX.
 * @param {number} index Indeks predykcji.
 * @param {Object} options Parametry obiektu.
 */
function setPrediction(
  output,
  index,
  {
    classId,
    centerX = 80,
    centerY = 80,
    width = 80,
    height = 80,
    objectness = 0.9,
    classProbability = 0.9,
  },
) {
  const stride = 8;
  const gridX = index;
  const gridY = 0;

  const offset =
    index * predictionSize;

  output[offset] =
    (centerX / stride) - gridX;

  output[offset + 1] =
    (centerY / stride) - gridY;

  output[offset + 2] =
    Math.log(width / stride);

  output[offset + 3] =
    Math.log(height / stride);

  output[offset + 4] =
    objectness;

  output[
    offset + 5 + classId
  ] = classProbability;
}

/**
 * Sprawdza wartość zmiennoprzecinkową.
 *
 * @param {number} actual Wynik.
 * @param {number} expected Oczekiwana wartość.
 */
function assertNear(
  actual,
  expected,
) {
  assert.ok(
    Math.abs(actual - expected) <
      0.0001,
  );
}

test(
  'dekoduje wykrycie osoby',
  () => {
    const output =
      createOutput();

    setPrediction(
      output,
      0,
      {
        classId: 0,
      },
    );

    const detections =
      decodeYoloxOutput(output);

    assert.equal(
      detections.length,
      1,
    );

    const detection =
      detections[0];

    assert.equal(
      detection.type,
      'person',
    );

    assert.equal(
      detection.className,
      'person',
    );

    assertNear(
      detection.score,
      0.81,
    );

    assertNear(
      detection.box.left,
      40,
    );

    assertNear(
      detection.box.top,
      40,
    );

    assertNear(
      detection.box.right,
      120,
    );

    assertNear(
      detection.box.bottom,
      120,
    );
  },
);

test(
  'łączy nakładające się osoby',
  () => {
    const output =
      createOutput();

    setPrediction(
      output,
      0,
      {
        classId: 0,
        objectness: 0.9,
      },
    );

    setPrediction(
      output,
      1,
      {
        classId: 0,
        objectness: 0.8,
      },
    );

    const detections =
      decodeYoloxOutput(output);

    assert.equal(
      detections.length,
      1,
    );

    assertNear(
      detections[0].score,
      0.81,
    );
  },
);

test(
  'zachowuje osobę i pojazd',
  () => {
    const output =
      createOutput();

    setPrediction(
      output,
      0,
      {
        classId: 0,
      },
    );

    setPrediction(
      output,
      1,
      {
        classId: 2,
        objectness: 0.8,
      },
    );

    const detections =
      decodeYoloxOutput(output);

    assert.equal(
      detections.length,
      2,
    );

    assert.deepEqual(
      detections.map(
        (item) => item.type,
      ),
      [
        'person',
        'vehicle',
      ],
    );
  },
);

test(
  'oblicza IoU prostokątów',
  () => {
    const first = {
      box: {
        left: 0,
        top: 0,
        right: 10,
        bottom: 10,
        width: 10,
        height: 10,
      },
    };

    const second = {
      box: {
        left: 5,
        top: 5,
        right: 15,
        bottom: 15,
        width: 10,
        height: 10,
      },
    };

    assertNear(
      intersectionOverUnion(
        first,
        second,
      ),
      25 / 175,
    );
  },
);

test(
  'odrzuca nieprawidłowe dane',
  () => {
    assert.throws(
      () => {
        decodeYoloxOutput(
          new Float32Array(10),
        );
      },
      /Nieprawidłowe wyjście/,
    );
  },
);