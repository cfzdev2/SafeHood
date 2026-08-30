class CommunityProfile {
  final String id;
  final String firstName;
  final bool notificationsEnabled;

  const CommunityProfile({
    required this.id,
    required this.firstName,
    required this.notificationsEnabled,
  });

  Map<String, dynamic> toMap() {
    return {
      'firstName': firstName,
      'notificationsEnabled': notificationsEnabled,
    };
  }

  factory CommunityProfile.fromMap(
    String id,
    Map<String, dynamic> map,
  ) {
    return CommunityProfile(
      id: id,
      firstName: map['firstName'] as String? ?? '',
      notificationsEnabled:
          map['notificationsEnabled'] as bool? ?? true,
    );
  }
}