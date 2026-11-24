'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {CameraFrameCache} = require('../camera_frame_cache');
const {IncidentLivePublisher} = require('../incident_live_publisher');
const sessionId = 'a'.repeat(32);
const instruction = (now) => ({sessionId, incidentId: 'report', cameraId: 'camera',
  expiresAtMillis: now + 600000});

test('report publishing needs fresh frames and expires without owner-phone calls', async () => {
  let now = Date.now();
  const cache = new CameraFrameCache({now: () => now});
  const sent = [];
  const publisher = new IncidentLivePublisher({frameCache: cache, now: () => now,
    publish: async (frame) => sent.push(frame)});
  publisher.sync([instruction(now)]);
  assert.equal(sent.length, 0);
  cache.preview('camera', Buffer.from([255, 216, 1, 2, 255, 217]));
  const session = publisher.sessions.get(sessionId);
  clearTimeout(session.timer);
  await publisher._tick(session);
  assert.equal(sent.length, 1);
  assert.equal(sent[0].incidentId, 'report');
  now += 4000;
  clearTimeout(session.timer);
  await publisher._tick(session);
  assert.equal(sent.length, 1);
  now = session.expiresAtMillis + 1;
  clearTimeout(session.timer);
  await publisher._tick(session);
  assert.equal(publisher.sessions.size, 0);
  publisher.close();
});

test('revoking a share aborts its upload and a late reply cannot restart it', async () => {
  const cache = new CameraFrameCache();
  cache.preview('camera', Buffer.from([255, 216, 1, 2, 255, 217]));
  let reply;
  let signal;
  const publisher = new IncidentLivePublisher({frameCache: cache,
    publish: (_, value) => { signal = value; return new Promise((r) => { reply = r; }); }});
  publisher.sync([instruction(Date.now())]);
  publisher.sync([]);
  assert.equal(signal.aborted, true);
  reply();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(publisher.sessions.size, 0);
  publisher.close();
});
