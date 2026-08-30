import 'package:flutter/material.dart';

import '../../features/community/domain/community_member.dart';
import '../../features/incidents/domain/incident.dart';
import '../../features/profile/domain/app_user.dart';

class AppState extends ChangeNotifier {
  AppState({
    required this.currentUser,
  });

  AppUser currentUser;

  // Tymczasowo zostawiamy puste listy,
  // dopóki te elementy nie zostaną
  // całkowicie przeniesione do Firestore.

  final List<CommunityMember> nearbyMembers = [];

  final List<CommunityMember> manualMembers = [];

  final List<Incident> incidents = [];

  void updateCurrentUser(AppUser user) {
    currentUser = user;
    notifyListeners();
  }
}