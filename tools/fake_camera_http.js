const http = require('http');
const os = require('os');
const zlib = require('zlib');
const fs = require('fs');
const path = require('path');

const PORT = Number.parseInt(
  process.env.SAFEHOOD_FAKE_CAMERA_PORT || '8899',
  10,
);

if (
  !Number.isInteger(PORT) ||
  PORT < 1 ||
  PORT > 65535
) {
  throw new Error(
    'SAFEHOOD_FAKE_CAMERA_PORT musi być poprawnym numerem portu.',
  );
}

function getLanAddresses() {
  const interfaces = os.networkInterfaces();
  const addresses = [];

  for (const entries of Object.values(interfaces)) {
    if (!entries) continue;

    for (const entry of entries) {
      if (
        entry.family === 'IPv4' &&
        !entry.internal
      ) {
        addresses.push(entry.address);
      }
    }
  }

  return addresses;
}

function crc32(buffer) {
  let crc = 0xffffffff;

  for (const byte of buffer) {
    crc ^= byte;

    for (
      let bit = 0;
      bit < 8;
      bit += 1
    ) {
      const shouldFlip =
        (crc & 1) !== 0;

      crc =
        (crc >>> 1) ^
        (shouldFlip
          ? 0xedb88320
          : 0);
    }
  }

  return (
    (crc ^ 0xffffffff) >>>
    0
  );
}

function createPngChunk(
  type,
  data,
) {
  const typeBuffer =
    Buffer.from(
      type,
      'ascii',
    );

  const length =
    Buffer.alloc(4);

  length.writeUInt32BE(
    data.length,
    0,
  );

  const crc =
    Buffer.alloc(4);

  crc.writeUInt32BE(
    crc32(
      Buffer.concat([
        typeBuffer,
        data,
      ]),
    ),
    0,
  );

  return Buffer.concat([
    length,
    typeBuffer,
    data,
    crc,
  ]);
}

function createSnapshotPng() {
  const width = 640;
  const height = 360;

  const bytesPerRow =
    width * 3 + 1;

  const raw =
    Buffer.alloc(
      bytesPerRow * height,
    );

  function setPixel(
    x,
    y,
    red,
    green,
    blue,
  ) {
    if (
      x < 0 ||
      x >= width ||
      y < 0 ||
      y >= height
    ) {
      return;
    }

    const rowStart =
      y * bytesPerRow;

    const pixelStart =
      rowStart + 1 + x * 3;

    raw[pixelStart] = red;
    raw[pixelStart + 1] =
      green;
    raw[pixelStart + 2] =
      blue;
  }

  function fillRect(
    x,
    y,
    rectWidth,
    rectHeight,
    red,
    green,
    blue,
  ) {
    for (
      let currentY = y;
      currentY <
      y + rectHeight;
      currentY += 1
    ) {
      for (
        let currentX = x;
        currentX <
        x + rectWidth;
        currentX += 1
      ) {
        setPixel(
          currentX,
          currentY,
          red,
          green,
          blue,
        );
      }
    }
  }

  function fillCircle(
    centerX,
    centerY,
    radius,
    red,
    green,
    blue,
  ) {
    const radiusSquared =
      radius * radius;

    for (
      let y =
        centerY - radius;
      y <=
      centerY + radius;
      y += 1
    ) {
      for (
        let x =
          centerX - radius;
        x <=
        centerX + radius;
        x += 1
      ) {
        const dx =
          x - centerX;

        const dy =
          y - centerY;

        if (
          dx * dx +
            dy * dy <=
          radiusSquared
        ) {
          setPixel(
            x,
            y,
            red,
            green,
            blue,
          );
        }
      }
    }
  }

  //
  // Tło "obrazu kamery".
  //
  for (
    let y = 0;
    y < height;
    y += 1
  ) {
    const rowStart =
      y * bytesPerRow;

    raw[rowStart] = 0;

    for (
      let x = 0;
      x < width;
      x += 1
    ) {
      const pixelStart =
        rowStart +
        1 +
        x * 3;

      const shade =
        26 +
        Math.floor(
          (y / height) * 26,
        );

      raw[pixelStart] =
        shade;

      raw[pixelStart + 1] =
        shade + 6;

      raw[pixelStart + 2] =
        shade + 12;
    }
  }

  //
  // Ramka obrazu.
  //
  fillRect(
    18,
    18,
    604,
    4,
    210,
    210,
    210,
  );

  fillRect(
    18,
    338,
    604,
    4,
    210,
    210,
    210,
  );

  fillRect(
    18,
    18,
    4,
    324,
    210,
    210,
    210,
  );

  fillRect(
    618,
    18,
    4,
    324,
    210,
    210,
    210,
  );

  //
  // Prosta sylwetka osoby.
  //
  fillCircle(
    320,
    110,
    38,
    220,
    220,
    220,
  );

  fillRect(
    296,
    148,
    48,
    100,
    220,
    220,
    220,
  );

  fillRect(
    250,
    172,
    50,
    16,
    220,
    220,
    220,
  );

  fillRect(
    340,
    172,
    50,
    16,
    220,
    220,
    220,
  );

  fillRect(
    286,
    240,
    18,
    75,
    220,
    220,
    220,
  );

  fillRect(
    336,
    240,
    18,
    75,
    220,
    220,
    220,
  );

  //
  // Ruchoma linia skanowania.
  // Dzięki temu kolejne snapshoty
  // nie są idealnie identyczne.
  //
  const scanX =
    40 +
    (
      Math.floor(
        Date.now() / 250,
      ) %
      560
    );

  fillRect(
    scanX,
    28,
    3,
    300,
    120,
    220,
    160,
  );

  const signature =
    Buffer.from([
      137,
      80,
      78,
      71,
      13,
      10,
      26,
      10,
    ]);

  const ihdr =
    Buffer.alloc(13);

  ihdr.writeUInt32BE(
    width,
    0,
  );

  ihdr.writeUInt32BE(
    height,
    4,
  );

  ihdr[8] = 8;
  ihdr[9] = 2;
  ihdr[10] = 0;
  ihdr[11] = 0;
  ihdr[12] = 0;

  const compressed =
    zlib.deflateSync(raw);

  return Buffer.concat([
    signature,

    createPngChunk(
      'IHDR',
      ihdr,
    ),

    createPngChunk(
      'IDAT',
      compressed,
    ),

    createPngChunk(
      'IEND',
      Buffer.alloc(0),
    ),
  ]);
}

