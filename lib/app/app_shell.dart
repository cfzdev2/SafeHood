import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../core/services/push_notification_service.dart';
import '../core/state/app_state.dart';
import '../features/cameras/data/camera_service.dart';
import '../features/cameras/domain/camera.dart';
import '../features/cameras/presentation/cameras_screen.dart';
import '../features/camera_events/data/camera_monitoring_service.dart';
import '../features/community/presentation/community_screen.dart';
import '../features/incidents/data/incident_service.dart';
import '../features/incidents/domain/incident.dart';
import '../features/incidents/presentation/incident_chat_screen.dart';
import '../features/incidents/presentation/incident_details_screen.dart';
import '../features/incidents/presentation/incidents_screen.dart';
import '../features/profile/domain/app_user.dart';
import '../features/profile/presentation/profile_screen.dart';
import '../features/camera_events/presentation/camera_event_details_screen.dart';

class AppShell extends StatefulWidget {
  final AppUser currentUser;

  const AppShell({super.key, required this.currentUser});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int selectedIndex = 0;

  late final AppState appState;

  final PushNotificationService _pushNotificationService =
      PushNotificationService.instance;

  final IncidentService _incidentService = IncidentService();

  final CameraService _cameraService = CameraService();

  final CameraMonitoringService _cameraMonitoringService =
      CameraMonitoringService();

  late final Stream<List<Incident>> _incidentsStream;

  StreamSubscription<List<Camera>>? _camerasSubscription;

  Timer? _incidentStatusTimer;

  bool _openingPushTarget = false;

  Future<void> _syncCameraMonitoring(List<Camera> cameras) async {
    final onvifCameras = cameras
        .where(
          (camera) =>
              camera.connectionType == CameraConnectionType.onvif &&
              camera.monitoringMode == CameraMonitoringMode.app,
        )
        .toList();

    final desiredCameraIds = onvifCameras.map((camera) => camera.id).toSet();

    final activeCameraIds = _cameraMonitoringService.activeCameraIds;

    final cameraIdsToStop = activeCameraIds.difference(desiredCameraIds);

    for (final cameraId in cameraIdsToStop) {
      await _cameraMonitoringService.stopCamera(cameraId);
    }

    if (onvifCameras.isEmpty) {
      debugPrint(
        'CAMERA MONITORING: '
        'brak kamer ONVIF do monitorowania '
        'w aplikacji',
      );

      return;
    }

    for (final camera in onvifCameras) {
      try {
        await _cameraMonitoringService.start(camera);
      } catch (error, stackTrace) {
        debugPrint(
          'CAMERA MONITORING APP ERROR '
          '[${camera.id}]: '
          '$error',
        );

        debugPrint(
          'CAMERA MONITORING APP STACKTRACE '
          '[${camera.id}]: '
          '$stackTrace',
        );
      }
    }
  }

