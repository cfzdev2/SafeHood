'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {CameraEndpointRecovery, deviceIdentity, privateEndpoint, matchingEndpoints} =
  require('../camera_endpoint_recovery');
const id = '12345678-1234-1234-1234-123456789abc';
const reply = (identity, address, message = 'probe') => `<Envelope><RelatesTo>uuid:${message}</RelatesTo><ProbeMatch><EndpointReference><Address>urn:uuid:${identity}</Address></EndpointReference><XAddrs>${address}</XAddrs></ProbeMatch></Envelope>`;

test('endpoint recovery matches a stable device and its probe, never its name or nearest IP', () => {
  assert.equal(deviceIdentity('NVT'), null);
  assert.equal(deviceIdentity('onvif-192.168.1.9'), null);
  assert.equal(deviceIdentity(`urn:uuid:${id}`), id);
  assert.equal(privateEndpoint('https://example.com/onvif'), null);
  assert.equal(privateEndpoint('http://user:pass@192.168.1.12/onvif'), null);
  const endpoint = 'http://192.168.1.12:8899/onvif/device_service';
  assert.deepEqual(matchingEndpoints(reply(id, endpoint), id, 'probe'), [endpoint]);
  assert.deepEqual(matchingEndpoints(reply(id, endpoint), id, 'different-probe'), []);
  assert.deepEqual(matchingEndpoints(reply('aaaaaaaa-1234-1234-1234-123456789abc',
    endpoint), id, 'probe'), []);
});

test('unknown cameras do not trigger discovery and failed recovery is rate limited', async () => {
  let calls = 0;
  let now = 100000;
  const recovery = new CameraEndpointRecovery({now: () => now,
    discover: async () => { calls++; return 'http://192.168.1.12:8899/onvif/device_service'; }});
  const camera = {id: 'robot', ipAddress: '192.168.1.9'};
  assert.equal(await recovery.recover(camera), null);
  assert.equal(calls, 0);
  camera.onvifDeviceId = id;
  assert.equal((await recovery.recover(camera)).ipAddress, '192.168.1.12');
  assert.equal(await recovery.recover(camera), null);
  assert.equal(calls, 1);
  now += 31000;
  assert.equal(await recovery.recover(camera, AbortSignal.abort()), null);
  assert.equal(calls, 1);
});
