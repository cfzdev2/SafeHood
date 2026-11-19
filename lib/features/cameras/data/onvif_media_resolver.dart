import 'package:xml/xml.dart';

import '../domain/camera.dart';
import 'local_camera_connection.dart';
import 'onvif_soap_client.dart';

class OnvifDevice {
  const OnvifDevice(this.endpoint, this.soap);

  final Uri endpoint;
  final OnvifSoapClient soap;

  Future<OnvifSoapResult> call(
    String operation, {
    String body = '',
    Duration timeout = const Duration(seconds: 4),
    bool sensitive = false,
  }) => soap.call(
    endpoint,
    onvifDeviceNamespace,
    operation,
    body: body,
    timeout: timeout,
    sensitive: sensitive,
  );
}

class OnvifStream {
  const OnvifStream(this.uri, this.profileToken, this.mediaEndpoint);

  final Uri uri;
  final String profileToken;
  final Uri mediaEndpoint;
}

List<Uri> cameraOnvifEndpoints(Camera camera) {
  final saved = parseManualOnvifUri(camera.onvifServiceUrl ?? '');
  final ip = camera.ipAddress;
  final host = ip != null && isCameraLanHost(ip) ? ip : saved?.host;
  if (host == null) return const [];
  final endpoints = <Uri>{
    if (saved != null) saved.replace(host: host),
    for (final port in {
      ...camera.openPorts.where(
        const {80, 443, 8000, 8080, 8443, 8899, 9000}.contains,
      ),
      80,
      8899,
      8080,
      8000,
      443,
    })
      Uri(
        scheme: const {443, 8443}.contains(port) ? 'https' : 'http',
        host: host,
        port: port,
        path: '/onvif/device_service',
      ),
  };
  return endpoints.toList(growable: false);
}

Future<OnvifDevice> openOnvifDevice(Camera camera, CameraLogin? login) async {
  final endpoints = cameraOnvifEndpoints(camera);
  if (endpoints.isEmpty) {
    throw const CameraConnectionIssue(
      'Kamera nie ma lokalnego adresu ONVIF.',
      retryable: false,
    );
  }

  Future<(OnvifDevice, bool)?> check(Uri endpoint) async {
    final soap = OnvifSoapClient(endpoint.host, login: login);
    try {
      final response = await soap.call(
        endpoint,
        onvifDeviceNamespace,
        'GetSystemDateAndTime',
        timeout: const Duration(seconds: 2),
        authenticated: false,
      );
      final clock = response.response('GetSystemDateAndTime');
      soap.updateCameraClock(clock);
      final device = OnvifDevice(endpoint, soap);
      if (clock != null || response.fault != null) {
        return (device, true);
      }
      return response.requiresLogin ? (device, false) : null;
    } on Exception {
      return null;
    }
  }

  // Use the advertised/entered endpoint first. Only probe alternative ports
  // if it didn't return ONVIF. Requests at this stage contain no credentials.
  final preferred = await check(endpoints.first);
  if (preferred != null && preferred.$2) return preferred.$1;
  if (preferred != null &&
      parseManualOnvifUri(camera.onvifServiceUrl ?? '') != null) {
    return preferred.$1;
  }
  final alternatives = await Future.wait(endpoints.skip(1).map(check));
  for (final result in alternatives) {
    if (result != null && result.$2) return result.$1;
  }
  if (preferred != null) return preferred.$1;
  for (final result in alternatives) {
    if (result != null) return result.$1;
  }
  throw const CameraConnectionIssue(
    'Kamera nie odpowiada na ONVIF. Sprawdź jej adres i włącz ONVIF w kamerze.',
  );
}

/// Use the selected camera host even if a camera advertises 0.0.0.0, its
/// factory IP, or a different machine. Never follow redirects with a login.
Uri? onvifAdvertisedUri(
  String? value,
  Uri base, {
  required Set<String> schemes,
}) {
  if (value == null || value.trim().isEmpty) return null;
  final parsed = Uri.tryParse(value.trim());
  if (parsed == null) return null;
  final resolved = base.resolveUri(parsed);
  if (!schemes.contains(resolved.scheme) ||
      (resolved.hasPort && (resolved.port < 1 || resolved.port > 65535))) {
    return null;
  }
  // Do not reuse credentials supplied by the camera, or carry a fragment.
  return resolved.replace(host: base.host, userInfo: '').removeFragment();
}

String buildOnvifStreamBody(
  String token, {
  required bool media2,
  required bool preferTcp,
}) {
  final escaped = onvifEscape(token);
  if (media2) {
    return '<o:Protocol>${preferTcp ? 'RTSP' : 'RtspUnicast'}</o:Protocol>'
        '<o:ProfileToken>$escaped</o:ProfileToken>';
  }
  return '<o:StreamSetup><tt:Stream>RTP-Unicast</tt:Stream>'
      '<tt:Transport><tt:Protocol>${preferTcp ? 'RTSP' : 'UDP'}</tt:Protocol>'
      '</tt:Transport></o:StreamSetup><o:ProfileToken>$escaped</o:ProfileToken>';
}

class OnvifMediaResolver {
  const OnvifMediaResolver(this.device);

  final OnvifDevice device;

