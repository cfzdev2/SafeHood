import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals, visibleForTesting;
import 'package:mime/mime.dart';

import 'local_camera_connection.dart';

enum Focus72DirectStatus {
  unavailable,
  loginRequired,
  photo,
  sameFrames,
  video,
}

class Focus72DirectResult {
  const Focus72DirectResult(this.status, {this.image});

  final Focus72DirectStatus status;
  final Uint8List? image;
}

/// The test targets exactly the private IPv4 the user supplies. In particular,
/// a localhost feed from a phone relay cannot pass this check.
List<Uri> focus72DirectCandidates(String input) {
  final address = InternetAddress.tryParse(input.trim());
  if (address == null ||
      address.type != InternetAddressType.IPv4 ||
      address.isLoopback ||
      !isCameraLanHost(address.address)) {
    return const [];
  }

  return [
    for (final port in [8080, 80]) ...[
      Uri(
        scheme: 'http',
        host: address.address,
        port: port,
        path: '/axis-cgi/mjpg/video.cgi',
      ),
      Uri(
        scheme: 'http',
        host: address.address,
        port: port,
        path: '/image.cgi',
        queryParameters: const {'type': 'motion'},
      ),
    ],
  ];
}

/// A single read-only probe. No vendor account, login attempts, or redirects.
class Focus72DirectProbe {
  HttpClient? _client;
  bool _closed = false;

  Future<Focus72DirectResult> check(String address) async {
    var best = const Focus72DirectResult(Focus72DirectStatus.unavailable);
    for (final uri in focus72DirectCandidates(address)) {
      if (_closed) break;
      final client = HttpClient()
        ..autoUncompress = false
        ..connectionTimeout = const Duration(seconds: 2)
        ..findProxy = (_) => 'DIRECT';
      _client = client;
      final observation = _Focus72Observation();
      try {
        await _read(
          uri,
          client,
          observation,
        ).timeout(const Duration(seconds: 4));
      } catch (_) {
        // Try the next known endpoint, retaining evidence from a partial feed.
      } finally {
        client.close(force: true);
        _client = null;
      }
      final result = observation.result;
      if (result.status.index > best.status.index) best = result;
      if (best.status == Focus72DirectStatus.video) break;
    }
    return best;
  }

  Future<void> _read(
    Uri uri,
    HttpClient client,
    _Focus72Observation observation,
  ) async {
    final request = await client.getUrl(uri);
    request.followRedirects = false;
    request.persistentConnection = false;
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    request.headers.set(
      HttpHeaders.acceptHeader,
      'multipart/x-mixed-replace, image/jpeg',
    );
    final response = await request.close();
    if (response.statusCode == HttpStatus.unauthorized ||
        response.statusCode == HttpStatus.forbidden) {
      observation.result = const Focus72DirectResult(
        Focus72DirectStatus.loginRequired,
      );
    } else if (response.statusCode == HttpStatus.ok) {
      await observation.read(response, response.headers.contentType);
    }
  }

  void close() {
    _closed = true;
    _client?.close(force: true);
  }
}

@visibleForTesting
Future<Focus72DirectResult> inspectFocus72Image(
  Stream<List<int>> body,
  ContentType? contentType,
) async {
  final observation = _Focus72Observation();
  await observation.read(body, contentType);
  return observation.result;
}

class _Focus72Observation {
  static const _maxJpegBytes = 2 * 1024 * 1024;
  static const _maxResponseBytes = 8 * 1024 * 1024;
  static const _maxFrames = 24;
  Focus72DirectResult result = const Focus72DirectResult(
    Focus72DirectStatus.unavailable,
  );

  Future<void> read(Stream<List<int>> body, ContentType? contentType) async {
    if (contentType?.mimeType == 'image/jpeg') {
      final jpeg = await _readJpeg(body);
      if (await _pixelSample(jpeg) != null) {
        result = Focus72DirectResult(Focus72DirectStatus.photo, image: jpeg);
      }
      return;
    }
    final boundary = contentType?.parameters['boundary'];
    if (contentType?.mimeType != 'multipart/x-mixed-replace' ||
        boundary == null ||
        boundary.isEmpty ||
        boundary.length > 70 ||
        boundary.codeUnits.any((unit) => unit < 32 || unit > 126)) {
      return;
    }

    Uint8List? firstSample;
    var frames = 0;
    final parts = _withByteLimit(
      body,
      _maxResponseBytes,
    ).transform(MimeMultipartTransformer(boundary));
    await for (final part in parts) {
      final type = part.headers[HttpHeaders.contentTypeHeader];
      if (type != null &&
          type.split(';').first.trim().toLowerCase() != 'image/jpeg') {
        await part.drain<void>();
        continue;
      }
      final jpeg = await _readJpeg(part);
      final sample = await _pixelSample(jpeg);
      if (sample == null) continue;
      final status = firstSample == null
          ? Focus72DirectStatus.photo
          : listEquals(firstSample, sample)
          ? Focus72DirectStatus.sameFrames
          : Focus72DirectStatus.video;
      result = Focus72DirectResult(status, image: jpeg);
      firstSample ??= sample;
      if (++frames >= _maxFrames || status == Focus72DirectStatus.video) return;
    }
  }

  Future<Uint8List> _readJpeg(Stream<List<int>> body) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in _withByteLimit(body, _maxJpegBytes)) {
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  Stream<List<int>> _withByteLimit(Stream<List<int>> body, int limit) async* {
    var total = 0;
    await for (final chunk in body) {
      total += chunk.length;
      if (total > limit) {
        throw const FormatException('Image sample is too large.');
      }
      yield chunk;
    }
  }

  Future<Uint8List?> _pixelSample(Uint8List bytes) async {
    if (bytes.length < 4 || bytes[0] != 0xff || bytes[1] != 0xd8) return null;
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        if (descriptor.width > 4096 ||
            descriptor.height > 4096 ||
            descriptor.width * descriptor.height > 8 * 1024 * 1024) {
          return null;
        }
        final codec = await descriptor.instantiateCodec(
          targetWidth: 32,
          targetHeight: 24,
        );
        try {
          final image = (await codec.getNextFrame()).image;
          try {
            final pixels = await image.toByteData();
            return pixels?.buffer.asUint8List(
              pixels.offsetInBytes,
              pixels.lengthInBytes,
            );
          } finally {
            image.dispose();
          }
        } finally {
          codec.dispose();
        }
      } finally {
        descriptor.dispose();
      }
    } on Exception {
      return null;
    } finally {
      buffer.dispose();
    }
  }
}
