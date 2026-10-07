'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const {AiEventOutbox} = require('../ai/event_outbox');
const {createFaultProxy} = require('../../tools/bridge_ai_outbox_fault_proxy');

async function listen(server) {
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return server.address().port;
}

async function close(server) {
  server.closeAllConnections();
  await new Promise((resolve) => server.close(resolve));
}

test('utrata odpowiedzi przez HTTP powoduje retry z tym samym UUID', {timeout: 5000}, async (t) => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'safehood-http-outbox-'));
  const requests = [];
  const receipts = new Set();
  const upstream = http.createServer(async (request, response) => {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const event = JSON.parse(Buffer.concat(chunks));
    requests.push(event);
    const duplicate = receipts.has(event.externalEventId);
    receipts.add(event.externalEventId);
    response.writeHead(200, {'Content-Type': 'application/json'});
    response.end(JSON.stringify({ok: true, eventId: 'saved-event', type: event.type,
      externalEventId: event.externalEventId, merged: false, occurrenceCount: 1,
      snapshotRequired: false, duplicate}));
  });
  const upstreamPort = await listen(upstream);
  const proxy = createFaultProxy({upstreamPort, log: () => {}});
  const port = await listen(proxy);
  let delivered;
  const completed = new Promise((resolve) => { delivered = resolve; });
  const outbox = new AiEventOutbox({
    directory, retryDelaysMs: [1],
    deliver: async (payload, signal) => {
      const response = await fetch(`http://127.0.0.1:${port}/ingestBridgeCameraEvent`, {
        method: 'POST', body: JSON.stringify(payload), signal,
      });
      return response.json();
    },
    onDelivered: delivered,
  });
  t.after(async () => {
    await outbox.close(); await close(proxy); await close(upstream);
    await fs.rm(directory, {recursive: true, force: true});
  });
  await fetch(`http://127.0.0.1:${port}/__safehood_outbox_fault?mode=drop_ack`);
  await outbox.enqueue({cameraId: 'camera-1', type: 'person', source: 'local-ai',
    confidence: 0.9, occurredAt: '2026-10-06T19:00:00.000Z'});
  const result = await completed;
  assert.equal(requests.length, 2);
  assert.deepEqual(requests[0], requests[1]);
  assert.equal(receipts.size, 1);
  assert.equal(result.result.duplicate, true);
  assert.equal(outbox.pendingCount, 0);
});

test('blokada testowa dotyczy ingestu i przepuszcza konfigurację', async (t) => {
  let received = 0;
  const upstream = http.createServer((_request, response) => {
    received += 1;
    response.writeHead(200, {'Content-Type': 'application/json'});
    response.end('{"cameras":[]}');
  });
  const upstreamPort = await listen(upstream);
  const proxy = createFaultProxy({upstreamPort, log: () => {}});
  const port = await listen(proxy);
  t.after(async () => { await close(proxy); await close(upstream); });
  await fetch(`http://127.0.0.1:${port}/__safehood_outbox_fault?mode=block`);
  const rejected = await fetch(`http://127.0.0.1:${port}/ingestBridgeCameraEvent`, {method: 'POST'});
  assert.equal(rejected.status, 503);
  const configuration = await fetch(`http://127.0.0.1:${port}/getBridgeConfiguration`, {method: 'POST'});
  assert.equal(configuration.status, 200);
  assert.equal(received, 1);
});
