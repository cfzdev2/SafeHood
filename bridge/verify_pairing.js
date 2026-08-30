const fs =
  require('fs');

const path =
  require('path');

const configPath =
  path.join(
    __dirname,
    'config.json',
  );

function loadConfig() {
  if (
    !fs.existsSync(
      configPath,
    )
  ) {
    throw new Error(
      'Brak bridge/config.json. ' +
      'Najpierw sparuj Bridge.',
    );
  }

  const config =
    JSON.parse(
      fs.readFileSync(
        configPath,
        'utf8',
      ),
    );

  if (
    typeof config.bridgeId !==
      'string' ||
    typeof config.bridgeSecret !==
      'string'
  ) {
    throw new Error(
      'Nieprawidłowy plik config.json.',
    );
  }

  return config;
}

async function main() {
  const config =
    loadConfig();

  const projectId =
    config.projectId ||
    'safehood-security-app';

  const region =
    config.region ||
    'europe-central2';

  const endpoint =
    process.env
      .SAFEHOOD_CONFIGURATION_ENDPOINT ||
    (
      'http://127.0.0.1:5001/' +
      `${projectId}/${region}/` +
      'getBridgeConfiguration'
    );

  console.log('');

  console.log(
    '[BRIDGE AUTH] sprawdzam połączenie...',
  );

  const response =
    await fetch(
      endpoint,
      {
        method:
          'POST',

        headers: {
          'Content-Type':
            'application/json',

          'x-safehood-bridge-id':
            config.bridgeId,

          Authorization:
            `Bearer ${config.bridgeSecret}`,
        },

        body:
          JSON.stringify({}),
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

  console.log('');

  console.log(
    '[BRIDGE AUTH] autoryzacja poprawna',
  );

  console.log(
    `[BRIDGE AUTH] bridgeId = ${result.bridgeId}`,
  );

  console.log(
    '[BRIDGE AUTH] przypisanych kamer = ' +
    `${result.cameraCount ?? 0}`,
  );

  console.log('');
}

main().catch(
  (error) => {
    console.error('');

    console.error(
      `[BRIDGE AUTH ERROR] ${error.message}`,
    );

    console.error('');

    process.exit(1);
  },
);