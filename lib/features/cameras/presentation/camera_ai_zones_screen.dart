import 'package:flutter/material.dart';

import '../../camera_events/data/camera_event_service.dart';
import '../../camera_events/domain/camera_event.dart';
import '../../camera_events/presentation/widgets/camera_event_snapshot.dart';
import '../data/camera_service.dart';
import '../domain/camera.dart';
import '../domain/camera_ai_zone.dart';

class CameraAiZonesResult {
  final List<CameraAiZone> detectionZones;
  final List<CameraAiZone> ignoreZones;

  const CameraAiZonesResult({
    required this.detectionZones,
    required this.ignoreZones,
  });
}

class CameraAiZonesScreen extends StatefulWidget {
  final Camera camera;

  const CameraAiZonesScreen({super.key, required this.camera});

  @override
  State<CameraAiZonesScreen> createState() => _CameraAiZonesScreenState();
}

class _CameraAiZonesScreenState extends State<CameraAiZonesScreen> {
  final CameraService _cameraService = CameraService();
  final CameraEventService _eventService = CameraEventService();

  late final Stream<List<CameraEvent>> _eventsStream;
  late final List<CameraAiZone> _detectionZones;
  late final List<CameraAiZone> _ignoreZones;

  _ZoneType? _selectedType;
  int? _selectedIndex;
  bool _saving = false;
  bool _zoneGestureActive = false;

  @override
  void initState() {
    super.initState();
    _eventsStream = _eventService.watchCameraEvents(
      cameraId: widget.camera.id,
      limit: 20,
    );
    _detectionZones = List.of(widget.camera.aiDetectionZones);
    _ignoreZones = List.of(widget.camera.aiIgnoreZones);
  }

  List<CameraAiZone> _zonesFor(_ZoneType type) {
    return type == _ZoneType.detection ? _detectionZones : _ignoreZones;
  }

