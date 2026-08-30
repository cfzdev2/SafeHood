import 'dart:async';

import 'package:flutter/material.dart';

import '../../bridges/data/bridge_service.dart';
import '../../bridges/domain/bridge_status.dart';
import '../../bridges/presentation/bridge_management_screen.dart';
import '../../bridges/presentation/widgets/bridge_status_card.dart';
import '../data/camera_service.dart';
import '../domain/camera.dart';
import 'add_camera_screen.dart';
import 'camera_details_screen.dart';
import 'widgets/camera_card.dart';

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

  Timer? _statusRefreshTimer;

  @override
  void initState() {
    super.initState();

    _cameraService = CameraService();

    _bridgeService = BridgeService();

    _camerasStream = _cameraService.watchCameras();

    _bridgesStream = _bridgeService.watchBridges();

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
    final newCamera = await Navigator.of(
      context,
    ).push<Camera>(MaterialPageRoute(builder: (_) => const AddCameraScreen()));

    if (newCamera == null) {
      return;
    }

    await _cameraService.addCamera(newCamera);
  }

  void _openCamera(BuildContext context, Camera camera) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => CameraDetailsScreen(camera: camera)),
    );
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
              Expanded(child: _buildCameraList(bridges)),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'cameras_add_camera_fab',
        onPressed: () {
          _openAddCameraScreen(context);
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

    if (camera.monitoringMode != CameraMonitoringMode.bridge) {
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
