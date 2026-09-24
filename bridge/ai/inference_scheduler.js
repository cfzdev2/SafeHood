'use strict';

class AiInferenceScheduler {
  constructor({
    detector,
    maximumPendingCameras = 32,
  }) {
    if (
      !detector ||
      typeof detector.detectBgrFrame !==
        'function'
    ) {
      throw new TypeError(
        'Detector musi udostępniać ' +
        'detectBgrFrame().',
      );
    }

    if (
      !Number.isInteger(
        maximumPendingCameras,
      ) ||
      maximumPendingCameras < 1
    ) {
      throw new RangeError(
        'maximumPendingCameras musi być ' +
        'dodatnią liczbą całkowitą.',
      );
    }

    this.detector = detector;

    this.maximumPendingCameras =
      maximumPendingCameras;

    this._pendingByCamera =
      new Map();

    this._cameraOrder = [];

    this._running = false;
    this._runningCameraId = null;
    this._drainScheduled = false;
    this._closed = false;
  }

  get isRunning() {
    return this._running;
  }

  get pendingCount() {
    return this._pendingByCamera.size;
  }

  submit({
    cameraId,
    frame,
    options = {},
  }) {
    if (this._closed) {
      return Promise.reject(
        new Error(
          'Scheduler AI został zamknięty.',
        ),
      );
    }

    if (
      typeof cameraId !== 'string' ||
      !cameraId.trim()
    ) {
      return Promise.reject(
        new TypeError(
          'cameraId jest wymagane.',
        ),
      );
    }

    if (!Buffer.isBuffer(frame)) {
      return Promise.reject(
        new TypeError(
          'Klatka musi być obiektem Buffer.',
        ),
      );
    }

    if (
      !options ||
      typeof options !== 'object' ||
      Array.isArray(options)
    ) {
      return Promise.reject(
        new TypeError(
          'Opcje detekcji są nieprawidłowe.',
        ),
      );
    }

    const normalizedCameraId =
      cameraId.trim();

    const previousRequest =
      this._pendingByCamera.get(
        normalizedCameraId,
      );

    if (
      !previousRequest &&
      this._pendingByCamera.size >=
        this.maximumPendingCameras
    ) {
      return Promise.resolve({
        dropped: true,
        reason: 'capacity',
        detections: [],
      });
    }

    return new Promise(
      (resolve, reject) => {
        if (previousRequest) {
          previousRequest.resolve({
            dropped: true,
            reason: 'superseded',
            detections: [],
          });
        } else {
          this._cameraOrder.push(
            normalizedCameraId,
          );
        }

        this._pendingByCamera.set(
          normalizedCameraId,
          {
            cameraId:
              normalizedCameraId,
            frame,
            options: {
              ...options,
            },
            resolve,
            reject,
          },
        );

        this._scheduleDrain();
      },
    );
  }

  cancelCamera(cameraId) {
    if (typeof cameraId !== 'string') {
      return false;
    }

    const normalizedCameraId =
      cameraId.trim();

    const request =
      this._pendingByCamera.get(
        normalizedCameraId,
      );

    if (!request) {
      return false;
    }

    this._pendingByCamera.delete(
      normalizedCameraId,
    );

    request.resolve({
      dropped: true,
      reason: 'cancelled',
      detections: [],
    });

    return true;
  }

  close() {
    if (this._closed) {
      return;
    }

    this._closed = true;

    for (
      const request
      of this._pendingByCamera.values()
    ) {
      request.resolve({
        dropped: true,
        reason: 'closed',
        detections: [],
      });
    }

    this._pendingByCamera.clear();
    this._cameraOrder = [];
  }

  _scheduleDrain() {
    if (
      this._drainScheduled ||
      this._running ||
      this._closed
    ) {
      return;
    }

    this._drainScheduled = true;

    queueMicrotask(() => {
      this._drainScheduled = false;
      this._drain();
    });
  }

  async _drain() {
    if (
      this._running ||
      this._closed
    ) {
      return;
    }

    let request = null;

    while (
      this._cameraOrder.length > 0
    ) {
      const cameraId =
        this._cameraOrder.shift();

      const candidate =
        this._pendingByCamera.get(
          cameraId,
        );

      if (!candidate) {
        continue;
      }

      this._pendingByCamera.delete(
        cameraId,
      );

      request = candidate;
      break;
    }

    if (!request) {
      return;
    }

    this._running = true;

    this._runningCameraId =
      request.cameraId;

    try {
      const detections =
        await this.detector
          .detectBgrFrame(
            request.frame,
            request.options,
          );

      if (!Array.isArray(detections)) {
        throw new TypeError(
          'Detector zwrócił ' +
          'nieprawidłowy wynik.',
        );
      }

      request.resolve({
        dropped: false,
        reason: null,
        detections,
      });
    } catch (error) {
      request.reject(error);
    } finally {
      this._running = false;
      this._runningCameraId = null;

      this._scheduleDrain();
    }
  }
}

module.exports = {
  AiInferenceScheduler,
};