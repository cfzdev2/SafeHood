class CameraAiZone {
  static const int maximumZonesPerType = 4;
  static const double minimumExtent = 0.02;

  final double left;
  final double top;
  final double width;
  final double height;

  const CameraAiZone({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  double get right => left + width;

  double get bottom => top + height;

  bool get isValid {
    return left.isFinite &&
        top.isFinite &&
        width.isFinite &&
        height.isFinite &&
        left >= 0 &&
        top >= 0 &&
        width >= minimumExtent &&
        height >= minimumExtent &&
        right <= 1 &&
        bottom <= 1;
  }

  CameraAiZone copyWith({
    double? left,
    double? top,
    double? width,
    double? height,
  }) {
    return CameraAiZone(
      left: left ?? this.left,
      top: top ?? this.top,
      width: width ?? this.width,
      height: height ?? this.height,
    );
  }

  Map<String, double> toMap() {
    return {
      'left': _round(left),
      'top': _round(top),
      'width': _round(width),
      'height': _round(height),
    };
  }

  static CameraAiZone? tryParse(dynamic value) {
    if (value is! Map) {
      return null;
    }

    final left = _readDouble(value['left']);
    final top = _readDouble(value['top']);
    final width = _readDouble(value['width']);
    final height = _readDouble(value['height']);

    if (left == null || top == null || width == null || height == null) {
      return null;
    }

    final zone = CameraAiZone(
      left: left,
      top: top,
      width: width,
      height: height,
    );

    return zone.isValid ? zone : null;
  }

  static List<CameraAiZone> parseList(dynamic value) {
    if (value is! List || value.length > maximumZonesPerType) {
      return const [];
    }

    final zones = <CameraAiZone>[];

    for (final item in value) {
      final zone = tryParse(item);

      if (zone == null) {
        return const [];
      }

      zones.add(zone);
    }

    return List.unmodifiable(zones);
  }

  static double? _readDouble(dynamic value) {
    if (value is! num) {
      return null;
    }

    final result = value.toDouble();
    return result.isFinite ? result : null;
  }

  static double _round(double value) {
    return (value * 1000000).roundToDouble() / 1000000;
  }

  @override
  bool operator ==(Object other) {
    return other is CameraAiZone &&
        other.left == left &&
        other.top == top &&
        other.width == width &&
        other.height == height;
  }

  @override
  int get hashCode => Object.hash(left, top, width, height);
}
