import 'package:flutter/material.dart';

import '../domain/camera.dart';
import '../domain/camera_snapshot.dart';

class CameraSnapshotPreviewScreen extends StatefulWidget {
  final Camera camera;
  final CameraSnapshot snapshot;

  const CameraSnapshotPreviewScreen({
    super.key,
    required this.camera,
    required this.snapshot,
  });

  @override
  State<CameraSnapshotPreviewScreen> createState() =>
      _CameraSnapshotPreviewScreenState();
}

class _CameraSnapshotPreviewScreenState
    extends State<CameraSnapshotPreviewScreen> {
  int _reloadAttempt = 0;

  String _formatDate(DateTime date) {
    final local = date.toLocal();

    String twoDigits(int value) => value.toString().padLeft(2, '0');

    return '${twoDigits(local.day)}.'
        '${twoDigits(local.month)}.'
        '${local.year}  '
        '${twoDigits(local.hour)}:'
        '${twoDigits(local.minute)}:'
        '${twoDigits(local.second)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Snapshot'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: InteractiveViewer(
                  minScale: 1,
                  maxScale: 4,
                  child: Image.network(
                    widget.snapshot.imageUri.toString(),
                    key: ValueKey(_reloadAttempt),
                    fit: BoxFit.contain,
                    loadingBuilder: (context, child, progress) {
                      if (progress == null) {
                        return child;
                      }

                      return const Center(child: CircularProgressIndicator());
                    },
                    errorBuilder: (context, error, stackTrace) {
                      return Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.broken_image_outlined,
                              color: Colors.white70,
                              size: 64,
                            ),
                            const SizedBox(height: 16),
                            const Text(
                              'Nie udało się wczytać zdjęcia.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.white),
                            ),
                            const SizedBox(height: 16),
                            OutlinedButton.icon(
                              onPressed: () {
                                setState(() {
                                  _reloadAttempt++;
                                });
                              },
                              icon: const Icon(Icons.refresh),
                              label: const Text('Spróbuj ponownie'),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              color: Colors.black,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.camera.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _formatDate(widget.snapshot.capturedAt),
                    style: const TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
