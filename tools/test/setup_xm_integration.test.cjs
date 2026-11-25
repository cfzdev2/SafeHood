'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');
const {setupXmIntegration} = require('../setup_xm_integration.cjs');

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'safehood-xm-'));
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  fs.mkdirSync(path.join(root, 'functions'));
  fs.mkdirSync(path.join(root, 'android'));
  fs.writeFileSync(path.join(root, '.firebaserc'), '{"projects":{"default":"demo-safehood-xm"}}');
  fs.writeFileSync(path.join(root, 'android', 'xm-sdk.properties.example'), 'enabled=false\nuuid=\n');
  return root;
}

test('configuration is idempotent and preserves the account encryption key and user settings', t => {
  const root = fixture(t);
  fs.writeFileSync(path.join(root, 'functions', '.secret.local'), 'OTHER_SECRET=keep\n');
  const first = setupXmIntegration({root});
  const key = fs.readFileSync(first.secretFile, 'utf8');
  assert.match(key.trim(), /^[a-f0-9]{64}$/);
  fs.writeFileSync(first.sdkConfig, 'enabled=true\nuuid=existing\n');
  setupXmIntegration({root});
  assert.equal(fs.readFileSync(first.secretFile, 'utf8'), key);
  assert.equal(fs.readFileSync(first.sdkConfig, 'utf8'), 'enabled=true\nuuid=existing\n');
  assert.match(fs.readFileSync(path.join(root, 'functions', '.secret.local'), 'utf8'), /OTHER_SECRET=keep/);
});

test('an existing emulator secret is adopted without generating a different key', t => {
  const root = fixture(t);
  const original = 'ab'.repeat(32);
  fs.writeFileSync(path.join(root, 'functions', '.secret.local'), `SAFEHOOD_XM_ACCOUNT_KEY=${original}\n`);
  const result = setupXmIntegration({root});
  assert.equal(fs.readFileSync(result.secretFile, 'utf8').trim(), original);
});

test('rejects insecure callbacks before writing files', t => {
  const root = fixture(t);
  assert.throws(() => setupXmIntegration({root, callbackUrl: 'http://example.test'}));
  assert.equal(fs.existsSync(path.join(root, '.safehood-dev')), false);
});
