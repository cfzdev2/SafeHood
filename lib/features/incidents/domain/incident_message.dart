import 'package:cloud_firestore/cloud_firestore.dart';

class IncidentMessage {
  final String id;
  final String userId;
  final String firstName;
  final String text;
  final DateTime createdAt;

  const IncidentMessage({
    required this.id,
    required this.userId,
    required this.firstName,
    required this.text,
    required this.createdAt,
  });

  factory IncidentMessage.fromMap(
    String id,
    Map<String, dynamic> map,
  ) {
    return IncidentMessage(
      id: id,
      userId: map['userId'] as String? ?? '',
      firstName:
          map['firstName'] as String? ??
              'Użytkownik',
      text: map['text'] as String? ?? '',
      createdAt: _dateFromValue(
        map['createdAt'],
      ),
    );
  }

  static DateTime _dateFromValue(
    dynamic value,
  ) {
    if (value is Timestamp) {
      return value.toDate();
    }

    if (value is DateTime) {
      return value;
    }

    return DateTime.now();
  }
}