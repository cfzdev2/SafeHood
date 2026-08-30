enum CommunityMemberSource {
  nearby,
  manual,
}

class CommunityMember {
  final String id;
  final String firstName;
  final CommunityMemberSource source;

  // Dla osób z okolicy.
  final double? distanceMeters;

  // Przyda się później do ręcznie dodanych kontaktów
  // i ewentualnego kontaktu podczas aktywnego zgłoszenia.
  final String? phoneNumber;

  final bool notificationsEnabled;

  const CommunityMember({
    required this.id,
    required this.firstName,
    required this.source,
    this.distanceMeters,
    this.phoneNumber,
    this.notificationsEnabled = true,
  });
}