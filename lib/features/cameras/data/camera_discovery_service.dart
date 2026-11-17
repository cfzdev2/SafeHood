import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_device_discovery/flutter_local_device_discovery.dart';
import 'package:xml/xml.dart';

import '../domain/camera.dart';
import 'local_camera_store.dart';
import 'onvif_soap_client.dart';

enum CameraDiscoveryStage { preparing, standardNetwork, activeLan, finished }

class CameraDiscoveryProgress {
  final CameraDiscoveryStage stage;
  final String message;
  final int step;
  final int totalSteps;

  const CameraDiscoveryProgress({
    required this.stage,
    required this.message,
    required this.step,
    required this.totalSteps,
  });
}

class DetectedCamera {
  final String deviceId;
  final String displayName;
  final String brand;
  final String model;
  final String? ipAddress;
  final String? macAddress;
  final String? onvifServiceUrl;
  final CameraConnectionType connectionType;
  final Set<String> discoverySources;
  final int confidence;
  final Set<int> openPorts;
  final Set<int> rtspPorts;

  const DetectedCamera({
    required this.deviceId,
    required this.displayName,
    required this.brand,
    required this.model,
    required this.ipAddress,
    required this.connectionType,
    this.macAddress,
    this.onvifServiceUrl,
    this.discoverySources = const {},
    this.confidence = 0,
    this.openPorts = const {},
    this.rtspPorts = const {},
  });

  DetectedCamera copyWith({
    String? deviceId,
    String? displayName,
    String? brand,
    String? model,
    String? ipAddress,
    String? macAddress,
    String? onvifServiceUrl,
    CameraConnectionType? connectionType,
    Set<String>? discoverySources,
    int? confidence,
    Set<int>? openPorts,
    Set<int>? rtspPorts,
  }) {
    return DetectedCamera(
      deviceId: deviceId ?? this.deviceId,
      displayName: displayName ?? this.displayName,
      brand: brand ?? this.brand,
      model: model ?? this.model,
      ipAddress: ipAddress ?? this.ipAddress,
      macAddress: macAddress ?? this.macAddress,
      onvifServiceUrl: onvifServiceUrl ?? this.onvifServiceUrl,
      connectionType: connectionType ?? this.connectionType,
      discoverySources: discoverySources ?? this.discoverySources,
      confidence: confidence ?? this.confidence,
      openPorts: openPorts ?? this.openPorts,
      rtspPorts: rtspPorts ?? this.rtspPorts,
    );
  }
}

abstract class CameraDiscoveryStrategy {
  String get name;

  Future<List<DetectedCamera>> discover({
    void Function(List<DetectedCamera>)? onResults,
    bool Function()? isCancelled,
  });
}

class CameraDiscoveryService {
  CameraDiscoveryService()
    : this.withStrategies(
        networkStrategies: [
          DirectOnvifDiscoveryStrategy(),
          DirectSsdpDiscoveryStrategy(),
          StandardNetworkDiscoveryStrategy(),
        ],
        lanStrategy: ActiveLanCameraProbeStrategy(),
      );

  @visibleForTesting
  CameraDiscoveryService.withStrategies({
    required List<CameraDiscoveryStrategy> networkStrategies,
    required this._lanStrategy,
  }) : _networkStrategies = List.unmodifiable(networkStrategies);

  final List<CameraDiscoveryStrategy> _networkStrategies;
  final CameraDiscoveryStrategy _lanStrategy;

  /// Probe only the address of a camera that was already saved on this phone.
  Future<DetectedCamera?> findLocalCamera(String address) async {
    final local = parseLocalRtsp('rtsp://$address/');
    if (local == null || local.host != address || local.hasPort) return null;
    final found = await ActiveLanCameraProbeStrategy()._scanHost(address);
    return found == null ? null : VendorCameraRecognizer.enrich(found);
  }

