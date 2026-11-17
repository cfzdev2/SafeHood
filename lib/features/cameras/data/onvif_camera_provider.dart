import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/camera.dart';
import '../domain/camera_provider.dart';
import 'local_camera_connection.dart';
import 'onvif_media_resolver.dart';
import 'onvif_soap_client.dart';

class OnvifCameraProvider
    implements
        CameraProvider,
        CameraLiveStreamAlternatives,
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
  OnvifDevice? _device;
  List<Uri> _alternatives = const [];

  @override
  List<Uri> get liveStreamAlternatives => _alternatives;

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
    supportsAudio: _streamUri != null,
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
      final settings = await const LocalCameraConnectionStore().read(camera.id);
      final device = _device ??= await openOnvifDevice(
        settings.cameraWithLocalEndpoint(camera),
        settings.login,
      );
      final eventsUrl = await _getEventsServiceUrl(device);

      if (!_detectionMonitoringRequested || _disposed) {
        return;
      }

      if (eventsUrl == null) {
        debugPrint('ONVIF EVENTS: brak Events Service');

        _scheduleEventReconnect();

        return;
      }

      _eventsServiceUrl = eventsUrl;

      debugPrint('ONVIF EVENTS: usługa dostępna');

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
    _streamUri = null;
    _alternatives = const [];
    _mediaServiceUrl = null;
    _profileToken = null;
    _emit(_state.copyWith(isConnecting: true, isOnline: false, isLive: false));

    try {
      final settings = await const LocalCameraConnectionStore().read(camera.id);
      if (_disposed) return;
      final manualUri = settings.playbackUri;
      if (manualUri != null) {
        _streamUri = manualUri;
      } else {
        final device = await openOnvifDevice(
          settings.cameraWithLocalEndpoint(camera),
          settings.login,
        );
        if (_disposed) return;
        _device = device;
        final streams = await OnvifMediaResolver(device).resolve();
        if (_disposed) return;
        final selected = streams.first;
        _streamUri = selected.uri;
        _profileToken = selected.profileToken;
        _mediaServiceUrl = selected.mediaEndpoint;
        _alternatives = streams.skip(1).map((item) => item.uri).toList();
      }
      debugPrint(
        'ONVIF: dostępny strumień RTSP (${_alternatives.length + 1} profili)',
      );
      _emit(
        _state.copyWith(isConnecting: false, isOnline: true, isLive: false),
      );
    } catch (_) {
      _emit(
        _state.copyWith(isConnecting: false, isOnline: false, isLive: false),
      );
      rethrow;
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
    _alternatives = const [];
    _device = null;

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

    debugPrint('ONVIF: uruchamiam LIVE');

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

  Future<Uri?> _getEventsServiceUrl(OnvifDevice device) async {
    final reply = await device.call(
      'GetCapabilities',
      body: '<o:Category>All</o:Category>',
    );
    final events = onvifElements(
      reply.response('GetCapabilities'),
      'Events',
    ).firstOrNull;
    return onvifAdvertisedUri(
      onvifText(events, 'XAddr'),
      device.endpoint,
      schemes: const {'http', 'https'},
    );
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

    final uri = onvifAdvertisedUri(
      value,
      eventsServiceUrl,
      schemes: const {'http', 'https'},
    );
    if (uri == null) return false;

    _pullPointUrl = uri;
    debugPrint('ONVIF EVENTS: PullPoint utworzony');

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
    final device = _device;
    if (device == null) return null;
    try {
      final reply = await device.soap.postEnvelope(
        endpoint,
        body,
        timeout: connectionTimeout + responseTimeout,
      );
      if (logSuccess || !reply.ok) {
        debugPrint('ONVIF EVENTS SOAP: HTTP ${reply.status}');
      }
      return reply.ok ? reply.xml.toString() : null;
    } on Exception catch (error) {
      debugPrint('ONVIF EVENTS SOAP: ${error.runtimeType}');
      return null;
    }
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

const String _createPullPointSubscriptionSoap =
    '''<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope
 xmlns:s="http://www.w3.org/2003/05/soap-envelope">
 <s:Body>
  <CreatePullPointSubscription
   xmlns="http://www.onvif.org/ver10/events/wsdl">
   <InitialTerminationTime>PT1H</InitialTerminationTime>
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
