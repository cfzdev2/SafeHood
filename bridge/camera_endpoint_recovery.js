'use strict';

const dgram = require('node:dgram');
const os = require('node:os');
const {randomUUID} = require('node:crypto');

function deviceIdentity(value) {
  const match = /^(?:urn:)?(?:uuid:)?([a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12})$/i
    .exec(typeof value === 'string' ? value.trim() : '');
  return match ? match[1].toLowerCase() : null;
}

function privateEndpoint(value) {
  try {
    const uri = new URL(value);
    const parts = uri.hostname.split('.').map(Number);
    const local = parts.length === 4 && parts.every((part) => Number.isInteger(part) &&
      part >= 0 && part <= 255) && (parts[0] === 10 ||
      (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) ||
      (parts[0] === 192 && parts[1] === 168));
    return local && ['http:', 'https:'].includes(uri.protocol) &&
      !uri.username && !uri.password && !uri.search && !uri.hash &&
      uri.pathname.length <= 256 ? uri : null;
  } catch (_) { return null; }
}

function matchingEndpoints(xml, identity, messageId) {
  if (typeof xml !== 'string' || xml.length > 65536 || !deviceIdentity(identity)) return [];
  const relates = /<(?:[\w-]+:)?RelatesTo\b[^>]*>([^<]+)</i.exec(xml)?.[1]?.trim();
  if (relates !== `uuid:${messageId}`) return [];
  const endpoints = [];
  for (const [, match] of xml.matchAll(/<(?:[\w-]+:)?ProbeMatch\b[^>]*>([\s\S]*?)<\/(?:[\w-]+:)?ProbeMatch>/gi)) {
    const address = /<(?:[\w-]+:)?Address\b[^>]*>([^<]+)</i.exec(match)?.[1];
    if (deviceIdentity(address) !== deviceIdentity(identity)) continue;
    const values = /<(?:[\w-]+:)?XAddrs\b[^>]*>([^<]+)</i.exec(match)?.[1];
    for (const value of (values || '').trim().split(/\s+/).slice(0, 8)) {
      const endpoint = privateEndpoint(value);
      if (endpoint) endpoints.push(endpoint.toString());
    }
  }
  return endpoints;
}

function discoverEndpoint(identity, {signal, timeoutMs = 1800} = {}) {
  if (!deviceIdentity(identity) || signal?.aborted) return Promise.resolve(null);
  const messageId = randomUUID();
  const body = Buffer.from(`<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:a="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"><s:Header><a:MessageID>uuid:${messageId}</a:MessageID><a:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</a:To><a:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</a:Action></s:Header><s:Body><d:Probe/></s:Body></s:Envelope>`);
  return new Promise((resolve) => {
    const socket = dgram.createSocket({type: 'udp4', reuseAddr: true});
    const candidates = new Set();
    let ended = false;
    const finish = () => {
      if (ended) return;
      ended = true;
      clearTimeout(timer);
      signal?.removeEventListener('abort', finish);
      try { socket.close(); } catch (_) {}
      // Conflicting answers never change a camera's saved address.
      const values = [...candidates];
      const hosts = new Set(values.map((value) => new URL(value).hostname));
      resolve(!signal?.aborted && hosts.size === 1 ? values[0] : null);
    };
    const timer = setTimeout(finish, Math.min(3000, Math.max(100, timeoutMs)));
    signal?.addEventListener('abort', finish, {once: true});
    socket.on('error', finish);
    socket.on('message', (bytes) => {
      for (const endpoint of matchingEndpoints(bytes.toString('utf8'), identity, messageId)) {
        if (candidates.size < 16) candidates.add(endpoint);
      }
    });
    socket.bind(0, async () => {
      const interfaces = Object.values(os.networkInterfaces()).flat().filter((entry) =>
        entry && entry.family === 'IPv4' && !entry.internal &&
        privateEndpoint(`http://${entry.address}/`)).slice(0, 8);
      for (const entry of interfaces) {
        if (ended) return;
        try {
          socket.setMulticastInterface(entry.address);
          await new Promise((done) => socket.send(body, 3702, '239.255.255.250', done));
        } catch (_) {}
      }
    });
  });
}

class CameraEndpointRecovery {
  constructor({discover = discoverEndpoint, now = Date.now} = {}) {
    Object.assign(this, {discover, now});
    this.attempts = new Map();
  }

  async recover(camera, signal) {
    const identity = deviceIdentity(camera.onvifDeviceId);
    if (!identity || signal?.aborted) return null;
    const previous = this.attempts.get(camera.id);
    if (previous && this.now() - previous.at < 30000) return null;
    this.attempts.set(camera.id, {at: this.now()});
    const value = await this.discover(identity, {signal});
    const endpoint = privateEndpoint(value);
    if (!endpoint || signal?.aborted || endpoint.hostname === camera.ipAddress) return null;
    return {ipAddress: endpoint.hostname, onvifServiceUrl: endpoint.toString()};
  }
}

module.exports = {CameraEndpointRecovery, deviceIdentity, privateEndpoint, matchingEndpoints};