  Future<List<DetectedCamera>> discoverCameras({
    void Function(CameraDiscoveryProgress progress)? onProgress,
    void Function(List<DetectedCamera> cameras)? onResults,
    bool Function()? isCancelled,
  }) async {
    const totalSteps = 4;

    bool cancelled() => isCancelled?.call() == true;

    void report(CameraDiscoveryStage stage, String message, int step) {
      if (cancelled()) return;
      onProgress?.call(
        CameraDiscoveryProgress(
          stage: stage,
          message: message,
          step: step,
          totalSteps: totalSteps,
        ),
      );
    }

    debugPrint('');
    debugPrint('════════ CAMERA DISCOVERY START ════════');

    report(
      CameraDiscoveryStage.preparing,
      'Sprawdzam połączenie i możliwości sieci...',
      1,
    );

    // Keep one snapshot per strategy. Results found via several protocols
    // still represent one device, and protocol completion order is irrelevant.
    final resultsByStrategy = {
      for (final strategy in [..._networkStrategies, _lanStrategy])
        strategy: const <DetectedCamera>[],
    };

    List<DetectedCamera> mergedCameras() =>
        CameraDiscoveryResultMerger.merge([
              for (final results in resultsByStrategy.values) ...results,
            ])
            .map(VendorCameraRecognizer.enrich)
            .where((camera) => camera.confidence >= 60)
            .toList()
          ..sort((a, b) => b.confidence.compareTo(a.confidence));

    Future<void> run(CameraDiscoveryStrategy strategy) async {
      if (cancelled()) return;
      debugPrint('DISCOVERY: start ${strategy.name}');
      final stopwatch = Stopwatch()..start();

      void publish(List<DetectedCamera> results) {
        if (cancelled()) return;
        resultsByStrategy[strategy] = results;
        if (onResults != null) onResults(mergedCameras());
      }

      try {
        final results = await strategy.discover(
          onResults: onResults == null ? null : publish,
          isCancelled: isCancelled,
        );
        publish(results);
        debugPrint(
          'DISCOVERY: ${strategy.name} '
          '→ ${results.length} wyników '
          '(${stopwatch.elapsedMilliseconds} ms)',
        );
      } catch (error, stackTrace) {
        debugPrint('DISCOVERY ERROR [${strategy.name}]: $error');
        debugPrint('DISCOVERY STACK [${strategy.name}]: $stackTrace');
      }
    }

    report(
      CameraDiscoveryStage.standardNetwork,
      'Szukam kamer w sieci Wi-Fi...',
      2,
    );
    await Future.wait(_networkStrategies.map(run));
    if (cancelled()) return const [];

    // Cameras that don't advertise their services still need the LAN probe.
    report(CameraDiscoveryStage.activeLan, 'Szukam kolejnych kamer...', 3);
    await run(_lanStrategy);
    if (cancelled()) return const [];

    final cameras = mergedCameras();

    for (final camera in cameras) {
      debugPrint(
        'CAMERA FOUND: '
        '${camera.displayName} | '
        'IP=${camera.ipAddress} | '
        'MAC=${camera.macAddress} | '
        '${camera.connectionType.name} | '
        '${camera.confidence}% | '
        '${camera.discoverySources.join(", ")}',
      );
    }

    debugPrint('════════ CAMERA DISCOVERY END ══════════');

    report(
      CameraDiscoveryStage.finished,
      cameras.isEmpty
          ? 'Skanowanie zakończone.'
          : 'Znaleziono ${cameras.length} '
                '${cameras.length == 1 ? "kamerę" : "kamery"}.',
      totalSteps,
    );

    return cameras;
  }
}

///
/// 1. mDNS / DNS-SD / SSDP / UPnP / WS-Discovery
///
class StandardNetworkDiscoveryStrategy implements CameraDiscoveryStrategy {
  final FlutterLocalDeviceDiscovery _discovery = FlutterLocalDeviceDiscovery();

  @override
  String get name => 'STANDARD_NETWORK';

