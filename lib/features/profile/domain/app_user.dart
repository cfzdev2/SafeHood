class AppUser {
  final String id;
  final String firstName;
  final String phoneNumber;
  final String address;
  final double? latitude;
  final double? longitude;
  final bool notificationsEnabled;
  final bool localAiEnabled;

  const AppUser({
    required this.id,
    required this.firstName,
    required this.phoneNumber,
    required this.address,
    this.latitude,
    this.longitude,
    this.notificationsEnabled = true,
    this.localAiEnabled = false,
  });

  Map<String, dynamic> toMap() {
    return {
      'firstName': firstName,
      'phoneNumber': phoneNumber,
      'address': address,
      'latitude': latitude,
      'longitude': longitude,
      'notificationsEnabled': notificationsEnabled,
      'localAiEnabled': localAiEnabled,
    };
  }

  factory AppUser.fromMap(String id, Map<String, dynamic> map) {
    return AppUser(
      id: id,
      firstName: map['firstName'] as String? ?? '',
      phoneNumber: map['phoneNumber'] as String? ?? '',
      address: map['address'] as String? ?? '',
      latitude: (map['latitude'] as num?)?.toDouble(),
      longitude: (map['longitude'] as num?)?.toDouble(),
      notificationsEnabled: map['notificationsEnabled'] as bool? ?? true,
      localAiEnabled: map['localAiEnabled'] == true,
    );
  }
}
