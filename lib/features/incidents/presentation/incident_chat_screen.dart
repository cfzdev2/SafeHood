import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../data/incident_chat_service.dart';
import '../domain/incident.dart';
import '../domain/incident_message.dart';

class IncidentChatScreen
    extends StatefulWidget {
  final Incident incident;

  const IncidentChatScreen({
    super.key,
    required this.incident,
  });

  @override
  State<IncidentChatScreen> createState() =>
      _IncidentChatScreenState();
}

class _IncidentChatScreenState
    extends State<IncidentChatScreen> {
  final IncidentChatService _chatService =
      IncidentChatService();

  final TextEditingController
      _messageController =
      TextEditingController();

  final ScrollController _scrollController =
      ScrollController();

  Timer? _timer;

  bool _sending = false;

  String? get _currentUid =>
      FirebaseAuth.instance.currentUser?.uid;

  bool get _isActive {
    if (widget.incident.status !=
        IncidentStatus.active) {
      return false;
    }

    final expiresAt =
        widget.incident.expiresAt;

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

    _timer = Timer.periodic(
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
    _timer?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _sendMessage() async {
    if (_sending || !_isActive) {
      return;
    }

    final text =
        _messageController.text.trim();

    if (text.isEmpty) {
      return;
    }

    setState(() {
      _sending = true;
    });

    try {
      await _chatService.sendMessage(
        incidentId: widget.incident.id,
        text: text,
      );

      _messageController.clear();

      _scrollToBottom();
    } catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context)
          .showSnackBar(
        SnackBar(
          content: Text(
            'Nie udało się wysłać '
            'wiadomości: $error',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
        });
      }
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance
        .addPostFrameCallback(
      (_) {
        if (!_scrollController.hasClients) {
          return;
        }

        _scrollController.animateTo(
          _scrollController
              .position.maxScrollExtent,
          duration:
              const Duration(
            milliseconds: 250,
          ),
          curve: Curves.easeOut,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isActive = _isActive;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            const Text(
              'Czat zdarzenia',
            ),
            Text(
              widget.incident.title,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall,
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          if (!isActive)
            Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 10,
              ),
              child: const Text(
                'Zgłoszenie zakończyło się. '
                'Czat jest dostępny tylko '
                'do odczytu.',
                textAlign: TextAlign.center,
              ),
            ),

          Expanded(
            child: StreamBuilder<
                List<IncidentMessage>>(
              stream:
                  _chatService.watchMessages(
                widget.incident.id,
              ),
              builder: (
                context,
                snapshot,
              ) {
                if (snapshot.connectionState ==
                        ConnectionState.waiting &&
                    !snapshot.hasData) {
                  return const Center(
                    child:
                        CircularProgressIndicator(),
                  );
                }

                if (snapshot.hasError) {
                  return Center(
                    child: Padding(
                      padding:
                          const EdgeInsets.all(
                        24,
                      ),
                      child: Text(
                        'Nie udało się '
                        'wczytać czatu.\n\n'
                        '${snapshot.error}',
                        textAlign:
                            TextAlign.center,
                      ),
                    ),
                  );
                }

                final messages =
                    snapshot.data ?? [];

                if (messages.isEmpty) {
                  return const Center(
                    child: Padding(
                      padding:
                          EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize:
                            MainAxisSize.min,
                        children: [
                          Icon(
                            Icons
                                .chat_bubble_outline,
                            size: 48,
                          ),
                          SizedBox(height: 12),
                          Text(
                            'Brak wiadomości',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight:
                                  FontWeight.bold,
                            ),
                          ),
                          SizedBox(height: 6),
                          Text(
                            'Napisz pierwszą '
                            'wiadomość dotyczącą '
                            'tego zdarzenia.',
                            textAlign:
                                TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  );
                }

                _scrollToBottom();

                return ListView.builder(
                  controller:
                      _scrollController,
                  padding:
                      const EdgeInsets.fromLTRB(
                    12,
                    16,
                    12,
                    16,
                  ),
                  itemCount:
                      messages.length,
                  itemBuilder: (
                    context,
                    index,
                  ) {
                    final message =
                        messages[index];

                    final isMine =
                        message.userId ==
                            _currentUid;

                    return _MessageBubble(
                      message: message,
                      isMine: isMine,
                    );
                  },
                );
              },
            ),
          ),

          SafeArea(
            top: false,
            child: Container(
              padding:
                  const EdgeInsets.fromLTRB(
                12,
                8,
                12,
                8,
              ),
              child: Row(
                crossAxisAlignment:
                    CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller:
                          _messageController,
                      enabled:
                          isActive &&
                          !_sending,
                      minLines: 1,
                      maxLines: 4,
                      maxLength: 500,
                      textCapitalization:
                          TextCapitalization
                              .sentences,
                      decoration:
                          InputDecoration(
                        hintText: isActive
                            ? 'Napisz wiadomość...'
                            : 'Czat zakończony',
                        counterText: '',
                        border:
                            const OutlineInputBorder(),
                      ),
                      onSubmitted: (_) {
                        _sendMessage();
                      },
                    ),
                  ),

                  const SizedBox(width: 8),

                  IconButton.filled(
                    onPressed:
                        isActive && !_sending
                            ? _sendMessage
                            : null,
                    icon: _sending
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child:
                                CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          )
                        : const Icon(
                            Icons.send,
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageBubble
    extends StatelessWidget {
  final IncidentMessage message;
  final bool isMine;

  const _MessageBubble({
    required this.message,
    required this.isMine,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme =
        Theme.of(context).colorScheme;

    return Align(
      alignment: isMine
          ? Alignment.centerRight
          : Alignment.centerLeft,
      child: Container(
        constraints:
            const BoxConstraints(
          maxWidth: 300,
        ),
        margin:
            const EdgeInsets.only(
          bottom: 10,
        ),
        padding:
            const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 10,
        ),
        decoration: BoxDecoration(
          color: isMine
              ? colorScheme.primaryContainer
              : colorScheme
                  .surfaceContainerHighest,
          borderRadius:
              BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            if (!isMine) ...[
              Text(
                message.firstName,
                style: TextStyle(
                  fontWeight:
                      FontWeight.bold,
                  color:
                      colorScheme.primary,
                ),
              ),
              const SizedBox(height: 3),
            ],

            Text(
              message.text,
              style:
                  const TextStyle(
                fontSize: 16,
              ),
            ),

            const SizedBox(height: 4),

            Align(
              alignment:
                  Alignment.centerRight,
              child: Text(
                _formatTime(
                  message.createdAt,
                ),
                style: Theme.of(context)
                    .textTheme
                    .bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _formatTime(
    DateTime dateTime,
  ) {
    final now = DateTime.now();

    final sameDay =
        now.year == dateTime.year &&
        now.month == dateTime.month &&
        now.day == dateTime.day;

    final hour =
        dateTime.hour
            .toString()
            .padLeft(2, '0');

    final minute =
        dateTime.minute
            .toString()
            .padLeft(2, '0');

    if (sameDay) {
      return '$hour:$minute';
    }

    final day =
        dateTime.day
            .toString()
            .padLeft(2, '0');

    final month =
        dateTime.month
            .toString()
            .padLeft(2, '0');

    return '$day.$month • '
        '$hour:$minute';
  }
}