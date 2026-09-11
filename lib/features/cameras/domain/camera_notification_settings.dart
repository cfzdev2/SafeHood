class CameraNotificationSettings {
  final bool enabled;
  final bool motionEnabled;
  final bool personEnabled;
  final bool vehicleEnabled;
  final bool soundEnabled;

  const CameraNotificationSettings({
    this.enabled = true,
    this.motionEnabled = true,
    this.personEnabled = true,
    this.vehicleEnabled = true,
    this.soundEnabled = true,
  });

  CameraNotificationSettings copyWith({
    bool? enabled,
    bool? motionEnabled,
    bool? personEnabled,
    bool? vehicleEnabled,
    bool? soundEnabled,
  }) {
    return CameraNotificationSettings(
      enabled: enabled ?? this.enabled,
      motionEnabled: motionEnabled ?? this.motionEnabled,
      personEnabled: personEnabled ?? this.personEnabled,
      vehicleEnabled: vehicleEnabled ?? this.vehicleEnabled,
      soundEnabled: soundEnabled ?? this.soundEnabled,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'enabled': enabled,
      'motion': motionEnabled,
      'person': personEnabled,
      'vehicle': vehicleEnabled,
      'sound': soundEnabled,
    };
  }

  factory CameraNotificationSettings.fromMap(dynamic value) {
    if (value is! Map) {
      return const CameraNotificationSettings();
    }

    bool readBool(String key) {
      final field = value[key];

      return field is bool ? field : true;
    }

    return CameraNotificationSettings(
      enabled: readBool('enabled'),
      motionEnabled: readBool('motion'),
      personEnabled: readBool('person'),
      vehicleEnabled: readBool('vehicle'),
      soundEnabled: readBool('sound'),
    );
  }
}
