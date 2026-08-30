const net = require('net');
const os = require('os');

const PORT = 8554;

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

const server = net.createServer((socket) => {
  console.log(
    `[FAKE RTSP] connection from ${socket.remoteAddress}`
  );

  socket.once('data', (data) => {
    const request = data.toString();

    console.log('');
    console.log('──── RTSP REQUEST ────');
    console.log(request.trim());
    console.log('──────────────────────');

    if (request.startsWith('OPTIONS')) {
      socket.write(
        'RTSP/1.0 200 OK\r\n' +
        'CSeq: 1\r\n' +
        'Server: SafeHood Fake RTSP Camera\r\n' +
        'Public: OPTIONS, DESCRIBE, SETUP, PLAY\r\n' +
        '\r\n'
      );

      console.log(
        '[FAKE RTSP] OPTIONS → 200 OK'
      );
    } else {
      socket.write(
        'RTSP/1.0 400 Bad Request\r\n' +
        'CSeq: 1\r\n' +
        '\r\n'
      );
    }

    setTimeout(() => {
      socket.end();
    }, 100);
  });

  socket.on('error', (error) => {
    console.log(
      `[FAKE RTSP] socket error: ${error.message}`
    );
  });
});

server.listen(PORT, '0.0.0.0', () => {
  console.log('');
  console.log(
    '════════ FAKE RTSP CAMERA STARTED ════════'
  );
  console.log(`Port: ${PORT}`);

  for (const address of getLanAddresses()) {
    console.log(
      `RTSP: rtsp://${address}:${PORT}/fake-stream`
    );
  }

  console.log(
    '═══════════════════════════════════════════'
  );
  console.log('');
});