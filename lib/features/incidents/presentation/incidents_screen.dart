import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/state/app_state.dart';
import '../data/incident_service.dart';
import '../domain/incident.dart';
import 'incident_details_screen.dart';

class IncidentsScreen extends StatefulWidget {
  final AppState appState;

  const IncidentsScreen({
    super.key,
    required this.appState,
  });

  @override
  State<IncidentsScreen> createState() =>
      _IncidentsScreenState();
}

class _IncidentsScreenState
    extends State<IncidentsScreen> {
  final IncidentService _incidentService =
      IncidentService();

  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();

    // Odświeżamy ekran regularnie,
    // żeby zgłoszenie samo przeszło
    // do historii po expiresAt.
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) {
        if (mounted) {
          setState(() {});
        }
      },
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Zgłoszenia',
        ),
      ),
      body: StreamBuilder<List<Incident>>(
        stream:
            _incidentService.watchMyIncidents(),
        builder: (context, snapshot) {
          if (snapshot.connectionState ==
                  ConnectionState.waiting &&
              !snapshot.hasData) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }

          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding:
                    const EdgeInsets.all(24),
                child: Text(
                  'Nie udało się wczytać '
                  'zgłoszeń.\n\n'
                  '${snapshot.error}',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          final incidents =
              snapshot.data ?? [];

          final activeIncidents = incidents
              .where(
                _isIncidentActive,
              )
              .toList();

          final resolvedIncidents = incidents
              .where(
                (incident) =>
                    !_isIncidentActive(
                  incident,
                ),
              )
              .toList();

          if (incidents.isEmpty) {
            return const Center(
              child: Padding(
                padding:
                    EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment:
                      MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.shield_outlined,
                      size: 54,
                    ),
                    SizedBox(height: 16),
                    Text(
                      'Brak zgłoszeń',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Gdy zgłosisz problem '
                      'z poziomu kamery, '
                      'pojawi się tutaj.',
                      textAlign:
                          TextAlign.center,
                    ),
                  ],
                ),
              ),
            );
          }

          return ListView(
            padding:
                const EdgeInsets.fromLTRB(
              16,
              16,
              16,
              100,
            ),
            children: [
              if (activeIncidents
                  .isNotEmpty) ...[
                Text(
                  'Aktywne',
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(
                        fontWeight:
                            FontWeight.bold,
                      ),
                ),

                const SizedBox(height: 12),

                for (final incident
                    in activeIncidents)
                  Padding(
                    padding:
                        const EdgeInsets.only(
                      bottom: 12,
                    ),
                    child: _IncidentCard(
                      incident: incident,
                    ),
                  ),

                const SizedBox(height: 16),
              ],

              Text(
                'Historia',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(
                      fontWeight:
                          FontWeight.bold,
                    ),
              ),

              const SizedBox(height: 12),

              if (resolvedIncidents.isEmpty)
                const Card(
                  child: Padding(
                    padding:
                        EdgeInsets.all(20),
                    child: Text(
                      'Brak wcześniejszych '
                      'zgłoszeń.',
                    ),
                  ),
                )
              else
                for (final incident
                    in resolvedIncidents)
                  Padding(
                    padding:
                        const EdgeInsets.only(
                      bottom: 12,
                    ),
                    child: _IncidentCard(
                      incident: incident,
                    ),
                  ),
            ],
          );
        },
      ),
    );
  }
}

bool _isIncidentActive(
  Incident incident,
) {
  if (incident.status !=
      IncidentStatus.active) {
    return false;
  }

  final expiresAt =
      incident.expiresAt;

  if (expiresAt == null) {
    return true;
  }

  return DateTime.now().isBefore(
    expiresAt,
  );
}

class _IncidentCard
    extends StatelessWidget {
  final Incident incident;

  const _IncidentCard({
    required this.incident,
  });

  @override
  Widget build(BuildContext context) {
    final isActive =
        _isIncidentActive(
      incident,
    );

    return Card(
      child: InkWell(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) =>
                  IncidentDetailsScreen(
                incident: incident,
              ),
            ),
          );
        },
        borderRadius:
            BorderRadius.circular(12),
        child: Padding(
          padding:
              const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                child: Icon(
                  isActive
                      ? Icons.warning_amber
                      : Icons.history,
                ),
              ),

              const SizedBox(width: 14),

              Expanded(
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            incident.title,
                            style:
                                const TextStyle(
                              fontWeight:
                                  FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ),

                        if (isActive)
                          const Text(
                            'AKTYWNE',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight:
                                  FontWeight.bold,
                            ),
                          ),
                      ],
                    ),

                    const SizedBox(height: 6),

                    Text(
                      '${incident.reporterName} '
                      '• ${incident.cameraName}',
                    ),

                    const SizedBox(height: 4),

                    Text(
                      _formatTime(
                        incident.createdAt,
                      ),
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall,
                    ),

                    if (incident.description !=
                        null) ...[
                      const SizedBox(
                        height: 8,
                      ),
                      Text(
                        incident.description!,
                      ),
                    ],

                    if (isActive &&
                        incident.expiresAt !=
                            null) ...[
                      const SizedBox(
                        height: 10,
                      ),
                      Text(
                        _formatExpiresAt(
                          incident.expiresAt!,
                        ),
                        style:
                            Theme.of(context)
                                .textTheme
                                .bodySmall,
                      ),
                    ],

                    if (!isActive) ...[
                      const SizedBox(
                        height: 10,
                      ),
                      Text(
                        'Zgłoszenie zakończone',
                        style:
                            Theme.of(context)
                                .textTheme
                                .bodySmall,
                      ),
                    ],

                    if (incident
                        .hasRecording) ...[
                      const SizedBox(
                        height: 10,
                      ),
                      Row(
                        children: [
                          const Icon(
                            Icons
                                .play_circle_outline,
                            size: 18,
                          ),
                          const SizedBox(
                            width: 6,
                          ),
                          Text(
                            'Nagranie '
                            '${_formatDuration(
                              incident
                                  .recordingDurationSeconds,
                            )}',
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _formatDuration(
    int? seconds,
  ) {
    if (seconds == null) {
      return '';
    }

    final minutes =
        seconds ~/ 60;

    final remainingSeconds =
        seconds % 60;

    return '$minutes:'
        '${remainingSeconds.toString().padLeft(2, '0')}';
  }

  static String _formatTime(
    DateTime dateTime,
  ) {
    final now =
        DateTime.now();

    final difference =
        now.difference(
      dateTime,
    );

    if (difference.inMinutes < 1) {
      return 'Przed chwilą';
    }

    if (difference.inMinutes < 60) {
      return '${difference.inMinutes} min temu';
    }

    if (difference.inHours < 24) {
      return '${difference.inHours} godz. temu';
    }

    return '${difference.inDays} dni temu';
  }

  static String _formatExpiresAt(
    DateTime expiresAt,
  ) {
    final difference =
        expiresAt.difference(
      DateTime.now(),
    );

    if (difference.isNegative) {
      return 'Czas zgłoszenia minął';
    }

    if (difference.inMinutes <= 1) {
      return 'Wygasa za chwilę';
    }

    return 'Wygasa za '
        '${difference.inMinutes} min';
  }
}