import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../../../core/state/app_state.dart';
import '../domain/community_member.dart';

class CommunityScreen extends StatefulWidget {
  final AppState appState;

  const CommunityScreen({
    super.key,
    required this.appState,
  });

  @override
  State<CommunityScreen> createState() =>
      _CommunityScreenState();
}

class _CommunityScreenState
    extends State<CommunityScreen> {
  bool isLoading = true;

  String? errorMessage;

  List<_NearbyUser> nearbyUsers = [];

  @override
  void initState() {
    super.initState();

    loadNearbyUsers();
  }

  Future<void> loadNearbyUsers() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      debugPrint(
        'COMMUNITY: wywołuję getNearbyUsers',
      );

      final functions =
          FirebaseFunctions.instanceFor(
        region: 'europe-central2',
      );

      final callable =
          functions.httpsCallable(
        'getNearbyUsers',
      );

      final result = await callable.call();

      debugPrint(
        'COMMUNITY: odpowiedź=${result.data}',
      );

      final data =
          Map<String, dynamic>.from(
        result.data as Map,
      );

      final rawUsers =
          data['users'] as List<dynamic>? ??
              [];

      final loadedUsers = rawUsers
          .map(
            (item) {
              final map =
                  Map<String, dynamic>.from(
                item as Map,
              );

              return _NearbyUser(
                id: map['id']?.toString() ?? '',
                firstName:
                    map['firstName']?.toString() ??
                        'Użytkownik',
                distanceMeters:
                    (map['distanceMeters']
                                as num?)
                            ?.round() ??
                        0,
              );
            },
          )
          .where(
            (user) => user.id.isNotEmpty,
          )
          .toList();

      if (!mounted) {
        return;
      }

      setState(() {
        nearbyUsers = loadedUsers;
        isLoading = false;
      });

      debugPrint(
        'COMMUNITY: znaleziono '
        '${loadedUsers.length} użytkowników',
      );
    } on FirebaseFunctionsException catch (error) {
      debugPrint(
        'COMMUNITY FUNCTIONS ERROR: '
        '${error.code} - ${error.message}',
      );

      if (!mounted) {
        return;
      }

      setState(() {
        errorMessage =
            '${error.code}: '
            '${error.message ?? 'Nieznany błąd'}';

        isLoading = false;
      });
    } catch (error, stackTrace) {
      debugPrint(
        'COMMUNITY ERROR: $error',
      );

      debugPrint(
        'COMMUNITY STACKTRACE: $stackTrace',
      );

      if (!mounted) {
        return;
      }

      setState(() {
        errorMessage =
            'Nie udało się pobrać użytkowników: '
            '$error';

        isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final manualMembers =
        widget.appState.manualMembers;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Społeczność',
        ),
        actions: [
          IconButton(
            onPressed:
                isLoading
                    ? null
                    : loadNearbyUsers,
            icon: const Icon(
              Icons.refresh,
            ),
            tooltip: 'Odśwież',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: loadNearbyUsers,
        child: ListView(
          physics:
              const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(
            16,
            16,
            16,
            100,
          ),
          children: [
            Text(
              'Twoja okolica',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),

            const SizedBox(height: 6),

            Text(
              'Użytkownicy SafeHood znajdujący się '
              'w promieniu 1 km.',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium,
            ),

            const SizedBox(height: 16),

            _buildNearbySection(),

            const SizedBox(height: 28),

            Text(
              'Dodani ręcznie',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),

            const SizedBox(height: 6),

            Text(
              'Zaufane osoby, które dodałeś '
              'samodzielnie.',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium,
            ),

            const SizedBox(height: 16),

            if (manualMembers.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: Text(
                    'Nie dodałeś jeszcze '
                    'żadnych zaufanych osób.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            else
              Card(
                child: Column(
                  children: [
                    for (
                      int i = 0;
                      i < manualMembers.length;
                      i++
                    ) ...[
                      _CommunityMemberTile(
                        member:
                            manualMembers[i],
                      ),
                      if (i !=
                          manualMembers.length -
                              1)
                        const Divider(
                          height: 1,
                        ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
      floatingActionButton:
          FloatingActionButton.extended(
            heroTag: 'community_fab',
        onPressed: () {
          debugPrint(
            'Dodaj osobę ręcznie',
          );
        },
        icon: const Icon(
          Icons.person_add_outlined,
        ),
        label: const Text(
          'Dodaj osobę',
        ),
      ),
    );
  }

  Widget _buildNearbySection() {
    if (isLoading) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Center(
            child: Column(
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 12),
                Text(
                  'Szukam użytkowników '
                  'w pobliżu...',
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (errorMessage != null) {
      return Card(
        child: Padding(
          padding:
              const EdgeInsets.all(20),
          child: Column(
            children: [
              const Icon(
                Icons.error_outline,
                size: 36,
              ),

              const SizedBox(height: 12),

              const Text(
                'Nie udało się pobrać '
                'użytkowników z okolicy.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                ),
              ),

              const SizedBox(height: 8),

              Text(
                errorMessage!,
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 16),

              FilledButton.icon(
                onPressed: loadNearbyUsers,
                icon: const Icon(
                  Icons.refresh,
                ),
                label: const Text(
                  'Spróbuj ponownie',
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (nearbyUsers.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text(
            'Na razie nie znaleziono '
            'innych użytkowników SafeHood '
            'w promieniu 1 km.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return Card(
      child: Column(
        children: [
          for (
            int i = 0;
            i < nearbyUsers.length;
            i++
          ) ...[
            _NearbyUserTile(
              user: nearbyUsers[i],
            ),

            if (i != nearbyUsers.length - 1)
              const Divider(
                height: 1,
              ),
          ],
        ],
      ),
    );
  }
}

class _NearbyUser {
  final String id;
  final String firstName;
  final int distanceMeters;

  const _NearbyUser({
    required this.id,
    required this.firstName,
    required this.distanceMeters,
  });
}

class _NearbyUserTile
    extends StatelessWidget {
  final _NearbyUser user;

  const _NearbyUserTile({
    required this.user,
  });

  @override
  Widget build(BuildContext context) {
    final firstLetter =
        user.firstName.trim().isEmpty
            ? '?'
            : user.firstName
                .trim()
                .substring(0, 1)
                .toUpperCase();

    return ListTile(
      leading: CircleAvatar(
        child: Text(
          firstLetter,
        ),
      ),
      title: Text(
        user.firstName,
        style: const TextStyle(
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        '${user.distanceMeters} m od Ciebie',
      ),
      trailing: const Icon(
        Icons.location_on_outlined,
      ),
    );
  }
}

class _CommunityMemberTile
    extends StatelessWidget {
  final CommunityMember member;

  const _CommunityMemberTile({
    required this.member,
  });

  @override
  Widget build(BuildContext context) {
    final firstLetter =
        member.firstName.trim().isEmpty
            ? '?'
            : member.firstName
                .trim()
                .substring(0, 1)
                .toUpperCase();

    final isNearby =
        member.source ==
            CommunityMemberSource.nearby;

    return ListTile(
      leading: CircleAvatar(
        child: Text(
          firstLetter,
        ),
      ),
      title: Text(
        member.firstName,
        style: const TextStyle(
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: isNearby
          ? Text(
              '${member.distanceMeters?.round() ?? 0} '
              'm od Ciebie',
            )
          : const Text(
              'Dodany ręcznie',
            ),
      trailing: Icon(
        isNearby
            ? Icons.location_on_outlined
            : Icons
                .person_add_alt_1_outlined,
      ),
    );
  }
}