  @override
  Future<List<DetectedCamera>> discover({
    void Function(List<DetectedCamera>)? onResults,
    bool Function()? isCancelled,
  }) async {
    // This package enables reusePort in its shared UDP engines. On Android
    // keep native DNS-SD and use SafeHood's ONVIF/SSDP probes for the rest.
    final useDirectUdp = defaultTargetPlatform == TargetPlatform.android;
    final request = LocalDiscoveryRequest(
      mode: LocalDiscoveryMode.servicesAndDevices,
      duration: const Duration(seconds: 6),
      protocols: {
        LocalDiscoveryProtocol.mdns,
        LocalDiscoveryProtocol.dnsSd,
        if (!useDirectUdp) ...{
          LocalDiscoveryProtocol.ssdp,
          LocalDiscoveryProtocol.upnp,
          LocalDiscoveryProtocol.wsDiscovery,
        },
      },
      serviceTypes: const {'_http._tcp', '_https._tcp', '_rtsp._tcp'},
      ssdpSearchTargets: useDirectUdp ? const {} : const {'ssdp:all'},
      wsDiscoveryTypes: useDirectUdp
          ? const {}
          : const {'dn:NetworkVideoTransmitter'},
      resolveServices: true,
      fetchUpnpDescriptions: !useDirectUdp,
      deduplicateResults: true,
      classifyDevices: true,
      monitorNetworkChanges: !useDirectUdp,
      metadataSecurityPolicy: MetadataSecurityPolicy.defaultPolicy,
    );

    final readiness = await _discovery.checkReadiness(request);
    if (isCancelled?.call() == true) return const [];

    if (!readiness.canStart) {
      throw StateError(
        'Discovery niedostępne: '
        '${readiness.requirements.join(", ")}',
      );
    }

    final snapshot = await _discovery.discover(request);

    final results = <DetectedCamera>[];

    for (final device in snapshot.devices) {
      final wsDiscovery = device.discoveredBy.contains(
        LocalDiscoveryProtocol.wsDiscovery,
      );

      final streamServices = device.services.where(
        (service) => service.serviceType.toLowerCase().contains('rtsp'),
      );
      final rtsp = streamServices.isNotEmpty;

      final classifiedAsCamera = device.type == LocalDeviceType.camera;

      if (!classifiedAsCamera && !wsDiscovery && !rtsp) {
        continue;
      }

      final ip = device.addresses.isEmpty
          ? null
          : device.addresses.first.address;

      final brand = _cleanString(device.manufacturer) ?? 'Nieznany producent';

      final model =
          _cleanString(device.model) ??
          _cleanString(device.displayName) ??
          'Nieznany model';

      var confidence = 45;

      if (classifiedAsCamera) {
        confidence += 25;
      }

      if (wsDiscovery) {
        confidence += 30;
      }

      if (rtsp) {
        confidence += 25;
      }

      results.add(
        DetectedCamera(
          deviceId: device.id,
          displayName: _cleanString(device.displayName) ?? model,
          brand: brand,
          model: model,
          ipAddress: ip,
          connectionType: wsDiscovery
              ? CameraConnectionType.onvif
              : rtsp
              ? CameraConnectionType.rtsp
              : CameraConnectionType.unknown,
          discoverySources: {
            'standard',
            if (classifiedAsCamera) 'classified-camera',
            if (wsDiscovery) 'ws-discovery',
            if (rtsp) 'rtsp-service',
          },
          confidence: min(100, confidence),
          rtspPorts: {
            for (final service in streamServices)
              if (service.port case final int port
                  when port > 0 && port <= 65535)
                port,
          },
        ),
      );
    }

    return results;
  }
}

///
/// 2. Niezależne ONVIF WS-Discovery
///
class DirectOnvifDiscoveryStrategy implements CameraDiscoveryStrategy {
  @override
  String get name => 'DIRECT_ONVIF';

  @override
  Future<List<DetectedCamera>> discover({
    void Function(List<DetectedCamera>)? onResults,
    bool Function()? isCancelled,
  }) async {
    RawDatagramSocket? socket;

    try {
      socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: true,
      );
      if (isCancelled?.call() == true) return const [];

      final activeSocket = socket;

      final messageId = _createMessageId();

      final probe =
          '''<?xml version="1.0" encoding="UTF-8"?>
<e:Envelope
 xmlns:e="http://www.w3.org/2003/05/soap-envelope"
 xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing"
 xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"
 xmlns:dn="http://www.onvif.org/ver10/network/wsdl">
 <e:Header>
  <w:MessageID>uuid:$messageId</w:MessageID>
  <w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>
  <w:Action e:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>
 </e:Header>
 <e:Body>
  <d:Probe>
   <d:Types>dn:NetworkVideoTransmitter</d:Types>
  </d:Probe>
 </e:Body>
</e:Envelope>''';

      activeSocket.send(
        utf8.encode(probe),
        InternetAddress('239.255.255.250'),
        3702,
      );

      final results = <String, DetectedCamera>{};

      final completer = Completer<void>();

      late StreamSubscription<RawSocketEvent> subscription;

      subscription = activeSocket.listen(
        (event) {
          if (event != RawSocketEvent.read) {
            return;
          }

          Datagram? datagram;

          while ((datagram = activeSocket.receive()) != null) {
            final packet = datagram!;
            if (isCancelled?.call() == true) continue;

            final text = utf8.decode(packet.data, allowMalformed: true);

            if (!_looksLikeOnvif(text)) {
              continue;
            }

            final ip = packet.address.address;

            final scopes = _extractXmlValue(text, 'Scopes');

            final xAddrs = _extractXmlValue(text, 'XAddrs');
            final onvifServiceUrl = _extractFirstHttpUrl(xAddrs);
            final previous = results[ip];
            if (previous != null &&
                (previous.onvifServiceUrl != null || onvifServiceUrl == null)) {
              continue;
            }

            final name = _guessOnvifScope(scopes, 'name') ?? 'Kamera $ip';

            final model =
                _guessOnvifScope(scopes, 'hardware') ?? 'Kamera ONVIF';

            results[ip] = DetectedCamera(
              deviceId: 'onvif-$ip',
              displayName: name,
              brand: 'Nieznany producent',
              model: model,
              ipAddress: ip,
              connectionType: CameraConnectionType.onvif,
              onvifServiceUrl: onvifServiceUrl,
              discoverySources: {
                'direct-onvif',
                if (xAddrs != null) 'onvif-xaddr',
              },
              confidence: xAddrs == null ? 95 : 100,
            );
            onResults?.call(results.values.toList());
          }
        },
        onError: (Object error) {
          debugPrint(
            'DIRECT ONVIF ERROR: '
            '$error',
          );
        },
      );

      Timer(const Duration(seconds: 4), () {
        if (!completer.isCompleted) {
          completer.complete();
        }
      });

      await completer.future;

      await subscription.cancel();

      return results.values.toList();
    } finally {
      socket?.close();
    }
  }
}

