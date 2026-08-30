import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/incident_service.dart';
import '../domain/incident.dart';
import 'incident_chat_screen.dart';

class IncidentDetailsScreen
    extends StatefulWidget {
  final Incident incident;

  const IncidentDetailsScreen({
    super.key,
    required this.incident,
  });

  @override
  State<IncidentDetailsScreen> createState() =>
      _IncidentDetailsScreenState();
}

class _IncidentDetailsScreenState
    extends State<IncidentDetailsScreen> {
  final IncidentService _incidentService =
      IncidentService();

  String? _reporterPhone;
  String? _contactError;

  bool _loadingContact = false;
  bool _savingResponse = false;

  Incident get incident =>
      widget.incident;

  String? get _currentUid =>
      FirebaseAuth.instance.currentUser?.uid;

  bool get _isReporter =>
      _currentUid == incident.reporterId;

  bool get _isActive {
    if (incident.status !=
        IncidentStatus.active) {
      return false;
    }

    final expiresAt = incident.expiresAt;

    if (expiresAt == null) {
      return true;
    }

    return DateTime.now().isBefore(
      expiresAt,
    );
  }

  @override
  void initState() {
    super.initState();

    if (_isActive && !_isReporter) {
      _loadReporterContact();
    }
  }

  Future<void> _loadReporterContact() async {
    if (_loadingContact) {
      return;
    }

    setState(() {
      _loadingContact = true;
      _contactError = null;
    });

    try {
      final contact =
          await _incidentService
              .getIncidentContact(
        incident.id,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _reporterPhone =
            contact.phoneNumber;
        _loadingContact = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _loadingContact = false;
        _contactError =
            'Nie udało się pobrać numeru.';
      });

      debugPrint(
        'INCIDENT CONTACT ERROR: $error',
      );
    }
  }

  Future<void> _callReporter() async {
    final phone = _reporterPhone;

    if (phone == null ||
        phone.isEmpty) {
      return;
    }

    final uri = Uri(
      scheme: 'tel',
      path: phone,
    );

    try {
      final launched =
          await launchUrl(uri);

      if (!launched && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(
          const SnackBar(
            content: Text(
              'Nie udało się otworzyć '
              'aplikacji telefonu.',
            ),
          ),
        );
      }
    } catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context)
          .showSnackBar(
        const SnackBar(
          content: Text(
            'Nie udało się rozpocząć '
            'połączenia.',
          ),
        ),
      );
    }
  }

  Future<void> _setResponse(
    IncidentResponseStatus status,
  ) async {
    if (_savingResponse) {
      return;
    }

    setState(() {
      _savingResponse = true;
    });

    try {
      await _incidentService.setResponse(
        incidentId: incident.id,
        status: status,
      );
    } catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context)
          .showSnackBar(
        SnackBar(
          content: Text(
            'Nie udało się zapisać '
            'reakcji: $error',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _savingResponse = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isActive = _isActive;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Szczegóły zgłoszenia',
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          16,
          16,
          16,
          32,
        ),
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 24,
                child: Icon(
                  isActive
                      ? Icons.warning_amber
                      : Icons.check,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Text(
                      incident.title,
                      style: Theme.of(context)
                          .textTheme
                          .titleLarge
                          ?.copyWith(
                            fontWeight:
                                FontWeight.bold,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      isActive
                          ? 'Aktywne zgłoszenie'
                          : 'Zakończone',
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(
                    Icons.person_outline,
                  ),
                  title: const Text(
                    'Zgłaszający',
                  ),
                  subtitle: Text(
                    incident.reporterName,
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(
                    Icons.videocam_outlined,
                  ),
                  title: const Text(
                    'Kamera',
                  ),
                  subtitle: Text(
                    incident.cameraName,
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(
                    Icons.schedule,
                  ),
                  title: const Text(
                    'Czas zgłoszenia',
                  ),
                  subtitle: Text(
                    _formatDateTime(
                      incident.createdAt,
                    ),
                  ),
                ),
              ],
            ),
          ),

          if (incident.description != null &&
              incident.description!
                  .trim()
                  .isNotEmpty) ...[
            const SizedBox(height: 20),

            Text(
              'Opis',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(
                    fontWeight:
                        FontWeight.bold,
                  ),
            ),

            const SizedBox(height: 8),

            Card(
              child: Padding(
                padding:
                    const EdgeInsets.all(16),
                child: Text(
                  incident.description!,
                ),
              ),
            ),
          ],

          const SizedBox(height: 20),

          Text(
            isActive
                ? 'Transmisja zdarzenia'
                : 'Nagranie zdarzenia',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(
                  fontWeight:
                      FontWeight.bold,
                ),
          ),

          const SizedBox(height: 8),

          AspectRatio(
            aspectRatio: 16 / 9,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius:
                    BorderRadius.circular(16),
              ),
              child: Center(
                child: Column(
                  mainAxisSize:
                      MainAxisSize.min,
                  children: [
                    Icon(
                      isActive
                          ? Icons
                              .videocam_outlined
                          : Icons
                              .play_circle_outline,
                      size: 52,
                      color: Colors.white70,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      isActive
                          ? 'LIVE będzie dostępny tutaj'
                          : incident.hasRecording
                              ? 'Nagranie będzie '
                                  'dostępne tutaj'
                              : 'Brak nagrania',
                      style:
                          const TextStyle(
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          if (incident.hasRecording &&
              incident
                      .recordingDurationSeconds !=
                  null) ...[
            const SizedBox(height: 8),
            Text(
              'Długość nagrania: '
              '${_formatDuration(
                incident
                    .recordingDurationSeconds!,
              )}',
            ),
          ],

          if (isActive) ...[
            const SizedBox(height: 24),

            Text(
              'Reakcje',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(
                    fontWeight:
                        FontWeight.bold,
                  ),
            ),

            const SizedBox(height: 8),

            _buildResponsesSection(),

            const SizedBox(height: 24),

            Text(
              'Kontakt',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(
                    fontWeight:
                        FontWeight.bold,
                  ),
            ),

            const SizedBox(height: 8),

            _buildContactCard(),

            const SizedBox(height: 12),

            Card(
              child: ListTile(
                leading: const Icon(
                  Icons.chat_bubble_outline,
                ),
                title: const Text(
                  'Czat zdarzenia',
                ),
                subtitle: const Text(
                  'Rozmawiaj z uczestnikami '
                  'zgłoszenia',
                ),
                trailing: const Icon(
                  Icons.chevron_right,
                ),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          IncidentChatScreen(
                        incident: incident,
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildResponsesSection() {
    return StreamBuilder<
        List<IncidentResponse>>(
      stream: _incidentService
          .watchResponses(
        incident.id,
      ),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Card(
            child: Padding(
              padding:
                  const EdgeInsets.all(16),
              child: Text(
                'Nie udało się pobrać '
                'reakcji: ${snapshot.error}',
              ),
            ),
          );
        }

        if (!snapshot.hasData) {
          return const Card(
            child: Padding(
              padding:
                  EdgeInsets.all(20),
              child: Center(
                child:
                    CircularProgressIndicator(),
              ),
            ),
          );
        }

        final responses =
            snapshot.data!;

        IncidentResponse? myResponse;

        for (final response in responses) {
          if (response.userId ==
              _currentUid) {
            myResponse = response;
            break;
          }
        }

        final watchingCount = responses
            .where(
              (response) =>
                  response.status ==
                  IncidentResponseStatus
                      .watching,
            )
            .length;

        final goingCount = responses
            .where(
              (response) =>
                  response.status ==
                  IncidentResponseStatus
                      .going,
            )
            .length;

        final onSiteCount = responses
            .where(
              (response) =>
                  response.status ==
                  IncidentResponseStatus
                      .onSite,
            )
            .length;

        return Card(
          child: Padding(
            padding:
                const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _ResponseCounter(
                        icon:
                            Icons.visibility_outlined,
                        label: 'Obserwuje',
                        count: watchingCount,
                      ),
                    ),
                    Expanded(
                      child: _ResponseCounter(
                        icon:
                            Icons.directions_walk,
                        label: 'Idzie',
                        count: goingCount,
                      ),
                    ),
                    Expanded(
                      child: _ResponseCounter(
                        icon:
                            Icons.location_on_outlined,
                        label: 'Na miejscu',
                        count: onSiteCount,
                      ),
                    ),
                  ],
                ),

                if (!_isReporter) ...[
                  const SizedBox(height: 20),

                  const Text(
                    'Twoja reakcja',
                    style: TextStyle(
                      fontWeight:
                          FontWeight.w600,
                    ),
                  ),

                  const SizedBox(height: 10),

                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ChoiceChip(
                        avatar: const Icon(
                          Icons
                              .visibility_outlined,
                          size: 18,
                        ),
                        label: const Text(
                          'Obserwuję',
                        ),
                        selected:
                            myResponse?.status ==
                                IncidentResponseStatus
                                    .watching,
                        onSelected:
                            _savingResponse
                                ? null
                                : (_) {
                                    _setResponse(
                                      IncidentResponseStatus
                                          .watching,
                                    );
                                  },
                      ),
                      ChoiceChip(
                        avatar: const Icon(
                          Icons
                              .directions_walk,
                          size: 18,
                        ),
                        label: const Text(
                          'Idę sprawdzić',
                        ),
                        selected:
                            myResponse?.status ==
                                IncidentResponseStatus
                                    .going,
                        onSelected:
                            _savingResponse
                                ? null
                                : (_) {
                                    _setResponse(
                                      IncidentResponseStatus
                                          .going,
                                    );
                                  },
                      ),
                      ChoiceChip(
                        avatar: const Icon(
                          Icons
                              .location_on_outlined,
                          size: 18,
                        ),
                        label: const Text(
                          'Jestem na miejscu',
                        ),
                        selected:
                            myResponse?.status ==
                                IncidentResponseStatus
                                    .onSite,
                        onSelected:
                            _savingResponse
                                ? null
                                : (_) {
                                    _setResponse(
                                      IncidentResponseStatus
                                          .onSite,
                                    );
                                  },
                      ),
                    ],
                  ),
                ],

                if (responses.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  const Divider(),
                  const SizedBox(height: 8),

                  const Text(
                    'Reakcje sąsiadów',
                    style: TextStyle(
                      fontWeight:
                          FontWeight.w600,
                    ),
                  ),

                  const SizedBox(height: 8),

                  ...responses.map(
                    (response) => ListTile(
                      contentPadding:
                          EdgeInsets.zero,
                      leading: Icon(
                        _responseIcon(
                          response.status,
                        ),
                      ),
                      title: Text(
                        response.firstName,
                      ),
                      subtitle: Text(
                        _responseLabel(
                          response.status,
                        ),
                      ),
                    ),
                  ),
                ],

                if (responses.isEmpty &&
                    _isReporter) ...[
                  const SizedBox(height: 16),
                  const Text(
                    'Nikt jeszcze nie '
                    'zareagował na zgłoszenie.',
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildContactCard() {
    if (_isReporter) {
      return const Card(
        child: ListTile(
          leading: Icon(
            Icons.phone_outlined,
          ),
          title: Text(
            'Kontakt ze zgłaszającym',
          ),
          subtitle: Text(
            'To jest Twoje zgłoszenie.',
          ),
        ),
      );
    }

    return Card(
      child: ListTile(
        leading: const Icon(
          Icons.phone_outlined,
        ),
        title: Text(
          'Kontakt z '
          '${incident.reporterName}',
        ),
        subtitle: _loadingContact
            ? const Text(
                'Pobieranie numeru...',
              )
            : _reporterPhone != null
                ? Text(_reporterPhone!)
                : Text(
                    _contactError ??
                        'Numer niedostępny',
                  ),
        trailing: _loadingContact
            ? const SizedBox(
                width: 22,
                height: 22,
                child:
                    CircularProgressIndicator(
                  strokeWidth: 2,
                ),
              )
            : _reporterPhone != null
                ? IconButton(
                    tooltip: 'Zadzwoń',
                    onPressed:
                        _callReporter,
                    icon: const Icon(
                      Icons.call,
                    ),
                  )
                : IconButton(
                    tooltip: 'Spróbuj ponownie',
                    onPressed:
                        _loadReporterContact,
                    icon: const Icon(
                      Icons.refresh,
                    ),
                  ),
        onTap: _reporterPhone != null
            ? _callReporter
            : _loadReporterContact,
      ),
    );
  }

  static IconData _responseIcon(
    IncidentResponseStatus status,
  ) {
    switch (status) {
      case IncidentResponseStatus.watching:
        return Icons.visibility_outlined;

      case IncidentResponseStatus.going:
        return Icons.directions_walk;

      case IncidentResponseStatus.onSite:
        return Icons.location_on_outlined;
    }
  }

  static String _responseLabel(
    IncidentResponseStatus status,
  ) {
    switch (status) {
      case IncidentResponseStatus.watching:
        return 'Obserwuje sytuację';

      case IncidentResponseStatus.going:
        return 'Idzie sprawdzić';

      case IncidentResponseStatus.onSite:
        return 'Jest na miejscu';
    }
  }

  static String _formatDuration(
    int seconds,
  ) {
    final minutes = seconds ~/ 60;
    final remainingSeconds =
        seconds % 60;

    return '$minutes:'
        '${remainingSeconds.toString().padLeft(2, '0')}';
  }

  static String _formatDateTime(
    DateTime dateTime,
  ) {
    final day =
        dateTime.day
            .toString()
            .padLeft(2, '0');

    final month =
        dateTime.month
            .toString()
            .padLeft(2, '0');

    final year = dateTime.year;

    final hour =
        dateTime.hour
            .toString()
            .padLeft(2, '0');

    final minute =
        dateTime.minute
            .toString()
            .padLeft(2, '0');

    return '$day.$month.$year • '
        '$hour:$minute';
  }
}

class _ResponseCounter
    extends StatelessWidget {
  final IconData icon;
  final String label;
  final int count;

  const _ResponseCounter({
    required this.icon,
    required this.label,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon),
        const SizedBox(height: 4),
        Text(
          '$count',
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
        ),
        Text(
          label,
          textAlign: TextAlign.center,
          style: Theme.of(context)
              .textTheme
              .bodySmall,
        ),
      ],
    );
  }
}