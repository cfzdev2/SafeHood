'use strict';

const {
  spawn,
} = require('node:child_process');

const frameWidth = 416;
const frameHeight = 416;
const frameChannels = 3;

const frameByteLength =
  frameWidth *
  frameHeight *
  frameChannels;

class FfmpegFrameSource {
  constructor({
    input,
    onFrame,
    onError = () => {},
    onExit = () => {},
    framesPerSecond = 2,
    realtimeInput = false,
    ffmpegPath =
      process.env.SAFEHOOD_FFMPEG_PATH ||
      'ffmpeg',
  }) {
    if (
      typeof input !== 'string' ||
      !input.trim() ||
      input.includes('\0')
    ) {
      throw new TypeError(
        'Źródło obrazu jest nieprawidłowe.',
      );
    }

    if (typeof onFrame !== 'function') {
      throw new TypeError(
        'onFrame musi być funkcją.',
      );
    }

    if (
      typeof onError !== 'function' ||
      typeof onExit !== 'function'
    ) {
      throw new TypeError(
        'Callback musi być funkcją.',
      );
    }

    if (
      !Number.isFinite(framesPerSecond) ||
      framesPerSecond <= 0 ||
      framesPerSecond > 30
    ) {
      throw new RangeError(
        'Nieprawidłowa liczba klatek na sekundę.',
      );
    }

    this.input = input.trim();
    this.onFrame = onFrame;
    this.onError = onError;
    this.onExit = onExit;
    this.framesPerSecond =
      framesPerSecond;
    this.realtimeInput =
      realtimeInput === true;
    this.ffmpegPath = ffmpegPath;

    this._child = null;
    this._buffer = Buffer.alloc(0);
    this._frameRunning = false;
    this._pendingFrame = null;
    this._stopping = false;
    this._exitInfo = null;
    this._exitDelivered = false;
  }

  get isRunning() {
    return this._child !== null;
  }

  start() {
    if (this._child) {
      throw new Error(
        'FFmpeg jest już uruchomiony.',
      );
    }

    this._buffer = Buffer.alloc(0);
    this._pendingFrame = null;
    this._stopping = false;
    this._exitInfo = null;
    this._exitDelivered = false;

    const inputOptions = [];

    if (this.realtimeInput) {
      inputOptions.push('-re');
    }

    if (/^rtsps?:\/\//i.test(this.input)) {
      inputOptions.push(
        '-rtsp_transport',
        'tcp',
      );
    }

    const filter =
      `fps=${this.framesPerSecond},` +
      'scale=416:416:' +
      'force_original_aspect_ratio=decrease,' +
      'pad=416:416:0:0:color=0x727272';

    const args = [
      '-hide_banner',
      '-loglevel',
      'error',
      '-nostdin',
      ...inputOptions,
      '-i',
      this.input,
      '-an',
      '-sn',
      '-dn',
      '-vf',
      filter,
      '-pix_fmt',
      'bgr24',
      '-f',
      'rawvideo',
      'pipe:1',
    ];

    const child = spawn(
      this.ffmpegPath,
      args,
      {
        shell: false,
        windowsHide: true,
        stdio: [
          'ignore',
          'pipe',
          'pipe',
        ],
      },
    );

    this._child = child;

    child.stdout.on(
      'data',
      (chunk) => {
        this._consumeChunk(chunk);
      },
    );

    // Opróżniamy stderr, ale nie zapisujemy go
    // w logach, ponieważ może zawierać URI.
    child.stderr.resume();

    let processErrorReported = false;

    child.once(
      'error',
      () => {
        processErrorReported = true;

        if (!this._stopping) {
          this._reportError(
            new Error(
              'Nie udało się uruchomić FFmpeg.',
            ),
          );
        }
      },
    );

    child.once(
      'close',
      (code, signal) => {
        if (this._child === child) {
          this._child = null;
        }

        if (
          !this._stopping &&
          code !== 0 &&
          !processErrorReported
        ) {
          this._reportError(
            new Error(
              'FFmpeg zakończył pracę z błędem.',
            ),
          );
        }

        this._exitInfo = {
          code,
          signal,
          stopped: this._stopping,
        };

        this._deliverExitIfReady();
      },
    );

    return this;
  }

  stop() {
    this._stopping = true;
    this._pendingFrame = null;
    this._buffer = Buffer.alloc(0);

    const child = this._child;

    if (!child) {
      return Promise.resolve();
    }

    return new Promise((resolve) => {
      let finished = false;
      let forceTimer = null;

      const finish = () => {
        if (finished) {
          return;
        }

        finished = true;

        if (forceTimer) {
          clearTimeout(forceTimer);
        }

        resolve();
      };

      child.once('close', finish);

      try {
        child.kill('SIGTERM');
      } catch (_) {
        finish();
        return;
      }

      forceTimer = setTimeout(
        () => {
          try {
            child.kill('SIGKILL');
          } catch (_) {
            // Proces został już zakończony.
          }
        },
        2000,
      );

      forceTimer.unref();
    });
  }

  _consumeChunk(chunk) {
    if (this._stopping) {
      return;
    }

    const data = this._buffer.length > 0
      ? Buffer.concat([
          this._buffer,
          chunk,
        ])
      : chunk;

    let offset = 0;

    while (
      data.length - offset >=
      frameByteLength
    ) {
      const frame = Buffer.from(
        data.subarray(
          offset,
          offset + frameByteLength,
        ),
      );

      offset += frameByteLength;

      this._dispatchFrame(frame);
    }

    this._buffer = Buffer.from(
      data.subarray(offset),
    );
  }

  _dispatchFrame(frame) {
    if (this._frameRunning) {
      // Zachowujemy tylko najnowszą klatkę.
      this._pendingFrame = frame;
      return;
    }

    this._frameRunning = true;

    Promise.resolve()
      .then(() => this.onFrame(frame))
      .catch(() => {
        this._reportError(
          new Error(
            'Nie udało się przetworzyć klatki AI.',
          ),
        );
      })
      .finally(() => {
        this._frameRunning = false;

        const pendingFrame =
          this._pendingFrame;

        this._pendingFrame = null;

        if (
          pendingFrame &&
          !this._stopping
        ) {
          this._dispatchFrame(
            pendingFrame,
          );

          return;
        }

        this._deliverExitIfReady();
      });
  }

  _deliverExitIfReady() {
    if (
      !this._exitInfo ||
      this._frameRunning ||
      this._pendingFrame ||
      this._exitDelivered
    ) {
      return;
    }

    this._exitDelivered = true;

    try {
      this.onExit(this._exitInfo);
    } catch (_) {
      this._reportError(
        new Error(
          'Błąd obsługi zakończenia FFmpeg.',
        ),
      );
    }
  }

  _reportError(error) {
    try {
      this.onError(error);
    } catch (_) {
      // Callback błędu nie może zatrzymać Bridge.
    }
  }
}

module.exports = {
  FfmpegFrameSource,
  frameByteLength,
  frameHeight,
  frameWidth,
};