function sendSnapshot(res) {
  const image =
    createSnapshotPng();

  res.writeHead(200, {
    'Content-Type':
      'image/png',

    'Content-Length':
      image.length,

    'Cache-Control':
      'no-store, no-cache, must-revalidate, max-age=0',

    Pragma:
      'no-cache',

    Server:
      'SafeHood Fake Camera',
  });

  res.end(image);
}

function sendSoap(
  res,
  body,
) {
  res.writeHead(200, {
    'Content-Type':
      'application/soap+xml; charset=utf-8',

    Server:
      'DEKCO SafeHood Fake ONVIF Camera',
  });

  res.end(body);
}

function readBody(req) {
  return new Promise(
    (resolve) => {
      let body = '';

      req.on(
        'data',
        (chunk) => {
          body +=
            chunk.toString();
        },
      );

      req.on(
        'end',
        () => {
          resolve(body);
        },
      );
    },
  );
}

const fakeClipPath = path.join(
  __dirname,
  'fake_clip.mp4',
);

function sendClip(req, res) {
  if (!fs.existsSync(fakeClipPath)) {
    res.writeHead(404, {
      'Content-Type': 'text/plain',
    });

    res.end('Fake clip not found');
    return;
  }

  const stat = fs.statSync(fakeClipPath);
  const fileSize = stat.size;

  const range = req.headers.range;

  if (range) {
    const parts = range
      .replace(/bytes=/, '')
      .split('-');

    const start = parseInt(
      parts[0],
      10,
    );

    const end = parts[1]
      ? parseInt(parts[1], 10)
      : fileSize - 1;

    const chunkSize =
      end - start + 1;

    const stream =
      fs.createReadStream(
        fakeClipPath,
        {
          start,
          end,
        },
      );

    res.writeHead(206, {
      'Content-Range':
        `bytes ${start}-${end}/${fileSize}`,

      'Accept-Ranges':
        'bytes',

      'Content-Length':
        chunkSize,

      'Content-Type':
        'video/mp4',

      'Cache-Control':
        'no-store',
    });

    stream.pipe(res);
    return;
  }

  res.writeHead(200, {
    'Content-Length':
      fileSize,

    'Content-Type':
      'video/mp4',

    'Accept-Ranges':
      'bytes',

    'Cache-Control':
      'no-store',
  });

  fs.createReadStream(
    fakeClipPath,
  ).pipe(res);
}

