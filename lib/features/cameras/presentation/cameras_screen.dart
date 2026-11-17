import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../bridges/data/bridge_service.dart';
import '../../bridges/domain/bridge_status.dart';
import '../../bridges/presentation/bridge_management_screen.dart';
import '../../bridges/presentation/widgets/bridge_status_card.dart';
import '../data/camera_service.dart';
import '../data/local_camera_registration.dart';
import '../data/local_camera_store.dart';
import '../domain/camera.dart';
import 'add_camera_screen.dart';
import 'camera_details_screen.dart';
import 'local_camera_setup_screen.dart';
import 'widgets/camera_card.dart';

typedef _LegacyCamera = ({LocalCameraStore store, SavedLocalCamera camera});

class CamerasScreen extends StatefulWidget {
  const CamerasScreen({super.key});

  @override
  State<CamerasScreen> createState() => _CamerasScreenState();
}

class _CamerasScreenState extends State<CamerasScreen> {
  late final CameraService _cameraService;

  late final BridgeService _bridgeService;

  late final Stream<List<Camera>> _camerasStream;

  late final Stream<List<BridgeStatus>> _bridgesStream;
  Future<List<_LegacyCamera>>? _legacyCameras;

  Timer? _statusRefreshTimer;

  @override
  void initState() {
    super.initState();

    _cameraService = CameraService();

    _bridgeService = BridgeService();

    _camerasStream = _cameraService.watchCameras();

    _bridgesStream = _bridgeService.watchBridges();

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null && supportsLocalCameraSetup) {
      _legacyCameras = _readLegacyCameras(uid);
    }

    // Wymusza ponowne sprawdzenie wieku
    // heartbeat również wtedy, gdy Bridge
    // przestał pisać do Firestore.
    _statusRefreshTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _statusRefreshTimer?.cancel();

