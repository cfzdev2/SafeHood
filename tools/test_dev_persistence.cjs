'use strict';

const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const {spawn} = require('node:child_process');
const {resolveCli, selectImport} = require('./start_dev_firebase.cjs');

async function main() {
  const projectId = 'demo-safehood-persistence';
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'safehood-persistence-'));
  const cli = resolveCli(path.join(__dirname, '..'));
  const probe = path.join(__dirname, 'test', 'dev_persistence_probe.cjs');
  fs.mkdirSync(path.join(root, '.safehood-dev'));
  fs.writeFileSync(path.join(root, 'firebase.json'), JSON.stringify({emulators: {
    auth: {port: 9098}, firestore: {port: 8082}, storage: {port: 9197},
    ui: {enabled: false}, singleProjectMode: true,
  }, firestore: {rules: path.join(__dirname, '..', 'firestore.rules')},
  storage: {rules: path.join(__dirname, '..', 'storage.rules')}}));
  try {
    for (const phase of ['seed', 'verify']) {
      const args = [cli, 'emulators:exec', '--only', 'auth,firestore,storage',
        '--project', projectId, '--config', path.join(root, 'firebase.json')];
      if (phase === 'verify') args.push('--import', selectImport(root, projectId));
      args.push(`"${process.execPath}" "${probe}" ${phase}`);
      const code = await new Promise((resolve, reject) => {
        const child = spawn(process.execPath, args, {cwd: root, stdio: 'inherit',
          env: {...process.env, CI: 'true', SAFEHOOD_FIREBASE_CLI: cli,
            SAFEHOOD_PERSISTENCE_TEST_ROOT: root}});
        child.on('error', reject);
        child.on('close', resolve);
      });
      if (code !== 0) throw new Error(`Test zapisu Firebase: ${phase} (${code}).`);
    }
  } finally { fs.rmSync(root, {recursive: true, force: true}); }
}
main().catch((error) => { console.error(error.message); process.exitCode = 1; });
