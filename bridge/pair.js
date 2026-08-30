const fs =
  require('fs');

const os =
  require('os');

const path =
  require('path');

const PROJECT_ID =
  process.env
    .SAFEHOOD_PROJECT_ID ||
  'safehood-security-app';

const REGION =
  process.env
    .SAFEHOOD_REGION ||
  'europe-central2';

const PAIR_ENDPOINT =
  process.env
    .SAFEHOOD_PAIR_ENDPOINT ||
  (
    'http://127.0.0.1:5001/' +
    `${PROJECT_ID}/${REGION}/` +
    'claimBridgePairing'
  );

const code =
  process.argv
    .slice(2)
    .join('')
    .trim();

if (!code) {
  console.error('');

  console.error(
    'Użycie: npm run pair -- 1234-5678',
  );

  console.error('');

  process.exit(1);
}

async function main() {
  console.log('');

  console.log(
    '[BRIDGE PAIRING] łączenie...',
  );

  const response =
    await fetch(
      PAIR_ENDPOINT,
      {
        method:
          'POST',

        headers: {
          'Content-Type':
            'application/json',
        },

        body:
          JSON.stringify({
            code,

            name:
              process.env
                .SAFEHOOD_BRIDGE_NAME ||
              `SafeHood Bridge ${os.hostname()}`,

            platform:
              process.platform,

            version:
              '1.0.0',
          }),
      },
    );

  const responseText =
    await response.text();

  let result;

  try {
    result =
      JSON.parse(
        responseText,
      );
  } catch (_) {
    result = {
      error:
        responseText,
    };
  }

  if (!response.ok) {
    throw new Error(
      result.error ||
      `Backend HTTP ${response.status}`,
    );
  }

  if (
    typeof result.bridgeId !==
      'string' ||
    typeof result.bridgeSecret !==
      'string'
  ) {
    throw new Error(
      'Backend nie zwrócił danych Bridge.',
    );
  }

  const configPath =
    path.join(
      __dirname,
      'config.json',
    );

  const temporaryPath =
    path.join(
      __dirname,
      'config.json.tmp',
    );

  const config = {
    projectId:
      PROJECT_ID,

    region:
      REGION,

    bridgeId:
      result.bridgeId,

    bridgeSecret:
      result.bridgeSecret,

    pairedAt:
      new Date()
        .toISOString(),
  };

  fs.writeFileSync(
    temporaryPath,
    `${JSON.stringify(
      config,
      null,
      2,
    )}\n`,
    {
      encoding:
        'utf8',

      mode:
        0o600,
    },
  );

  fs.renameSync(
    temporaryPath,
    configPath,
  );

  try {
    fs.chmodSync(
      configPath,
      0o600,
    );
  } catch (_) {
    // Windows może nie obsługiwać
    // uprawnień zgodnych z Unix.
  }

  console.log('');

  console.log(
    '[BRIDGE PAIRING] sparowano',
  );

  console.log(
    `[BRIDGE PAIRING] bridgeId = ${result.bridgeId}`,
  );

  console.log(
    `[BRIDGE PAIRING] konfiguracja = ${configPath}`,
  );

  console.log('');
}

main().catch(
  (error) => {
    console.error('');

    console.error(
      `[BRIDGE PAIRING ERROR] ${error.message}`,
    );

    console.error('');

    process.exit(1);
  },
);