    super.dispose();
  }

  void _openBridgeManagementScreen(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const BridgeManagementScreen()),
    );
  }

  Future<void> _openAddCameraScreen(BuildContext context) async {
    final newCamera = await Navigator.of(context).push<AddCameraSelection>(
      MaterialPageRoute(builder: (_) => const AddCameraScreen()),
    );

    if (newCamera == null) {
      return;
    }

    try {
      await _cameraService.addCamera(
        newCamera.camera,
        connection: newCamera.connection,
      );
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Nie udało się zapisać kamery. Spróbuj ponownie.'),
        ),
      );
    }
  }

  void _openCamera(BuildContext context, Camera camera) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => CameraDetailsScreen(camera: camera)),
    );
  }

  Future<List<_LegacyCamera>> _readLegacyCameras(String uid) async {
    final saved = <_LegacyCamera>[];
    for (final store in [
      LocalCameraStore(uid),
      const LocalCameraStore('guest'),
    ]) {
      try {
        for (final camera in await store.list()) {
          saved.add((store: store, camera: camera));
        }
      } catch (_) {
        debugPrint('Nie udało się odczytać starszych kamer z tego telefonu.');
      }
    }
    return saved;
  }

  Future<void> _pickLegacyCamera(
    BuildContext context,
    List<_LegacyCamera> cameras,
  ) async {
    final selected = await showModalBottomSheet<_LegacyCamera>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('Wybierz kamerę do przeniesienia'),
              subtitle: Text('Kamera zachowa zapisany podgląd.'),
            ),
            for (final saved in cameras)
              ListTile(
                leading: const Icon(Icons.videocam_outlined),
                title: Text(saved.camera.source.name),
                subtitle: Text(saved.camera.source.uri.host),
                onTap: () => Navigator.of(sheet).pop(saved),
              ),
          ],
        ),
      ),
    );
    if (context.mounted && selected != null) {
      await _openSetup(context, legacy: selected);
    }
  }

  Future<void> _openSetup(BuildContext context, {_LegacyCamera? legacy}) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null ||
        (legacy != null &&
            legacy.store.scope != uid &&
            legacy.store.scope != 'guest')) {
      return;
    }
    final result = await Navigator.of(context).push<LocalCameraSetupResult>(
      MaterialPageRoute<LocalCameraSetupResult>(
        builder: (_) => LocalCameraSetupScreen(
          savedSource: legacy?.camera.source,
          onSave: (LocalCameraRegistration setup) async {
            if (FirebaseAuth.instance.currentUser?.uid != uid) {
              throw StateError(
                'Konto SafeHood zmieniło się podczas dodawania.',
              );
            }
            await _cameraService.addCamera(
              setup.camera,
              connection: setup.connection,
              legacyId: legacy?.camera.id,
            );
          },
        ),
      ),
    );
    if (result != LocalCameraSetupResult.saved || !context.mounted) return;
    if (legacy != null) {
      try {
        await legacy.store.delete(legacy.camera.id);
      } catch (_) {
        // The account camera is already saved; a retry won't duplicate it.
        debugPrint('Nie udało się usunąć przeniesionego wpisu z telefonu.');
      }
      if (!mounted ||
          !context.mounted ||
          FirebaseAuth.instance.currentUser?.uid != uid) {
        return;
      }
      setState(() => _legacyCameras = _readLegacyCameras(uid));
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Kamera jest na liście Moje kamery.')),
    );
  }

  Future<void> _chooseHowToAdd(BuildContext context) async {
    if (!supportsLocalCameraSetup) {
      await _openAddCameraScreen(context);
      return;
    }
    final local = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.wifi_find),
              title: const Text('Skonfiguruj kamerę i sprawdź obraz'),
              subtitle: const Text('Bluetooth, hotspot kamery, ONVIF lub RTSP'),
              onTap: () => Navigator.of(sheet).pop(true),
            ),
            ListTile(
              leading: const Icon(Icons.hub_outlined),
              title: const Text('Inne sposoby dodawania kamery'),
              subtitle: const Text(
                'Integracja producenta lub ręczna konfiguracja',
              ),
              onTap: () => Navigator.of(sheet).pop(false),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted || local == null) return;
    if (!local) {
      await _openAddCameraScreen(context);
      return;
    }
    await _openSetup(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Moje kamery'),
        actions: [
          IconButton(
            tooltip: 'Zarządzaj Bridge',
            onPressed: () {
              _openBridgeManagementScreen(context);
            },
            icon: const Icon(Icons.hub_outlined),
          ),
        ],
      ),
      body: StreamBuilder<List<BridgeStatus>>(
        stream: _bridgesStream,
        builder: (context, bridgeSnapshot) {
          final bridges = bridgeSnapshot.data ?? [];

          final primaryBridge = bridges.isEmpty ? null : bridges.first;

          return Column(
            children: [
              BridgeStatusCard(
                bridge: primaryBridge,
                isLoading:
                    bridgeSnapshot.connectionState == ConnectionState.waiting,
                error: bridgeSnapshot.error,
              ),
              if (_legacyCameras != null)
                FutureBuilder<List<_LegacyCamera>>(
                  future: _legacyCameras,
                  builder: (context, snapshot) {
                    final cameras = snapshot.data;
                    if (cameras == null || cameras.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    return TextButton.icon(
                      onPressed: () => _pickLegacyCamera(context, cameras),
                      icon: const Icon(Icons.move_to_inbox_outlined),
                      label: const Text('Przenieś wcześniej zapisaną kamerę'),
                    );
                  },
                ),
              Expanded(child: _buildCameraList(bridges)),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'cameras_add_camera_fab',
        onPressed: () {
          _chooseHowToAdd(context);
        },
        icon: const Icon(Icons.add),
        label: const Text('Dodaj kamerę'),
      ),
    );
  }

  Widget _buildCameraList(List<BridgeStatus> bridges) {
    return StreamBuilder<List<Camera>>(
      stream: _camerasStream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return Center(
            child: Text(
              'Nie udało się wczytać kamer.\n'
              '${snapshot.error}',
              textAlign: TextAlign.center,
            ),
          );
        }

        final cameras = snapshot.data ?? [];

        if (cameras.isEmpty) {
          return const Center(
            child: Text(
              'Nie dodano jeszcze '
              'żadnych kamer.',
            ),
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
          itemCount: cameras.length,
          separatorBuilder: (_, _) {
            return const SizedBox(height: 12);
          },
          itemBuilder: (context, index) {
            final camera = cameras[index];

            return CameraCard(
              camera: camera,
              status: _cameraStatus(camera, bridges),
              onTap: () {
                _openCamera(context, camera);
              },
            );
          },
        );
      },
    );
  }

  CameraCardStatus _cameraStatus(Camera camera, List<BridgeStatus> bridges) {
    if (!camera.motionDetectionEnabled) {
      return CameraCardStatus.monitoringDisabled;
    }

    if (camera.monitoringMode == CameraMonitoringMode.cloud) {
      final cloudDeviceId = camera.cloudDeviceId;

      final isCloudCameraLinked =
          camera.cloudProvider != null &&
          cloudDeviceId != null &&
          cloudDeviceId.trim().isNotEmpty;

      return isCloudCameraLinked
          ? CameraCardStatus.monitoringActive
          : CameraCardStatus.monitoringUnavailable;
    }

    if (camera.monitoringMode == CameraMonitoringMode.app) {
      return camera.isOnline
          ? CameraCardStatus.monitoringActive
          : CameraCardStatus.monitoringUnavailable;
    }

    final bridgeId = camera.bridgeId;

    if (bridgeId == null) {
      return CameraCardStatus.bridgeOffline;
    }

    BridgeStatus? assignedBridge;

    for (final bridge in bridges) {
      if (bridge.id == bridgeId) {
        assignedBridge = bridge;
        break;
      }
    }

    if (assignedBridge == null || !assignedBridge.isOnlineAt(DateTime.now())) {
      return CameraCardStatus.bridgeOffline;
    }

    switch (camera.bridgeMonitoringStatus) {
      case CameraMonitoringRuntimeStatus.online:
        return CameraCardStatus.monitoringActive;

      case CameraMonitoringRuntimeStatus.connecting:
      case CameraMonitoringRuntimeStatus.reconnecting:
        return CameraCardStatus.monitoringConnecting;

      case CameraMonitoringRuntimeStatus.offline:
      case CameraMonitoringRuntimeStatus.unknown:
        return CameraCardStatus.monitoringUnavailable;
    }
  }
}
