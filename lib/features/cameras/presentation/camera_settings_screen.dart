import 'dart:async';

import 'package:flutter/material.dart';

import '../data/camera_service.dart';
import '../domain/camera.dart';
import '../domain/camera_notification_settings.dart';

class CameraSettingsScreen extends StatefulWidget {
  final Camera camera;

  const CameraSettingsScreen({super.key, required this.camera});

  @override
  State<CameraSettingsScreen> createState() => _CameraSettingsScreenState();
}

class _CameraSettingsScreenState extends State<CameraSettingsScreen> {
  final CameraService _cameraService = CameraService();

  late bool _monitoringEnabled;

  late String _cameraName;
  late String _locationName;

  CameraNotificationSettings _notificationSettings =
      const CameraNotificationSettings();

  bool _loadingMonitoring = true;
  bool _savingMonitoring = false;
  bool _deleting = false;

  bool _loadingNotifications = true;
  bool _savingNotifications = false;
  bool _savingDetails = false;
  @override
  void initState() {
    super.initState();

    _monitoringEnabled = widget.camera.motionDetectionEnabled;
    _cameraName = widget.camera.name;
    _locationName = widget.camera.locationName;

    unawaited(_loadCurrentCamera());
  }

  Future<void> _loadCurrentCamera() async {
    try {
      final currentCamera = await _cameraService.getCamera(widget.camera.id);

      final notificationSettings = await _cameraService.getNotificationSettings(
        widget.camera.id,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        if (currentCamera != null) {
          _cameraName = currentCamera.name;
          _locationName = currentCamera.locationName;
          _monitoringEnabled = currentCamera.motionDetectionEnabled;
        }

        _notificationSettings = notificationSettings;
      });
    } catch (_) {
      // Pozostawiamy wartości domyślne.
    } finally {
      if (mounted) {
        setState(() {
          _loadingMonitoring = false;
          _loadingNotifications = false;
        });
      }
    }
  }

  Future<void> _editCameraDetails() async {
    if (_savingDetails || _deleting) {
      return;
    }

    final formKey = GlobalKey<FormState>();

    final nameController = TextEditingController(text: _cameraName);

    final locationController = TextEditingController(text: _locationName);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Edytuj kamerę'),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: nameController,
                  autofocus: true,
                  maxLength: 60,
                  decoration: const InputDecoration(
                    labelText: 'Nazwa kamery',
                    prefixIcon: Icon(Icons.videocam_outlined),
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Podaj nazwę kamery.';
                    }

                    return null;
                  },
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: locationController,
                  maxLength: 100,
                  decoration: const InputDecoration(
                    labelText: 'Lokalizacja',
                    prefixIcon: Icon(Icons.place_outlined),
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Podaj lokalizację kamery.';
                    }

                    return null;
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(false);
              },
              child: const Text('Anuluj'),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState?.validate() ?? false) {
                  Navigator.of(dialogContext).pop(true);
                }
              },
              child: const Text('Zapisz'),
            ),
          ],
        );
      },
    );

    final newName = nameController.text.trim();
    final newLocationName = locationController.text.trim();

    if (confirmed != true || !mounted) {
      return;
    }

    setState(() {
      _savingDetails = true;
    });

    try {
      await _cameraService.updateCameraDetails(
        cameraId: widget.camera.id,
        name: newName,
        locationName: newLocationName,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _cameraName = newName;
        _locationName = newLocationName;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Dane kamery zostały zapisane.')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Nie udało się zapisać danych kamery: $error')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _savingDetails = false;
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

  Future<void> _setNotificationSettings(
    CameraNotificationSettings settings,
  ) async {
    if (_savingNotifications || _deleting) {
      return;
    }

    final previousSettings = _notificationSettings;

    setState(() {
      _notificationSettings = settings;
      _savingNotifications = true;
    });

    try {
      await _cameraService.setNotificationSettings(
        cameraId: widget.camera.id,
        settings: settings,
      );
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _notificationSettings = previousSettings;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Nie udało się zapisać powiadomień: $error')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _savingNotifications = false;
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
            'Kamera „$_cameraName” '
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
    final notificationsBusy =
        _loadingNotifications || _savingNotifications || _deleting;

    final notificationTypesEnabled =
        _notificationSettings.enabled && !notificationsBusy;

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
                  subtitle: Text(_cameraName),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.place_outlined),
                  title: const Text('Lokalizacja'),
                  subtitle: Text(_locationName),
                ),
                const Divider(height: 1),
                ListTile(
                  enabled: !_savingDetails && !_deleting,
                  leading: _savingDetails
                      ? const SizedBox.square(
                          dimension: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.edit_outlined),
                  title: Text(
                    _savingDetails
                        ? 'Zapisywanie zmian...'
                        : 'Edytuj nazwę i lokalizację',
                  ),
                  trailing: _savingDetails
                      ? null
                      : const Icon(Icons.chevron_right),
                  onTap: _savingDetails || _deleting
                      ? null
                      : _editCameraDetails,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.hub_outlined),
                  title: const Text('Bridge'),
                  subtitle: Text(bridgeId ?? 'Nieprzypisany'),
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
                        ? 'SafeHood odbiera i zapisuje '
                              'zdarzenia z kamery.'
                        : 'Zdarzenia z kamery nie są '
                              'odbierane ani zapisywane.',
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
            'Powiadomienia',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                SwitchListTile.adaptive(
                  secondary: const Icon(Icons.notifications_outlined),
                  title: const Text('Powiadomienia z kamery'),
                  subtitle: Text(
                    _notificationSettings.enabled
                        ? 'SafeHood wyśle wybrane alerty.'
                        : 'Zdarzenia będą zapisywane, '
                              'ale bez powiadomień.',
                  ),
                  value: _notificationSettings.enabled,
                  onChanged: notificationsBusy
                      ? null
                      : (enabled) {
                          unawaited(
                            _setNotificationSettings(
                              _notificationSettings.copyWith(enabled: enabled),
                            ),
                          );
                        },
                ),
                const Divider(height: 1),
                SwitchListTile.adaptive(
                  secondary: const Icon(Icons.sensors),
                  title: const Text('Wykrycie ruchu'),
                  value: _notificationSettings.motionEnabled,
                  onChanged: notificationTypesEnabled
                      ? (enabled) {
                          unawaited(
                            _setNotificationSettings(
                              _notificationSettings.copyWith(
                                motionEnabled: enabled,
                              ),
                            ),
                          );
                        }
                      : null,
                ),
                const Divider(height: 1),
                SwitchListTile.adaptive(
                  secondary: const Icon(Icons.person_outline),
                  title: const Text('Wykrycie osoby'),
                  value: _notificationSettings.personEnabled,
                  onChanged: notificationTypesEnabled
                      ? (enabled) {
                          unawaited(
                            _setNotificationSettings(
                              _notificationSettings.copyWith(
                                personEnabled: enabled,
                              ),
                            ),
                          );
                        }
                      : null,
                ),
                const Divider(height: 1),
                SwitchListTile.adaptive(
                  secondary: const Icon(Icons.directions_car_outlined),
                  title: const Text('Wykrycie pojazdu'),
                  value: _notificationSettings.vehicleEnabled,
                  onChanged: notificationTypesEnabled
                      ? (enabled) {
                          unawaited(
                            _setNotificationSettings(
                              _notificationSettings.copyWith(
                                vehicleEnabled: enabled,
                              ),
                            ),
                          );
                        }
                      : null,
                ),
                const Divider(height: 1),
                SwitchListTile.adaptive(
                  secondary: const Icon(Icons.volume_up_outlined),
                  title: const Text('Wykrycie dźwięku'),
                  value: _notificationSettings.soundEnabled,
                  onChanged: notificationTypesEnabled
                      ? (enabled) {
                          unawaited(
                            _setNotificationSettings(
                              _notificationSettings.copyWith(
                                soundEnabled: enabled,
                              ),
                            ),
                          );
                        }
                      : null,
                ),
                if (_loadingNotifications || _savingNotifications)
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
