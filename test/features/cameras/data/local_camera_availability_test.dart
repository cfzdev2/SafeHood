import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safehood/features/cameras/data/local_camera_availability.dart';
import 'package:safehood/features/cameras/data/local_camera_connection.dart';
import 'package:safehood/features/cameras/domain/camera.dart';

const _camera = Camera(
  id: 'saved-camera',
  name: 'Kamera',
  locationName: 'Dom',
  brand: 'Test',
  model: 'Test',
  isOnline: true,
  motionDetectionEnabled: false,
  hasSdCard: false,
  ipAddress: '127.0.0.1',
  connectionType: CameraConnectionType.onvif,
);

void main() {
  test(
    'checks the saved ONVIF service even when monitoring is disabled',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        expect(request.method, 'POST');
        expect(request.uri.path, '/onvif/device_service');
        expect(request.headers[HttpHeaders.authorizationHeader], isNull);
        expect(
          await utf8.decoder.bind(request).join(),
          contains('GetSystemDateAndTime'),
        );
        request.response.write('''
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
  <s:Body><GetSystemDateAndTimeResponse/></s:Body>
</s:Envelope>''');
        await request.response.close();
      });
      final camera = _camera.copyWith(
        onvifServiceUrl: 'http://127.0.0.1:${server.port}/onvif/device_service',
      );
      Future<CameraAvailability> check() => checkLocalCameraAvailability(
        camera,
        connection: const LocalCameraConnection(),
      );
      expect(await check(), CameraAvailability.online);

      // Firestore still says the last preview was online. The endpoint is gone.
      await server.close(force: true);
      expect(await check(), CameraAvailability.offline);
    },
  );

  test(
    'checks RTSP without opening video or using the stream credentials',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      var response = 'RTSP/1.0 401 Unauthorized\r\nCSeq: 1\r\n\r\n';
      server.listen((client) async {
        try {
          var request = '';
          await for (final bytes in client) {
            request += utf8.decode(bytes);
            if (!request.endsWith('\r\n\r\n')) continue;
            expect(
              request,
              startsWith('OPTIONS rtsp://127.0.0.1:${server.port}/ RTSP/1.0'),
            );
            expect(request, isNot(contains('example-secret')));
            expect(request, isNot(contains('example-ticket')));
            client.write(response);
            await client.flush();
            break;
          }
        } finally {
          client.destroy();
        }
      });
      final camera = _camera.copyWith(
        connectionType: CameraConnectionType.rtsp,
      );
      final connection = LocalCameraConnection(
        rtspUri: Uri.parse(
          'rtsp://user:example-secret@127.0.0.1:${server.port}/live?key=example-ticket',
        ),
      );
      expect(
        await checkLocalCameraAvailability(camera, connection: connection),
        CameraAvailability.online,
      );

      // A different service on that IP/port must not produce a green badge.
      response = 'HTTP/1.1 200 OK\r\n\r\n';
      expect(
        await checkLocalCameraAvailability(camera, connection: connection),
        CameraAvailability.offline,
      );
    },
  );
}
