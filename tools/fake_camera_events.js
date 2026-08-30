const readline =
  require('readline');

const os =
  require('os');

const PROJECT_ID =
  process.env
    .SAFEHOOD_PROJECT_ID ||
  'safehood-security-app';

const REGION =
  'europe-central2';

const FUNCTIONS_HOST =
  process.env
    .SAFEHOOD_FUNCTIONS_HOST ||
  '127.0.0.1';

const FUNCTIONS_PORT =
  process.env
    .SAFEHOOD_FUNCTIONS_PORT ||
  '5001';

const DEV_SECRET =
  process.env
    .SAFEHOOD_DEV_EVENT_SECRET ||
  'safehood-local-dev';

const FAKE_CAMERA_PORT =
  process.env
    .SAFEHOOD_FAKE_CAMERA_PORT ||
  '8899';

const ownerId =
  process.argv[2];

const cameraId =
  process.argv[3];

if (
  !ownerId ||
  !cameraId
) {
  console.error('');

  console.error(
    'Użycie: node tools/fake_camera_events.js OWNER_ID CAMERA_ID',
  );

  console.error('');

  process.exit(1);
}

function buildClipUrl() {
  return (
    `${fakeCameraBaseUrl}` +
    `/clip.mp4`
  );
}

const endpoint =
  `http://${FUNCTIONS_HOST}:${FUNCTIONS_PORT}/` +
  `${PROJECT_ID}/${REGION}/devIngestCameraEvent`;

function is192Address(
  address,
) {
  return address.startsWith(
    '192.168.',
  );
}

function is10Address(
  address,
) {
  return address.startsWith(
    '10.',
  );
}

function is172PrivateAddress(
  address,
) {
  const parts =
    address.split('.');

  if (
    parts.length !== 4 ||
    parts[0] !== '172'
  ) {
    return false;
  }

  const second =
    Number(parts[1]);

  return (
    second >= 16 &&
    second <= 31
  );
}

function getLanAddresses() {
  const interfaces =
    os.networkInterfaces();

  const addresses = [];

  for (
    const entries of
    Object.values(
      interfaces,
    )
  ) {
    if (!entries) {
      continue;
    }

    for (
      const entry of entries
    ) {
      if (
        entry.family !== 'IPv4' ||
        entry.internal
      ) {
        continue;
      }

      addresses.push(
        entry.address,
      );
    }
  }

  return addresses;
}

function getPreferredLanAddress() {
  const addresses =
    getLanAddresses();

  const address192 =
    addresses.find(
      is192Address,
    );

  if (address192) {
    return address192;
  }

  const address10 =
    addresses.find(
      is10Address,
    );

  if (address10) {
    return address10;
  }

  const address172 =
    addresses.find(
      is172PrivateAddress,
    );

  if (address172) {
    return address172;
  }

  return (
    addresses[0] ??
    null
  );
}

function getFakeCameraBaseUrl() {
  const override =
    process.env
      .SAFEHOOD_FAKE_CAMERA_BASE_URL;

  if (
    override &&
    override.trim()
  ) {
    return override
      .trim()
      .replace(
        /\/+$/,
        '',
      );
  }

  const lanAddress =
    getPreferredLanAddress();

  if (!lanAddress) {
    throw new Error(
      'Nie udało się wykryć adresu LAN komputera. ' +
        'Ustaw SAFEHOOD_FAKE_CAMERA_BASE_URL ręcznie.',
    );
  }

  return (
    `http://${lanAddress}:` +
    `${FAKE_CAMERA_PORT}`
  );
}

const fakeCameraBaseUrl =
  getFakeCameraBaseUrl();

function sleep(ms) {
  return new Promise(
    (resolve) => {
      setTimeout(
        resolve,
        ms,
      );
    },
  );
}

function confidenceFor(
  type,
) {
  switch (type) {
    case 'person':
      return 0.94;

    case 'vehicle':
      return 0.88;

    case 'motion':
      return 0.62;

    case 'sound':
      return 0.70;

    case 'tamper':
      return 0.91;

    default:
      return null;
  }
}

function buildSnapshotUrl() {
  const timestamp =
    Date.now();

  return (
    `${fakeCameraBaseUrl}` +
    `/snapshot.png` +
    `?event=${timestamp}`
  );
}

