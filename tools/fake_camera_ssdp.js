const dgram = require('dgram');
const os = require('os');

const SSDP_ADDRESS = '239.255.255.250';
const SSDP_PORT = 1900;

function getLanIp() {
  const interfaces = os.networkInterfaces();

  for (const entries of Object.values(interfaces)) {
    if (!entries) continue;

    for (const entry of entries) {
      if (
        entry.family === 'IPv4' &&
        !entry.internal &&
        (
          entry.address.startsWith('192.168.') ||
          entry.address.startsWith('10.') ||
          entry.address.startsWith('172.')
        )
      ) {
        return entry.address;
      }
    }
  }

  return null;
}

const lanIp = getLanIp();

if (!lanIp) {
  console.error(
    'Nie znaleziono lokalnego IPv4.'
  );

  process.exit(1);
}

const socket = dgram.createSocket({
  type: 'udp4',
  reuseAddr: true,
});

socket.on('error', (error) => {
  console.error(
    '[FAKE SSDP ERROR]',
    error
  );
});

socket.on(
  'message',
  (message, rinfo) => {
    const text =
      message.toString('utf8');

    console.log('');
    console.log(
      `[FAKE SSDP] UDP od ${rinfo.address}:${rinfo.port}`
    );

    if (
      !text.toUpperCase().includes(
        'M-SEARCH'
      )
    ) {
      console.log(
        '[FAKE SSDP] ignoruję - to nie M-SEARCH'
      );

      return;
    }

    console.log(
      '[FAKE SSDP] otrzymano M-SEARCH'
    );

    const response =
      'HTTP/1.1 200 OK\r\n' +
      'CACHE-CONTROL: max-age=1800\r\n' +
      'EXT:\r\n' +
      `LOCATION: http://${lanIp}:8899/device.xml\r\n` +
      'SERVER: SafeHood/1.0 UPnP/1.1 DEKCO ONVIF Network Camera\r\n' +
      'ST: urn:schemas-upnp-org:device:NetworkCamera:1\r\n' +
      'USN: uuid:safehood-fake-camera::urn:onvif-org:device:NetworkVideoTransmitter\r\n' +
      '\r\n';

    socket.send(
      Buffer.from(response),
      rinfo.port,
      rinfo.address,
      (error) => {
        if (error) {
          console.error(
            '[FAKE SSDP] błąd odpowiedzi:',
            error
          );

          return;
        }

        console.log(
          `[FAKE SSDP] odpowiedź → ${rinfo.address}:${rinfo.port}`
        );

        console.log(
          `[FAKE SSDP] urządzenie = ${lanIp}`
        );
      }
    );
  }
);

socket.bind(
  SSDP_PORT,
  '0.0.0.0',
  () => {
    socket.addMembership(
      SSDP_ADDRESS,
      lanIp
    );

    socket.setMulticastLoopback(true);

    console.log('');
    console.log(
      '════════ FAKE SSDP CAMERA ════════'
    );

    console.log(
      `LAN IP: ${lanIp}`
    );

    console.log(
      `Nasłuch: ${SSDP_ADDRESS}:${SSDP_PORT}`
    );

    console.log(
      'Czekam na M-SEARCH z SafeHood...'
    );

    console.log(
      '══════════════════════════════════'
    );
    console.log('');
  }
);