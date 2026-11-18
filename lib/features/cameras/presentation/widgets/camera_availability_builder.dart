import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../data/local_camera_availability.dart';
import '../../domain/camera.dart';

/// Refreshes a visible camera's availability without opening LIVE or writing
/// this phone's network state back to the account.
class CameraAvailabilityBuilder extends StatefulWidget {
  const CameraAvailabilityBuilder({
    super.key,
    required this.camera,
    required this.enabled,
    required this.builder,
    this.check = checkLocalCameraAvailability,
  });

  final Camera camera;
  final bool enabled;
  final Widget Function(BuildContext, CameraAvailability) builder;
  final Future<CameraAvailability> Function(Camera) check;

  @override
  State<CameraAvailabilityBuilder> createState() =>
      _CameraAvailabilityBuilderState();
}

class _CameraAvailabilityBuilderState extends State<CameraAvailabilityBuilder> {
  CameraAvailability _availability = CameraAvailability.unknown;
  Timer? _nextCheck;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _restart();
  }

  @override
  void didUpdateWidget(CameraAvailabilityBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.camera;
    final camera = widget.camera;
    if (oldWidget.enabled != widget.enabled ||
        previous.id != camera.id ||
        previous.connectionType != camera.connectionType ||
        previous.ipAddress != camera.ipAddress ||
        previous.onvifServiceUrl != camera.onvifServiceUrl ||
        !setEquals(previous.openPorts, camera.openPorts)) {
      _restart();
    }
  }

  void _restart() {
    final generation = ++_generation;
    _nextCheck?.cancel();
    _availability = CameraAvailability.unknown;
    if (widget.enabled && widget.camera.usesLocalConnection) {
      _availability = CameraAvailability.checking;
      unawaited(_check(generation));
    }
  }

  Future<void> _check(int generation) async {
    CameraAvailability result;
    try {
      result = await widget
          .check(widget.camera)
          .timeout(const Duration(seconds: 6));
    } on Exception {
      result = CameraAvailability.unknown;
    }
    if (!mounted || generation != _generation) return;
    if (result != _availability) {
      setState(() {
        _availability = result;
      });
    }
    _nextCheck = Timer(const Duration(seconds: 10), () {
      unawaited(_check(generation));
    });
  }

  @override
  void dispose() {
    _nextCheck?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final availability = widget.camera.usesLocalConnection
        ? _availability
        : widget.camera.isOnline
        ? CameraAvailability.online
        : CameraAvailability.offline;
    return widget.builder(context, availability);
  }
}
