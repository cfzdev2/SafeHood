'use strict';

const fs = require('node:fs');
const path = require('node:path');
const {spawn} = require('node:child_process');
const {resolveJava} = require('./dev_java.cjs');

const root = path.join(__dirname, '..');
const unitOnly = process.argv.includes('--unit-only');
const includeFlutter = !process.argv.includes('--skip-flutter');
const npm = process.platform === 'win32' ? 'npm.cmd' : 'npm';
const flutter = process.platform === 'win32' ? 'flutter.bat' : 'flutter';
const checks = [];
const npmCheck = (directory, script) => checks.push({
  name: `${directory}:${script}`, command: npm,
  args: ['--prefix', directory, 'run', script],
});
for (const script of ['check', 'test:ai', 'test:background-motion',
  'test:recording', 'test:evidence']) npmCheck('bridge', script);
checks.push({name: 'dev-startup', command: process.execPath,
  args: ['--test', ...fs.readdirSync(path.join(__dirname, 'test'))
    .filter((name) => name.endsWith('.test.cjs'))
    .map((name) => `tools/test/${name}`)]});
for (const script of ['lint', 'test']) npmCheck('functions', script);
if (!unitOnly) {
  checks.push({name: 'dev-persistence', command: process.execPath,
    args: ['tools/test_dev_persistence.cjs']});
  for (const script of ['test:rules', 'test:storage-rules', 'test:clips:backend',
    'test:free-flow', 'test:phone-motion', 'test:incident-live',
    'test:account-deletion', 'test:xm']) npmCheck('functions', script);
}
if (includeFlutter) {
  checks.push({name: 'flutter:analyze', command: flutter,
    args: ['--suppress-analytics', '--no-version-check', 'analyze']});
  checks.push({name: 'flutter:test', command: flutter,
    args: ['--suppress-analytics', '--no-version-check', 'test', '--no-pub']});
}

async function main() {
  const environment = unitOnly ? process.env : resolveJava().env;
  const directory = path.join(root, '.safehood-dev', `checks-${Date.now()}`);
  fs.mkdirSync(directory, {recursive: true});
  const result = {startedAt: new Date().toISOString(), unitOnly,
    manualCameraTests: 'PENDING', checks: []};
  for (const check of checks) {
    const started = Date.now();
    console.log(`[SafeHood] Sprawdzam ${check.name}`);
    const log = fs.createWriteStream(path.join(directory,
      check.name.replace(/[^a-zA-Z0-9_-]/g, '-') + '.log'));
    const outcome = await new Promise((resolve) => {
      const child = spawn(check.command, check.args, {cwd: root,
        // Windows command shims need cmd.exe; arguments here are fixed code.
        shell: process.platform === 'win32' && check.command !== process.execPath,
        env: {...environment, CI: 'true'}, stdio: ['ignore', 'pipe', 'pipe']});
      child.stdout.pipe(log, {end: false});
      child.stderr.pipe(log, {end: false});
      child.once('error', (error) => resolve({code: 1, error: error.code}));
      child.once('close', (code) => resolve({code: code ?? 1}));
    });
    await new Promise((resolve) => log.end(resolve));
    result.checks.push({name: check.name, ...outcome, durationMillis: Date.now() - started});
    console.log(`[SafeHood] ${check.name}: ${outcome.code === 0 ? 'OK' : 'BŁĄD'}`);
    fs.writeFileSync(path.join(directory, 'result.json'), JSON.stringify(result, null, 2));
    if (outcome.code !== 0) break;
  }
  const passed = result.checks.length === checks.length &&
    result.checks.every((check) => check.code === 0);
  console.log(`[SafeHood] Wynik i logi: ${path.relative(root, directory)}`);
  console.log('[SafeHood] Próby na kamerach nadal oczekują. Ten skrypt ich nie zalicza.');
  process.exitCode = passed ? 0 : 1;
}

main().catch((error) => {
  console.error(`[SafeHood] ${error.message}`);
  process.exitCode = 1;
});