  Future<List<OnvifStream>> resolve() async {
    final uriSchemes = const {'http', 'https'};
    final endpoints = <(Uri, String)>{};
    final candidates = <OnvifStream>[];
    var authRequired = false;
    final watch = Stopwatch()..start();
    const budget = Duration(seconds: 16);

    Future<OnvifSoapResult?> tryCall(
      Future<OnvifSoapResult> Function(Duration) call,
    ) async {
      final remaining = budget - watch.elapsed;
      if (remaining <= Duration.zero) return null;
      const limit = Duration(seconds: 4);
      try {
        final result = await call(remaining < limit ? remaining : limit);
        authRequired |= result.requiresLogin;
        return result;
      } on Exception {
        return null;
      }
    }

    void addEndpoint(String? advertised, String namespace) {
      final uri = onvifAdvertisedUri(
        advertised,
        device.endpoint,
        schemes: uriSchemes,
      );
      if (uri != null) endpoints.add((uri, namespace));
    }

    final caps = await tryCall(
      (timeout) => device.call(
        'GetCapabilities',
        body: '<o:Category>All</o:Category>',
        timeout: timeout,
      ),
    );
    final media = onvifElements(caps?.response('GetCapabilities'), 'Media');
    for (final item in media) {
      addEndpoint(onvifText(item, 'XAddr'), onvifMediaNamespace);
    }

    final tried = <(Uri, String)>{};
    Future<void> resolveAvailable() async {
      for (final (endpoint, namespace) in endpoints) {
        if (!tried.add((endpoint, namespace))) continue;
        final media2 = namespace == onvifMedia2Namespace;
        var profiles = await tryCall(
          (timeout) => device.soap.call(
            endpoint,
            namespace,
            'GetProfiles',
            body: media2 ? '<o:Type>VideoEncoder</o:Type>' : '',
            timeout: timeout,
          ),
        );
        if (media2 && profiles?.response('GetProfiles') == null) {
          profiles = await tryCall(
            (timeout) => device.soap.call(
              endpoint,
              namespace,
              'GetProfiles',
              timeout: timeout,
            ),
          );
        }

        final tokens = onvifElements(
          profiles?.response('GetProfiles'),
          'Profiles',
        ).map(_OnvifProfile.tryParse).whereType<_OnvifProfile>().toList();
        tokens.sort((a, b) => a.score.compareTo(b.score));

        for (final profile in tokens.take(4)) {
          for (final preferTcp in [true, false]) {
            final reply = await tryCall(
              (timeout) => device.soap.call(
                endpoint,
                namespace,
                'GetStreamUri',
                timeout: timeout,
                body: buildOnvifStreamBody(
                  profile.token,
                  media2: media2,
                  preferTcp: preferTcp,
                ),
              ),
            );
            final stream = onvifAdvertisedUri(
              onvifText(reply?.response('GetStreamUri'), 'Uri'),
              endpoint,
              schemes: const {'rtsp'},
            );
            if (stream == null) {
              if (reply?.requiresLogin == true) break;
              continue;
            }
            final withLogin = applyCameraLogin(stream, device.soap.login);
            if (!candidates.any((item) => item.uri == withLogin)) {
              candidates.add(OnvifStream(withLogin, profile.token, endpoint));
            }
            break;
          }
          if (candidates.length >= 2) return;
        }
        if (candidates.isNotEmpty) return;
      }
    }

    await resolveAvailable();
    if (candidates.isNotEmpty) return candidates;

    final services = await tryCall(
      (timeout) => device.call(
        'GetServices',
        timeout: timeout,
        body: '<o:IncludeCapability>false</o:IncludeCapability>',
      ),
    );
    for (final service in onvifElements(
      services?.response('GetServices'),
      'Service',
    )) {
      final namespace = onvifText(service, 'Namespace');
      if (namespace == onvifMediaNamespace ||
          namespace == onvifMedia2Namespace) {
        addEndpoint(onvifText(service, 'XAddr'), namespace!);
      }
    }

    // Common defaults for devices with incomplete capabilities responses.
    if (!authRequired || device.soap.login != null) {
      addEndpoint('/onvif/media_service', onvifMediaNamespace);
      addEndpoint('/onvif/media2_service', onvifMedia2Namespace);
    }

    await resolveAvailable();
    if (candidates.isNotEmpty) return candidates;
    if (authRequired) {
      throw CameraConnectionIssue(
        device.soap.login == null
            ? 'Kamera wymaga logowania. Dodaj konto ONVIF w ustawieniach kamery.'
            : 'Kamera odrzuciła logowanie. Sprawdź dane konta ONVIF.',
        retryable: false,
      );
    }
    throw const CameraConnectionIssue(
      'Kamera nie zwróciła adresu obrazu. Możesz wpisać adres RTSP w ustawieniach.',
    );
  }
}

class _OnvifProfile {
  const _OnvifProfile(this.token, this.score);

  final String token;
  final int score;

  static _OnvifProfile? tryParse(XmlElement element) {
    final token = element.getAttribute('token')?.trim();
    if (token == null || token.isEmpty) return null;

    final codec = onvifText(element, 'Encoding')?.toUpperCase();
    final height = int.tryParse(onvifText(element, 'Height') ?? '');
    final codecPenalty = switch (codec) {
      'H264' || 'H.264' => 0,
      null => 10000,
      _ => 20000,
    };
    // On phones prefer a usable H.264 substream before a very large main stream.
    return _OnvifProfile(
      token,
      codecPenalty + (height == null ? 800 : (height - 720).abs()),
    );
  }
}