///
/// 3. ARP / Neighbor Table
///
/// To NIE oznacza automatycznie "kamera".
/// Wynik ma bardzo niski confidence.
/// Potem scalamy go z RTSP / HTTP / ONVIF.
///
class NeighborTableDiscoveryStrategy implements CameraDiscoveryStrategy {
  @override
  String get name => 'NEIGHBOR_TABLE';

  @override
  Future<List<DetectedCamera>> discover({
    void Function(List<DetectedCamera>)? onResults,
    bool Function()? isCancelled,
  }) async {
    final entries = await NeighborTable.getEntries();
    if (isCancelled?.call() == true) return const [];

    debugPrint(
      'NEIGHBOR TABLE: '
      '${entries.length} urządzeń',
    );

    final results = <DetectedCamera>[];

    for (final entry in entries) {
      final ip = entry.ipAddress.trim();

      final mac = entry.macAddress.trim();

      if (!_isPrivateIpv4(ip)) {
        continue;
      }

      if (mac.isEmpty || mac == '00:00:00:00:00:00') {
        continue;
      }

      debugPrint(
        'NEIGHBOR: '
        '$ip | $mac | '
        '${entry.interfaceName}',
      );

      results.add(
        DetectedCamera(
          deviceId: 'neighbor-$mac',
          displayName: 'Urządzenie $ip',
          brand: 'Nieznany producent',
          model: 'Nieznany model',
          ipAddress: ip,
          macAddress: mac,
          connectionType: CameraConnectionType.unknown,
          discoverySources: const {'neighbor-table'},

          // Sam ARP absolutnie nie wystarcza,
          // żeby pokazać urządzenie jako kamerę.
          confidence: 10,
        ),
      );
    }

    return results;
  }
}

///
/// 4. Aktywne skanowanie całej typowej sieci /24
///
/// - ReachabilityProber
/// - RTSP handshake
/// - HTTP / HTTPS fingerprint
///
///
class DirectSsdpDiscoveryStrategy implements CameraDiscoveryStrategy {
  @override
  String get name => 'DIRECT_SSDP';

