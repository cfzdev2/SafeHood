'use strict';

// Runs exclusively inside the isolated demo project's Firebase emulators.
const assert = require('node:assert/strict');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const requireFunctions = require('node:module').createRequire(
  path.join(__dirname, '../../functions/package.json'));
const {initializeApp, deleteApp} = requireFunctions('firebase-admin/app');
const {getAuth} = requireFunctions('firebase-admin/auth');
const {getFirestore} = requireFunctions('firebase-admin/firestore');
const {getStorage} = requireFunctions('firebase-admin/storage');
const {commitExport} = require('../start_dev_firebase.cjs');

async function main() {
  const projectId = 'demo-safehood-persistence';
  for (const variable of ['FIRESTORE_EMULATOR_HOST', 'FIREBASE_AUTH_EMULATOR_HOST',
    'FIREBASE_STORAGE_EMULATOR_HOST']) {
    assert.match(process.env[variable] || '', /^(127\.0\.0\.1|localhost):\d+$/);
  }
  const app = initializeApp({projectId, storageBucket: `${projectId}.appspot.com`});
  try {
    const db = getFirestore(app);
    const bucket = getStorage(app).bucket();
    const document = db.doc('users/persistence-owner/cameras/robot');
    const file = bucket.file('users/persistence-owner/cameraEvents/event/snapshot.jpg');
    if (process.argv[2] === 'seed') {
      await getAuth(app).createUser({uid: 'persistence-owner',
        email: 'owner@example.test', emailVerified: true, password: 'test-only-98765'});
      await document.set({name: 'Robot', motionDetectionEnabled: true});
      await file.save(Buffer.from([255, 216, 1, 2, 255, 217]), {resumable: false});
      const root = process.env.SAFEHOOD_PERSISTENCE_TEST_ROOT;
      const output = path.join(root, '.safehood-dev', 'snapshot-1000-abcdef');
      const result = spawnSync(process.execPath,
        [process.env.SAFEHOOD_FIREBASE_CLI, 'emulators:export', output,
          '--project', projectId, '--force'], {cwd: root, stdio: 'inherit'});
      assert.equal(result.status, 0);
      assert.equal(commitExport(root, projectId, output).accounts, 1);
    } else {
      assert.equal((await getAuth(app).getUser('persistence-owner')).emailVerified, true);
      assert.equal((await document.get()).data().name, 'Robot');
      assert.deepEqual((await file.download())[0], Buffer.from([255, 216, 1, 2, 255, 217]));
      console.log('[SafeHood] Po restarcie zachowano konto, kamerę i zdjęcie.');
    }
  } finally { await deleteApp(app); }
}
main().catch((error) => { console.error(error); process.exitCode = 1; });
