'use strict';

const inputSize = 416;
const predictionSize = 85;

const strides = [
  8,
  16,
  32,
];

const trackedClasses = [
  {
    id: 0,
    name: 'person',
    type: 'person',
  },
  {
    id: 1,
    name: 'bicycle',
    type: 'vehicle',
  },
  {
    id: 2,
    name: 'car',
    type: 'vehicle',
  },
  {
    id: 3,
    name: 'motorcycle',
    type: 'vehicle',
  },
  {
    id: 5,
    name: 'bus',
    type: 'vehicle',
  },
  {
    id: 7,
    name: 'truck',
    type: 'vehicle',
  },
];

/**
 * Ogranicza liczbę do wskazanego zakresu.
 *
 * @param {number} value Wartość.
 * @param {number} minimum Minimum.
 * @param {number} maximum Maksimum.
 * @return {number} Ograniczona wartość.
 */
function clamp(
  value,
  minimum,
  maximum,
) {
  return Math.min(
    maximum,
    Math.max(minimum, value),
  );
}

/**
 * Oblicza część wspólną dwóch prostokątów.
 *
 * @param {Object} first Pierwsza detekcja.
 * @param {Object} second Druga detekcja.
 * @return {number} Wartość IoU.
 */
function intersectionOverUnion(
  first,
  second,
) {
  const left =
    Math.max(
      first.box.left,
      second.box.left,
    );

  const top =
    Math.max(
      first.box.top,
      second.box.top,
    );

  const right =
    Math.min(
      first.box.right,
      second.box.right,
    );

  const bottom =
    Math.min(
      first.box.bottom,
      second.box.bottom,
    );

  const intersectionWidth =
    Math.max(0, right - left);

  const intersectionHeight =
    Math.max(0, bottom - top);

  const intersectionArea =
    intersectionWidth *
    intersectionHeight;

  const firstArea =
    first.box.width *
    first.box.height;

  const secondArea =
    second.box.width *
    second.box.height;

  const unionArea =
    firstArea +
    secondArea -
    intersectionArea;

  if (unionArea <= 0) {
    return 0;
  }

  return intersectionArea / unionArea;
}

/**
 * Usuwa nakładające się detekcje.
 *
 * @param {Array<Object>} detections Detekcje.
 * @param {number} threshold Próg IoU.
 * @param {number} maximum Maksymalna liczba wyników.
 * @return {Array<Object>} Wyniki po NMS.
 */
function applyNms(
  detections,
  threshold,
  maximum,
) {
  const sorted =
    [...detections].sort(
      (first, second) =>
        second.score - first.score,
    );

  const accepted = [];

  for (const detection of sorted) {
    const overlaps =
      accepted.some(
        (existing) =>
          existing.type === detection.type &&
          intersectionOverUnion(
            existing,
            detection,
          ) > threshold,
      );

    if (overlaps) {
      continue;
    }

    accepted.push(detection);

    if (accepted.length >= maximum) {
      break;
    }
  }

  return accepted;
}

/**
 * Dekoduje wyjście modelu YOLOX-Nano.
 *
 * @param {Float32Array} output Surowe wyjście ONNX.
 * @param {{
 *   scoreThreshold?: number,
 *   nmsThreshold?: number,
 *   maximumDetections?: number
 * }} options Opcje dekodowania.
 * @return {Array<Object>} Wykryte obiekty.
 */
function decodeYoloxOutput(
  output,
  {
    scoreThreshold = 0.35,
    nmsThreshold = 0.45,
    maximumDetections = 100,
  } = {},
) {
  const expectedLength =
    3549 * predictionSize;

  if (
    !(output instanceof Float32Array) ||
    output.length !== expectedLength
  ) {
    throw new Error(
      'Nieprawidłowe wyjście modelu YOLOX.',
    );
  }

  if (
    scoreThreshold < 0 ||
    scoreThreshold > 1 ||
    nmsThreshold < 0 ||
    nmsThreshold > 1 ||
    !Number.isInteger(maximumDetections) ||
    maximumDetections < 1
  ) {
    throw new Error(
      'Nieprawidłowe ustawienia detekcji YOLOX.',
    );
  }

  const detections = [];
  let predictionIndex = 0;

  for (const stride of strides) {
    const gridSize =
      inputSize / stride;

    for (
      let gridY = 0;
      gridY < gridSize;
      gridY += 1
    ) {
      for (
        let gridX = 0;
        gridX < gridSize;
        gridX += 1
      ) {
        const offset =
          predictionIndex *
          predictionSize;

        predictionIndex += 1;

        const objectness =
          output[offset + 4];

        if (
          !Number.isFinite(objectness) ||
          objectness <= 0
        ) {
          continue;
        }

        let selectedClass = null;
        let selectedScore = -Infinity;

        for (
          const trackedClass
          of trackedClasses
        ) {
          const classProbability =
            output[
              offset +
              5 +
              trackedClass.id
            ];

          const score =
            objectness *
            classProbability;

          if (score > selectedScore) {
            selectedClass =
              trackedClass;

            selectedScore =
              score;
          }
        }

        if (
          selectedClass === null ||
          !Number.isFinite(selectedScore) ||
          selectedScore < scoreThreshold
        ) {
          continue;
        }

        const centerX =
          (
            output[offset] +
            gridX
          ) * stride;

        const centerY =
          (
            output[offset + 1] +
            gridY
          ) * stride;

        const width =
          Math.exp(
            output[offset + 2],
          ) * stride;

        const height =
          Math.exp(
            output[offset + 3],
          ) * stride;

        if (
          !Number.isFinite(centerX) ||
          !Number.isFinite(centerY) ||
          !Number.isFinite(width) ||
          !Number.isFinite(height)
        ) {
          continue;
        }

        const left =
          clamp(
            centerX - (width / 2),
            0,
            inputSize,
          );

        const top =
          clamp(
            centerY - (height / 2),
            0,
            inputSize,
          );

        const right =
          clamp(
            centerX + (width / 2),
            0,
            inputSize,
          );

        const bottom =
          clamp(
            centerY + (height / 2),
            0,
            inputSize,
          );

        if (
          right <= left ||
          bottom <= top
        ) {
          continue;
        }

        detections.push({
          type:
            selectedClass.type,

          classId:
            selectedClass.id,

          className:
            selectedClass.name,

          score:
            selectedScore,

          box: {
            left,
            top,
            right,
            bottom,
            width:
              right - left,
            height:
              bottom - top,
          },
        });
      }
    }
  }

  return applyNms(
    detections,
    nmsThreshold,
    maximumDetections,
  );
}

module.exports = {
  decodeYoloxOutput,
  intersectionOverUnion,
};