  @override
  Future<List<DetectedCamera>> discover({
    void Function(List<DetectedCamera>)? onResults,
    bool Function()? isCancelled,
  }) async {
    RawDatagramSocket? socket;

    try {
      socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: true,
      );
      if (isCancelled?.call() == true) return const [];

      final activeSocket = socket;

      const request =
          'M-SEARCH * HTTP/1.1\r\n'
          'HOST: 239.255.255.250:1900\r\n'
          'MAN: "ssdp:discover"\r\n'
          'MX: 2\r\n'
          'ST: ssdp:all\r\n'
          '\r\n';

      final results = <String, DetectedCamera>{};

      final completer = Completer<void>();

      late StreamSubscription<RawSocketEvent> subscription;

      subscription = activeSocket.listen(
        (event) {
          if (event != RawSocketEvent.read) {
            return;
          }

          Datagram? datagram;

          while ((datagram = activeSocket.receive()) != null) {
            final packet = datagram!;
            if (isCancelled?.call() == true) continue;

            final response = utf8.decode(packet.data, allowMalformed: true);

            final headers = _parseSsdpHeaders(response);

            final ip = packet.address.address;

            final location = headers['location'];

            final server = headers['server'] ?? '';

            final st = headers['st'] ?? '';

            final usn = headers['usn'] ?? '';

            final text = '$server $st $usn $location'.toLowerCase();

            final looksInteresting =
                text.contains('camera') ||
                text.contains('onvif') ||
                text.contains('networkvideo') ||
                text.contains('ipcam') ||
                text.contains('nvr') ||
                _detectVendor(text) != null;

            if (!looksInteresting) {
              continue;
            }

            final brand = _detectVendor(text) ?? 'Nieznany producent';

            final camera = DetectedCamera(
              deviceId: 'ssdp-$ip',
              displayName: brand == 'Nieznany producent'
                  ? 'Urządzenie $ip'
                  : '$brand $ip',
              brand: brand,
              model: 'Nieznany model',
              ipAddress: ip,
              connectionType: text.contains('onvif')
                  ? CameraConnectionType.onvif
                  : CameraConnectionType.unknown,
              discoverySources: {
                'direct-ssdp',
                if (location != null) 'upnp-location',
              },
              confidence: text.contains('camera') || text.contains('onvif')
                  ? 70
                  : 45,
            );
            final previous = results[ip];
            if (previous != null &&
                previous.confidence >= camera.confidence &&
                (previous.connectionType == CameraConnectionType.onvif ||
                    camera.connectionType != CameraConnectionType.onvif)) {
              continue;
            }
            results[ip] = camera;
            onResults?.call(results.values.toList());
          }
        },
        onError: (Object error) {
          debugPrint('DIRECT SSDP ERROR: $error');
        },
      );

      activeSocket.send(
        utf8.encode(request),
        InternetAddress('239.255.255.250'),
        1900,
      );

      // Wysyłamy drugi probe,
      // bo część tanich urządzeń potrafi
      // zgubić pierwszy pakiet.
      await Future<void>.delayed(const Duration(milliseconds: 350));

      if (isCancelled?.call() == true) {
        await subscription.cancel();
        return const [];
      }
      activeSocket.send(
        utf8.encode(request),
        InternetAddress('239.255.255.250'),
        1900,
      );

      Timer(const Duration(seconds: 4), () {
        if (!completer.isCompleted) {
          completer.complete();
        }
      });

      await completer.future;

      await subscription.cancel();

      return results.values.toList();
    } finally {
      socket?.close();
    }
  }
}

Map<String, String> _parseSsdpHeaders(String response) {
  final result = <String, String>{};

  for (final line in const LineSplitter().convert(response)) {
    final separator = line.indexOf(':');

    if (separator <= 0) {
      continue;
    }

    final key = line.substring(0, separator).trim().toLowerCase();

    final value = line.substring(separator + 1).trim();

    if (key.isNotEmpty && value.isNotEmpty) {
      result[key] = value;
    }
  }

  return result;
}

class ActiveLanCameraProbeStrategy implements CameraDiscoveryStrategy {
  static const _rtspPorts = [554, 8554];

  static const _webPorts = [80, 443, 8080, 8443, 8000, 8899, 9000, 2020];

  @override
  String get name => 'ACTIVE_LAN_PROBE';

  @override
  Future<List<DetectedCamera>> discover({
    void Function(List<DetectedCamera>)? onResults,
    bool Function()? isCancelled,
  }) async {
    final localIp = await _findPrivateIpv4();
    if (isCancelled?.call() == true) return const [];

    if (localIp == null) {
      debugPrint('ACTIVE LAN: brak IPv4');

      return [];
    }

    final parts = localIp.split('.');

    if (parts.length != 4) {
      return [];
    }

    final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';

    debugPrint(
      'ACTIVE LAN: skanuję '
      '$prefix.0/24',
    );

    final addresses = <String>[];

    for (var i = 1; i <= 254; i++) {
      final ip = '$prefix.$i';

      if (ip != localIp) {
        addresses.add(ip);
      }
    }

    final results = <DetectedCamera>[];

    const batchSize = 28;

    for (var start = 0; start < addresses.length; start += batchSize) {
      if (isCancelled?.call() == true) break;
      final end = min(start + batchSize, addresses.length);

      final batch = addresses.sublist(start, end);

      await Future.wait(
        batch.map((ip) async {
          final camera = await _scanHost(ip, isCancelled: isCancelled);
          if (camera == null || isCancelled?.call() == true) return;
          results.add(camera);
          onResults?.call(List.of(results));
        }),
      );
    }

    return results;
  }

