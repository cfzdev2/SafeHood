'use strict';

// Lokalny test awarii samego ingestu; konfiguracja i heartbeat przechodzą dalej.
const http = require('node:http');

function createFaultProxy({upstreamPort = 5001, log = console.log} = {}) {
  let mode = 'normal';
  let forwarded = 0;
  let dropped = 0;
  const server = http.createServer((request, response) => {
    const url = new URL(request.url, 'http://127.0.0.1');
    if (url.pathname === '/__safehood_outbox_fault') {
      const next = url.searchParams.get('mode');
      if (next && !['normal', 'block', 'drop_ack'].includes(next)) {
        response.writeHead(400).end('Nieprawidłowy tryb.');
        return;
      }
      if (next) mode = next;
      response.writeHead(200, {'Content-Type': 'application/json'});
      response.end(JSON.stringify({mode, forwarded, dropped}));
      return;
    }

    const ingest = url.pathname.endsWith('/ingestBridgeCameraEvent');
    if (ingest && mode === 'block') {
      request.resume();
      response.writeHead(503, {'Content-Type': 'application/json'});
      response.end(JSON.stringify({error: 'Kontrolowana awaria ingestu.'}));
      return;
    }
    if (ingest) forwarded += 1;
    const upstream = http.request({
      hostname: '127.0.0.1', port: upstreamPort, method: request.method,
      path: request.url,
      headers: {...request.headers, host: `127.0.0.1:${upstreamPort}`},
    }, (incoming) => {
      if (ingest && mode === 'drop_ack' && incoming.statusCode === 200) {
        mode = 'normal';
        incoming.resume();
        incoming.once('end', () => {
          dropped += 1;
          log('[OUTBOX TEST] Backend przyjął zdarzenie; przerwano odpowiedź.');
          response.destroy();
        });
        return;
      }
      response.writeHead(incoming.statusCode, incoming.headers);
      incoming.pipe(response);
    });
    upstream.setTimeout(25000, () => upstream.destroy(new Error('Timeout testu.')));
    upstream.once('error', () => {
      if (response.headersSent) response.destroy();
      else {
        response.writeHead(503, {'Content-Type': 'application/json'});
        response.end(JSON.stringify({error: 'Lokalny backend niedostępny.'}));
      }
    });
    request.once('aborted', () => upstream.destroy());
    request.pipe(upstream);
  });
  return server;
}

if (require.main === module) {
  const server = createFaultProxy();
  server.listen(15001, '127.0.0.1', () => {
    console.log('[OUTBOX TEST] Proxy 127.0.0.1:15001 -> 127.0.0.1:5001');
    console.log('[OUTBOX TEST] Sterowanie: /__safehood_outbox_fault?mode=block|normal|drop_ack');
  });
  server.once('error', (error) => {
    console.error(`[OUTBOX TEST] ${error.message}`);
    process.exitCode = 1;
  });
}

module.exports = {createFaultProxy};
