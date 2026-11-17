import 'package:flutter/material.dart';

import '../data/local_camera_store.dart';
import 'local_camera_preview.dart';
import 'local_camera_setup_screen.dart';

class LocalCamerasScreen extends StatefulWidget {
  const LocalCamerasScreen({super.key, required this.store});

  final LocalCameraStore store;

  @override
  State<LocalCamerasScreen> createState() => _LocalCamerasScreenState();
}

class _LocalCamerasScreenState extends State<LocalCamerasScreen> {
  late var _cameras = widget.store.list();

  void _refresh() => setState(() => _cameras = widget.store.list());

  Future<void> _add() async {
    final result = await Navigator.of(context).push<LocalCameraSetupResult>(
      MaterialPageRoute<LocalCameraSetupResult>(
        builder: (_) => LocalCameraSetupScreen(store: widget.store),
      ),
    );
    if (result == LocalCameraSetupResult.saved && mounted) _refresh();
  }

  void _open(SavedLocalCamera camera) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            LocalCameraPreview(source: camera.source, store: widget.store),
      ),
    );
  }

  Future<void> _edit(SavedLocalCamera camera) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) =>
            ManualLocalCameraScreen(store: widget.store, existing: camera),
      ),
    );
    if (saved == true && mounted) _refresh();
  }

  Future<void> _remove(SavedLocalCamera camera) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Usuń kamerę z telefonu?'),
        content: Text(camera.source.name),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Anuluj'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Usuń'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.store.delete(camera.id);
      if (mounted) _refresh();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nie udało się usunąć kamery.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Kamery lokalne')),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: null,
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('Dodaj kamerę'),
      ),
      body: FutureBuilder<List<SavedLocalCamera>>(
        future: _cameras,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: OutlinedButton(
                onPressed: _refresh,
                child: const Text(
                  'Nie udało się wczytać kamer. Spróbuj ponownie',
                ),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final cameras = snapshot.data!;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
            children: [
              const Text(
                'Te kamery i ich dane dostępu są zapisane tylko na tym telefonie. '
                'Podgląd działa, gdy telefon jest w sieci kamery.',
              ),
              const SizedBox(height: 12),
              if (cameras.isEmpty)
                const Text('Nie ma jeszcze kamer lokalnych.'),
              for (final camera in cameras)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.videocam_outlined),
                    title: Text(camera.source.name),
                    subtitle: Text(camera.source.uri.host),
                    onTap: () => _open(camera),
                    trailing: PopupMenuButton<String>(
                      onSelected: (action) {
                        if (action == 'edit') _edit(camera);
                        if (action == 'delete') _remove(camera);
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'edit',
                          child: Text('Zmień adres RTSP'),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: Text('Usuń z telefonu'),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

void openLocalCameras(BuildContext context, String scope) {
  Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => LocalCamerasScreen(store: LocalCameraStore(scope)),
    ),
  );
}
