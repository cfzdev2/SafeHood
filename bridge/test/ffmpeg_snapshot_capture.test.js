'use strict';

const assert =
  require('node:assert/strict');

const {
  EventEmitter,
} = require('node:events');

const {
  PassThrough,
} = require('node:stream');

const {
  test,
} = require('node:test');

const {
  buildSnapshotArguments,
  captureJpegSnapshot,
} = require(
  '../ai/ffmpeg_snapshot_capture'
);

const validJpeg =
  Buffer.from([
    0xff,
    0xd8,
    0xff,
    0xd9,
  ]);

function createFakeChild() {
  const child =
    new EventEmitter();

  child.stdout =
    new PassThrough();

  child.stderr =
    new PassThrough();

  child.killedSignals = [];

  child.kill = (signal) => {
    child.killedSignals.push(
      signal,
    );

    return true;
  };

  return child;
}

test(
  'dodaje transport TCP dla strumienia RTSP',
  () => {
    const args =
      buildSnapshotArguments(
        'rtsp://camera.local/live',
      );

    const inputIndex =
      args.indexOf('-i');

    assert.ok(inputIndex > 2);

    assert.deepEqual(
      args.slice(
        inputIndex - 2,
        inputIndex,
      ),
      [
        '-rtsp_transport',
        'tcp',
      ],
    );

    assert.equal(
      args[inputIndex + 1],
      'rtsp://camera.local/live',
    );

    assert.ok(
      args.includes('-frames:v'),
    );

    assert.ok(
      args.includes('image2pipe'),
    );
  },
);

test(
  'nie dodaje transportu RTSP dla pliku',
  () => {
    const args =
      buildSnapshotArguments(
        'recording.mp4',
      );

    assert.equal(
      args.includes(
        '-rtsp_transport',
      ),
      false,
    );
  },
);

test(
  'zwraca poprawny JPEG z procesu FFmpeg',
  async () => {
    const child =
      createFakeChild();

    let spawnCall = null;

    const spawnProcess = (
      command,
      args,
      options,
    ) => {
      spawnCall = {
        command,
        args,
        options,
      };

      queueMicrotask(
        () => {
          child.stdout.end(
            validJpeg,
          );

          child.stderr.end();

          child.emit(
            'close',
            0,
            null,
          );
        },
      );

      return child;
    };

    const snapshot =
      await captureJpegSnapshot({
        input:
          'rtsp://camera.local/live',

        ffmpegPath:
          'custom-ffmpeg',

        spawnProcess,
      });

    assert.deepEqual(
      snapshot,
      validJpeg,
    );

    assert.equal(
      spawnCall.command,
      'custom-ffmpeg',
    );

    assert.deepEqual(
      spawnCall.options.stdio,
      [
        'ignore',
        'pipe',
        'pipe',
      ],
    );

    assert.equal(
      spawnCall.options.windowsHide,
      true,
    );
  },
);

test(
  'ukrywa adres źródła w błędzie FFmpeg',
  async () => {
    const child =
      createFakeChild();

    const spawnProcess = () => {
      queueMicrotask(
        () => {
          child.stderr.end(
            'rtsp://user:secret@camera.local/live: ' +
            'Connection refused',
          );

          child.stdout.end();

          child.emit(
            'close',
            1,
            null,
          );
        },
      );

      return child;
    };

    await assert.rejects(
      captureJpegSnapshot({
        input:
          'rtsp://user:secret@camera.local/live',

        spawnProcess,
      }),
      (error) => {
        assert.match(
          error.message,
          /adres źródła ukryty/,
        );

        assert.doesNotMatch(
          error.message,
          /secret/,
        );

        assert.doesNotMatch(
          error.message,
          /camera\.local/,
        );

        return true;
      },
    );
  },
);

test(
  'odrzuca nieprawidłowy obraz',
  async () => {
    const child =
      createFakeChild();

    const spawnProcess = () => {
      queueMicrotask(
        () => {
          child.stdout.end(
            Buffer.from(
              'not-a-jpeg',
            ),
          );

          child.stderr.end();

          child.emit(
            'close',
            0,
            null,
          );
        },
      );

      return child;
    };

    await assert.rejects(
      captureJpegSnapshot({
        input:
          'recording.mp4',

        spawnProcess,
      }),
      /nieprawidłowy JPEG/,
    );
  },
);

test(
  'odrzuca snapshot przekraczający limit',
  async () => {
    const child =
      createFakeChild();

    const spawnProcess = () => {
      queueMicrotask(
        () => {
          child.stdout.write(
            Buffer.from([
              0xff,
              0xd8,
              1,
              2,
              0xff,
              0xd9,
            ]),
          );
        },
      );

      return child;
    };

    await assert.rejects(
      captureJpegSnapshot({
        input:
          'recording.mp4',

        maximumBytes: 4,
        spawnProcess,
      }),
      /przekroczył dozwolony rozmiar/,
    );

    assert.deepEqual(
      child.killedSignals,
      [
        'SIGKILL',
      ],
    );
  },
);

test(
  'zatrzymuje FFmpeg po przekroczeniu czasu',
  async () => {
    const child =
      createFakeChild();

    const spawnProcess =
      () => child;

    await assert.rejects(
      captureJpegSnapshot({
        input:
          'recording.mp4',

        timeoutMs: 10,
        spawnProcess,
      }),
      /Przekroczono czas/,
    );

    assert.deepEqual(
      child.killedSignals,
      [
        'SIGKILL',
      ],
    );
  },
);

test(
  'odrzuca nieprawidłowe źródło',
  () => {
    assert.throws(
      () =>
        captureJpegSnapshot({
          input: '',
        }),
      /Źródło snapshotu/,
    );

    assert.throws(
      () =>
        captureJpegSnapshot({
          input:
            'rtsp://camera\0/live',
        }),
      /Źródło snapshotu/,
    );
  },
);

test('anulowanie przed startem nie uruchamia FFmpeg', async () => {
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(captureJpegSnapshot({
    input: 'recording.mp4',
    signal: controller.signal,
    spawnProcess: () => assert.fail('Nie wolno uruchomić procesu.'),
  }), /Anulowano/);
});

test('anulowanie aktywnego snapshotu zatrzymuje FFmpeg', async () => {
  const controller = new AbortController();
  const child = createFakeChild();
  const capture = captureJpegSnapshot({
    input: 'recording.mp4',
    signal: controller.signal,
    spawnProcess: () => child,
  });
  controller.abort();
  await assert.rejects(capture, /Anulowano/);
  assert.deepEqual(child.killedSignals, ['SIGKILL']);
  child.emit('close', 0, null);
});
