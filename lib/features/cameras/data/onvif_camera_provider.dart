import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../domain/camera.dart';
import '../domain/camera_provider.dart';

class OnvifCameraProvider
    implements
        CameraProvider,
        CameraDetectionSource,
        CameraDetectionMonitoringController {
  @override
  final Camera camera;

  late CameraRuntimeState _state;

  Uri? _mediaServiceUrl;
  Uri? _eventsServiceUrl;
  Uri? _pullPointUrl;

  Uri? get eventsServiceUrl => _eventsServiceUrl;

  String? _profileToken;
  Uri? _streamUri;

  Timer? _eventPollingTimer;
  Timer? _eventReconnectTimer;

  bool _pullingEvents = false;
  bool _startingDetectionMonitoring = false;
  bool _detectionMonitoringRequested = false;
  bool _disposed = false;

  int _eventReconnectAttempt = 0;

  Uri? get mediaServiceUrl => _mediaServiceUrl;

  String? get profileToken => _profileToken;

  Uri? get streamUri => _streamUri;

  @override
  Uri? get liveStreamUri => _streamUri;

  final StreamController<CameraRuntimeState> _stateController =
      StreamController<CameraRuntimeState>.broadcast();

  final StreamController<CameraDetection> _detectionController =
      StreamController<CameraDetection>.broadcast();

  OnvifCameraProvider({required this.camera}) {
    _state = CameraRuntimeState.fromCamera(
      camera,
    ).copyWith(isOnline: false, isConnecting: false, isLive: false);
  }

  @override
  CameraCapabilities get capabilities => CameraCapabilities(
    supportsLive: _streamUri != null,
    supportsAudio: false,
    supportsTalk: false,
    supportsMotionDetection: false,
    supportsPersonDetection: false,
    supportsRecordings: false,
    supportsSnapshot: false,
    supportsPtz: false,
  );

  @override
  Stream<CameraRuntimeState> watchState() async* {
    yield _state;
    yield* _stateController.stream;
  }

  @override
  Stream<CameraDetection> watchDetections() {
    return _detectionController.stream;
  }

  @override
  Future<void> startDetectionMonitoring() async {
    _detectionMonitoringRequested = true;

    if (_disposed) {
      return;
    }

    if (_pullPointUrl != null) {
      debugPrint('ONVIF EVENTS: monitoring już aktywny');

      return;
    }

    if (_startingDetectionMonitoring) {
      debugPrint('ONVIF EVENTS: monitoring już się uruchamia');

      return;
    }

    _eventReconnectTimer?.cancel();
    _eventReconnectTimer = null;
    _startingDetectionMonitoring = true;

    try {
      final endpoint = _resolveDeviceServiceUrl();
      final eventsUrl = await _getEventsServiceUrl(endpoint);

      if (!_detectionMonitoringRequested || _disposed) {
        return;
      }

      if (eventsUrl == null) {
        debugPrint('ONVIF EVENTS: brak Events Service');

        _scheduleEventReconnect();

        return;
      }

      _eventsServiceUrl = eventsUrl;

      debugPrint('ONVIF EVENTS: service = $eventsUrl');

      final subscriptionCreated = await _createEventSubscription(eventsUrl);

      if (!subscriptionCreated) {
        _scheduleEventReconnect();
      }
    } catch (error, stackTrace) {
      debugPrint('ONVIF EVENTS START ERROR: $error');

      debugPrint('$stackTrace');

      _scheduleEventReconnect();
    } finally {
      _startingDetectionMonitoring = false;
    }
  }

  @override
  Future<void> stopDetectionMonitoring() async {
    _detectionMonitoringRequested = false;
    _eventReconnectAttempt = 0;

    _stopEventPolling();

    _eventsServiceUrl = null;
  }

  @override
  Future<void> connect() async {
    _emit(_state.copyWith(isConnecting: true, isOnline: false, isLive: false));

    try {
      final endpoint = _resolveDeviceServiceUrl();

      debugPrint('ONVIF: próbuję $endpoint');

      final result = await _probeDeviceService(endpoint);

      switch (result) {
        case _OnvifProbeResult.available:
          debugPrint('ONVIF: urządzenie odpowiada');

          //
          // Media / RTSP
          //

          final mediaUrl = await _getMediaServiceUrl(endpoint);

          if (mediaUrl != null) {
            _mediaServiceUrl = mediaUrl;

            debugPrint(
              'ONVIF: Media Service = '
              '$mediaUrl',
            );

            final profileToken = await _getFirstProfileToken(mediaUrl);

            if (profileToken != null) {
              _profileToken = profileToken;

              debugPrint(
                'ONVIF: profile token = '
                '$profileToken',
              );

              final streamUri = await _getStreamUri(mediaUrl, profileToken);

              if (streamUri != null) {
                _streamUri = streamUri;

                debugPrint(
                  'ONVIF: RTSP URI = '
                  '$streamUri',
                );
              } else {
                debugPrint(
                  'ONVIF: nie udało się '
                  'pobrać RTSP URI',
                );
              }
            } else {
              debugPrint(
                'ONVIF: nie udało się '
                'pobrać profilu Media',
              );
            }
          } else {
            debugPrint(
              'ONVIF: nie udało się '
              'ustalić Media Service',
            );
          }

          _emit(
            _state.copyWith(isConnecting: false, isOnline: true, isLive: false),
          );

        case _OnvifProbeResult.authenticationRequired:
          debugPrint(
            'ONVIF: urządzenie odpowiada, '
            'ale wymaga logowania',
          );

          _emit(
            _state.copyWith(isConnecting: false, isOnline: true, isLive: false),
          );

        case _OnvifProbeResult.unavailable:
          debugPrint('ONVIF: brak poprawnej odpowiedzi');

          _emit(
            _state.copyWith(
              isConnecting: false,
              isOnline: false,
              isLive: false,
            ),
          );
      }
    } catch (error) {
      debugPrint('ONVIF CONNECT ERROR: $error');

      _emit(
        _state.copyWith(isConnecting: false, isOnline: false, isLive: false),
      );
    }
  }

  @override
  Future<void> disconnect() async {
    _detectionMonitoringRequested = false;
    _eventReconnectAttempt = 0;

    _stopEventPolling();

    _mediaServiceUrl = null;
    _eventsServiceUrl = null;
    _pullPointUrl = null;

    _profileToken = null;
    _streamUri = null;

    _emit(_state.copyWith(isConnecting: false, isOnline: false, isLive: false));
  }

  @override
  Future<void> startLive() async {
    final streamUri = _streamUri;

    if (streamUri == null) {
      debugPrint(
        'ONVIF: LIVE niedostępne - '
        'brak RTSP URI',
      );

      _emit(_state.copyWith(isLive: false, isConnecting: false));

      return;
    }

    debugPrint(
      'ONVIF: uruchamiam LIVE: '
      '$streamUri',
    );

    _emit(_state.copyWith(isOnline: true, isConnecting: false, isLive: true));
  }

  @override
  Future<void> stopLive() async {
    _emit(_state.copyWith(isLive: false));
  }

  @override
  Future<void> setMotionDetection(bool enabled) async {
    debugPrint(
      'ONVIF: motion detection '
      'jeszcze nieobsługiwane',
    );
  }

  @override
  Future<void> takeSnapshot() async {
    debugPrint(
      'ONVIF: snapshot '
      'jeszcze nieobsługiwany',
    );
  }

  Uri _resolveDeviceServiceUrl() {
    final stored = camera.onvifServiceUrl;

    if (stored != null && stored.trim().isNotEmpty) {
      final uri = Uri.tryParse(stored.trim());

      if (uri != null &&
          (uri.scheme == 'http' || uri.scheme == 'https') &&
          uri.host.isNotEmpty) {
        return uri;
      }
    }

    final ip = camera.ipAddress;

    if (ip == null || ip.trim().isEmpty) {
      throw StateError('Kamera ONVIF nie ma adresu IP.');
    }

    var scheme = 'http';
    var port = 80;

    if (camera.openPorts.contains(80)) {
      scheme = 'http';
      port = 80;
    } else if (camera.openPorts.contains(443)) {
      scheme = 'https';
      port = 443;
    } else if (camera.openPorts.contains(8080)) {
      scheme = 'http';
      port = 8080;
    } else if (camera.openPorts.contains(8443)) {
      scheme = 'https';
      port = 8443;
    } else if (camera.openPorts.contains(8000)) {
      scheme = 'http';
      port = 8000;
    } else if (camera.openPorts.contains(8899)) {
      scheme = 'http';
      port = 8899;
    }

    return Uri(
      scheme: scheme,
      host: ip,
      port: port,
      path: '/onvif/device_service',
    );
  }

  Future<_OnvifProbeResult> _probeDeviceService(Uri endpoint) async {
    final client = HttpClient();

    client.connectionTimeout = const Duration(seconds: 3);

    client.badCertificateCallback = (X509Certificate _, String host, int _) {
      return _isPrivateIpv4(host);
    };

    try {
      final request = await client
          .postUrl(endpoint)
          .timeout(const Duration(seconds: 4));

      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/soap+xml; '
        'charset=utf-8',
      );

      request.headers.set(HttpHeaders.userAgentHeader, 'SafeHood/1.0');

      request.write(_getSystemDateAndTimeSoap);

      final response = await request.close().timeout(
        const Duration(seconds: 4),
      );

      debugPrint(
        'ONVIF: HTTP '
        '${response.statusCode}',
      );

      if (response.statusCode == 401 || response.statusCode == 403) {
        await response.drain<void>();

        return _OnvifProbeResult.authenticationRequired;
      }

      final buffer = StringBuffer();

      await for (final chunk in response.transform(utf8.decoder)) {
        buffer.write(chunk);

        if (buffer.length > 32768) {
          break;
        }
      }

      final body = buffer.toString().toLowerCase();

      if (response.statusCode == 200 && _looksLikeSoap(body)) {
        return _OnvifProbeResult.available;
      }

      //
      // SOAP Fault nadal potwierdza,
      // że trafiliśmy w usługę
      // SOAP/ONVIF.
      //

      if (body.contains('soap') && body.contains('fault')) {
        return _OnvifProbeResult.available;
      }

      return _OnvifProbeResult.unavailable;
    } on SocketException catch (error) {
      debugPrint('ONVIF SOCKET ERROR: $error');

      return _OnvifProbeResult.unavailable;
    } on TimeoutException {
      debugPrint('ONVIF: timeout');

      return _OnvifProbeResult.unavailable;
    } finally {
      client.close(force: true);
    }
  }

  Future<Uri?> _getMediaServiceUrl(Uri deviceServiceUrl) async {
    final response = await _sendSoapRequest(
      deviceServiceUrl,
      _getCapabilitiesSoap,
    );

    if (response == null) {
      return null;
    }

    final match = RegExp(
      r'<(?:\w+:)?Media[^>]*>[\s\S]*?'
      r'<(?:\w+:)?XAddr[^>]*>'
      r'(.*?)'
      r'</(?:\w+:)?XAddr>',
      caseSensitive: false,
    ).firstMatch(response);

    final value = match?.group(1)?.trim();

    if (value == null || value.isEmpty) {
      debugPrint('ONVIF: brak Media XAddr');

      return null;
    }

    final uri = Uri.tryParse(value);

    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      debugPrint(
        'ONVIF: niepoprawny '
        'Media XAddr: $value',
      );

      return null;
    }

    return uri;
  }

  Future<String?> _getFirstProfileToken(Uri mediaServiceUrl) async {
    final response = await _sendSoapRequest(mediaServiceUrl, _getProfilesSoap);

    if (response == null) {
      return null;
    }

    final match = RegExp(
      r'''<(?:\w+:)?Profiles[^>]*token=["']([^"']+)["']''',
      caseSensitive: false,
    ).firstMatch(response);

    final token = match?.group(1)?.trim();

    if (token == null || token.isEmpty) {
      debugPrint('ONVIF: brak profilu Media');

      return null;
    }

    return token;
  }

  Future<Uri?> _getStreamUri(Uri mediaServiceUrl, String profileToken) async {
    final body = _buildGetStreamUriSoap(profileToken);

    final response = await _sendSoapRequest(mediaServiceUrl, body);

    if (response == null) {
      return null;
    }

    final match = RegExp(
      r'<(?:\w+:)?Uri[^>]*>'
      r'(.*?)'
      r'</(?:\w+:)?Uri>',
      caseSensitive: false,
    ).firstMatch(response);

    final value = match?.group(1)?.trim();

    if (value == null || value.isEmpty) {
      debugPrint('ONVIF: brak Stream URI');

      return null;
    }

    final uri = Uri.tryParse(value);

    if (uri == null || uri.scheme.toLowerCase() != 'rtsp') {
      debugPrint(
        'ONVIF: niepoprawny '
        'RTSP URI: $value',
      );

      return null;
    }

    return uri;
  }

  Future<Uri?> _getEventsServiceUrl(Uri deviceServiceUrl) async {
    final response = await _sendSoapRequest(
      deviceServiceUrl,
      _getCapabilitiesSoap,
    );

    if (response == null) {
      debugPrint(
        'ONVIF EVENTS: brak odpowiedzi '
        'GetCapabilities',
      );

      return null;
    }

    final eventsMatch = RegExp(
      r'<(?:[A-Za-z_][A-Za-z0-9_.-]*:)?Events\b[^>]*>'
      r'([\s\S]*?)'
      r'</(?:[A-Za-z_][A-Za-z0-9_.-]*:)?Events>',
      caseSensitive: false,
    ).firstMatch(response);

    if (eventsMatch == null) {
      debugPrint(
        'ONVIF EVENTS: '
        'brak sekcji Events w XML',
      );

      return null;
    }

    final eventsBlock = eventsMatch.group(1) ?? '';

    final xAddrMatch = RegExp(
      r'<(?:[A-Za-z_][A-Za-z0-9_.-]*:)?XAddr\b[^>]*>'
      r'\s*([^<]+?)\s*'
      r'</(?:[A-Za-z_][A-Za-z0-9_.-]*:)?XAddr>',
      caseSensitive: false,
    ).firstMatch(eventsBlock);

    final value = xAddrMatch?.group(1)?.trim();

    if (value == null || value.isEmpty) {
      debugPrint(
        'ONVIF EVENTS: '
        'sekcja Events istnieje, '
        'ale brak XAddr',
      );

      return null;
    }

    final uri = Uri.tryParse(value);

    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      debugPrint(
        'ONVIF EVENTS: '
        'niepoprawny XAddr: $value',
      );

      return null;
    }

    debugPrint(
      'ONVIF EVENTS: '
      'znaleziono XAddr = $uri',
    );

    return uri;
  }

  Future<bool> _createEventSubscription(Uri eventsServiceUrl) async {
    final response = await _sendSoapRequest(
      eventsServiceUrl,
      _createPullPointSubscriptionSoap,
    );

    if (!_detectionMonitoringRequested || _disposed) {
      return false;
    }

    if (response == null) {
      debugPrint(
        'ONVIF EVENTS: '
        'nie udało się utworzyć PullPoint',
      );

      return false;
    }

    final match = RegExp(
      r'<(?:\w+:)?Address[^>]*>'
      r'\s*(.*?)\s*'
      r'</(?:\w+:)?Address>',
      caseSensitive: false,
    ).firstMatch(response);

    final value = match?.group(1)?.trim();

    if (value == null || value.isEmpty) {
      debugPrint('ONVIF EVENTS: brak adresu PullPoint');

      return false;
    }

    final uri = Uri.tryParse(value);

    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      debugPrint(
        'ONVIF EVENTS: '
        'niepoprawny PullPoint: $value',
      );

      return false;
    }

    _pullPointUrl = uri;

    debugPrint('ONVIF EVENTS: PullPoint utworzony');

    debugPrint('ONVIF EVENTS: subscription = $uri');

    _startEventPolling();

    return true;
  }

  void _startEventPolling() {
    _eventPollingTimer?.cancel();

    debugPrint(
      'ONVIF EVENTS: '
      'czekam na zdarzenia...',
    );

    unawaited(_pullEvents());

    _eventPollingTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_pullEvents());
    });
  }

  void _stopEventPolling() {
    _eventPollingTimer?.cancel();
    _eventPollingTimer = null;

    _eventReconnectTimer?.cancel();
    _eventReconnectTimer = null;

    _pullPointUrl = null;
  }

  void _scheduleEventReconnect() {
    if (!_detectionMonitoringRequested ||
        _disposed ||
        _eventReconnectTimer != null) {
      return;
    }

    _stopEventPolling();

    _eventReconnectAttempt += 1;

    final delaySeconds = _eventReconnectDelaySeconds(_eventReconnectAttempt);

    debugPrint(
      'ONVIF EVENTS: reconnect '
      'próba $_eventReconnectAttempt '
      'za $delaySeconds s',
    );

    _eventReconnectTimer = Timer(Duration(seconds: delaySeconds), () {
      _eventReconnectTimer = null;

      if (!_detectionMonitoringRequested || _disposed) {
        return;
      }

      debugPrint('ONVIF EVENTS: próbuję połączyć ponownie');

      unawaited(startDetectionMonitoring());
    });
  }

  int _eventReconnectDelaySeconds(int attempt) {
    const delays = <int>[2, 4, 8, 16, 30];

    final index = attempt - 1;

    if (index < 0) {
      return delays.first;
    }

    if (index >= delays.length) {
      return delays.last;
    }

    return delays[index];
  }

  Future<void> _pullEvents() async {
    if (_disposed || !_detectionMonitoringRequested || _pullingEvents) {
      return;
    }

    final pullPoint = _pullPointUrl;

    if (pullPoint == null) {
      return;
    }

    _pullingEvents = true;

    try {
      final response = await _sendSoapRequest(
        pullPoint,
        _pullMessagesSoap,
        connectionTimeout: const Duration(seconds: 10),
        responseTimeout: const Duration(seconds: 15),
        logSuccess: false,
      );

      if (!_detectionMonitoringRequested || _disposed) {
        return;
      }

      if (response == null) {
        _scheduleEventReconnect();

        return;
      }

      _eventReconnectAttempt = 0;

      final type = _parseOnvifEventType(response);

      if (type == null || type == 'unknown') {
        return;
      }

      final occurredAt = _parseOnvifOccurredAt(response);

      final detection = CameraDetection(
        type: type,
        occurredAt: occurredAt ?? DateTime.now().toUtc(),
        source: 'onvif',
      );

      debugPrint('ONVIF EVENT: ${detection.type}');

      if (!_detectionController.isClosed) {
        _detectionController.add(detection);
      }
    } finally {
      _pullingEvents = false;
    }
  }

  String? _parseOnvifEventType(String response) {
    final lower = response.toLowerCase();

    if (!lower.contains('notificationmessage')) {
      return null;
    }

    if (lower.contains('person') || lower.contains('human')) {
      return 'person';
    }

    if (lower.contains('vehicle') || lower.contains('car')) {
      return 'vehicle';
    }

    if (lower.contains('motion')) {
      return 'motion';
    }

    return 'unknown';
  }

  DateTime? _parseOnvifOccurredAt(String response) {
    final match = RegExp(
      r'''UtcTime=["']([^"']+)["']''',
      caseSensitive: false,
    ).firstMatch(response);

    final value = match?.group(1)?.trim();

    if (value == null || value.isEmpty) {
      return null;
    }

    return DateTime.tryParse(value)?.toUtc();
  }

  Future<String?> _sendSoapRequest(
    Uri endpoint,
    String body, {
    Duration connectionTimeout = const Duration(seconds: 4),
    Duration responseTimeout = const Duration(seconds: 5),
    bool logSuccess = true,
  }) async {
    final client = HttpClient();

    client.connectionTimeout = connectionTimeout;

    client.badCertificateCallback = (X509Certificate _, String host, int _) {
      return _isPrivateIpv4(host);
    };

    try {
      final request = await client.postUrl(endpoint).timeout(connectionTimeout);

      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/soap+xml; charset=utf-8',
      );

      request.headers.set(HttpHeaders.userAgentHeader, 'SafeHood/1.0');

      request.write(body);

      final response = await request.close().timeout(responseTimeout);

      if (logSuccess ||
          response.statusCode < 200 ||
          response.statusCode >= 300) {
        debugPrint(
          'ONVIF SOAP: '
          '${endpoint.path} → '
          '${response.statusCode}',
        );
      }

      if (response.statusCode == 401 || response.statusCode == 403) {
        await response.drain<void>();

        debugPrint('ONVIF SOAP: wymagane logowanie');

        return null;
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.drain<void>();

        return null;
      }

      final buffer = StringBuffer();

      await for (final chunk in response.transform(utf8.decoder)) {
        buffer.write(chunk);

        if (buffer.length >= 65536) {
          break;
        }
      }

      final responseBody = buffer.toString();

      if (responseBody.isEmpty) {
        return null;
      }

      return responseBody;
    } on SocketException catch (error) {
      debugPrint('ONVIF SOAP SOCKET ERROR [${endpoint.path}]: $error');

      return null;
    } on TimeoutException {
      debugPrint('ONVIF SOAP TIMEOUT: ${endpoint.path}');

      return null;
    } finally {
      client.close(force: true);
    }
  }

  bool _looksLikeSoap(String body) {
    return body.contains('envelope') &&
        (body.contains('getsystemdateandtimeresponse') ||
            body.contains('onvif') ||
            body.contains('soap'));
  }

  bool _isPrivateIpv4(String host) {
    final parts = host.split('.');

    if (parts.length != 4) {
      return false;
    }

    final values = parts.map(int.tryParse).toList();

    if (values.any((value) => value == null)) {
      return false;
    }

    final a = values[0]!;

    final b = values[1]!;

    if (a == 10) {
      return true;
    }

    if (a == 192 && b == 168) {
      return true;
    }

    return a == 172 && b >= 16 && b <= 31;
  }

  void _emit(CameraRuntimeState state) {
    _state = state;

    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _detectionMonitoringRequested = false;
    _eventReconnectAttempt = 0;

    _stopEventPolling();

    await _detectionController.close();
    await _stateController.close();
  }
}

