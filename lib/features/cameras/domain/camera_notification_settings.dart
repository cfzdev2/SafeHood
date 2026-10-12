class CameraNotificationSettings {
  static const allowedCooldownSeconds = <int>{0, 30, 60, 300, 900};

  final bool enabled;
  final bool motionEnabled;
  final bool personEnabled;
  final bool vehicleEnabled;
  final bool soundEnabled;
  final int cooldownSeconds;

  const CameraNotificationSettings({
    this.enabled = true,
    this.motionEnabled = true,
    this.personEnabled = true,
    this.vehicleEnabled = true,
    this.soundEnabled = true,
    this.cooldownSeconds = 0,
  });

  CameraNotificationSettings copyWith({
    bool? enabled,
    bool? motionEnabled,
    bool? personEnabled,
    bool? vehicleEnabled,
    bool? soundEnabled,
    int? cooldownSeconds,
  }) {
    return CameraNotificationSettings(
      enabled: enabled ?? this.enabled,
      motionEnabled: motionEnabled ?? this.motionEnabled,
      personEnabled: personEnabled ?? this.personEnabled,
      vehicleEnabled: vehicleEnabled ?? this.vehicleEnabled,
      soundEnabled: soundEnabled ?? this.soundEnabled,
      cooldownSeconds: cooldownSeconds ?? this.cooldownSeconds,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'enabled': enabled,
      'motion': motionEnabled,
      'person': personEnabled,
      'vehicle': vehicleEnabled,
      'sound': soundEnabled,
      'cooldownSeconds': cooldownSeconds,
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

    int readCooldownSeconds() {
      final field = value['cooldownSeconds'];

      return field is int && allowedCooldownSeconds.contains(field) ? field : 0;
    }

    return CameraNotificationSettings(
      enabled: readBool('enabled'),
      motionEnabled: readBool('motion'),
      personEnabled: readBool('person'),
      vehicleEnabled: readBool('vehicle'),
      soundEnabled: readBool('sound'),
      cooldownSeconds: readCooldownSeconds(),
    );
  }
}
