import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safehood/features/cameras/data/camera_live_playback.dart';
import 'package:safehood/features/cameras/data/local_camera_connection.dart';
import 'package:safehood/features/cameras/data/onvif_media_resolver.dart';
import 'package:safehood/features/cameras/data/onvif_soap_client.dart';
import 'package:safehood/features/cameras/data/onvif_wifi_setup.dart';
import 'package:safehood/features/cameras/domain/camera.dart';
import 'package:xml/xml.dart';

const _camera = Camera(
  id: 'local',
  name: 'Kamera',
  locationName: 'Dom',
  brand: 'NVT',
  model: '',
  isOnline: false,
  motionDetectionEnabled: false,
  hasSdCard: false,
  connectionType: CameraConnectionType.onvif,
);

Future<Uri> _serve(Future<void> Function(HttpRequest) handler) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen(handler);
  return Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: server.port,
    path: '/onvif/device_service',
  );
}

Future<void> _reply(HttpRequest request, String body, {int code = 200}) async {
  request.response.statusCode = code;
  request.response.headers.contentType = ContentType(
    'application',
    'soap+xml',
    charset: 'utf-8',
  );
  request.response.write(
    '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">'
    '<s:Body>$body</s:Body></s:Envelope>',
  );
  await request.response.close();
}

XmlElement _operation(String text) =>
    onvifElements(XmlDocument.parse(text), 'Body').single.childElements.single;