enum _OnvifProbeResult { available, authenticationRequired, unavailable }

const String _createPullPointSubscriptionSoap =
    '''<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope
 xmlns:s="http://www.w3.org/2003/05/soap-envelope">
 <s:Body>
  <CreatePullPointSubscription
   xmlns="http://www.onvif.org/ver10/events/wsdl">
   <InitialTerminationTime>
    PT1H
   </InitialTerminationTime>
  </CreatePullPointSubscription>
 </s:Body>
</s:Envelope>''';

const String _pullMessagesSoap = '''<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope
 xmlns:s="http://www.w3.org/2003/05/soap-envelope">
 <s:Body>
  <PullMessages
   xmlns="http://www.onvif.org/ver10/events/wsdl">
   <Timeout>PT1S</Timeout>
   <MessageLimit>10</MessageLimit>
  </PullMessages>
 </s:Body>
</s:Envelope>''';

const String _getSystemDateAndTimeSoap =
    '''<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope
 xmlns:s="http://www.w3.org/2003/05/soap-envelope">
 <s:Body>
  <GetSystemDateAndTime
   xmlns="http://www.onvif.org/ver10/device/wsdl"/>
 </s:Body>
</s:Envelope>''';

const String _getCapabilitiesSoap = '''<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope
 xmlns:s="http://www.w3.org/2003/05/soap-envelope">
 <s:Body>
  <GetCapabilities
   xmlns="http://www.onvif.org/ver10/device/wsdl">
   <Category>All</Category>
  </GetCapabilities>
 </s:Body>
</s:Envelope>''';

const String _getProfilesSoap = '''<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope
 xmlns:s="http://www.w3.org/2003/05/soap-envelope">
 <s:Body>
  <GetProfiles
   xmlns="http://www.onvif.org/ver10/media/wsdl"/>
 </s:Body>
</s:Envelope>''';

String _buildGetStreamUriSoap(String profileToken) {
  final safeToken = _escapeXml(profileToken);

  return '''<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope
 xmlns:s="http://www.w3.org/2003/05/soap-envelope">
 <s:Body>
  <GetStreamUri
   xmlns="http://www.onvif.org/ver10/media/wsdl">
   <StreamSetup>
    <Stream
     xmlns="http://www.onvif.org/ver10/schema">
     RTP-Unicast
    </Stream>
    <Transport
     xmlns="http://www.onvif.org/ver10/schema">
     <Protocol>RTSP</Protocol>
    </Transport>
   </StreamSetup>
   <ProfileToken>$safeToken</ProfileToken>
  </GetStreamUri>
 </s:Body>
</s:Envelope>''';
}

String _escapeXml(String value) {
  return value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}
