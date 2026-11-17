import 'dart:convert';

import 'package:xml/xml.dart';

import 'local_camera_connection.dart';
import 'onvif_media_resolver.dart';
import 'onvif_soap_client.dart';

class OnvifWifiInterface {
  const OnvifWifiInterface(this.token, this.label);
  final String token;
  final String label;
}

class OnvifWifiSetup {
  OnvifWifiSetup(this.device);
  final OnvifDevice device;
  final Map<String, OnvifWifiInterface> _interfaces = {};
  bool _canScan = false;

  Future<List<OnvifWifiInterface>> inspect() async {
    _interfaces.clear();
    _canScan = false;
    final reply = await device.call('GetNetworkInterfaces');
    final interfaces = _response(reply, 'GetNetworkInterfaces');
    for (final node in onvifElements(interfaces, 'NetworkInterfaces')) {
      final token = node.getAttribute('token');
      final extension = onvifChild(node, 'Extension');
      // IANA ifType 71 = ieee80211. Never infer Wi-Fi from a token such as wlan0.
      final wireless =
          onvifChild(extension, 'InterfaceType')?.innerText.trim() == '71' ||
          onvifChild(extension, 'Dot11') != null;
      if (wireless && token != null && token.isNotEmpty) {
        final name = onvifChild(
          onvifChild(node, 'Info'),
          'Name',
        )?.innerText.trim();
        _interfaces[token] = OnvifWifiInterface(token, name ?? token);
      }
    }
    if (_interfaces.isEmpty) {
      throw const CameraConnectionIssue(
        'Kamera nie udostępnia ustawień Wi-Fi przez ONVIF. Skonfiguruj sieć w aplikacji lub panelu producenta i wróć do wykrywania.',
      );
    }

    // Network scan is optional; a confirmed wireless interface can still be
    // configured by entering the SSID manually.
    try {
      final capabilities = await device.call('GetDot11Capabilities');
      final scan = onvifText(
        capabilities.response('GetDot11Capabilities'),
        'ScanAvailableNetworks',
      );
      _canScan = scan == 'true' || scan == '1';
    } on Exception {
      _canScan = false;
    }
    return List.unmodifiable(_interfaces.values);
  }

  bool get canScan => _canScan;

  Future<List<String>> scan(OnvifWifiInterface wireless) async {
    _requireWireless(wireless);
    if (!_canScan) return const [];
    final reply = await device.call(
      'ScanAvailableDot11Networks',
      body:
          '<o:InterfaceToken>${onvifEscape(wireless.token)}</o:InterfaceToken>',
      timeout: const Duration(seconds: 12),
    );
    final response = _response(reply, 'ScanAvailableDot11Networks');
    final networks = <String>{};
    for (final node in onvifElements(response, 'Networks')) {
      final hex = onvifText(node, 'SSID');
      if (hex == null ||
          hex.length > 64 ||
          !RegExp(r'^(?:[0-9a-fA-F]{2})+$').hasMatch(hex)) {
        continue;
      }
      final bytes = [
        for (var i = 0; i < hex.length; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16),
      ];
      try {
        final ssid = utf8.decode(bytes);
        final modes = onvifElements(
          node,
          'AuthAndMangementSuite',
        ).map((value) => value.innerText.trim()).toSet();
        if (modes.isEmpty || modes.contains('PSK')) networks.add(ssid);
      } on FormatException {
        // Non-UTF-8 SSIDs cannot be selected from this list.
      }
    }
    return networks.toList()..sort();
  }

  Future<bool> connect({
    required OnvifWifiInterface wireless,
    required String ssid,
    required String password,
  }) async {
    _requireWireless(wireless);
    final body = buildOnvifWifiBody(
      interfaceToken: wireless.token,
      ssid: ssid,
      password: password,
    );
    final reply = await device.call(
      'SetNetworkInterfaces',
      body: body,
      sensitive: true,
      timeout: const Duration(seconds: 10),
    );
    final response = _response(reply, 'SetNetworkInterfaces');
    final reboot = onvifText(response, 'RebootNeeded');
    return reboot == 'true' || reboot == '1';
  }

  void _requireWireless(OnvifWifiInterface wireless) {
    if (!_interfaces.containsKey(wireless.token)) {
      throw const CameraConnectionIssue(
        'Nie rozpoznano interfejsu Wi-Fi kamery.',
      );
    }
  }
}

XmlElement _response(OnvifSoapResult reply, String operation) {
  if (reply.requiresLogin) {
    throw const CameraConnectionIssue(
      'Kamera wymaga konta ONVIF z uprawnieniami do zmiany sieci.',
    );
  }
  return reply.response(operation) ??
      (throw CameraConnectionIssue(
        'Kamera odrzuciła operację $operation (HTTP ${reply.status}).',
      ));
}

String buildOnvifWifiBody({
  required String interfaceToken,
  required String ssid,
  required String password,
}) {
  final ssidBytes = utf8.encode(ssid);
  if (ssidBytes.isEmpty || ssidBytes.length > 32) {
    throw const CameraConnectionIssue(
      'Nazwa sieci Wi-Fi musi mieć od 1 do 32 bajtów.',
    );
  }
  final hexSsid = ssidBytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  final hexKey = RegExp(r'^[0-9A-Fa-f]{64}$').hasMatch(password);
  if (!hexKey || password.length != 64) {
    if (password.length < 8 ||
        password.length > 63 ||
        password.codeUnits.any((c) => c < 32 || c > 126)) {
      throw const CameraConnectionIssue(
        'Hasło WPA2 musi mieć od 8 do 63 znaków ASCII albo być kluczem z 64 znaków szesnastkowych.',
      );
    }
  }
  final key = hexKey ? 'Key' : 'Passphrase';
  return '''<o:InterfaceToken>${onvifEscape(interfaceToken)}</o:InterfaceToken>
<o:NetworkInterface>
  <tt:Enabled>true</tt:Enabled>
  <tt:IPv4><tt:Enabled>true</tt:Enabled><tt:DHCP>true</tt:DHCP></tt:IPv4>
  <tt:Extension><tt:Dot11>
    <tt:SSID>$hexSsid</tt:SSID><tt:Mode>Infrastructure</tt:Mode>
    <tt:Alias>SafeHood</tt:Alias><tt:Priority>0</tt:Priority>
    <tt:Security><tt:Mode>PSK</tt:Mode><tt:Algorithm>CCMP</tt:Algorithm>
      <tt:PSK><tt:$key>${onvifEscape(password)}</tt:$key></tt:PSK>
    </tt:Security>
  </tt:Dot11></tt:Extension>
</o:NetworkInterface>''';
}