  void _addZone(_ZoneType type) {
    final zones = _zonesFor(type);

    if (zones.length >= CameraAiZone.maximumZonesPerType) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Możesz dodać maksymalnie 4 strefy.')),
      );
      return;
    }

    final offset = zones.length * 0.06;
    final zone = CameraAiZone(
      left: 0.1 + offset,
      top: 0.15 + offset,
      width: 0.48,
      height: 0.32,
    );

    setState(() {
      zones.add(zone);
      _selectedType = type;
      _selectedIndex = zones.length - 1;
    });
  }

  void _selectZone(_ZoneType type, int index) {
    setState(() {
      _selectedType = type;
      _selectedIndex = index;
    });
  }

  void _beginZoneGesture(_ZoneType type, int index) {
    setState(() {
      _selectedType = type;
      _selectedIndex = index;
      _zoneGestureActive = true;
    });
  }

  void _endZoneGesture() {
    if (!_zoneGestureActive) {
      return;
    }

    setState(() {
      _zoneGestureActive = false;
    });
  }

  void _moveZone(_ZoneType type, int index, Offset delta, double side) {
    if (side <= 0) {
      return;
    }

    final zones = _zonesFor(type);
    final zone = zones[index];
    final nextLeft = (zone.left + delta.dx / side)
        .clamp(0.0, 1.0 - zone.width)
        .toDouble();
    final nextTop = (zone.top + delta.dy / side)
        .clamp(0.0, 1.0 - zone.height)
        .toDouble();

    setState(() {
      zones[index] = zone.copyWith(left: nextLeft, top: nextTop);
      _selectedType = type;
      _selectedIndex = index;
    });
  }

  void _resizeZone(
    _ZoneType type,
    int index,
    _ZoneCorner corner,
    Offset delta,
    double side,
  ) {
    if (side <= 0) {
      return;
    }

    final zones = _zonesFor(type);
    final zone = zones[index];
    final horizontalDelta = delta.dx / side;
    final verticalDelta = delta.dy / side;
    var left = zone.left;
    var top = zone.top;
    var right = zone.right;
    var bottom = zone.bottom;

    switch (corner) {
      case _ZoneCorner.topLeft:
        left = (left + horizontalDelta)
            .clamp(0.0, right - CameraAiZone.minimumExtent)
            .toDouble();
        top = (top + verticalDelta)
            .clamp(0.0, bottom - CameraAiZone.minimumExtent)
            .toDouble();
        break;
      case _ZoneCorner.topRight:
        right = (right + horizontalDelta)
            .clamp(left + CameraAiZone.minimumExtent, 1.0)
            .toDouble();
        top = (top + verticalDelta)
            .clamp(0.0, bottom - CameraAiZone.minimumExtent)
            .toDouble();
        break;
      case _ZoneCorner.bottomLeft:
        left = (left + horizontalDelta)
            .clamp(0.0, right - CameraAiZone.minimumExtent)
            .toDouble();
        bottom = (bottom + verticalDelta)
            .clamp(top + CameraAiZone.minimumExtent, 1.0)
            .toDouble();
        break;
      case _ZoneCorner.bottomRight:
        right = (right + horizontalDelta)
            .clamp(left + CameraAiZone.minimumExtent, 1.0)
            .toDouble();
        bottom = (bottom + verticalDelta)
            .clamp(top + CameraAiZone.minimumExtent, 1.0)
            .toDouble();
        break;
    }

    setState(() {
      zones[index] = CameraAiZone(
        left: left,
        top: top,
        width: right - left,
        height: bottom - top,
      );
      _selectedType = type;
      _selectedIndex = index;
    });
  }

  void _applyPreset(_ZonePreset preset) {
    final type = _selectedType;
    final index = _selectedIndex;

    if (type == null || index == null) {
      return;
    }

    final zones = _zonesFor(type);

    if (index < 0 || index >= zones.length) {
      return;
    }

    final zone = switch (preset) {
      _ZonePreset.full => const CameraAiZone(
          left: 0,
          top: 0,
          width: 1,
          height: 1,
        ),
      _ZonePreset.top => const CameraAiZone(
          left: 0,
          top: 0,
          width: 1,
          height: 0.5,
        ),
      _ZonePreset.bottom => const CameraAiZone(
          left: 0,
          top: 0.5,
          width: 1,
          height: 0.5,
        ),
      _ZonePreset.left => const CameraAiZone(
          left: 0,
          top: 0,
          width: 0.5,
          height: 1,
        ),
      _ZonePreset.right => const CameraAiZone(
          left: 0.5,
          top: 0,
          width: 0.5,
          height: 1,
        ),
    };

    setState(() {
      zones[index] = zone;
    });
  }

  void _removeSelectedZone() {
    final type = _selectedType;
    final index = _selectedIndex;

    if (type == null || index == null) {
      return;
    }

    final zones = _zonesFor(type);

    if (index < 0 || index >= zones.length) {
      return;
    }

    setState(() {
      zones.removeAt(index);
      _selectedType = null;
      _selectedIndex = null;
    });
  }

  void _clearZones() {
    setState(() {
      _detectionZones.clear();
      _ignoreZones.clear();
      _selectedType = null;
      _selectedIndex = null;
    });
  }

  Future<void> _save() async {
    if (_saving) {
      return;
    }

    setState(() {
      _saving = true;
    });

    try {
      await _cameraService.setAiZones(
        cameraId: widget.camera.id,
        detectionZones: _detectionZones,
        ignoreZones: _ignoreZones,
      );

      if (!mounted) {
        return;
      }

      Navigator.of(context).pop(
        CameraAiZonesResult(
          detectionZones: List.unmodifiable(_detectionZones),
          ignoreZones: List.unmodifiable(_ignoreZones),
        ),
      );
    } catch (_) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Nie udało się zapisać stref. Spróbuj ponownie.'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  CameraEvent? _latestSnapshot(List<CameraEvent>? events) {
    if (events == null) {
      return null;
    }

    for (final event in events) {
      if (event.hasSnapshot) {
        return event;
      }
    }

    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Strefy wykrywania AI'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Zapisz'),
          ),
        ],
      ),
      body: ListView(
        physics: _zoneGestureActive
            ? const NeverScrollableScrollPhysics()
            : null,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Text(
            'Ustaw obszary na ostatnim zdjęciu z kamery',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Zielone strefy dopuszczają wykrycia. Czerwone obszary są zawsze '
            'ignorowane. Bez zielonej strefy analizowany jest cały obraz.',
          ),
          const SizedBox(height: 16),
          StreamBuilder<List<CameraEvent>>(
            stream: _eventsStream,
            builder: (context, snapshot) {
              return _buildCanvas(_latestSnapshot(snapshot.data));
            },
          ),
          const SizedBox(height: 12),
          Text(
            'Przeciągnij wnętrze strefy, aby ją przesunąć. Cztery narożne '
            'uchwyty zmieniają jej położenie i rozmiar.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (_selectedType != null) ...[
            const SizedBox(height: 12),
            Text(
              'Szybkie dopasowanie wybranej strefy',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ActionChip(
                  label: const Text('Cały obraz'),
                  onPressed: () => _applyPreset(_ZonePreset.full),
                ),
                ActionChip(
                  label: const Text('Góra'),
                  onPressed: () => _applyPreset(_ZonePreset.top),
                ),
                ActionChip(
                  label: const Text('Dół'),
                  onPressed: () => _applyPreset(_ZonePreset.bottom),
                ),
                ActionChip(
                  label: const Text('Lewo'),
                  onPressed: () => _applyPreset(_ZonePreset.left),
                ),
                ActionChip(
                  label: const Text('Prawo'),
                  onPressed: () => _applyPreset(_ZonePreset.right),
                ),
              ],
            ),
          ],
          const SizedBox(height: 20),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _detectionZones.length <
                        CameraAiZone.maximumZonesPerType
                    ? () => _addZone(_ZoneType.detection)
                    : null,
                icon: const Icon(Icons.add),
                label: Text('Strefa aktywna (${_detectionZones.length}/4)'),
              ),
              FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                ),
                onPressed:
                    _ignoreZones.length < CameraAiZone.maximumZonesPerType
                    ? () => _addZone(_ZoneType.ignore)
                    : null,
                icon: const Icon(Icons.block),
                label: Text('Ignoruj (${_ignoreZones.length}/4)'),
              ),
              OutlinedButton.icon(
                onPressed: _selectedType == null ? null : _removeSelectedZone,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Usuń wybraną'),
              ),
              TextButton.icon(
                onPressed: _detectionZones.isEmpty && _ignoreZones.isEmpty
                    ? null
                    : _clearZones,
                icon: const Icon(Icons.restart_alt),
                label: const Text('Wyczyść'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'SafeHood sprawdza dolny środek ramki osoby lub pojazdu. '
                      'Strefy wpływają na zdarzenia, zdjęcia, nagrania i alerty.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCanvas(CameraEvent? event) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = constraints.maxWidth;

        return SizedBox.square(
          dimension: side,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFF727272),
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(12),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(11),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (event != null)
                    CameraEventSnapshot(
                      event: event,
                      fit: BoxFit.contain,
                      alignment: Alignment.topLeft,
                    )
                  else
                    const _EmptyZoneBackground(),
                  ..._buildZoneWidgets(_ZoneType.detection, side),
                  ..._buildZoneWidgets(_ZoneType.ignore, side),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Iterable<Widget> _buildZoneWidgets(_ZoneType type, double side) sync* {
    final zones = _zonesFor(type);
    final color = type == _ZoneType.detection
        ? const Color(0xFF3DDC84)
        : const Color(0xFFFF5252);

    for (var index = 0; index < zones.length; index += 1) {
      final zone = zones[index];
      final selected = _selectedType == type && _selectedIndex == index;

      yield Positioned(
        left: zone.left * side,
        top: zone.top * side,
        width: zone.width * side,
        height: zone.height * side,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (_) => _beginZoneGesture(type, index),
                onPointerUp: (_) => _endZoneGesture(),
                onPointerCancel: (_) => _endZoneGesture(),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _selectZone(type, index),
                  onPanUpdate: (details) {
                    _moveZone(type, index, details.delta, side);
                  },
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: selected ? 0.24 : 0.14),
                      border: Border.all(
                        color: color,
                        width: selected ? 3 : 2,
                      ),
                    ),
                    child: Stack(
                      children: [
                        Positioned(
                          left: 6,
                          top: 4,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: color,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 2,
                              ),
                              child: Text(
                                type == _ZoneType.detection
                                    ? 'AKTYWNA'
                                    : 'IGNORUJ',
                                style: const TextStyle(
                                  color: Colors.black,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (selected)
              _buildResizeHandle(
                type: type,
                index: index,
                corner: _ZoneCorner.topLeft,
                side: side,
                color: color,
              ),
            if (selected)
              _buildResizeHandle(
                type: type,
                index: index,
                corner: _ZoneCorner.topRight,
                side: side,
                color: color,
              ),
            if (selected)
              _buildResizeHandle(
                type: type,
                index: index,
                corner: _ZoneCorner.bottomLeft,
                side: side,
                color: color,
              ),
            if (selected)
              _buildResizeHandle(
                type: type,
                index: index,
                corner: _ZoneCorner.bottomRight,
                side: side,
                color: color,
              ),
          ],
        ),
      );
    }
  }

  Widget _buildResizeHandle({
    required _ZoneType type,
    required int index,
    required _ZoneCorner corner,
    required double side,
    required Color color,
  }) {
    final onLeft = corner == _ZoneCorner.topLeft ||
        corner == _ZoneCorner.bottomLeft;
    final onTop = corner == _ZoneCorner.topLeft ||
        corner == _ZoneCorner.topRight;
    final alignment = Alignment(
      onLeft ? -1.0 : 1.0,
      onTop ? -1.0 : 1.0,
    );

    return Positioned(
      left: onLeft ? 0 : null,
      right: onLeft ? null : 0,
      top: onTop ? 0 : null,
      bottom: onTop ? null : 0,
      width: 52,
      height: 52,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => _beginZoneGesture(type, index),
        onPointerUp: (_) => _endZoneGesture(),
        onPointerCancel: (_) => _endZoneGesture(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (details) {
            _resizeZone(type, index, corner, details.delta, side);
          },
          child: Align(
            alignment: alignment,
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.black87, width: 2),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black38,
                    blurRadius: 4,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: const Icon(
                Icons.open_in_full,
                size: 21,
                color: Colors.black,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _ZoneType { detection, ignore }

enum _ZoneCorner { topLeft, topRight, bottomLeft, bottomRight }

enum _ZonePreset { full, top, bottom, left, right }

class _EmptyZoneBackground extends StatelessWidget {
  const _EmptyZoneBackground();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _ZoneGridPainter(),
      child: const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Brak zdjęcia podglądowego.\nStrefy nadal możesz ustawić.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white),
          ),
        ),
      ),
    );
  }
}

class _ZoneGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1;

    for (var index = 1; index < 4; index += 1) {
      final offset = size.width * index / 4;
      canvas.drawLine(Offset(offset, 0), Offset(offset, size.height), paint);
      canvas.drawLine(Offset(0, offset), Offset(size.width, offset), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