void main() {
  test('retains the detected ONVIF address and tries common alternatives', () {
    final candidates = cameraOnvifEndpoints(
      _camera.copyWith(
        ipAddress: '192.168.1.6',
        onvifServiceUrl: 'http://192.168.1.6:8899/custom',
        openPorts: {8899, 8080},
      ),
    );
    expect(candidates.first.toString(), 'http://192.168.1.6:8899/custom');
    expect(
      candidates,
      contains(Uri.parse('http://192.168.1.6/onvif/device_service')),
    );
    expect(candidates.every((uri) => uri.host == '192.168.1.6'), isTrue);
  });

  test(
    'pins advertised addresses to the camera and keeps local stream options',
    () {
      final base = Uri.parse('http://192.168.1.6:8899/onvif/device_service');
      expect(
        onvifAdvertisedUri('/onvif/media_service', base, schemes: {'http'}),
        Uri.parse('http://192.168.1.6:8899/onvif/media_service'),
      );
      expect(
        onvifAdvertisedUri(
          'rtsp://user:pass@0.0.0.0:554/live?x=1&y=2',
          base,
          schemes: {'rtsp'},
        ),
        Uri.parse('rtsp://192.168.1.6:554/live?x=1&y=2'),
      );
      expect(
        onvifAdvertisedUri('ftp://example.org/stream', base, schemes: {'rtsp'}),
        isNull,
      );

      final stream = applyCameraLogin(
        Uri.parse('rtsp://192.168.1.6/live'),
        const CameraLogin('a:b', 'p@w#?'),
      );
      expect(stream.toString(), 'rtsp://a%3Ab:p%40w%23%3F@192.168.1.6/live');
      expect(parseManualOnvifUri('http://name:pass@192.168.1.6'), isNull);
      expect(parseManualOnvifUri('http://example.org'), isNull);
    },
  );

  test(
    'uses a fixed-length SOAP body and replays it with HTTP Digest',
    () async {
      final calls = <(String, String?, int, String?)>[];
      final uri = await _serve((request) async {
        final body = await utf8.decoder.bind(request).join();
        final auth = request.headers.value(HttpHeaders.authorizationHeader);
        calls.add((
          body,
          auth,
          request.headers.contentLength,
          request.headers.value(HttpHeaders.contentTypeHeader),
        ));
        if (auth == null) {
          request.response.headers.set(
            HttpHeaders.wwwAuthenticateHeader,
            'Digest realm="Camera", nonce="n123", qop="auth", algorithm=MD5',
          );
          await _reply(request, '<Fault/>', code: 401);
        } else {
          await _reply(request, '<GetCapabilitiesResponse/>');
        }
      });

      final result = await OnvifSoapClient(
        uri.host,
        login: const CameraLogin('oper&ator', 'p@ss'),
      ).call(uri, onvifDeviceNamespace, 'GetCapabilities');
      expect(result.response('GetCapabilities'), isNotNull);
      expect(calls, hasLength(2));
      for (final (body, _, length, type) in calls) {
        expect(_operation(body).name.local, 'GetCapabilities');
        expect(onvifText(XmlDocument.parse(body), 'Username'), 'oper&ator');
        expect(utf8.encode(body).length, length);
        expect(
          type,
          contains('action="$onvifDeviceNamespace/GetCapabilities"'),
        );
      }
      final auth = calls.last.$2!;
      expect(auth, startsWith('Digest '));
      final cnonce = RegExp(r'cnonce="([^"]+)"').firstMatch(auth)![1];
      String hash(String text) => md5.convert(utf8.encode(text)).toString();
      final ha1 = hash('oper&ator:Camera:p@ss');
      final ha2 = hash('POST:/onvif/device_service');
      expect(
        auth,
        contains('response="${hash('$ha1:n123:00000001:$cnonce:auth:$ha2')}"'),
      );
    },
  );

  test(
    'legacy Media requests an H.264 substream and falls back after a TCP fault',
    () async {
      final attempts = <(String, String)>[];
      final uri = await _serve((request) async {
        final operation = _operation(await utf8.decoder.bind(request).join());
        switch (operation.name.local) {
          case 'GetSystemDateAndTime':
            await _reply(request, '<GetSystemDateAndTimeResponse/>');
          case 'GetCapabilities':
            await _reply(
              request,
              '<GetCapabilitiesResponse><Capabilities><Media>'
              '<XAddr>http://0.0.0.0:${request.requestedUri.port}/onvif/media_service</XAddr>'
              '</Media></Capabilities></GetCapabilitiesResponse>',
            );
          case 'GetProfiles':
            await _reply(
              request,
              '<GetProfilesResponse>'
              '<Profiles token="main"><Encoding>H265</Encoding><Height>2160</Height></Profiles>'
              '<Profiles token="sub&amp;1"><Encoding>H264</Encoding><Height>720</Height></Profiles>'
              '</GetProfilesResponse>',
            );
          case 'GetStreamUri':
            final token = onvifText(operation, 'ProfileToken')!;
            final protocol = onvifText(operation, 'Protocol')!;
            attempts.add((token, protocol));
            if (onvifElements(operation, 'Stream').single.innerText !=
                    'RTP-Unicast' ||
                protocol == 'RTSP') {
              await _reply(request, '<Fault/>', code: 400);
            } else {
              await _reply(
                request,
                '<GetStreamUriResponse><MediaUri>'
                '<Uri>rtsp://0.0.0.0:554/${onvifEscape(token)}</Uri>'
                '</MediaUri></GetStreamUriResponse>',
              );
            }
          default:
            await _reply(request, '<Fault/>', code: 400);
        }
      });

      final camera = _camera.copyWith(
        ipAddress: uri.host,
        onvifServiceUrl: uri.toString(),
      );
      final device = await openOnvifDevice(camera, null);
      final streams = await OnvifMediaResolver(device).resolve();
      expect(attempts.take(2), [('sub&1', 'RTSP'), ('sub&1', 'UDP')]);
      expect(streams.map((stream) => stream.profileToken), ['sub&1', 'main']);
      expect(streams.first.uri.host, uri.host);
    },
  );

  test('resolves a camera exposing only Media2 through GetServices', () async {
    final uri = await _serve((request) async {
      final operation = _operation(await utf8.decoder.bind(request).join());
      final name = operation.name.local;
      if (name == 'GetCapabilities') {
        await _reply(request, '<GetCapabilitiesResponse/>');
      } else if (name == 'GetServices') {
        await _reply(
          request,
          '<GetServicesResponse><Service>'
          '<Namespace>$onvifMedia2Namespace</Namespace><XAddr>/media2</XAddr>'
          '</Service></GetServicesResponse>',
        );
      } else if (request.uri.path != '/media2' ||
          operation.name.namespaceUri != onvifMedia2Namespace) {
        await _reply(request, '<Fault/>', code: 400);
      } else if (name == 'GetProfiles') {
        await _reply(
          request,
          '<GetProfilesResponse><Profiles token="m2"/></GetProfilesResponse>',
        );
      } else if (name == 'GetStreamUri' &&
          onvifText(operation, 'Protocol') == 'RTSP' &&
          onvifElements(operation, 'StreamSetup').isEmpty) {
        await _reply(
          request,
          '<GetStreamUriResponse><Uri>rtsp://127.0.0.1/live</Uri>'
          '</GetStreamUriResponse>',
        );
      } else {
        await _reply(request, '<Fault/>', code: 400);
      }
    });

    final result = await OnvifMediaResolver(
      OnvifDevice(uri, OnvifSoapClient(uri.host)),
    ).resolve();
    expect(result.single.uri.path, '/live');
  });

  test('Wi-Fi configuration touches only the proven wireless interface', () async {
    final operations = <XmlElement>[];
    final uri = await _serve((request) async {
      final operation = _operation(await utf8.decoder.bind(request).join());
      operations.add(operation);
      switch (operation.name.local) {
        case 'GetNetworkInterfaces':
          await _reply(
            request,
            '<GetNetworkInterfacesResponse>'
            '<NetworkInterfaces token="eth0"><Extension><InterfaceType>6</InterfaceType>'
            '</Extension></NetworkInterfaces>'
            '<NetworkInterfaces token="wifi"><Extension><InterfaceType>71</InterfaceType>'
            '</Extension></NetworkInterfaces></GetNetworkInterfacesResponse>',
          );
        case 'GetDot11Capabilities':
          await _reply(
            request,
            '<GetDot11CapabilitiesResponse><Capabilities>'
            '<ScanAvailableNetworks>true</ScanAvailableNetworks>'
            '</Capabilities></GetDot11CapabilitiesResponse>',
          );
        case 'ScanAvailableDot11Networks':
          await _reply(
            request,
            '<ScanAvailableDot11NetworksResponse><Networks>'
            '<SSID>446f6d</SSID><AuthAndMangementSuite>PSK</AuthAndMangementSuite>'
            '</Networks></ScanAvailableDot11NetworksResponse>',
          );
        case 'SetNetworkInterfaces':
          await _reply(
            request,
            '<SetNetworkInterfacesResponse><RebootNeeded>false</RebootNeeded>'
            '</SetNetworkInterfacesResponse>',
          );
        default:
          await _reply(request, '<Fault/>', code: 400);
      }
    });
    final setup = OnvifWifiSetup(OnvifDevice(uri, OnvifSoapClient(uri.host)));
    final wireless = (await setup.inspect()).single;
    expect(wireless.token, 'wifi');
    expect(await setup.scan(wireless), ['Dom']);
    await expectLater(
      setup.connect(
        wireless: const OnvifWifiInterface('eth0', 'LAN'),
        ssid: 'Dom',
        password: 'correct&key',
      ),
      throwsA(isA<CameraConnectionIssue>()),
    );
    expect(
      operations.where((x) => x.name.local == 'SetNetworkInterfaces'),
      isEmpty,
    );
    expect(
      await setup.connect(
        wireless: wireless,
        ssid: 'Dom',
        password: 'correct&key',
      ),
      isFalse,
    );
    expect(onvifText(operations.last, 'InterfaceToken'), 'wifi');
    expect(onvifText(operations.last, 'SSID'), '446f6d');
    expect(onvifText(operations.last, 'Passphrase'), 'correct&key');
    expect(onvifText(operations.last, 'DHCP'), 'true');
    expect(
      () => buildOnvifWifiBody(
        interfaceToken: 'wifi',
        ssid: 'Dom',
        password: 'short',
      ),
      throwsA(isA<CameraConnectionIssue>()),
    );
  });

  test('Android tries TCP and alternate profiles without changing HLS', () {
    final a = Uri.parse('rtsp://192.168.1.6/sub');
    final b = Uri.parse('rtsp://192.168.1.6/main');
    final hls = Uri.parse('https://camera.example/live.m3u8');
    final attempts = cameraPlaybackAttempts([a, a, b], android: true);
    expect(attempts.map((attempt) => (attempt.uri, attempt.transport)), [
      (a, CameraRtspTransport.tcp),
      (b, CameraRtspTransport.tcp),
      (a, CameraRtspTransport.platformDefault),
      (b, CameraRtspTransport.platformDefault),
    ]);
    expect(
      cameraPlaybackAttempts([hls], android: true).single.transport,
      CameraRtspTransport.platformDefault,
    );
    expect(cameraPlaybackAttempts([a], android: false), hasLength(1));
  });
}