//
// Fake ONVIF Events
//

const onvifSubscriptions =
  new Map();

let onvifSubscriptionCounter = 0;

function queueOnvifEvent(type) {
  const allowedTypes = [
    'motion',
    'person',
    'vehicle',
  ];

  if (!allowedTypes.includes(type)) {
    return;
  }

  const event = {
    type,
    occurredAt:
      new Date().toISOString(),
  };

  for (
    const queue
    of onvifSubscriptions.values()
  ) {
    queue.push({
      ...event,
    });
  }

  console.log(
    `[FAKE ONVIF EVENT] queued: ${type}`,
  );
}

function buildOnvifNotification(
  event,
) {
  let topic =
    'tns1:RuleEngine/CellMotionDetector/Motion';

  let dataName =
    'IsMotion';

  let dataValue =
    'true';

  if (event.type === 'person') {
    topic =
      'tns1:RuleEngine/AnalyticsEngine/ObjectDetection/Person';

    dataName =
      'Class';

    dataValue =
      'Person';
  }

  if (event.type === 'vehicle') {
    topic =
      'tns1:RuleEngine/AnalyticsEngine/ObjectDetection/Vehicle';

    dataName =
      'Class';

    dataValue =
      'Vehicle';
  }

  return `
<wsnt:NotificationMessage>
 <wsnt:Topic
  Dialect="http://www.onvif.org/ver10/tev/topicExpression/ConcreteSet">
  ${topic}
 </wsnt:Topic>

 <wsnt:Message>
  <tt:Message
   UtcTime="${event.occurredAt}"
   PropertyOperation="Changed">

   <tt:Source>
    <tt:SimpleItem
     Name="VideoSourceConfigurationToken"
     Value="profile_1"/>
   </tt:Source>

   <tt:Data>
    <tt:SimpleItem
     Name="${dataName}"
     Value="${dataValue}"/>
   </tt:Data>

  </tt:Message>
 </wsnt:Message>
</wsnt:NotificationMessage>`;
}

function sendPullMessagesResponse(
  res,
  queue,
) {
  const event =
    queue.shift();

  const notification =
    event == null
      ? ''
      : buildOnvifNotification(
        event,
      );

  sendSoap(
    res,
    `<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope
 xmlns:s="http://www.w3.org/2003/05/soap-envelope"
 xmlns:tev="http://www.onvif.org/ver10/events/wsdl"
 xmlns:wsnt="http://docs.oasis-open.org/wsn/b-2"
 xmlns:tt="http://www.onvif.org/ver10/schema"
 xmlns:tns1="http://www.onvif.org/ver10/topics">
 <s:Body>
  <tev:PullMessagesResponse>
   <tev:CurrentTime>${new Date().toISOString()}</tev:CurrentTime>
   <tev:TerminationTime>${new Date(
     Date.now() + 60 * 60 * 1000,
   ).toISOString()}</tev:TerminationTime>
   ${notification}
  </tev:PullMessagesResponse>
 </s:Body>
</s:Envelope>`,
  );
}

