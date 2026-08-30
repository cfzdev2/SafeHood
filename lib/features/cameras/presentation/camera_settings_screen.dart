import 'dart:async';

import 'package:flutter/material.dart';

import '../data/camera_service.dart';
import '../domain/camera.dart';

class CameraSettingsScreen extends StatefulWidget {
  final Camera camera;

  const CameraSettingsScreen({super.key, required this.camera});

  @override
  State<CameraSettingsScreen> createState() => _CameraSettingsScreenState();
}

class _CameraSettingsScreenState extends State<CameraSettingsScreen> {
  final CameraService _cameraService = CameraService();

  late bool _monitoringEnabled;

  bool _loadingMonitoring = true;
  bool _savingMonitoring = false;
  bool _deleting = false;

  @override
  void initState() {
    super.initState();

    _monitoringEnabled = widget.camera.motionDetectionEnabled;

    unawaited(_loadCurrentCamera());
  }

  Future<void> _loadCurrentCamera() async {
    try {
      final currentCamera = await _cameraService.getCamera(widget.camera.id);

      if (!mounted) {
        return;
      }

      if (currentCamera != null) {
        _monitoringEnabled = currentCamera.motionDetectionEnabled;
      }
    } catch (_) {
      // Pozostawiamy wartość przekazaną
      // z ekranu szczegółów.
    } finally {
      if (mounted) {
        setState(() {
          _loadingMonitoring = false;
        });
      }
    }
  }

  Future<void> _setMonitoringEnabled(bool enabled) async {
    if (_savingMonitoring || _deleting) {
      return;
    }

    final previousValue = _monitoringEnabled;

    setState(() {
      _monitoringEnabled = enabled;
      _savingMonitoring = true;
    });

    try {
      await _cameraService.setMonitoringEnabled(
        cameraId: widget.camera.id,
        enabled: enabled,
      );

      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            enabled
                ? 'Monitoring kamery '
                      'został włączony.'
                : 'Monitoring kamery '
                      'został wyłączony.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _monitoringEnabled = previousValue;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Nie udało się zmienić '
            'monitoringu: $error',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _savingMonitoring = false;
        });
      }
    }
  }

  Future<void> _deleteCamera() async {
    if (_deleting) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Usunąć kamerę?'),
          content: Text(
            'Kamera „${widget.camera.name}” '
            'zostanie usunięta z SafeHood. '
            'Bridge natychmiast zakończy '
            'jej monitoring.',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(false);
              },
              child: const Text('Anuluj'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              onPressed: () {
                Navigator.of(dialogContext).pop(true);
              },
              child: const Text('Usuń'),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !mounted) {
      return;
    }

    setState(() {
      _deleting = true;
    });

    try {
      await _cameraService.deleteCamera(widget.camera.id);

      if (!mounted) {
        return;
      }

      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _deleting = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Nie udało się usunąć '
            'kamery: $error',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bridgeId = widget.camera.bridgeId;

    return Scaffold(
      appBar: AppBar(title: const Text('Ustawienia kamery')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [
          Text(
            'Informacje',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.videocam_outlined),
                  title: const Text('Nazwa'),
                  subtitle: Text(widget.camera.name),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.place_outlined),
                  title: const Text('Lokalizacja'),
                  subtitle: Text(widget.camera.locationName),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.hub_outlined),
                  title: const Text('Bridge'),
                                    subtitle: Text(
                    bridgeId ??
                        'Nieprzypisany',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Monitoring',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                SwitchListTile.adaptive(
                  secondary: const Icon(Icons.sensors_outlined),
                  title: const Text('Monitoring przez SafeHood'),
                  subtitle: Text(
                    _monitoringEnabled
                        ? 'Bridge odbiera '
                              'zdarzenia z kamery.'
                        : 'Zdarzenia z kamery '
                              'nie są odbierane.',
                  ),
                  value: _monitoringEnabled,
                  onChanged:
                      _loadingMonitoring || _savingMonitoring || _deleting
                      ? null
                      : _setMonitoringEnabled,
                ),
                if (_loadingMonitoring || _savingMonitoring)
                  const LinearProgressIndicator(),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Strefa niebezpieczna',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Theme.of(context).colorScheme.error,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              enabled: !_deleting,
              leading: _deleting
                  ? const SizedBox.square(
                      dimension: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      Icons.delete_outline,
                      color: Theme.of(context).colorScheme.error,
                    ),
              title: Text(
                _deleting ? 'Usuwanie kamery...' : 'Usuń kamerę',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: const Text(
                'Operacja wymaga '
                'potwierdzenia.',
              ),
              onTap: _deleting ? null : _deleteCamera,
            ),
          ),
        ],
      ),
    );
  }
}
