'use strict';

const fs = require('node:fs');
const path = require('node:path');
const {randomBytes} = require('node:crypto');

function valueIn(file, name) {
  if (!fs.existsSync(file)) return null;
  return fs.readFileSync(file, 'utf8').split(/\r?\n/)
    .find(line => line.startsWith(`${name}=`))?.slice(name.length + 1).trim() ?? null;
}

function addValue(file, name, value) {
  const before = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '';
  if (valueIn(file, name) != null) return;
  fs.writeFileSync(file, `${before}${before && !before.endsWith('\n') ? '\n' : ''}${name}=${value}\n`,
    {mode: 0o600});
}

function setupXmIntegration({root = path.join(__dirname, '..'), callbackUrl} = {}) {
  const project = JSON.parse(fs.readFileSync(path.join(root, '.firebaserc'), 'utf8')).projects?.default;
  if (typeof project !== 'string' || !/^[a-z0-9-]+$/.test(project)) {
    throw new Error('Nieprawidłowy projekt Firebase w .firebaserc.');
  }
  const url = new URL(callbackUrl ||
    `https://europe-central2-${project}.cloudfunctions.net/receiveXmCameraAlarm`);
  if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash) {
    throw new Error('Adres odbiornika alarmów musi być adresem HTTPS.');
  }
  const directory = path.join(root, '.safehood-dev', 'xm');
  const secretFile = path.join(directory, 'account-key.txt');
  const localSecrets = path.join(root, 'functions', '.secret.local');
  const previous = valueIn(localSecrets, 'SAFEHOOD_XM_ACCOUNT_KEY');
  let key = fs.existsSync(secretFile) ? fs.readFileSync(secretFile, 'utf8').trim() : previous;
  if (key && !/^[a-f0-9]{64}$/i.test(key)) throw new Error('Zapisany klucz usługi kamery jest uszkodzony.');
  if (key && previous && key !== previous) {
    throw new Error('Istnieją dwa różne klucze. Zachowaj oryginalny klucz kont usługi kamery.');
  }
  key ||= randomBytes(32).toString('hex');
  fs.mkdirSync(directory, {recursive: true, mode: 0o700});
  if (!fs.existsSync(secretFile)) fs.writeFileSync(secretFile, key + '\n', {mode: 0o600, flag: 'wx'});
  addValue(localSecrets, 'SAFEHOOD_XM_ACCOUNT_KEY', key);
  const environment = path.join(root, 'functions', `.env.${project}`);
  addValue(environment, 'SAFEHOOD_XM_ENABLED', 'true');
  addValue(environment, 'SAFEHOOD_XM_CALLBACK_BASE_URL', url.toString().replace(/\/$/, ''));
  const sdkConfig = path.join(root, 'android', 'xm-sdk.properties');
  if (!fs.existsSync(sdkConfig)) {
    fs.copyFileSync(path.join(root, 'android', 'xm-sdk.properties.example'), sdkConfig,
      fs.constants.COPYFILE_EXCL);
    fs.chmodSync(sdkConfig, 0o600);
  }
  return {project, secretFile, sdkConfig, environment};
}

if (require.main === module) {
  try {
    const args = process.argv.slice(2);
    if (args.length && (args.length !== 2 || args[0] !== '--callback-url')) {
      throw new Error('Użycie: node tools/setup_xm_integration.cjs [--callback-url HTTPS_URL]');
    }
    setupXmIntegration({callbackUrl: args[1]});
    console.log('Przygotowano prywatne pliki integracji kamer.');
    console.log('Uzupełnij zatwierdzone klucze w android/xm-sdk.properties.');
    console.log('Instrukcja uruchomienia backendu: docs/xm_camera_integration.md');
  } catch (error) {
    console.error(`[SafeHood] ${error.message}`);
    process.exitCode = 1;
  }
}

module.exports = {setupXmIntegration};