  Future<DetectedCamera?> _scanHost(
    String ip, {
    bool Function()? isCancelled,
  }) async {
    DetectedCamera? fallback;
    for (final port in _webPorts) {
      if (isCancelled?.call() == true) return null;
      final web = await ReachabilityProber.probe(
        ip,
        ports: [port],
        timeout: const Duration(milliseconds: 250),
      );
      if (web.status != LocalReachabilityStatus.reachable) continue;
      if (isCancelled?.call() == true) return null;

      // A camera need not advertise multicast or have a recognizable web page.
      final onvif = await _confirmOnvif(ip, port);
      if (onvif != null) return onvif;
      if (isCancelled?.call() == true) return null;
      fallback ??= await _fingerprintWebDevice(ip, port);
    }

    for (final port in _rtspPorts) {
      if (isCancelled?.call() == true) return null;
      if (!await _confirmRtsp(ip, port)) continue;
      return DetectedCamera(
        deviceId: 'rtsp-$ip-$port',
        displayName: 'Kamera $ip',
        brand: 'Nieznany producent',
        model: 'Nieznany model',
        ipAddress: ip,
        connectionType: CameraConnectionType.rtsp,
        discoverySources: const {'reachability', 'rtsp-handshake'},
        confidence: 95,
        openPorts: {port},
        rtspPorts: {port},
      );
    }
    return fallback;
  }

  Future<DetectedCamera?> _confirmOnvif(String ip, int port) async {
    final endpoint = Uri(
      scheme: port == 443 || port == 8443 ? 'https' : 'http',
      host: ip,
      port: port,
      path: '/onvif/device_service',
    );
    try {
      final result = await OnvifSoapClient(ip).call(
        endpoint,
        onvifDeviceNamespace,
        'GetSystemDateAndTime',
        timeout: const Duration(milliseconds: 750),
        authenticated: false,
      );
      // 401 alone could be a non-camera web server.
      if (result.response('GetSystemDateAndTime') == null &&
          !(result.fault != null &&
              onvifElements(result.fault, 'Value').any(
                (element) => element.innerText.trim().startsWith('ter:'),
              ))) {
        return null;
      }
      return DetectedCamera(
        deviceId: 'onvif-$ip-$port',
        displayName: 'Kamera ONVIF $ip',
        brand: 'Nieznany producent',
        model: 'Nieznany model',
        ipAddress: ip,
        onvifServiceUrl: endpoint.toString(),
        connectionType: CameraConnectionType.onvif,
        discoverySources: const {'reachability', 'onvif-soap'},
        confidence: 98,
        openPorts: {port},
      );
    } on Exception {
      return null;
    }
  }

  Future<bool> _confirmRtsp(String ip, int port) async {
    Socket? socket;

    try {
      socket = await Socket.connect(
        ip,
        port,
        timeout: const Duration(milliseconds: 350),
      );

      socket.write(
        'OPTIONS rtsp://$ip:$port/ RTSP/1.0\r\n'
        'CSeq: 1\r\n'
        'User-Agent: SafeHood\r\n'
        '\r\n',
      );

      await socket.flush();

      final data = await socket.first.timeout(
        const Duration(milliseconds: 500),
      );

      final response = utf8.decode(data, allowMalformed: true);

      return response.toUpperCase().contains('RTSP/1.0');
    } catch (_) {
      return false;
    } finally {
      socket?.destroy();
    }
  }

