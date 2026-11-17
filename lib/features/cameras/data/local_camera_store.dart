import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Only literal private IPv4 destinations are accepted. Camera-provided URLs
/// and user input cannot send credentials to a host resolved via public DNS.
Uri? parseLocalRtsp(String input) {
  final text = input.trim();
  if (text.length > 2048 ||
      RegExp(r'[\x00-\x20\x7f\\]|%(?![0-9a-fA-F]{2})').hasMatch(text)) {
    return null;
  }
  try {
    final uri = Uri.parse(text);
    if (uri.scheme != 'rtsp' ||
        !uri.hasAuthority ||
        uri.hasFragment ||
        (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
      return null;
    }
    final address = InternetAddress.tryParse(uri.host);
    if (address == null ||
        address.type != InternetAddressType.IPv4 ||
        address.address != uri.host) {
      return null;
    }
    final [a, b, ...] = address.rawAddress;
    if (a != 10 &&
        !(a == 172 && b >= 16 && b <= 31) &&
        !(a == 192 && b == 168)) {
      return null;
    }
    return uri;
  } on FormatException {
    return null;
  }
}

String normalizeReolinkUid(String text) => text.trim().toUpperCase();

bool isReolinkUid(String text) =>
    RegExp(r'^[A-Z0-9]{16}$').hasMatch(normalizeReolinkUid(text));

bool isCameraWifiSsid(String text) {
  final length = utf8.encode(text).length;
  return length >= 1 && length <= 32 && !text.contains('\u0000');
}

bool isCameraWifiPassword(String text) {
  final length = utf8.encode(text).length;
  return text.isEmpty ||
      (!text.contains('\u0000') &&
          ((length >= 8 && length <= 63) ||
              RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(text)));
}

bool isNewReolinkPassword(String text) =>
    RegExp(r'^[!-~]{8,31}$').hasMatch(text) &&
    RegExp(r'[A-Za-z]').hasMatch(text) &&
    RegExp(r'[0-9]').hasMatch(text);

@immutable
class LocalCameraSource {
  const LocalCameraSource({
    required this.name,
    required this.uri,
    this.reolinkUid,
  });

  factory LocalCameraSource.fromMap(Map<Object?, Object?> data) {
    final uri = parseLocalRtsp(data['uri'] as String);
    final name = data['name'] as String;
    final uid = data['reolinkUid'] as String?;
    if (uri == null ||
        name.trim().isEmpty ||
        name.length > 80 ||
        (uid != null && !RegExp(r'^[A-Z0-9]{16}$').hasMatch(uid))) {
      throw const FormatException('Nieprawidłowe dane kamery.');
    }
    return LocalCameraSource(name: name, uri: uri, reolinkUid: uid);
  }

  final String name;
  final Uri uri;
  final String? reolinkUid;

  Map<String, Object> toMap() => {
    'name': name,
    'uri': uri.toString(),
    'reolinkUid': ?reolinkUid,
  };
}

@immutable
class SavedLocalCamera {
  const SavedLocalCamera(this.id, this.source);

  final String id;
  final LocalCameraSource source;
}

class LocalCameraStore {
  const LocalCameraStore(this.scope);

  static const _channel = MethodChannel('safehood/local_camera_store');

  /// Guests keep cameras in a separate device-only catalog. An authenticated
  /// user can access their own catalog during an offline Firebase profile fetch.
  final String scope;

  Future<List<SavedLocalCamera>> list() async {
    final rows = await _channel.invokeListMethod<Object?>('list', {
      'scope': scope,
    });
    return (rows ?? [])
        .map((row) {
          final data = row! as Map<Object?, Object?>;
          return SavedLocalCamera(
            data['id'] as String,
            LocalCameraSource.fromMap(data),
          );
        })
        .toList(growable: false);
  }

  Future<void> save(LocalCameraSource source, {String? id}) =>
      _channel.invokeMethod<void>('save', {
        'scope': scope,
        'source': source.toMap(),
        'id': ?id,
      });

  Future<void> delete(String id) =>
      _channel.invokeMethod<void>('delete', {'scope': scope, 'id': id});
}

class LocalCameraPlayer {
  const LocalCameraPlayer();

  static const _channel = MethodChannel('safehood/local_camera_player');

  Future<int> open(Uri uri, {bool tryUdp = false}) async =>
      (await _channel.invokeMethod<int>('open', {
        'uri': uri.toString(),
        if (tryUdp) 'tryUdp': true,
      }))!;

  Future<Map<String, Object?>> state(int id) async =>
      (await _channel.invokeMapMethod<String, Object?>('state', {'id': id}))!;

  Future<void> stop(int id) => _channel.invokeMethod<void>('stop', {'id': id});

  Future<Uri> refreshReolink(String uid, Uri uri) async {
    final updated = await _channel.invokeMethod<String>('refreshReolink', {
      'uid': uid,
      'uri': uri.toString(),
    });
    final stream = updated == null ? null : parseLocalRtsp(updated);
    if (stream == null) throw const FormatException('Brak lokalnego RTSP.');
    return stream;
  }

  Future<Uri> resolveOnvif(
    Uri endpoint,
    String username,
    String password,
  ) async {
    final result = await _channel.invokeMethod<String>('resolveOnvif', {
      'endpoint': endpoint.toString(),
      'username': username,
      'password': password,
    });
    final stream = result == null ? null : parseLocalRtsp(result);
    if (stream == null) throw const FormatException('Brak lokalnego RTSP.');
    return stream;
  }
}

class ReolinkPairing {
  const ReolinkPairing();

  static const _channel = MethodChannel('safehood/reolink_pairing');

  Future<bool> select(String uid) async =>
      await _channel.invokeMethod<bool>('select', {'uid': uid}) ?? false;

  Future<String> connectWifi(String ssid, String password) async =>
      (await _channel.invokeMethod<String>('connectWifi', {
        'ssid': ssid,
        'password': password,
      }))!;

  Future<LocalCameraSource> prepareStream(
    String uid,
    String cameraPassword, {
    required bool factory,
  }) async {
    final response = await _channel.invokeMapMethod<Object?, Object?>(
      'prepareStream',
      {'uid': uid, 'password': cameraPassword, 'factory': factory},
    );
    return LocalCameraSource.fromMap({...response!, 'reolinkUid': uid});
  }

  Future<void> cancel() => _channel.invokeMethod<void>('cancel');
}
