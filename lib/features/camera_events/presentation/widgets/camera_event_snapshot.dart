import 'dart:typed_data';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';

import '../../domain/camera_event.dart';

class CameraEventSnapshot extends StatefulWidget {
  final CameraEvent event;
  final BoxFit fit;
  final bool compact;

  const CameraEventSnapshot({
    super.key,
    required this.event,
    this.fit = BoxFit.cover,
    this.compact = false,
  });

  @override
  State<CameraEventSnapshot> createState() => _CameraEventSnapshotState();
}

class _CameraEventSnapshotState extends State<CameraEventSnapshot> {
  static const _maxSnapshotBytes = 5 * 1024 * 1024;

  Future<Uint8List?>? _snapshotFuture;

  @override
  void initState() {
    super.initState();
    _prepareSnapshot();
  }

  @override
  void didUpdateWidget(covariant CameraEventSnapshot oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.event.id != widget.event.id ||
        oldWidget.event.ownerId != widget.event.ownerId ||
        _snapshotPath(oldWidget.event) != _snapshotPath(widget.event)) {
      _prepareSnapshot();
    }
  }

  String? _snapshotPath(CameraEvent event) {
    final path = event.snapshotPath?.trim();

    return path == null || path.isEmpty ? null : path;
  }

  void _prepareSnapshot() {
    final path = _snapshotPath(widget.event);

    _snapshotFuture = path == null
        ? null
        : _downloadSnapshot(path, widget.event.id);
  }

  Future<Uint8List?> _downloadSnapshot(String path, String eventId) async {
    try {
      return await FirebaseStorage.instance
          .ref(path)
          .getData(_maxSnapshotBytes);
    } on FirebaseException catch (error) {
      debugPrint('CAMERA SNAPSHOT [$eventId]: ${error.code}');
      rethrow;
    }
  }

  void _retrySnapshot() {
    setState(_prepareSnapshot);
  }

  @override
  Widget build(BuildContext context) {
    if (_snapshotPath(widget.event) != null) {
      return FutureBuilder<Uint8List?>(
        future: _snapshotFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return _loading();
          }

          final bytes = snapshot.data;

          if (snapshot.hasError || bytes == null || bytes.isEmpty) {
            return _failure(retry: true);
          }

          return Image.memory(
            bytes,
            fit: widget.fit,
            errorBuilder: (context, error, stackTrace) {
              return _failure(retry: true);
            },
          );
        },
      );
    }

    final url = widget.event.snapshotUrl?.trim();

    if (url != null && url.isNotEmpty) {
      return Image.network(
        url,
        fit: widget.fit,
        loadingBuilder: (context, child, loadingProgress) {
          return loadingProgress == null ? child : _loading();
        },
        errorBuilder: (context, error, stackTrace) {
          return _failure();
        },
      );
    }

    return _status(Icons.videocam_outlined, 'Brak zdjęcia');
  }

  Widget _loading() {
    return const ColoredBox(
      color: Colors.black87,
      child: Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Colors.white70,
          ),
        ),
      ),
    );
  }

  Widget _failure({bool retry = false}) {
    final message = retry
        ? 'Nie udało się wczytać zdjęcia.\nDotknij, aby ponowić.'
        : 'Nie udało się wczytać zdjęcia.';

    return GestureDetector(
      onTap: retry ? _retrySnapshot : null,
      child: Tooltip(
        message: message,
        child: _status(Icons.broken_image_outlined, message),
      ),
    );
  }

  Widget _status(IconData icon, String message) {
    return ColoredBox(
      color: Colors.black87,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: widget.compact ? 24 : 36, color: Colors.white70),
              if (!widget.compact) ...[
                const SizedBox(height: 8),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