  Future<DetectedCamera?> _fingerprintWebDevice(String ip, int port) async {
    final secure = port == 443 || port == 8443;

    final client = HttpClient();

    client.connectionTimeout = const Duration(milliseconds: 500);

    // Wiele lokalnych kamer ma
    // certyfikat self-signed.
    // Akceptujemy go TYLKO dla prywatnego IP
    // i tylko podczas fingerprintingu.
    client.badCertificateCallback = (X509Certificate _, String host, int _) {
      return _isPrivateIpv4(host);
    };

    try {
      final uri = Uri(
        scheme: secure ? 'https' : 'http',
        host: ip,
        port: port,
        path: '/',
      );

      final request = await client
          .getUrl(uri)
          .timeout(const Duration(milliseconds: 700));

      request.followRedirects = false;

      request.headers.set(HttpHeaders.userAgentHeader, 'SafeHood/1.0');

      final response = await request.close().timeout(
        const Duration(milliseconds: 900),
      );

      final buffer = BytesBuilder();

      var length = 0;

      await for (final chunk in response.timeout(
        const Duration(milliseconds: 900),
      )) {
        final remaining = 32768 - length;

        if (remaining <= 0) {
          break;
        }

        final data = chunk.length <= remaining
            ? chunk
            : chunk.sublist(0, remaining);

        buffer.add(data);

        length += data.length;

        if (length >= 32768) {
          break;
        }
      }

      final body = utf8.decode(buffer.takeBytes(), allowMalformed: true);

      final server = response.headers.value(HttpHeaders.serverHeader) ?? '';

      final title = _extractHtmlTitle(body);

      final fingerprint = '$server\n$title\n$body'.toLowerCase();

      final brand = _detectVendor(fingerprint);

      var confidence = 0;

      final sources = <String>{'http-fingerprint', secure ? 'https' : 'http'};

      final cameraTerms = [
        'network camera',
        'ip camera',
        'web camera',
        'webcam',
        'camera login',
        'camera configuration',
        'surveillance',
        'nvr',
        'onvif',
        'rtsp',
      ];

      final cameraTermFound = cameraTerms.any(fingerprint.contains);

      if (cameraTermFound) {
        confidence += 65;
        sources.add('camera-fingerprint');
      }

      if (brand != null) {
        confidence += 15;
        sources.add('vendor-fingerprint');
      }

      CameraConnectionType type = CameraConnectionType.unknown;

      if (fingerprint.contains('onvif')) {
        confidence += 20;
        type = CameraConnectionType.onvif;
        sources.add('onvif-fingerprint');
      } else if (fingerprint.contains('rtsp')) {
        confidence += 15;
        type = CameraConnectionType.rtsp;
        sources.add('rtsp-fingerprint');
      }

      if (confidence < 60) {
        return null;
      }

      return DetectedCamera(
        deviceId: 'http-$ip-$port',
        displayName: title ?? brand ?? 'Kamera $ip',
        brand: brand ?? 'Nieznany producent',
        model: title ?? 'Nieznany model',
        ipAddress: ip,
        connectionType: type,
        discoverySources: sources,
        confidence: min(confidence, 100),
        openPorts: {port},
      );
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}

class CameraDiscoveryResultMerger {
  const CameraDiscoveryResultMerger._();

  static List<DetectedCamera> merge(List<DetectedCamera> input) {
    final results = <String, DetectedCamera>{};

    for (final camera in input) {
      final key = camera.ipAddress != null
          ? 'ip:${camera.ipAddress}'
          : 'id:${camera.deviceId}';

      final existing = results[key];

      if (existing == null) {
        results[key] = camera;
        continue;
      }

      results[key] = _merge(existing, camera);
    }

    return results.values.toList();
  }

  static DetectedCamera _merge(DetectedCamera a, DetectedCamera b) {
    final sources = {...a.discoverySources, ...b.discoverySources};

    final ports = {...a.openPorts, ...b.openPorts};

    var confidence = max(a.confidence, b.confidence);

    if (sources.length >= 2) {
      confidence += 5;
    }

    if (sources.length >= 4) {
      confidence += 5;
    }

    return DetectedCamera(
      deviceId: a.deviceId.isNotEmpty ? a.deviceId : b.deviceId,
      displayName: _preferDisplayName(a.displayName, b.displayName),
      brand: _preferKnown(a.brand, b.brand, 'Nieznany producent'),
      model: _preferKnown(a.model, b.model, 'Nieznany model'),
      ipAddress: a.ipAddress ?? b.ipAddress,
      macAddress: a.macAddress ?? b.macAddress,
      onvifServiceUrl: a.onvifServiceUrl ?? b.onvifServiceUrl,
      connectionType: _bestConnection(a.connectionType, b.connectionType),
      discoverySources: sources,
      confidence: min(confidence, 100),
      openPorts: ports,
      rtspPorts: {...a.rtspPorts, ...b.rtspPorts},
    );
  }

  static CameraConnectionType _bestConnection(
    CameraConnectionType a,
    CameraConnectionType b,
  ) {
    if (a == CameraConnectionType.onvif || b == CameraConnectionType.onvif) {
      return CameraConnectionType.onvif;
    }

    if (a == CameraConnectionType.rtsp || b == CameraConnectionType.rtsp) {
      return CameraConnectionType.rtsp;
    }

    if (a == CameraConnectionType.manufacturerCloud ||
        b == CameraConnectionType.manufacturerCloud) {
      return CameraConnectionType.manufacturerCloud;
    }

    return a != CameraConnectionType.unknown ? a : b;
  }

  static String _preferKnown(String a, String b, String unknown) {
    if (a != unknown && a.trim().isNotEmpty) {
      return a;
    }

    if (b != unknown && b.trim().isNotEmpty) {
      return b;
    }

    return unknown;
  }

  static String _preferDisplayName(String a, String b) {
    final aGeneric = a.startsWith('Kamera ') || a.startsWith('Urządzenie ');

    final bGeneric = b.startsWith('Kamera ') || b.startsWith('Urządzenie ');

    if (!aGeneric) {
      return a;
    }

    if (!bGeneric) {
      return b;
    }

    return a;
  }
}

class VendorCameraRecognizer {
  const VendorCameraRecognizer._();

  static DetectedCamera enrich(DetectedCamera camera) {
    final text = [
      camera.displayName,
      camera.brand,
      camera.model,
    ].join(' ').toLowerCase();

    final brand = _detectVendor(text);

    if (brand == null) {
      return camera;
    }

    return camera.copyWith(
      brand: brand,
      confidence: min(100, camera.confidence + 10),
      discoverySources: {...camera.discoverySources, 'vendor-recognition'},
    );
  }
}

String? _detectVendor(String text) {
  final value = text.toLowerCase();

  if (value.contains('dekco')) {
    return 'DEKCO';
  }

  if (value.contains('reolink')) {
    return 'Reolink';
  }

  if (value.contains('hikvision')) {
    return 'Hikvision';
  }

  if (value.contains('dahua')) {
    return 'Dahua';
  }

  if (value.contains('amcrest')) {
    return 'Amcrest';
  }

  if (value.contains('foscam')) {
    return 'Foscam';
  }

  if (value.contains('axis')) {
    return 'Axis';
  }

  if (value.contains('ezviz')) {
    return 'EZVIZ';
  }

  if (value.contains('imou')) {
    return 'Imou';
  }

  if (value.contains('uniview')) {
    return 'Uniview';
  }

  if (value.contains('tapo')) {
    return 'TP-Link Tapo';
  }

  return null;
}

String? _extractHtmlTitle(String html) {
  final match = RegExp(
    r'<title[^>]*>(.*?)</title>',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(html);

  var value = match?.group(1)?.trim();

  if (value == null || value.isEmpty) {
    return null;
  }

  value = value.replaceAll(RegExp(r'\s+'), ' ');

  if (value.length > 80) {
    value = value.substring(0, 80);
  }

  return value;
}

bool _looksLikeOnvif(String value) {
  final text = value.toLowerCase();

  return text.contains('probematches') ||
      text.contains('networkvideotransmitter') ||
      text.contains('onvif');
}

String? _extractXmlValue(String xml, String tag) {
  final regex = RegExp(
    '<(?:[A-Za-z0-9_-]+:)?$tag[^>]*>'
    r'([\s\S]*?)'
    '</(?:[A-Za-z0-9_-]+:)?$tag>',
    caseSensitive: false,
  );

  final value = regex.firstMatch(xml)?.group(1)?.trim();

  if (value == null || value.isEmpty) {
    return null;
  }

  return value;
}

String? _guessOnvifScope(String? scopes, String type) {
  if (scopes == null) {
    return null;
  }

  final match = RegExp(
    'onvif://www\\.onvif\\.org/'
    '$type/([^\\s]+)',
    caseSensitive: false,
  ).firstMatch(scopes);

  final value = match?.group(1);

  if (value == null) {
    return null;
  }

  return Uri.decodeComponent(value).replaceAll('_', ' ');
}

String _createMessageId() {
  final random = Random.secure();

  final timestamp = DateTime.now().microsecondsSinceEpoch.toRadixString(16);

  final randomPart = List.generate(
    4,
    (_) => random.nextInt(0xffff).toRadixString(16).padLeft(4, '0'),
  ).join('-');

  return '$timestamp-$randomPart';
}

Future<String?> _findPrivateIpv4() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
  );

  for (final interface in interfaces) {
    for (final address in interface.addresses) {
      if (_isPrivateIpv4(address.address)) {
        return address.address;
      }
    }
  }

  return null;
}

bool _isPrivateIpv4(String ip) {
  final parts = ip.split('.');

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

String? _cleanString(String? value) {
  final result = value?.trim();

  if (result == null || result.isEmpty) {
    return null;
  }

  return result;
}

String? _extractFirstHttpUrl(String? value) {
  if (value == null || value.trim().isEmpty) {
    return null;
  }

  for (final part in value.trim().split(RegExp(r'\s+'))) {
    final uri = Uri.tryParse(part);

    if (uri == null) {
      continue;
    }

    if ((uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty) {
      return uri.toString();
    }
  }

  return null;
}
