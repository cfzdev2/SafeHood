const dgram = require('dgram');
const os = require('os');
const crypto = require('crypto');

const MULTICAST_ADDRESS = '239.255.255.250';
const ONVIF_PORT = 3702;

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
    '[FAKE ONVIF DISCOVERY ERROR]',
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
      `[FAKE ONVIF] UDP od ${rinfo.address}:${rinfo.port}`
    );

    if (
      !text.includes('Probe') &&
      !text.includes('NetworkVideoTransmitter')
    ) {
      console.log(
        '[FAKE ONVIF] ignoruję pakiet'
      );

      return;
    }

    console.log(
      '[FAKE ONVIF] otrzymano WS-Discovery Probe'
    );

    const uuid =
      crypto.randomUUID();

    const response =
      `<?xml version="1.0" encoding="UTF-8"?>
<e:Envelope
 xmlns:e="http://www.w3.org/2003/05/soap-envelope"
 xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing"
 xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"
 xmlns:dn="http://www.onvif.org/ver10/network/wsdl">
 <e:Header>
  <w:MessageID>uuid:${uuid}</w:MessageID>
  <w:RelatesTo>uuid:${uuid}</w:RelatesTo>
  <w:Action>
   http://schemas.xmlsoap.org/ws/2005/04/discovery/ProbeMatches
  </w:Action>
 </e:Header>

 <e:Body>
  <d:ProbeMatches>
   <d:ProbeMatch>

    <w:EndpointReference>
     <w:Address>
      urn:uuid:${uuid}
     </w:Address>
    </w:EndpointReference>

    <d:Types>
     dn:NetworkVideoTransmitter
    </d:Types>

    <d:Scopes>
     onvif://www.onvif.org/type/video_encoder
     onvif://www.onvif.org/name/SafeHood_Fake_ONVIF
     onvif://www.onvif.org/hardware/FakeCam_3K
    </d:Scopes>

    <d:XAddrs>
     http://${lanIp}:8899/onvif/device_service
    </d:XAddrs>

    <d:MetadataVersion>
     1
    </d:MetadataVersion>

   </d:ProbeMatch>
  </d:ProbeMatches>
 </e:Body>
</e:Envelope>`;

    socket.send(
      Buffer.from(response),
      rinfo.port,
      rinfo.address,
      (error) => {
        if (error) {
          console.error(
            '[FAKE ONVIF] błąd odpowiedzi:',
            error
          );

          return;
        }

        console.log(
          `[FAKE ONVIF] ProbeMatch → ${rinfo.address}:${rinfo.port}`
        );

        console.log(
          `[FAKE ONVIF] XAddr = http://${lanIp}:8899/onvif/device_service`
        );
      }
    );
  }
);

socket.bind(
  ONVIF_PORT,
  '0.0.0.0',
  () => {
    socket.addMembership(
      MULTICAST_ADDRESS,
      lanIp
    );

    socket.setMulticastLoopback(true);

    console.log('');
    console.log(
      '════════ FAKE ONVIF WS-DISCOVERY ════════'
    );

    console.log(
      `LAN IP: ${lanIp}`
    );

    console.log(
      `Nasłuch: ${MULTICAST_ADDRESS}:${ONVIF_PORT}`
    );

    console.log(
      'Czekam na Probe z SafeHood...'
    );

    console.log(
      '══════════════════════════════════════════'
    );
    console.log('');
  }
);