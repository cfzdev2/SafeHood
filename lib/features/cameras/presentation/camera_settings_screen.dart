import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../data/camera_monitoring_coordinator.dart';
import '../data/camera_service.dart';
import '../data/local_camera_connection.dart';
import 'camera_wifi_setup_screen.dart';
import 'local_camera_connection_dialog.dart';
import '../domain/camera.dart';
import '../domain/camera_ai_zone.dart';
import '../domain/camera_motion_preference.dart';
import '../domain/camera_notification_settings.dart';
import 'camera_ai_zones_screen.dart';
import '../../profile/data/user_profile_service.dart';
import '../../profile/domain/app_user.dart';
import 'widgets/camera_motion_setting.dart';

class CameraSettingsScreen extends StatefulWidget {
  final Camera camera;

  const CameraSettingsScreen({super.key, required this.camera});

  @override
  State<CameraSettingsScreen> createState() => _CameraSettingsScreenState();
}

class _CameraSettingsScreenState extends State<CameraSettingsScreen> {
  static const _notificationCooldownLabels = <int, String>{
    0: 'Bez ograniczeń',
    30: '30 s',
    60: '1 min',
    300: '5 min',
    900: '15 min',
  };

  final CameraService _cameraService = CameraService();
  final UserProfileService _profileService = UserProfileService();

  late bool _monitoringEnabled;
  late bool _liveMotionEnabled;
  late bool _aiEnabled;
  late bool _aiPersonEnabled;
  late bool _aiVehicleEnabled;
  late bool _aiRecordingEnabled;
  late String _aiSensitivity;
  late List<CameraAiZone> _aiDetectionZones;
  late List<CameraAiZone> _aiIgnoreZones;

  late String _cameraName;
  late String _locationName;
  String? _bridgeId;

  CameraNotificationSettings _notificationSettings =
      const CameraNotificationSettings();

  bool _loadingMonitoring = true;
  bool _savingMonitoring = false;
  bool _loadingAi = true;
  bool _savingAi = false;
  bool _deleting = false;