const server =
  http.createServer(
    async (req, res) => {
      console.log(
        `[FAKE CAMERA] ${req.method} ${req.url} ` +
          `from ${req.socket.remoteAddress}`,
      );

      const requestUrl =
        new URL(
          req.url,
          'http://fake-camera.local',
        );

      const pathname =
        requestUrl.pathname;

      //
      // Clip fake kamery.
      //
      if (
        req.method === 'GET' &&
        pathname === '/clip.mp4'
      ) {
        console.log(
          '[FAKE CAMERA] CLIP',
        );

        sendClip(
          req,
          res,
        );

        return;
      }

      //
      // Snapshot fake kamery.
      //
      if (
        req.method === 'GET' &&
        pathname ===
          '/snapshot.png'
      ) {
        console.log(
          '[FAKE CAMERA] SNAPSHOT',
        );

        sendSnapshot(res);

        return;
      }

      //
      // Zwykły panel HTTP kamery.
      //
      if (
        req.method === 'GET' &&
        pathname === '/'
      ) {
        res.writeHead(200, {
          'Content-Type':
            'text/html; charset=utf-8',

          Server:
            'DEKCO SafeHood Fake IP Camera',
        });

        res.end(`
<!DOCTYPE html>
<html>
<head>
  <title>SafeHood Fake IP Camera</title>
</head>
<body>
  <h1>DEKCO Network Camera</h1>

  <p>IP Camera surveillance device</p>
  <p>ONVIF compatible</p>
  <p>RTSP Network Video Camera</p>
  <p>Camera configuration panel</p>

  <p>
    <a href="/snapshot.png">
      Camera snapshot
    </a>
  </p>
</body>
</html>
        `);

        return;
      }

      //
      // ONVIF Device Service.
      //
      if (
        req.method === 'POST' &&
        pathname ===
          '/onvif/device_service'
      ) {
        const body =
          await readBody(req);

        console.log(
          '[FAKE ONVIF] Device Service request',
        );

        if (
          body.includes(
            'GetSystemDateAndTime',
          )
        ) {
          console.log(
            '[FAKE ONVIF] GetSystemDateAndTime',
          );

          sendSoap(
            res,
            `<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope
 xmlns:s="http://www.w3.org/2003/05/soap-envelope"
 xmlns:tds="http://www.onvif.org/ver10/device/wsdl"
 xmlns:tt="http://www.onvif.org/ver10/schema">
 <s:Body>
  <tds:GetSystemDateAndTimeResponse>
   <tds:SystemDateAndTime>
    <tt:DateTimeType>Manual</tt:DateTimeType>
   </tds:SystemDateAndTime>
  </tds:GetSystemDateAndTimeResponse>
 </s:Body>
</s:Envelope>`,
          );

          return;
        }

        if (
          body.includes(
            'GetCapabilities',
          )
        ) {
          console.log(
            '[FAKE ONVIF] GetCapabilities',
          );

          const host =
            req.headers.host;

          sendSoap(
            res,
            `<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope
 xmlns:s="http://www.w3.org/2003/05/soap-envelope"
 xmlns:tds="http://www.onvif.org/ver10/device/wsdl"
 xmlns:tt="http://www.onvif.org/ver10/schema">
 <s:Body>
  <tds:GetCapabilitiesResponse>
   <tds:Capabilities>
    <tt:Media>
     <tt:XAddr>http://${host}/onvif/media_service</tt:XAddr>
    </tt:Media>
    <tt:Events>
     <tt:XAddr>http://${host}/onvif/events_service</tt:XAddr>
     <tt:WSSubscriptionPolicySupport>
      false
     </tt:WSSubscriptionPolicySupport>
     <tt:WSPullPointSupport>
      true
     </tt:WSPullPointSupport>
    </tt:Events>
   </tds:Capabilities>
  </tds:GetCapabilitiesResponse>
 </s:Body>
</s:Envelope>`,
          );

          return;
        }

        res.writeHead(400);

        res.end(
          'Unknown ONVIF request',
        );

        return;
      }

      //
      // ONVIF Media Service.
      //
      if (
        req.method === 'POST' &&
        pathname ===
          '/onvif/media_service'
      ) {
        const body =
          await readBody(req);

        console.log(
          '[FAKE ONVIF] Media Service request',
        );

        if (
          body.includes(
            'GetProfiles',
          )
        ) {
          console.log(
            '[FAKE ONVIF] GetProfiles',
          );

          sendSoap(
            res,
            `<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope
 xmlns:s="http://www.w3.org/2003/05/soap-envelope"
 xmlns:trt="http://www.onvif.org/ver10/media/wsdl">
 <s:Body>
  <trt:GetProfilesResponse>
   <trt:Profiles token="profile_1"/>
  </trt:GetProfilesResponse>
 </s:Body>
</s:Envelope>`,
          );

          return;
        }

        if (
          body.includes(
            'GetStreamUri',
          )
        ) {
          console.log(
            '[FAKE ONVIF] GetStreamUri',
          );

          let ip =
            req.socket
              .localAddress;

          if (
            ip.startsWith(
              '::ffff:',
            )
          ) {
            ip =
              ip.substring(7);
          }

          sendSoap(
            res,
            `<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope
 xmlns:s="http://www.w3.org/2003/05/soap-envelope"
 xmlns:trt="http://www.onvif.org/ver10/media/wsdl"
 xmlns:tt="http://www.onvif.org/ver10/schema">
 <s:Body>
  <trt:GetStreamUriResponse>
   <trt:MediaUri>
    <tt:Uri>rtsp://${ip}:8554/fake-stream</tt:Uri>
   </trt:MediaUri>
  </trt:GetStreamUriResponse>
 </s:Body>
</s:Envelope>`,
          );

          return;
        }

        res.writeHead(400);

        res.end(
          'Unknown Media request',
        );

        return;
      }

      //
      // ONVIF Events Service.
      //
      if (
        req.method === 'POST' &&
        pathname ===
          '/onvif/events_service'
      ) {
        const body =
          await readBody(req);

        console.log(
          '[FAKE ONVIF] Events Service request',
        );

        if (
          body.includes(
            'CreatePullPointSubscription',
          )
        ) {
          console.log(
            '[FAKE ONVIF] CreatePullPointSubscription',
          );

          const host =
            req.headers.host;

          const subscriptionId =
            `sub_${++onvifSubscriptionCounter}`;

          onvifSubscriptions.set(
            subscriptionId,
            [],
          );

          console.log(
            '[FAKE ONVIF] '
            + `subscription created: ${subscriptionId}`,
          );

          sendSoap(
            res,
            `<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope
 xmlns:s="http://www.w3.org/2003/05/soap-envelope"
 xmlns:tev="http://www.onvif.org/ver10/events/wsdl"
 xmlns:wsa5="http://www.w3.org/2005/08/addressing">
 <s:Body>
  <tev:CreatePullPointSubscriptionResponse>
   <tev:SubscriptionReference>
    <wsa5:Address>
     http://${host}/onvif/pullpoint/${subscriptionId}
    </wsa5:Address>
   </tev:SubscriptionReference>

   <tev:CurrentTime>
    ${new Date().toISOString()}
   </tev:CurrentTime>

   <tev:TerminationTime>
    ${new Date(
      Date.now() + 60 * 60 * 1000,
    ).toISOString()}
   </tev:TerminationTime>
  </tev:CreatePullPointSubscriptionResponse>
 </s:Body>
</s:Envelope>`,
          );

          return;
        }

        res.writeHead(400);

        res.end(
          'Unknown Events request',
        );

        return;
      }

      //
      // ONVIF PullPoint.
      //
      const pullPointMatch =
        pathname.match(
          /^\/onvif\/pullpoint\/(sub_\d+)$/,
        );

      if (
        req.method === 'POST' &&
        pullPointMatch
      ) {
        const subscriptionId =
          pullPointMatch[1];

        const queue =
          onvifSubscriptions.get(
            subscriptionId,
          );

        if (queue == null) {
          res.writeHead(404);

          res.end(
            'Unknown subscription',
          );

          return;
        }

        const body =
          await readBody(req);

        if (
          body.includes(
            'PullMessages',
          )
        ) {
          console.log(
            '[FAKE ONVIF] '
            + `PullMessages ${subscriptionId}`,
          );

          sendPullMessagesResponse(
            res,
            queue,
          );

          return;
        }

        res.writeHead(400);

        res.end(
          'Unknown PullPoint request',
        );

        return;
      }

      res.writeHead(404, {
        'Content-Type':
          'text/plain',
      });

      res.end(
        'Not found',
      );
    },
  );

