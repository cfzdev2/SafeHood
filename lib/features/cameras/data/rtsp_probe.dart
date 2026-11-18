import 'dart:convert';
import 'dart:io';

import 'local_camera_connection.dart';

/// Check for a real RTSP reply without opening a stream or sending credentials.
Future<bool> probeRtsp(
  Uri endpoint, {
  required Duration connectTimeout,
  required Duration replyTimeout,
}) async {
  if (parseManualRtspUri(endpoint.toString()) == null) return false;
  final port = endpoint.hasPort ? endpoint.port : 554;
  final target = Uri(
    scheme: 'rtsp',
    host: endpoint.host,
    port: port,
    path: '/',
  );
  Socket? socket;
  try {
    final connection = socket = await Socket.connect(
      target.host,
      port,
      timeout: connectTimeout,
    );
    connection.write(
      'OPTIONS $target RTSP/1.0\r\n'
      'CSeq: 1\r\n'
      'User-Agent: SafeHood\r\n\r\n',
    );
    return await _hasRtspReply(connection).timeout(replyTimeout);
  } on Exception {
    return false;
  } finally {
    socket?.destroy();
  }
}

Future<bool> _hasRtspReply(Socket socket) async {
  await socket.flush();
  final line = <int>[];
  await for (final chunk in socket) {
    for (final byte in chunk) {
      if (byte == 10) {
        return RegExp(
          r'^RTSP/[12]\.0 [1-5][0-9]{2}(?:\s|$)',
        ).hasMatch(utf8.decode(line, allowMalformed: true));
      }
      if (line.length == 256) return false;
      line.add(byte);
    }
  }
  return false;
}
