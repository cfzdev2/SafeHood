import 'package:flutter/services.dart';

/// Evidence read from the selected camera. Stored privately with its connection.
class NativeCameraProfile {
  const NativeCameraProfile({
    required this.protocol,
    this.serialNumber,
    this.model,
    this.motionSupported = false,
  });

  final String protocol;
  final String? serialNumber;
  final String? model;
  final bool motionSupported;

  Map<String, Object?> toMap() => {
    'protocol': protocol,
    'serialNumber': serialNumber,
    'model': model,
    'motionSupported': motionSupported,
  };

  static NativeCameraProfile? fromMap(Object? value) {
    if (value is! Map || value['protocol'] != 'dvrip') return null;
    final serial = value['serialNumber'];
    final model = value['model'];
    return NativeCameraProfile(
      protocol: 'dvrip',
      serialNumber:
          serial is String && RegExp(r'^[a-zA-Z0-9_-]{8,64}$').hasMatch(serial)
          ? serial
          : null,
      model: model is String && model.length <= 100 ? model : null,
      motionSupported: value['motionSupported'] == true,
    );
  }
}

class NativeCameraInspector {
  NativeCameraInspector({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('safehood/background_motion');

  final MethodChannel _channel;
  final _attempted = <String>{};

  Future<NativeCameraProfile?> inspect({
    required String cameraId,
    required String host,
    required String username,
    required String password,
  }) async {
    // One authenticated attempt on the selected peer; no credential guessing loop.
    if (!_attempted.add(cameraId)) return null;
    try {
      return NativeCameraProfile.fromMap(
        await _channel
            .invokeMethod<Object?>('inspectNative', {
              'host': host,
              'username': username,
              'password': password,
            })
            .timeout(const Duration(seconds: 12)),
      );
    } on Exception {
      return null;
    }
  }
}
