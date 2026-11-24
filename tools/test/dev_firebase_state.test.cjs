'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {commitExport, selectImport, validateExport} = require('../start_dev_firebase.cjs');

function exportData(root, name, users = [{localId: 'owner'}]) {
  const directory = path.join(root, '.safehood-dev', name);
  fs.mkdirSync(path.join(directory, 'auth_export'), {recursive: true});
  fs.mkdirSync(path.join(directory, 'firestore_export'));
  fs.mkdirSync(path.join(directory, 'storage_export'));
  fs.writeFileSync(path.join(directory, 'auth_export/accounts.json'), JSON.stringify({users}));
  fs.writeFileSync(path.join(directory, 'firebase-export-metadata.json'), JSON.stringify({
    auth: {path: 'auth_export'}, firestore: {path: 'firestore_export'}, storage: {path: 'storage_export'},
  }));
  return directory;
}

test('restarts import the committed account checkpoint; partial exports never replace it', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'safehood-firebase-'));
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  assert.equal(selectImport(root, 'demo-safehood'), null);
  const valid = exportData(root, 'snapshot-1000-abcdef');
  assert.equal(commitExport(root, 'demo-safehood', valid).accounts, 1);
  assert.equal(selectImport(root, 'demo-safehood'), valid);
  const broken = exportData(root, 'snapshot-2000-abcdef');
  fs.rmSync(path.join(broken, 'auth_export/accounts.json'));
  assert.throws(() => commitExport(root, 'demo-safehood', broken));
  assert.equal(selectImport(root, 'demo-safehood'), valid);
  assert.throws(() => selectImport(root, 'different-project'));
  assert.equal(validateExport(valid).accounts, 1);
});

test('an existing incomplete emulator-data directory cannot silently open an empty database', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'safehood-firebase-'));
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  fs.mkdirSync(path.join(root, 'emulator-data'));
  assert.throws(() => selectImport(root, 'demo-safehood'));
});

test('task setup updates Firebase and Bridge, preserves other tasks and is repeatable', (t) => {
  const {execFileSync} = require('node:child_process');
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'safehood-tasks-'));
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  fs.mkdirSync(path.join(root, 'tools'));
  fs.mkdirSync(path.join(root, '.vscode'));
  const script = path.join(root, 'tools', 'setup_vscode_tasks.cjs');
  fs.copyFileSync(path.join(__dirname, '..', 'setup_vscode_tasks.cjs'), script);
  const filename = path.join(root, '.vscode', 'tasks.json');
  fs.writeFileSync(filename, JSON.stringify({version: '2.0.0', tasks: [
    {label: 'SafeHood - Firebase', command: 'old-firebase-command'},
    {label: 'My other task', command: 'unchanged'},
  ]}));
  execFileSync(process.execPath, [script]);
  const first = fs.readFileSync(filename, 'utf8');
  const config = JSON.parse(first);
  assert.equal(config.tasks.find((item) => item.label === 'My other task').command, 'unchanged');
  assert.equal(config.tasks.find((item) => item.label === 'SafeHood - Firebase').command,
    'node tools/start_dev_firebase.cjs');
  assert.deepEqual(config.tasks.find((item) => item.label === 'SafeHood - Start Dev Stack').dependsOn,
    ['SafeHood - Firebase', 'SafeHood - Bridge']);
  execFileSync(process.execPath, [script]);
  assert.equal(fs.readFileSync(filename, 'utf8'), first);
  assert.equal(fs.readdirSync(path.dirname(filename)).filter((name) => name.endsWith('.bak')).length, 1);
});
