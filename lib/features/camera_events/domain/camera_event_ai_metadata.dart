import 'package:cloud_firestore/cloud_firestore.dart';

class CameraEventAiMetadata {
  static const Set<String> supportedClasses = {
    'person',
    'bicycle',
    'car',
    'motorcycle',
    'bus',
    'truck',
  };
  static const Set<String> supportedModelIds = {
    'yolox-nano-coco-c789161e',
  };

  final int schemaVersion;
  final int totalObjects;
  final int personCount;
  final int vehicleCount;
  final Map<String, int> classCounts;
  final double? maximumConfidence;
  final DateTime firstSeenAt;
  final DateTime lastSeenAt;
  final int detectionFrameCount;
  final List<String> modelIds;

  CameraEventAiMetadata({
    required this.schemaVersion,
    required this.totalObjects,
    required this.personCount,
    required this.vehicleCount,
    required Map<String, int> classCounts,
    required this.maximumConfidence,
    required this.firstSeenAt,
    required this.lastSeenAt,
    required this.detectionFrameCount,
    required List<String> modelIds,
  }) : classCounts = Map.unmodifiable(classCounts),
       modelIds = List.unmodifiable(modelIds);

  Duration get activityDuration => lastSeenAt.difference(firstSeenAt);

  int? get confidencePercent => maximumConfidence == null
      ? null
      : (maximumConfidence! * 100).round().clamp(0, 100).toInt();

  Map<String, dynamic> toMap() {
    return {
      'schemaVersion': schemaVersion,
      'totalObjects': totalObjects,
      'personCount': personCount,
      'vehicleCount': vehicleCount,
      'classCounts': classCounts,
      'maximumConfidence': maximumConfidence,
      'firstSeenAt': Timestamp.fromDate(firstSeenAt),
      'lastSeenAt': Timestamp.fromDate(lastSeenAt),
      'detectionFrameCount': detectionFrameCount,
      'modelIds': modelIds,
    };
  }

  static CameraEventAiMetadata? tryParse(dynamic value) {
    if (value is! Map) {
      return null;
    }

    final schemaVersion = _readInt(value['schemaVersion']);
    final totalObjects = _readInt(value['totalObjects']);
    final personCount = _readInt(value['personCount']);
    final vehicleCount = _readInt(value['vehicleCount']);
    final detectionFrameCount = _readInt(value['detectionFrameCount']);
    final firstSeenAt = _readDateTime(value['firstSeenAt']);
    final lastSeenAt = _readDateTime(value['lastSeenAt']);
    final confidenceValue = value['maximumConfidence'];
    final maximumConfidence = confidenceValue == null
        ? null
        : _readDouble(confidenceValue);

    if (schemaVersion != 1 ||
        totalObjects == null ||
        totalObjects < 1 ||
        totalObjects > 10000 ||
        personCount == null ||
        personCount < 0 ||
        vehicleCount == null ||
        vehicleCount < 0 ||
        personCount + vehicleCount != totalObjects ||
        detectionFrameCount == null ||
        detectionFrameCount < totalObjects ||
        detectionFrameCount > 1000000 ||
        firstSeenAt == null ||
        lastSeenAt == null ||
        lastSeenAt.isBefore(firstSeenAt) ||
        (confidenceValue != null &&
            (maximumConfidence == null ||
                maximumConfidence < 0 ||
                maximumConfidence > 1))) {
      return null;
    }

    final rawClassCounts = value['classCounts'];
    if (rawClassCounts is! Map) {
      return null;
    }
    final classCounts = <String, int>{};
    for (final entry in rawClassCounts.entries) {
      final name = entry.key;
      final count = _readInt(entry.value);
      if (name is! String ||
          !supportedClasses.contains(name) ||
          count == null ||
          count < 1 ||
          count > totalObjects) {
        return null;
      }
      classCounts[name] = count;
    }
    final classTotal = classCounts.values.fold<int>(
      0,
      (accumulatedTotal, classCount) => accumulatedTotal + classCount,
    );
    if (classTotal != totalObjects ||
        (classCounts['person'] ?? 0) != personCount) {
      return null;
    }

    final rawModelIds = value['modelIds'];
    if (rawModelIds is! List ||
        rawModelIds.isEmpty ||
        rawModelIds.length > 4) {
      return null;
    }
    final modelIds = <String>[];
    for (final modelId in rawModelIds) {
      if (modelId is! String || !supportedModelIds.contains(modelId)) {
        return null;
      }
      if (!modelIds.contains(modelId)) {
        modelIds.add(modelId);
      }
    }

    return CameraEventAiMetadata(
      schemaVersion: 1,
      totalObjects: totalObjects,
      personCount: personCount,
      vehicleCount: vehicleCount,
      classCounts: classCounts,
      maximumConfidence: maximumConfidence,
      firstSeenAt: firstSeenAt,
      lastSeenAt: lastSeenAt,
      detectionFrameCount: detectionFrameCount,
      modelIds: modelIds,
    );
  }
}

int? _readInt(dynamic value) {
  if (value is! num || !value.isFinite || value != value.roundToDouble()) {
    return null;
  }
  return value.toInt();
}

double? _readDouble(dynamic value) {
  if (value is! num || !value.isFinite) {
    return null;
  }
  return value.toDouble();
}

DateTime? _readDateTime(dynamic value) {
  if (value is Timestamp) {
    return value.toDate();
  }
  if (value is DateTime) {
    return value;
  }
  if (value is String) {
    return DateTime.tryParse(value);
  }
  return null;
}
