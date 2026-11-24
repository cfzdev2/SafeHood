'use strict';

const fs = require('node:fs');
const path = require('node:path');
const {spawn} = require('node:child_process');

function readJson(filename) { return JSON.parse(fs.readFileSync(filename, 'utf8')); }

function validateExport(directory) {
  const metadata = readJson(path.join(directory, 'firebase-export-metadata.json'));
  for (const service of ['auth', 'firestore', 'storage']) {
    const entry = metadata[service];
    if (!entry || typeof entry.path !== 'string' ||
        path.isAbsolute(entry.path) || entry.path.split(/[\\/]/).includes('..') ||
        !fs.existsSync(path.join(directory, entry.path))) {
      throw new Error(`Niekompletny zapis Firebase: ${service}. Poprzednia kopia pozostaje dostępna.`);
    }
  }
  const accounts = readJson(path.join(directory, metadata.auth.path, 'accounts.json'));
  if (!Array.isArray(accounts.users)) throw new Error('Uszkodzony zapis kont Firebase.');
  return {accounts: accounts.users.length};
}

function resolveCli(root, env = process.env) {
  const candidates = [env.SAFEHOOD_FIREBASE_CLI,
    path.join(root, 'node_modules/firebase-tools/lib/bin/firebase.js')];
  for (const directory of (env.PATH || '').split(path.delimiter)) {
    candidates.push(path.join(directory, 'node_modules/firebase-tools/lib/bin/firebase.js'));
    try {
      const executable = path.join(directory, 'firebase');
      if (fs.existsSync(executable)) candidates.push(fs.realpathSync(executable));
    } catch (_) {}
  }
  const cli = candidates.find((file) => file && file.endsWith('.js') && fs.existsSync(file));
  if (!cli) throw new Error('Brak Firebase CLI. Zainstaluj: npm install -g firebase-tools');
  return cli;
}

function selectImport(root, projectId) {
  const manifest = path.join(root, '.safehood-dev', 'latest.json');
  if (fs.existsSync(manifest)) {
    const saved = readJson(manifest);
    if (saved.projectId !== projectId ||
        !/^snapshot-[0-9]+-[a-f0-9]+$/.test(saved.directory)) {
      throw new Error('Zapis Firebase należy do innego projektu lub jest uszkodzony. Nie uruchamiam pustej bazy.');
    }
    const directory = path.join(root, '.safehood-dev', saved.directory);
    validateExport(directory);
    return directory;
  }
  const legacy = path.join(root, 'emulator-data');
  if (fs.existsSync(legacy)) {
    validateExport(legacy);
    return legacy;
  }
  return null;
}

function commitExport(root, projectId, directory) {
  const counts = validateExport(directory);
  const state = path.join(root, '.safehood-dev');
  if (path.dirname(directory) !== state) throw new Error('Nieprawidłowy katalog kopii.');
  const temporary = path.join(state, `latest.${process.pid}.tmp`);
  fs.writeFileSync(temporary, JSON.stringify({projectId,
    directory: path.basename(directory), savedAt: new Date().toISOString(), ...counts}),
  {mode: 0o600});
  fs.renameSync(temporary, path.join(state, 'latest.json'));
  // Keep several complete checkpoints; never touch older user backups.
  const snapshots = fs.readdirSync(state).filter((name) =>
    /^snapshot-[0-9]+-[a-f0-9]+$/.test(name) && path.join(state, name) !== directory)
    .sort().reverse();
  for (const name of snapshots.slice(5)) {
    fs.rmSync(path.join(state, name), {recursive: true, force: true});
  }
  return counts;
}

async function main(root = path.join(__dirname, '..')) {
  const projectId = readJson(path.join(root, '.firebaserc')).projects?.default;
  if (typeof projectId !== 'string' || !/^[a-z0-9-]+$/.test(projectId)) {
    throw new Error('Brak projektu Firebase w .firebaserc.');
  }
  const cli = resolveCli(root);
  const initial = selectImport(root, projectId);
  const state = path.join(root, '.safehood-dev');
  fs.mkdirSync(state, {recursive: true, mode: 0o700});
  const lock = path.join(state, 'firebase.lock');
  if (fs.existsSync(lock)) {
    const pid = Number(fs.readFileSync(lock, 'utf8'));
    let alive = false;
    try { process.kill(pid, 0); alive = true; } catch (error) {
      alive = error.code !== 'ESRCH';
    }
    if (alive) throw new Error('Zadanie Firebase już działa. Użyj jego terminala.');
    fs.rmSync(lock);
  }
  fs.writeFileSync(lock, String(process.pid), {flag: 'wx', mode: 0o600});
  const newDirectory = () => path.join(state,
    `snapshot-${Date.now()}-${require('node:crypto').randomBytes(4).toString('hex')}`);
  const finalDirectory = newDirectory();
  const args = [cli, 'emulators:start', '--project', projectId,
    '--export-on-exit', finalDirectory];
  if (initial) args.push('--import', initial);
  console.log(initial ? `[SafeHood] Wczytuję ostatni zapis Firebase (${validateExport(initial).accounts} kont).` :
    '[SafeHood] Pierwszy start bez zapisu. Kolejne uruchomienia wczytają utworzone dane.');
  const child = spawn(process.execPath, args, {cwd: root, stdio: 'inherit', windowsHide: false});
  let stopping = false;
  let exporting = null;
  const checkpoint = () => {
    if (exporting || stopping) return exporting;
    exporting = new Promise((resolve) => {
      const directory = newDirectory();
      const exporter = spawn(process.execPath, [cli, 'emulators:export', directory,
        '--project', projectId, '--force'], {cwd: root, stdio: 'pipe', windowsHide: true});
      // Drain output without copying account details into logs.
      exporter.stdout.resume();
      exporter.stderr.resume();
      const timeout = setTimeout(() => exporter.kill(), 45000);
      let settled = false;
      const finish = (code) => {
        if (settled) return;
        settled = true;
        clearTimeout(timeout);
        if (code === 0) {
          try {
            const counts = commitExport(root, projectId, directory);
            console.log(`[SafeHood] Zapis Firebase: ${counts.accounts} kont.`);
          } catch (error) { console.warn(`[SafeHood] ${error.message}`); }
        }
        exporting = null;
        resolve();
      };
      exporter.on('error', () => finish(1));
      exporter.on('exit', finish);
    });
    return exporting;
  };
  const timer = setInterval(checkpoint, 60000);
  const stop = async () => {
    if (stopping) return;
    // Export before forwarding termination (Windows may terminate immediately).
    await checkpoint();
    stopping = true;
    clearInterval(timer);
    child.kill('SIGINT');
  };
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
  const code = await new Promise((resolve, reject) => {
    child.on('error', reject);
    child.on('exit', (code) => resolve(code ?? 0));
  }).finally(async () => {
    stopping = true;
    clearInterval(timer);
    if (exporting) await exporting;
    process.off('SIGINT', stop);
    process.off('SIGTERM', stop);
    fs.rmSync(lock, {force: true});
  });
  if (fs.existsSync(path.join(finalDirectory, 'firebase-export-metadata.json'))) {
    commitExport(root, projectId, finalDirectory);
  }
  process.exitCode = code;
}

if (require.main === module) main().catch((error) => {
  console.error(`[SafeHood] ${error.message}`);
  process.exitCode = 1;
});
module.exports = {validateExport, selectImport, commitExport, resolveCli};
