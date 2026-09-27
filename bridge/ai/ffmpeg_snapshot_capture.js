'use strict';

const {
  spawn,
} = require('node:child_process');

const defaultTimeoutMs =
  10000;

const defaultMaximumBytes =
  5 * 1024 * 1024;

const maximumErrorBytes =
  4096;

function buildSnapshotArguments(input) {
  const inputOptions = [];

  if (/^rtsps?:\/\//i.test(input)) {
    inputOptions.push(
      '-rtsp_transport',
      'tcp',
    );
  }

  return [
    '-hide_banner',
    '-loglevel',
    'error',
    '-nostdin',
    ...inputOptions,
    '-i',
    input,
    '-map',
    '0:v:0',
    '-frames:v',
    '1',
    '-an',
    '-sn',
    '-dn',
    '-c:v',
    'mjpeg',
    '-q:v',
    '2',
    '-f',
    'image2pipe',
    'pipe:1',
  ];
}

function isJpeg(buffer) {
  return (
    Buffer.isBuffer(buffer) &&
    buffer.length >= 4 &&
    buffer[0] === 0xff &&
    buffer[1] === 0xd8 &&
    buffer[buffer.length - 2] === 0xff &&
    buffer[buffer.length - 1] === 0xd9
  );
}

function safeFfmpegError(chunks) {
  if (chunks.length === 0) {
    return '';
  }

  return Buffer
    .concat(chunks)
    .toString('utf8')
    .replace(
      /\b[a-z][a-z0-9+.-]*:\/\/[^\s'"]+/gi,
      '[adres źródła ukryty]',
    )
    .replace(
      /\b(Bearer|Basic)\s+\S+/gi,
      '$1 ***',
    )
    .replace(
      /\s+/g,
      ' ',
    )
    .trim()
    .slice(0, 500);
}

function validateOptions({
  input,
  timeoutMs,
  maximumBytes,
  ffmpegPath,
  spawnProcess,
}) {
  if (
    typeof input !== 'string' ||
    !input.trim() ||
    input.includes('\0')
  ) {
    throw new TypeError(
      'Źródło snapshotu jest nieprawidłowe.',
    );
  }

  if (
    !Number.isInteger(timeoutMs) ||
    timeoutMs < 1 ||
    timeoutMs > 60000
  ) {
    throw new RangeError(
      'Timeout snapshotu jest nieprawidłowy.',
    );
  }

  if (
    !Number.isInteger(maximumBytes) ||
    maximumBytes < 4 ||
    maximumBytes >
      50 * 1024 * 1024
  ) {
    throw new RangeError(
      'Limit rozmiaru snapshotu jest nieprawidłowy.',
    );
  }

  if (
    typeof ffmpegPath !== 'string' ||
    !ffmpegPath.trim() ||
    ffmpegPath.includes('\0')
  ) {
    throw new TypeError(
      'Ścieżka FFmpeg jest nieprawidłowa.',
    );
  }

  if (typeof spawnProcess !== 'function') {
    throw new TypeError(
      'Funkcja uruchamiająca FFmpeg jest nieprawidłowa.',
    );
  }
}

function captureJpegSnapshot({
  input,
  timeoutMs =
    defaultTimeoutMs,
  maximumBytes =
    defaultMaximumBytes,
  ffmpegPath =
    process.env.SAFEHOOD_FFMPEG_PATH ||
    'ffmpeg',
  spawnProcess =
    spawn,
} = {}) {
  validateOptions({
    input,
    timeoutMs,
    maximumBytes,
    ffmpegPath,
    spawnProcess,
  });

  const normalizedInput =
    input.trim();

  const argumentsList =
    buildSnapshotArguments(
      normalizedInput,
    );

  return new Promise(
    (resolve, reject) => {
      let child;

      try {
        child =
          spawnProcess(
            ffmpegPath.trim(),
            argumentsList,
            {
              windowsHide: true,
              stdio: [
                'ignore',
                'pipe',
                'pipe',
              ],
            },
          );
      } catch (error) {
        reject(
          new Error(
            'Nie udało się uruchomić FFmpeg.',
            {
              cause: error,
            },
          ),
        );

        return;
      }

      if (
        !child ||
        typeof child.once !==
          'function' ||
        typeof child.kill !==
          'function' ||
        !child.stdout ||
        typeof child.stdout.on !==
          'function' ||
        !child.stderr ||
        typeof child.stderr.on !==
          'function'
      ) {
        reject(
          new Error(
            'Proces FFmpeg jest nieprawidłowy.',
          ),
        );

        return;
      }

      const outputChunks = [];
      const errorChunks = [];

      let outputBytes = 0;
      let errorBytes = 0;
      let settled = false;
      let timer = null;

      const finish = (
        error,
        snapshot = null,
      ) => {
        if (settled) {
          return;
        }

        settled = true;

        if (timer) {
          clearTimeout(timer);
        }

        if (error) {
          reject(error);
          return;
        }

        resolve(snapshot);
      };

      child.stdout.on(
        'data',
        (chunk) => {
          if (settled) {
            return;
          }

          const data =
            Buffer.isBuffer(chunk)
              ? chunk
              : Buffer.from(chunk);

          if (
            outputBytes +
              data.length >
            maximumBytes
          ) {
            finish(
              new Error(
                'Snapshot przekroczył dozwolony rozmiar.',
              ),
            );

            try {
              child.kill('SIGKILL');
            } catch (_) {
              // Proces został już zakończony.
            }

            return;
          }

          outputChunks.push(data);
          outputBytes += data.length;
        },
      );

      child.stderr.on(
        'data',
        (chunk) => {
          if (
            settled ||
            errorBytes >=
              maximumErrorBytes
          ) {
            return;
          }

          const data =
            Buffer.isBuffer(chunk)
              ? chunk
              : Buffer.from(chunk);

          const remaining =
            maximumErrorBytes -
            errorBytes;

          const limited =
            data.length > remaining
              ? data.subarray(
                  0,
                  remaining,
                )
              : data;

          errorChunks.push(limited);
          errorBytes += limited.length;
        },
      );

      child.once(
        'error',
        (error) => {
          finish(
            new Error(
              'Nie udało się uruchomić FFmpeg.',
              {
                cause: error,
              },
            ),
          );
        },
      );

      child.once(
        'close',
        (code, signal) => {
          if (settled) {
            return;
          }

          if (code !== 0) {
            const details =
              safeFfmpegError(
                errorChunks,
              );

            const exitDescription =
              code === null
                ? `sygnał ${signal || '-'}`
                : `kod ${code}`;

            finish(
              new Error(
                'FFmpeg nie utworzył snapshotu ' +
                `(${exitDescription})` +
                (
                  details
                    ? `: ${details}`
                    : '.'
                ),
              ),
            );

            return;
          }

          const snapshot =
            Buffer.concat(
              outputChunks,
              outputBytes,
            );

          if (!isJpeg(snapshot)) {
            finish(
              new Error(
                'FFmpeg zwrócił nieprawidłowy JPEG.',
              ),
            );

            return;
          }

          finish(
            null,
            snapshot,
          );
        },
      );

      timer = setTimeout(
        () => {
          finish(
            new Error(
              'Przekroczono czas wykonywania snapshotu.',
            ),
          );

          try {
            child.kill('SIGKILL');
          } catch (_) {
            // Proces został już zakończony.
          }
        },
        timeoutMs,
      );
    },
  );
}

module.exports = {
  buildSnapshotArguments,
  captureJpegSnapshot,
  isJpeg,
};