  bool _loadingNotifications = true;
  bool _savingNotifications = false;
  bool _savingDetails = false;
  @override
  void initState() {
    super.initState();

    _monitoringEnabled = widget.camera.motionDetectionEnabled;
    _liveMotionEnabled = widget.camera.liveMotionEnabled;
    _aiEnabled = widget.camera.aiEnabled;
    _aiPersonEnabled = widget.camera.aiPersonEnabled;
    _aiVehicleEnabled = widget.camera.aiVehicleEnabled;
    _aiRecordingEnabled = widget.camera.aiRecordingEnabled;
    _aiSensitivity = widget.camera.aiSensitivity;
    _aiDetectionZones = List.of(widget.camera.aiDetectionZones);
    _aiIgnoreZones = List.of(widget.camera.aiIgnoreZones);
    _cameraName = widget.camera.name;
    _locationName = widget.camera.locationName;
    _bridgeId = widget.camera.bridgeId;

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
          _bridgeId = currentCamera.bridgeId;
          _monitoringEnabled = currentCamera.motionDetectionEnabled;
          _liveMotionEnabled = currentCamera.liveMotionEnabled;
          _aiEnabled = currentCamera.aiEnabled;
          _aiPersonEnabled = currentCamera.aiPersonEnabled;
          _aiVehicleEnabled = currentCamera.aiVehicleEnabled;
          _aiRecordingEnabled = currentCamera.aiRecordingEnabled;
          _aiSensitivity = currentCamera.aiSensitivity;
          _aiDetectionZones = List.of(currentCamera.aiDetectionZones);
          _aiIgnoreZones = List.of(currentCamera.aiIgnoreZones);
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
          _loadingAi = false;
        });
      }
    }
  }

  Future<void> _editCameraDetails() async {
    if (_savingDetails || _deleting) {
      return;
    }

    final formKey = GlobalKey<FormState>();

    var editedName = _cameraName;
    var editedLocationName = _locationName;

    final editResult = await showDialog<_CameraDetailsEditResult>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Edytuj kamerę'),
          content: SingleChildScrollView(
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    initialValue: editedName,
                    autofocus: true,
                    maxLength: 60,
                    decoration: const InputDecoration(
                      labelText: 'Nazwa kamery',
                      prefixIcon: Icon(Icons.videocam_outlined),
                    ),
                    onChanged: (value) {
                      editedName = value;
                    },
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Podaj nazwę kamery.';
                      }

                      return null;
                    },
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    initialValue: editedLocationName,
                    maxLength: 100,
                    decoration: const InputDecoration(
                      labelText: 'Lokalizacja',
                      prefixIcon: Icon(Icons.place_outlined),
                    ),
                    onChanged: (value) {
                      editedLocationName = value;
                    },
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
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
              },
              child: const Text('Anuluj'),
            ),
            FilledButton(
              onPressed: () {
                if (!(formKey.currentState?.validate() ?? false)) {
                  return;
                }

                Navigator.of(dialogContext).pop(
                  _CameraDetailsEditResult(
                    name: editedName.trim(),
                    locationName: editedLocationName.trim(),
                  ),
                );
              },
              child: const Text('Zapisz'),
            ),
          ],
        );
      },
    );

    if (editResult == null || !mounted) {
      return;
    }

    setState(() {
      _savingDetails = true;
    });

    try {
      await _cameraService.updateCameraDetails(
        cameraId: widget.camera.id,
        name: editResult.name,
        locationName: editResult.locationName,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _cameraName = editResult.name;
        _locationName = editResult.locationName;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Dane kamery zostały zapisane.')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Nie udało się zapisać danych kamery. Spróbuj ponownie.',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _savingDetails = false;
        });
      }
    }
  }

  CameraMotionPreference get _motionPreference =>
      CameraMotionPreference.fromSettings(
        widget.camera.copyWith(
          motionDetectionEnabled: _monitoringEnabled,
          liveMotionEnabled: _liveMotionEnabled,
        ),
        _notificationSettings,
      );

  Future<void> _setMotionPreference(CameraMotionPreference preference) async {
    if (_savingMonitoring || _savingNotifications || _deleting) return;
    setState(() => _savingMonitoring = true);
    try {
      final notifications = await _cameraService.setMotionPreference(
        cameraId: widget.camera.id,
        preference: preference,
      );
      if (!mounted) return;
      setState(() {
        _monitoringEnabled =
            widget.camera.connectionType == CameraConnectionType.onvif &&
            preference.detects;
        _liveMotionEnabled = preference.detects;
        _notificationSettings = notifications;
      });
      unawaited(
        CameraMonitoringCoordinator.instance.intentChanged(
          widget.camera.copyWith(
            motionDetectionEnabled: _monitoringEnabled,
            liveMotionEnabled: _liveMotionEnabled,
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Nie udało się zapisać ustawienia ruchu.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _savingMonitoring = false);
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
            'monitoringu. Spróbuj ponownie.',
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

  Future<void> _setAiSettings({
    bool? enabled,
    bool? personEnabled,
    bool? vehicleEnabled,
    bool? recordingEnabled,
    String? sensitivity,
  }) async {
    if (_savingAi || _deleting) {
      return;
    }

    final nextEnabled = enabled ?? _aiEnabled;
    final nextPersonEnabled = personEnabled ?? _aiPersonEnabled;
    final nextVehicleEnabled = vehicleEnabled ?? _aiVehicleEnabled;
    final nextRecordingEnabled = recordingEnabled ?? _aiRecordingEnabled;
    final nextSensitivity = sensitivity ?? _aiSensitivity;

    if (nextEnabled && !nextPersonEnabled && !nextVehicleEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Włącz wykrywanie osoby lub pojazdu.')),
      );

      return;
    }

    final previousEnabled = _aiEnabled;
    final previousPersonEnabled = _aiPersonEnabled;
    final previousVehicleEnabled = _aiVehicleEnabled;
    final previousRecordingEnabled = _aiRecordingEnabled;
    final previousSensitivity = _aiSensitivity;

    setState(() {
      _aiEnabled = nextEnabled;
      _aiPersonEnabled = nextPersonEnabled;
      _aiVehicleEnabled = nextVehicleEnabled;
      _aiRecordingEnabled = nextRecordingEnabled;
      _aiSensitivity = nextSensitivity;
      _savingAi = true;
    });

    try {
      await _cameraService.setAiSettings(
        cameraId: widget.camera.id,
        enabled: nextEnabled,
        personEnabled: nextPersonEnabled,
        vehicleEnabled: nextVehicleEnabled,
        recordingEnabled: nextRecordingEnabled,
        sensitivity: nextSensitivity,
      );
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _aiEnabled = previousEnabled;
        _aiPersonEnabled = previousPersonEnabled;
        _aiVehicleEnabled = previousVehicleEnabled;
        _aiRecordingEnabled = previousRecordingEnabled;
        _aiSensitivity = previousSensitivity;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Nie udało się zapisać ustawień AI. Spróbuj ponownie.'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _savingAi = false;
        });
      }
    }
  }

  Future<void> _setNotificationSettings(
    CameraNotificationSettings settings,
  ) async {
    if (_savingNotifications || _savingMonitoring || _deleting) {
      return;
    }

    final previousSettings = _notificationSettings;

    setState(() {
      _notificationSettings = settings;
      _savingNotifications = true;
    });

    try {
      final saved = await _cameraService.setNotificationSettings(
        cameraId: widget.camera.id,
        settings: settings,
        keepMotionAlert: widget.camera.usesLocalConnection,
      );
      if (mounted) setState(() => _notificationSettings = saved);
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _notificationSettings = previousSettings;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Nie udało się zapisać powiadomień. Spróbuj ponownie.'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _savingNotifications = false;
        });
      }
    }
  }

  Future<void> _openAiZonesEditor() async {
    if (_savingAi || _deleting) {
      return;
    }

    final result = await Navigator.of(context).push<CameraAiZonesResult>(
      MaterialPageRoute(
        builder: (context) {
          return CameraAiZonesScreen(
            camera: widget.camera.copyWith(
              aiDetectionZones: _aiDetectionZones,
              aiIgnoreZones: _aiIgnoreZones,
            ),
          );
        },
      ),
    );

    if (result == null || !mounted) {
      return;
    }

    setState(() {
      _aiDetectionZones = List.of(result.detectionZones);
      _aiIgnoreZones = List.of(result.ignoreZones);
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Strefy wykrywania zostały zapisane.')),
    );
  }

  Future<void> _editLocalConnection() async {
    try {
      final camera = widget.camera;
      final current = await const LocalCameraConnectionStore().read(camera.id);
      if (!mounted) return;
      final connection = await showLocalCameraConnectionDialog(
        context,
        initial: current,
        requireRtsp: camera.connectionType == CameraConnectionType.rtsp,
        allowOnvifOverride: camera.connectionType == CameraConnectionType.onvif,
      );
      if (!mounted || connection == null) return;
      await _cameraService.saveLocalCameraConnection(camera.id, connection);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Zapisano lokalne ustawienia połączenia.'),
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Nie udało się zapisać ustawień na telefonie.'),
        ),
      );
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
            'kamery. Spróbuj ponownie.',
          ),
        ),
      );
    }
  }

  Widget _alertCooldown({required bool enabled}) {
    return ListTile(
      enabled: enabled,
      leading: const Icon(Icons.timer_outlined),
      title: const Text('Odstęp między alertami'),
      trailing: DropdownButton<int>(
        value: _notificationSettings.cooldownSeconds,
        items: _notificationCooldownLabels.entries
            .map(
              (entry) => DropdownMenuItem<int>(
                value: entry.key,
                child: Text(entry.value),
              ),
            )
            .toList(growable: false),
        onChanged: enabled
            ? (seconds) {
                if (seconds == null) return;
                unawaited(
                  _setNotificationSettings(
                    _notificationSettings.copyWith(cooldownSeconds: seconds),
                  ),
                );
              }
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final bridgeId = _bridgeId;
    final rtspOnly = widget.camera.connectionType == CameraConnectionType.rtsp;
    final local = widget.camera.usesLocalConnection;
    final notificationsBusy =
        _loadingNotifications ||
        _savingNotifications ||
        _savingMonitoring ||
        _deleting;

    final notificationTypesEnabled =
        _notificationSettings.enabled && !notificationsBusy;
    final canSetCooldown =
        !notificationsBusy &&
        ((!rtspOnly && _notificationSettings.enabled) ||
            (local && _motionPreference.sendsAlert));

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
          if (widget.camera.connectionType == CameraConnectionType.onvif ||
              widget.camera.connectionType == CameraConnectionType.rtsp) ...[
            const SizedBox(height: 12),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.vpn_key_outlined),
                    title: const Text('Adres i dane logowania kamery'),
                    subtitle: const Text(
                      'Ustawienia podglądu na tym telefonie',
                    ),
                    onTap: _deleting ? null : _editLocalConnection,
                  ),
                  if (widget.camera.connectionType ==
                      CameraConnectionType.onvif)
                    ListTile(
                      leading: const Icon(Icons.wifi),
                      title: const Text('Połącz kamerę z Wi-Fi'),
                      onTap: _deleting
                          ? null
                          : () => Navigator.of(context).push<bool>(
                              MaterialPageRoute(
                                builder: (_) => CameraWifiSetupScreen(
                                  camera: widget.camera,
                                ),
                              ),
                            ),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 24),
          Text(
            'Wykrywanie',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                if (local) ...[
                  CameraMotionSetting(
                    preference: _motionPreference,
                    onChanged: _loadingMonitoring || notificationsBusy
                        ? null
                        : _setMotionPreference,
                  ),
                  ListenableBuilder(
                    listenable: CameraMonitoringCoordinator.instance,
                    builder: (context, child) => Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Text(
                        CameraMonitoringCoordinator.instance
                            .messageFor(
                              widget.camera.copyWith(
                                motionDetectionEnabled: _monitoringEnabled,
                                liveMotionEnabled: _liveMotionEnabled,
                              ),
                            ),
                      ),
                    ),
                  ),
                ] else
                  SwitchListTile.adaptive(
                    secondary: const Icon(Icons.sensors_outlined),
                    title: const Text('Monitoring kamery'),
                    subtitle: Text(
                      _monitoringEnabled
                          ? 'SafeHood odbiera i zapisuje zdarzenia z kamery.'
                          : 'Zdarzenia z kamery nie są odbierane.',
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
          if (user != null && !rtspOnly) ...[
            const SizedBox(height: 24),
            Text(
              'Analiza AI',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            StreamBuilder<AppUser?>(
              stream: _profileService.watchProfile(user.uid),
              builder: (context, snapshot) {
                final profile = snapshot.data;
                final globalAiEnabled = profile?.localAiEnabled == true;
                final aiBusy = _loadingAi || _savingAi || _deleting;
                final aiOptionsEnabled =
                    globalAiEnabled && _aiEnabled && !aiBusy;

                String aiSubtitle;

                if (snapshot.hasError) {
                  aiSubtitle = 'Nie udało się pobrać głównego ustawienia AI.';
                } else if (profile == null) {
                  aiSubtitle = 'Wczytywanie ustawień AI...';
                } else if (!globalAiEnabled) {
                  aiSubtitle =
                      'Najpierw włącz lokalną analizę AI '
                      'w ustawieniach konta.';
                } else if (_aiEnabled) {
                  aiSubtitle = 'AI jest włączone dla tej kamery.';
                } else {
                  aiSubtitle = 'AI jest wyłączone dla tej kamery.';
                }

                return Card(
                  child: Column(
                    children: [
                      SwitchListTile.adaptive(
                        secondary: const Icon(Icons.psychology_outlined),
                        title: const Text('AI dla tej kamery'),
                        subtitle: Text(aiSubtitle),
                        value: _aiEnabled,
                        onChanged: !globalAiEnabled || aiBusy
                            ? null
                            : (enabled) {
                                unawaited(_setAiSettings(enabled: enabled));
                              },
                      ),
                      const Divider(height: 1),
                      SwitchListTile.adaptive(
                        secondary: const Icon(Icons.person_search_outlined),
                        title: const Text('Wykrywanie osób'),
                        value: _aiPersonEnabled,
                        onChanged: aiOptionsEnabled
                            ? (enabled) {
                                unawaited(
                                  _setAiSettings(personEnabled: enabled),
                                );
                              }
                            : null,
                      ),
                      const Divider(height: 1),
                      SwitchListTile.adaptive(
                        secondary: const Icon(Icons.directions_car_outlined),
                        title: const Text('Wykrywanie pojazdów'),
                        value: _aiVehicleEnabled,
                        onChanged: aiOptionsEnabled
                            ? (enabled) {
                                unawaited(
                                  _setAiSettings(vehicleEnabled: enabled),
                                );
                              }
                            : null,
                      ),
                      const Divider(height: 1),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: DropdownButtonFormField<String>(
                          key: ValueKey(_aiSensitivity),
                          initialValue: _aiSensitivity,
                          decoration: const InputDecoration(
                            labelText: 'Czułość wykrywania',
                            prefixIcon: Icon(Icons.tune),
                            border: OutlineInputBorder(),
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'low',
                              child: Text('Niska'),
                            ),
                            DropdownMenuItem(
                              value: 'standard',
                              child: Text('Standardowa'),
                            ),
                            DropdownMenuItem(
                              value: 'high',
                              child: Text('Wysoka'),
                            ),
                          ],
                          onChanged: aiOptionsEnabled
                              ? (sensitivity) {
                                  if (sensitivity == null) {
                                    return;
                                  }

                                  unawaited(
                                    _setAiSettings(sensitivity: sensitivity),
                                  );
                                }
                              : null,
                        ),
                      ),
                      const Divider(height: 1),
                      SwitchListTile.adaptive(
                        secondary: const Icon(Icons.movie_outlined),
                        title: const Text('Nagrywaj zdarzenia'),
                        subtitle: const Text(
                          'Prywatny film: do 5 s przed wykryciem i 10 s po nim. '
                          'Nagrania zajmują miejsce w chmurze.',
                        ),
                        value: _aiRecordingEnabled,
                        onChanged: aiOptionsEnabled
                            ? (enabled) {
                                unawaited(
                                  _setAiSettings(recordingEnabled: enabled),
                                );
                              }
                            : null,
                      ),
                      const Divider(height: 1),
                      ListTile(
                        enabled: aiOptionsEnabled,
                        leading: const Icon(Icons.crop_free),
                        title: const Text('Strefy wykrywania'),
                        subtitle: Text(
                          _aiDetectionZones.isEmpty && _aiIgnoreZones.isEmpty
                              ? 'Cały obraz jest analizowany.'
                              : '${_aiDetectionZones.length} aktywne, '
                                    '${_aiIgnoreZones.length} ignorowane',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: aiOptionsEnabled ? _openAiZonesEditor : null,
                      ),
                      if (_loadingAi || _savingAi)
                        const LinearProgressIndicator(),
                    ],
                  ),
                );
              },
            ),
          ],
          if (!rtspOnly) ...[
            const SizedBox(height: 24),
            Text(
              local ? 'Pozostałe powiadomienia' : 'Powiadomienia',
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
                    title: Text(
                      local
                          ? 'Alerty o innych zdarzeniach'
                          : 'Powiadomienia z kamery',
                    ),
                    value: _notificationSettings.enabled,
                    onChanged: notificationsBusy
                        ? null
                        : (enabled) {
                            unawaited(
                              _setNotificationSettings(
                                _notificationSettings.copyWith(
                                  enabled: enabled,
                                ),
                              ),
                            );
                          },
                  ),
                  if (!local) ...[
                    const Divider(height: 1),
                    SwitchListTile.adaptive(
                      secondary: const Icon(Icons.sensors),
                      title: const Text('Alert o ruchu'),
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
                  ],
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
                  const Divider(height: 1),
                  _alertCooldown(enabled: canSetCooldown),
                  if (_loadingNotifications || _savingNotifications)
                    const LinearProgressIndicator(),
                ],
              ),
            ),
          ] else if (_motionPreference.sendsAlert)
            ExpansionTile(
              title: const Text('Opcje alertu'),
              children: [_alertCooldown(enabled: canSetCooldown)],
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

class _CameraDetailsEditResult {
  final String name;
  final String locationName;

  const _CameraDetailsEditResult({
    required this.name,
    required this.locationName,
  });
}
