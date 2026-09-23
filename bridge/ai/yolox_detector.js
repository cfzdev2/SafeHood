'use strict';

const {
  createHash,
} = require('node:crypto');

const fs =
  require('node:fs');

const path =
  require('node:path');

const ort =
  require('onnxruntime-node');

const {
  decodeYoloxOutput,
} = require('./yolox_postprocess');

const inputWidth = 416;
const inputHeight = 416;
const channelCount = 3;
const predictionCount = 3549;
const predictionSize = 85;

const modelSha256 =
  'c789161ed43c8269fcd4e67c67eeeb4e' +
  '80c622da2eb296a20bc6007bd18a0b7d';

const defaultModelPath =
  path.join(
    __dirname,
    '..',
    'models',
    'yolox_nano.onnx',
  );

/**
 * Oblicza SHA-256 podanych danych.
 *
 * @param {Buffer} value Dane modelu.
 * @return {string} Skrót SHA-256.
 */
function sha256(value) {
  return createHash('sha256')
    .update(value)
    .digest('hex');
}

class YoloxDetector {
  /**
   * @param {{modelPath?: string}} options Opcje detektora.
   */
  constructor({
    modelPath = defaultModelPath,
  } = {}) {
    this.modelPath = modelPath;
    this.session = null;
    this.inputName = null;
    this.outputName = null;
  }

  /**
   * Ładuje i weryfikuje model.
   *
   * @return {Promise<void>}
   */
  async initialize() {
    const modelBytes =
      fs.readFileSync(this.modelPath);

    const actualSha256 =
      sha256(modelBytes);

    if (actualSha256 !== modelSha256) {
      throw new Error(
        'Model YOLOX ma nieprawidłową sumę SHA-256.',
      );
    }

    const session =
      await ort.InferenceSession.create(
        modelBytes,
        {
          executionProviders: ['cpu'],
          graphOptimizationLevel: 'all',
        },
      );

    const inputMetadata =
      session.inputMetadata[0];

    const outputMetadata =
      session.outputMetadata[0];

    const validInput =
      inputMetadata?.name === 'images' &&
      inputMetadata.type === 'float32' &&
      JSON.stringify(inputMetadata.shape) ===
        JSON.stringify([
          1,
          channelCount,
          inputHeight,
          inputWidth,
        ]);

    const validOutput =
      outputMetadata?.name === 'output' &&
      outputMetadata.type === 'float32' &&
      JSON.stringify(outputMetadata.shape) ===
        JSON.stringify([
          1,
          predictionCount,
          predictionSize,
        ]);

    if (!validInput || !validOutput) {
      throw new Error(
        'Model YOLOX ma nieobsługiwany format.',
      );
    }

    this.session = session;
    this.inputName = inputMetadata.name;
    this.outputName = outputMetadata.name;
  }

  /**
   * Uruchamia model na klatce BGR24 416x416.
   *
   * @param {Buffer} frame Klatka BGR24.
   * @return {Promise<Float32Array>} Surowe predykcje.
   */
  async inferBgrFrame(frame) {
    if (
      this.session === null ||
      this.inputName === null ||
      this.outputName === null
    ) {
      throw new Error(
        'Detektor YOLOX nie został uruchomiony.',
      );
    }

    const pixelCount =
      inputWidth * inputHeight;

    const expectedByteLength =
      pixelCount * channelCount;

    if (
      !Buffer.isBuffer(frame) ||
      frame.length !== expectedByteLength
    ) {
      throw new Error(
        'Klatka AI musi mieć format BGR24 416x416.',
      );
    }

    const inputData =
      new Float32Array(expectedByteLength);

    for (
      let pixelIndex = 0;
      pixelIndex < pixelCount;
      pixelIndex += 1
    ) {
      const sourceIndex =
        pixelIndex * channelCount;

      inputData[pixelIndex] =
        frame[sourceIndex];

      inputData[pixelCount + pixelIndex] =
        frame[sourceIndex + 1];

      inputData[
        (pixelCount * 2) + pixelIndex
      ] = frame[sourceIndex + 2];
    }

    const tensor =
      new ort.Tensor(
        'float32',
        inputData,
        [
          1,
          channelCount,
          inputHeight,
          inputWidth,
        ],
      );

    const result =
      await this.session.run({
        [this.inputName]: tensor,
      });

    const output =
      result[this.outputName];

    if (
      output === undefined ||
      output.data.length !==
        predictionCount * predictionSize
    ) {
      throw new Error(
        'Model YOLOX zwrócił nieprawidłowy wynik.',
      );
    }

    return output.data;
  }

    /**
   * Wykrywa osoby i pojazdy na klatce.
   *
   * @param {Buffer} frame Klatka BGR24.
   * @param {Object} options Opcje post-processingu.
   * @return {Promise<Array<Object>>} Detekcje.
   */
  async detectBgrFrame(
    frame,
    options = {},
  ) {
    const output =
      await this.inferBgrFrame(frame);

    return decodeYoloxOutput(
      output,
      options,
    );
  }
}

module.exports = {
  YoloxDetector,
  inputHeight,
  inputWidth,
};