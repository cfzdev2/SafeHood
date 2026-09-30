"use strict";

const assert = require("node:assert/strict");

const {
  test,
} = require("node:test");

const {
  CameraEventSnapshotError,
  buildSnapshotPath,
  decodeJpegBase64,
  isJpeg,
  maximumSnapshotBytes,
  normalizeDocumentId,
} = require(
    "../camera_event_snapshot",
);

test(
    "dekoduje poprawne zdjęcie JPEG",
    () => {
      const expected =
          Buffer.from([
            0xff,
            0xd8,
            0x01,
            0x02,
            0xff,
            0xd9,
          ]);

      const result =
          decodeJpegBase64(
              expected.toString("base64"),
          );

      assert.deepEqual(
          result,
          expected,
      );
    },
);

test(
    "rozpoznaje poprawny JPEG",
    () => {
      assert.equal(
          isJpeg(
              Buffer.from([
                0xff,
                0xd8,
                0xff,
                0xd9,
              ]),
          ),
          true,
      );

      assert.equal(
          isJpeg(
              Buffer.from("nie-jpeg"),
          ),
          false,
      );
    },
);

test(
    "odrzuca nieprawidłowy Base64",
    () => {
      assert.throws(
          () => {
            decodeJpegBase64(
                "to nie jest base64!",
            );
          },
          (error) => {
            assert.equal(
                error instanceof
                  CameraEventSnapshotError,
                true,
            );

            assert.equal(
                error.code,
                "invalid-base64",
            );

            return true;
          },
      );
    },
);

test(
    "odrzuca dane bez formatu JPEG",
    () => {
      const value =
          Buffer.from(
              "zwykły plik",
          ).toString("base64");

      assert.throws(
          () => {
            decodeJpegBase64(value);
          },
          (error) => {
            assert.equal(
                error.code,
                "invalid-jpeg",
            );

            return true;
          },
      );
    },
);

test(
    "odrzuca zdjęcie przekraczające limit",
    () => {
      const value =
          Buffer.from([
            0xff,
            0xd8,
            0x01,
            0xff,
            0xd9,
          ]).toString("base64");

      assert.throws(
          () => {
            decodeJpegBase64(
                value,
                {
                  maximumBytes: 4,
                },
            );
          },
          (error) => {
            assert.equal(
                error.code,
                "too-large",
            );

            return true;
          },
      );
    },
);

test(
    "buduje prywatną ścieżkę zdjęcia",
    () => {
      assert.equal(
          buildSnapshotPath(
              "owner-1",
              "event-1",
          ),
          "users/owner-1/" +
            "cameraEvents/event-1/" +
            "snapshot.jpg",
      );
    },
);

test(
    "odrzuca nieprawidłowe identyfikatory",
    () => {
      assert.throws(
          () => {
            normalizeDocumentId(
                "event/1",
                "eventId",
            );
          },
          (error) => {
            assert.equal(
                error.code,
                "invalid-id",
            );

            return true;
          },
      );

      assert.throws(
          () => {
            normalizeDocumentId(
                "",
                "eventId",
            );
          },
          CameraEventSnapshotError,
      );
    },
);

test(
    "akceptuje duże zdjęcia do limitu 5 MiB włącznie",
    () => {
      for (const size of [
        maximumSnapshotBytes - 1,
        maximumSnapshotBytes,
      ]) {
        const value = Buffer.alloc(size, 0x01);
        value[0] = 0xff;
        value[1] = 0xd8;
        value[size - 2] = 0xff;
        value[size - 1] = 0xd9;

        const decoded = decodeJpegBase64(
            value.toString("base64"),
        );

        assert.equal(decoded.length, size);
      }
    },
);

test(
    "odrzuca zdjęcia przekraczające limit 5 MiB",
    () => {
      for (const extraBytes of [1, 3]) {
        const size = maximumSnapshotBytes + extraBytes;
        const value = Buffer.alloc(size, 0x01);
        value[0] = 0xff;
        value[1] = 0xd8;
        value[size - 2] = 0xff;
        value[size - 1] = 0xd9;

        assert.throws(
            () => decodeJpegBase64(value.toString("base64")),
            (error) =>
              error instanceof CameraEventSnapshotError &&
              error.code === "too-large",
        );
      }
    },
);

test(
    "odrzuca nieprawidłowe dopełnienie Base64",
    () => {
      for (const value of [
        "A===",
        "====",
        "AA=A",
        "AA==AAAA",
      ]) {
        assert.throws(
            () => decodeJpegBase64(value),
            (error) =>
              error instanceof CameraEventSnapshotError &&
              error.code === "invalid-base64",
        );
      }
    },
);