server.listen(
  PORT,
  '0.0.0.0',
  () => {
    console.log('');

    console.log(
      '════════ FAKE ONVIF CAMERA STARTED ════════',
    );

    console.log(
      `Port: ${PORT}`,
    );

    for (
      const address of
      getLanAddresses()
    ) {
      console.log(
        `Fake camera: http://${address}:${PORT}`,
      );

      console.log(
        `Snapshot:    http://${address}:${PORT}/snapshot.png`,
      );
    }

    console.log(
      '═══════════════════════════════════════════',
    );

    console.log('');
  },
);

//
// Sterowanie fake ONVIF Events
// z terminala.
//

if (process.stdin.isTTY) {
  process.stdin.setEncoding(
    'utf8',
  );

  console.log(
    'ONVIF Events controls:',
  );

  console.log(
    '  m = motion',
  );

  console.log(
    '  p = person',
  );

  console.log(
    '  v = vehicle',
  );

  process.stdin.on(
    'data',
    (input) => {
      const command =
        input
          .trim()
          .toLowerCase();

      switch (command) {
        case 'm':
          queueOnvifEvent(
            'motion',
          );
          break;

        case 'p':
          queueOnvifEvent(
            'person',
          );
          break;

        case 'v':
          queueOnvifEvent(
            'vehicle',
          );
          break;

        default:
          if (
            command.length > 0
          ) {
            console.log(
              'Użyj: m / p / v',
            );
          }
      }
    },
  );
}