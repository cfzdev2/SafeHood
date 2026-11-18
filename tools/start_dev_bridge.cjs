'use strict';

const fs = require('node:fs');
const path = require('node:path');
const {setTimeout: delay} = require('node:timers/promises');

const root = path.join(__dirname, '..');
const configPath = path.join(root, 'bridge', 'config.json');

async function main() {
  if (!fs.existsSync(configPath)) {
    console.log('[SafeHood] Bridge nie jest sparowany. Sparuj go w aplikacji i uruchom zadanie „SafeHood - Bridge”.');
    return;
  }

  let config;
  try {
    config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  } catch {
    throw new Error('Nie udało się odczytać bridge/config.json.');
  }
  const {projectId, region, bridgeId, bridgeSecret} = config ?? {};
  if (![projectId, region, bridgeId, bridgeSecret]
      .every((value) => typeof value === 'string' && value.trim())) {
    throw new Error('Plik bridge/config.json nie zawiera kompletnych danych parowania.');
  }

  const firebase = JSON.parse(fs.readFileSync(path.join(root, 'firebase.json'), 'utf8'));
  const port = firebase.emulators?.functions?.port ?? 5001;
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error('Nieprawidłowy port emulatora Functions w firebase.json.');
  }
  const baseUrl = [
    `http://127.0.0.1:${port}`, encodeURIComponent(projectId), encodeURIComponent(region),
  ].join('/');
  console.log('[SafeHood] Czekam na lokalne Firebase i sprawdzam parowanie Bridge.');
  const deadline = Date.now() + 90_000;
  while (Date.now() < deadline) {
    const response = await fetch(`${baseUrl}/getBridgeConfiguration`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-safehood-bridge-id': bridgeId,
        authorization: `Bearer ${bridgeSecret}`,
      },
      body: '{}',
      signal: AbortSignal.timeout(3000),
      redirect: 'error',
    }).catch(() => null);
    const result = response?.ok ? await response.json().catch(() => null) : null;
    if (response && !response.ok) await response.body?.cancel().catch(() => {});

    if (response?.status === 401 || response?.status === 403) {
      throw new Error('Emulator odrzucił parowanie Bridge. Sprawdź, czy Firebase wczytał Twoje dane. Jeśli dane są poprawne, sparuj Bridge ponownie.');
    }
    if (result?.ok === true && result.bridgeId === bridgeId) {
      process.env.SAFEHOOD_FUNCTIONS_BASE_URL = baseUrl;
      console.log('[SafeHood] Firebase gotowy. Uruchamiam Bridge.');
      require('../bridge/supervisor.js');
      return;
    }
    await delay(1000);
  }
  throw new Error(`Bridge nie połączył się z lokalnym Firebase. Sprawdź zadanie „SafeHood - Firebase” i projekt ${projectId}.`);
}

main().catch((error) => {
  console.error(`[SafeHood] ${error.message}`);
  process.exitCode = 1;
});
