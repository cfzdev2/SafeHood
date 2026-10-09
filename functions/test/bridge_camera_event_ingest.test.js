"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const source = fs.readFileSync(
    path.join(__dirname, "..", "index.js"),
    "utf8",
);

// Uruchamiamy rzeczywisty handler, bez inicjalizacji Firebase
// i bez jakichkolwiek połączeń z emulatorami lub produkcją.
const readBlock = (startMarker, endMarker) => {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start);
  assert.ok(start >= 0 && end > start);
  return source.slice(start, end);
};

const handlerCode = [
  readBlock(
      "const allowedCameraEventTypes =",
      "\nconst allowedBridgeMonitoringStatuses",
  ),
  readBlock("function normalizeCameraEventType(", "\n/**"),
  readBlock("function normalizeCameraEventSource(", "\n/**"),
  readBlock("function normalizeBridgeExternalEventId(", "\n/**"),
  readBlock("exports.ingestBridgeCameraEvent =", "\n/**"),
].join("\n");

/** Błąd Firebase używany wyłącznie przez odizolowane testy. */
class TestHttpsError extends Error {
  /**
   * @param {string} code Kod błędu Firebase.
   * @param {string} message Komunikat błędu.
   */
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

const createHarness = ({
  camera = {},
  user = {},
  authenticated = true,
  cameraExists = true,
} = {}) => {
  const cameraData = {
    bridgeId: "test-bridge",
    connectionType: "onvif",
    motionDetectionEnabled: false,
    aiEnabled: true,
    aiPersonEnabled: true,
    aiVehicleEnabled: true,
    ...camera,
  };
  const userData = {localAiEnabled: true, ...user};
  const calls = [];
  const userRef = {
    get: async () => ({data: () => userData}),
    collection: (name) => {
      assert.equal(name, "cameras");
      return {
        doc: (id) => {
          assert.equal(id, "test-camera");
          return {
            get: async () => ({
              exists: cameraExists,
              data: () => cameraData,
            }),
          };
        },
      };
    },
  };
  const exported = {};

  vm.runInNewContext(handlerCode, {
    exports: exported,
    onRequest: (_options, handler) => handler,
    HttpsError: TestHttpsError,
    authenticateBridgeRequest: async () => authenticated ?
      {bridgeId: "test-bridge", ownerId: "test-owner"} : null,
    db: {
      collection: (name) => {
        assert.equal(name, "users");
        return {
          doc: (id) => {
            assert.equal(id, "test-owner");
            return userRef;
          },
        };
      },
    },
    ingestCameraEventInternal: async (input) => {
      calls.push(input);
      return {
        eventId: "test-event",
        type: input.type,
        merged: false,
        occurrenceCount: 1,
        snapshotRequired: input.source === "local-ai",
        externalEventId: input.bridgeReceipt &&
          input.bridgeReceipt.externalEventId,
      };
    },
    console: {log: () => {}, error: () => {}},
  });

  const response = {
    statusCode: null,
    body: null,
    status: (code) => {
      response.statusCode = code;
      return response;
    },
    json: (body) => {
      response.body = body;
      return response;
    },
  };

  return {
    response,
    calls,
    send: async (body = {}, method = "POST") => {
      await exported.ingestBridgeCameraEvent({
        method,
        body: {
          cameraId: "test-camera",
          type: "vehicle",
          source: "local-ai",
          ...body,
        },
      }, response);
    },
  };
};

test("przyjmuje AI mimo wyłączonego monitoringu ONVIF", async () => {
  const harness = createHarness();
  await harness.send();
  assert.equal(harness.response.statusCode, 200);
  assert.equal(harness.calls.length, 1);
  assert.equal(harness.calls[0].source, "local-ai");
  assert.equal(harness.calls[0].type, "vehicle");
  assert.equal(harness.response.body.snapshotRequired, true);
});

test("normalizuje źródło i typ przed kontrolą ustawień AI", async () => {
  const harness = createHarness();
  await harness.send({source: " LOCAL-AI ", type: " VEHICLE "});
  assert.equal(harness.response.statusCode, 200);
  assert.equal(harness.calls[0].source, "local-ai");
  assert.equal(harness.calls[0].type, "vehicle");
});

test("blokuje ONVIF przy wyłączonym monitoringu", async () => {
  const harness = createHarness();
  await harness.send({source: "onvif", type: "motion"});
  assert.equal(harness.response.statusCode, 409);
  assert.equal(harness.calls.length, 0);
});

test("monitoring ONVIF nie wymaga włączonego AI", async () => {
  const harness = createHarness({
    camera: {motionDetectionEnabled: true, aiEnabled: false},
    user: {localAiEnabled: false},
  });
  await harness.send({source: "onvif", type: "motion"});
  assert.equal(harness.response.statusCode, 200);
  assert.equal(harness.calls.length, 1);
});

for (const scenario of [
  {label: "globalne AI", user: {localAiEnabled: false}},
  {label: "AI kamery", camera: {aiEnabled: false}},
  {label: "wykrywanie pojazdów", camera: {aiVehicleEnabled: false}},
  {
    label: "wykrywanie osób",
    camera: {aiPersonEnabled: false},
    body: {type: "person"},
  },
]) {
  test(`blokuje zdarzenie, gdy wyłączone jest ${scenario.label}`, async () => {
    for (const motionDetectionEnabled of [false, true]) {
      const harness = createHarness({
        camera: {motionDetectionEnabled, ...scenario.camera},
        user: scenario.user,
      });
      await harness.send(scenario.body);
      assert.equal(harness.response.statusCode, 409);
      assert.equal(harness.calls.length, 0);
    }
  });
}

test("nie pozwala ominąć monitoringu przez source local-ai", async () => {
  const harness = createHarness();
  await harness.send({type: "motion"});
  assert.equal(harness.response.statusCode, 409);
  assert.equal(harness.calls.length, 0);
});

test("zachowuje domyślne typy AI dla starszych danych", async () => {
  const harness = createHarness({
    camera: {aiPersonEnabled: undefined, aiVehicleEnabled: undefined},
  });
  await harness.send();
  assert.equal(harness.response.statusCode, 200);
});

test("odrzuca kamerę przypisaną do innego Bridge", async () => {
  const harness = createHarness({camera: {bridgeId: "other-bridge"}});
  await harness.send();
  assert.equal(harness.response.statusCode, 403);
  assert.equal(harness.calls.length, 0);
});

test("odrzuca nieprawidłowy typ wykrycia", async () => {
  const harness = createHarness();
  await harness.send({type: "unsupported"});
  assert.equal(harness.response.statusCode, 400);
  assert.equal(harness.calls.length, 0);
});

test("wymaga uwierzytelnionego Bridge", async () => {
  const harness = createHarness({authenticated: false});
  await harness.send();
  assert.equal(harness.response.statusCode, 401);
  assert.equal(harness.calls.length, 0);
});

test("odrzuca nieistniejącą kamerę", async () => {
  const harness = createHarness({cameraExists: false});
  await harness.send();
  assert.equal(harness.response.statusCode, 404);
  assert.equal(harness.calls.length, 0);
});

test("wymaga metody POST", async () => {
  const harness = createHarness();
  await harness.send({}, "GET");
  assert.equal(harness.response.statusCode, 405);
  assert.equal(harness.calls.length, 0);
});

test("API wiąże UUID z uwierzytelnionym Bridge", async () => {
  const h = createHarness();
  const externalEventId = "11111111-1111-4111-8111-111111111111";
  await h.send({externalEventId});
  assert.equal(h.response.statusCode, 200);
  assert.equal(h.calls[0].bridgeReceipt.bridgeId, "test-bridge");
  assert.equal(h.response.body.externalEventId, externalEventId);
});

test("API przekazuje metadane AI wyłącznie do silnika backendu", async () => {
  const h = createHarness();
  const metadata = {
    schemaVersion: 1,
    className: "bus",
    detectionCount: 3,
    firstSeenAt: "2026-10-09T12:00:00.000Z",
    lastSeenAt: "2026-10-09T12:00:01.000Z",
    modelId: "yolox-nano-coco-c789161e",
  };
  await h.send({
    type: "vehicle",
    externalEventId: "11111111-1111-4111-8111-111111111111",
    aiMetadata: metadata,
  });
  assert.equal(h.response.statusCode, 200);
  assert.deepEqual(h.calls[0].aiMetadata, metadata);
});

test("API odrzuca nieprawidłowe UUID przed zapisem zdarzenia", async () => {
  const h = createHarness();
  await h.send({externalEventId: "wrong/id"});
  assert.equal(h.response.statusCode, 400);
  assert.equal(h.calls.length, 0);
});