async function sendEvent(
  type,
) {
  console.log('');

  console.log(
    `[FAKE CAMERA] ${type.toUpperCase()}`,
  );

  const snapshotUrl =
    buildSnapshotUrl();

  console.log(
    `[FAKE CAMERA] snapshotUrl = ${snapshotUrl}`,
  );

  const body = {
    ownerId,
    cameraId,
    type,

    source:
      'fake',

    confidence:
      confidenceFor(type),

    occurredAt:
      new Date()
        .toISOString(),

    snapshotUrl,

    clipUrl:
      buildClipUrl(),
  };

  try {
    const response =
      await fetch(
        endpoint,
        {
          method:
            'POST',

          headers: {
            'Content-Type':
              'application/json',

            'x-safehood-dev-secret':
              DEV_SECRET,
          },

          body:
            JSON.stringify(
              body,
            ),
        },
      );

    const text =
      await response.text();

    let result;

    try {
      result =
        JSON.parse(text);
    } catch (_) {
      result = {
        raw: text,
      };
    }

    if (!response.ok) {
      console.error(
        `[BACKEND ERROR ${response.status}]`,
        result,
      );

      return null;
    }

    console.log(
      '[BACKEND OK]',
      result,
    );

    return result;
  } catch (error) {
    console.error(
      '[NETWORK ERROR]',
      error,
    );

    return null;
  }
}

async function runAggregationTest() {
  console.log('');

  console.log(
    '════════ AGGREGATION TEST ════════',
  );

  console.log(
    '1/4 motion',
  );

  await sendEvent(
    'motion',
  );

  await sleep(1200);

  console.log(
    '2/4 motion',
  );

  await sendEvent(
    'motion',
  );

  await sleep(1200);

  console.log(
    '3/4 person',
  );

  await sendEvent(
    'person',
  );

  await sleep(1200);

  console.log(
    '4/4 motion',
  );

  await sendEvent(
    'motion',
  );

  console.log('');

  console.log(
    'OCZEKIWANY WYNIK:',
  );

  console.log(
    'type = person',
  );

  console.log(
    'occurrenceCount = 4',
  );

  console.log(
    'ten sam eventId we wszystkich odpowiedziach',
  );

  console.log(
    'snapshotUrl = ostatni dostępny snapshot',
  );

  console.log(
    '══════════════════════════════════',
  );
}

function printMenu() {
  console.log('');

  console.log(
    '════════ SAFEHOOD FAKE CAMERA ════════',
  );

  console.log(
    `Owner:    ${ownerId}`,
  );

  console.log(
    `Camera:   ${cameraId}`,
  );

  console.log(
    `Snapshot: ${fakeCameraBaseUrl}/snapshot.png`,
  );

  console.log('');

  console.log(
    '[m] Motion',
  );

  console.log(
    '[p] Person',
  );

  console.log(
    '[v] Vehicle',
  );

  console.log(
    '[s] Sound',
  );

  console.log(
    '[x] Tamper',
  );

  console.log('');

  console.log(
    '[t] Test agregacji',
  );

  console.log(
    '[q] Wyjście',
  );

  console.log(
    '════════════════════════════════════',
  );

  console.log('');
}

const rl =
  readline.createInterface({
    input:
      process.stdin,

    output:
      process.stdout,
  });

let busy =
  false;

printMenu();

rl.setPrompt('> ');
rl.prompt();

rl.on(
  'line',
  async (line) => {
    if (busy) {
      console.log(
        'Poczekaj na zakończenie operacji.',
      );

      rl.prompt();

      return;
    }

    const command =
      line
        .trim()
        .toLowerCase();

    busy = true;

    try {
      switch (command) {
        case 'm':
          await sendEvent(
            'motion',
          );
          break;

        case 'p':
          await sendEvent(
            'person',
          );
          break;

        case 'v':
          await sendEvent(
            'vehicle',
          );
          break;

        case 's':
          await sendEvent(
            'sound',
          );
          break;

        case 'x':
          await sendEvent(
            'tamper',
          );
          break;

        case 't':
          await runAggregationTest();
          break;

        case 'q':
          rl.close();
          return;

        default:
          console.log(
            'Nieznana komenda.',
          );
      }
    } finally {
      busy = false;
    }

    rl.prompt();
  },
);

rl.on(
  'close',
  () => {
    console.log('');

    console.log(
      'Fake camera stopped.',
    );

    process.exit(0);
  },
);