  @override
  void initState() {
    super.initState();

    appState = AppState(currentUser: widget.currentUser);

    _incidentsStream = _incidentService.watchIncidents();

    _camerasSubscription = _cameraService.watchCameras().listen(
      (cameras) {
        unawaited(_syncCameraMonitoring(cameras));
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint(
          'CAMERA MONITORING CAMERAS ERROR: '
          '$error',
        );

        debugPrint('$stackTrace');
      },
    );

    // Odświeżamy status również wtedy,

    // Odświeżamy status również wtedy,
    // gdy zgłoszenie wygaśnie tylko przez czas,
    // bez żadnej zmiany dokumentu w Firestore.
    _incidentStatusTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) {
        setState(() {});
      }
    });

    _pushNotificationService.pendingNavigation.addListener(
      _handlePendingNavigation,
    );

    _pushNotificationService.pendingCameraEventNavigation.addListener(
      _handlePendingCameraEventNavigation,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handlePendingNavigation();
      _handlePendingCameraEventNavigation();
    });
  }

  @override
  void dispose() {
    _incidentStatusTimer?.cancel();

    unawaited(_camerasSubscription?.cancel());

    unawaited(_cameraMonitoringService.dispose());

    _pushNotificationService.pendingNavigation.removeListener(
      _handlePendingNavigation,
    );

    _pushNotificationService.pendingCameraEventNavigation.removeListener(
      _handlePendingCameraEventNavigation,
    );

    appState.dispose();

    super.dispose();
  }

  bool _hasActiveIncident(List<Incident> incidents) {
    final now = DateTime.now();

    return incidents.any((incident) {
      final expiresAt = incident.expiresAt;

      return incident.status == IncidentStatus.active &&
          expiresAt != null &&
          expiresAt.isAfter(now);
    });
  }

  void _handlePendingNavigation() {
    final target = _pushNotificationService.pendingNavigation.value;

    if (target == null) {
      return;
    }

    if (_openingPushTarget) {
      return;
    }

    _openPushTarget(target);
  }

  void _handlePendingCameraEventNavigation() {
    final target = _pushNotificationService.pendingCameraEventNavigation.value;

    if (target == null) {
      return;
    }

    if (_openingPushTarget) {
      return;
    }

    _openCameraEventPushTarget(target);
  }

  Future<void> _openPushTarget(PushNavigationTarget target) async {
    if (_openingPushTarget || !mounted) {
      return;
    }

    _openingPushTarget = true;

    debugPrint(
      'PUSH NAV: otwieram incident '
      '${target.incidentId}, '
      'chat=${target.openChat}',
    );

    try {
      if (selectedIndex != 1) {
        setState(() {
          selectedIndex = 1;
        });

        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      final snapshot = await FirebaseFirestore.instance
          .collection('incidents')
          .doc(target.incidentId)
          .get();

      if (!mounted) {
        return;
      }

      if (!snapshot.exists) {
        _pushNotificationService.clearPendingNavigation(target.incidentId);

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Nie znaleziono tego '
              'zgłoszenia.',
            ),
          ),
        );

        return;
      }

      final data = snapshot.data();

      if (data == null) {
        _pushNotificationService.clearPendingNavigation(target.incidentId);

        return;
      }

      final incident = Incident.fromMap(snapshot.id, data);

      _pushNotificationService.clearPendingNavigation(target.incidentId);

      if (!mounted) {
        return;
      }

      if (target.openChat) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => IncidentChatScreen(incident: incident),
          ),
        );

        return;
      }

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => IncidentDetailsScreen(incident: incident),
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('PUSH NAV ERROR: $error');

      debugPrint(
        'PUSH NAV STACKTRACE: '
        '$stackTrace',
      );

      _pushNotificationService.clearPendingNavigation(target.incidentId);

      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Nie udało się otworzyć '
            'zgłoszenia: $error',
          ),
        ),
      );
    } finally {
      _openingPushTarget = false;

      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _handlePendingNavigation();
          _handlePendingCameraEventNavigation();
        });
      }
    }
  }

  Future<void> _openCameraEventPushTarget(
    CameraEventPushNavigationTarget target,
  ) async {
    if (_openingPushTarget || !mounted) {
      return;
    }

    _openingPushTarget = true;

    debugPrint(
      'PUSH NAV CAMERA EVENT: '
      'otwieram ${target.eventId}, '
      'camera=${target.cameraId}',
    );

    try {
      // Event kamery należy do zakładki Kamery.
      if (selectedIndex != 0) {
        setState(() {
          selectedIndex = 0;
        });

        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      if (!mounted) {
        return;
      }

      // Czyścimy target zanim otworzymy ekran,
      // żeby ten sam push nie został otwarty ponownie.
      _pushNotificationService.clearPendingCameraEventNavigation(
        target.eventId,
      );

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => CameraEventDetailsScreen(eventId: target.eventId),
        ),
      );
    } catch (error, stackTrace) {
      debugPrint(
        'PUSH NAV CAMERA EVENT ERROR: '
        '$error',
      );

      debugPrint(
        'PUSH NAV CAMERA EVENT STACKTRACE: '
        '$stackTrace',
      );

      _pushNotificationService.clearPendingCameraEventNavigation(
        target.eventId,
      );

      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Nie udało się otworzyć '
            'wykrycia: $error',
          ),
        ),
      );
    } finally {
      _openingPushTarget = false;

      // Gdyby w czasie otwierania przyszła
      // kolejna nawigacja, sprawdzamy ją ponownie.
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _handlePendingNavigation();
          _handlePendingCameraEventNavigation();
        });
      }
    }
  }

  Widget _buildIncidentsIcon({
    required bool selected,
    required bool hasActiveIncident,
  }) {
    return SizedBox(
      width: 24,
      height: 24,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Center(
            child: Icon(
              selected ? Icons.warning_amber : Icons.warning_amber_outlined,
            ),
          ),
          if (hasActiveIncident)
            Positioned(
              top: -8,
              right: -20,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.deepOrange,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'TRWA',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 8,
                    fontWeight: FontWeight.w700,
                    height: 1,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedBuilder(
        animation: appState,
        builder: (context, _) {
          final pages = [
            CamerasScreen(),
            IncidentsScreen(appState: appState),
            CommunityScreen(appState: appState),
            ProfileScreen(appState: appState),
          ];

          return IndexedStack(index: selectedIndex, children: pages);
        },
      ),
      bottomNavigationBar: StreamBuilder<List<Incident>>(
        stream: _incidentsStream,
        builder: (context, snapshot) {
          final incidents = snapshot.data ?? const <Incident>[];

          final hasActiveIncident = _hasActiveIncident(incidents);

          return NavigationBar(
            height: 80,
            selectedIndex: selectedIndex,
            onDestinationSelected: (index) {
              setState(() {
                selectedIndex = index;
              });
            },
            destinations: [
              const NavigationDestination(
                icon: Icon(Icons.videocam_outlined),
                selectedIcon: Icon(Icons.videocam),
                label: 'Kamery',
              ),
              NavigationDestination(
                icon: _buildIncidentsIcon(
                  selected: false,
                  hasActiveIncident: hasActiveIncident,
                ),
                selectedIcon: _buildIncidentsIcon(
                  selected: true,
                  hasActiveIncident: hasActiveIncident,
                ),
                label: 'Zgłoszenia',
              ),
              const NavigationDestination(
                icon: Icon(Icons.groups_outlined),
                selectedIcon: Icon(Icons.groups),
                label: 'Społeczność',
              ),
              const NavigationDestination(
                icon: Icon(Icons.person_outline),
                selectedIcon: Icon(Icons.person),
                label: 'Profil',
              ),
            ],
          );
        },
      ),
    );
  }
}
