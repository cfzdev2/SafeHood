import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../data/bridge_service.dart';
import '../domain/bridge_status.dart';
import 'bridge_pairing_screen.dart';

class BridgeManagementScreen extends StatefulWidget {
  const BridgeManagementScreen({super.key});

  @override
  State<BridgeManagementScreen> createState() => _BridgeManagementScreenState();
}

class _BridgeManagementScreenState extends State<BridgeManagementScreen> {
  late final BridgeService _bridgeService;

  late final Stream<List<BridgeStatus>> _bridgesStream;

  Timer? _statusTimer;

  String? _assigningBridgeId;

  String? _removingBridgeId;

  @override
  void initState() {
    super.initState();

    _bridgeService = BridgeService();

    _bridgesStream = _bridgeService.watchBridges();

    _statusTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _statusTimer?.cancel();

    super.dispose();
  }

  Future<void> _openPairing() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const BridgePairingScreen()),
    );
  }

  Future<void> _assignCameras(BridgeStatus bridge) async {
    if (_assigningBridgeId != null || _removingBridgeId != null) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Przypisać kamery?'),
          content: Text(
            'Wszystkie kamery ONVIF zostaną '
            'przeniesione do urządzenia '
            '"${bridge.name}".\n\n'
            'Dotychczasowy Bridge przestanie '
            'je monitorować, a nowy uruchomi '
            'własne połączenia ONVIF.',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(false);
              },
              child: const Text('Anuluj'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(true);
              },
              child: const Text('Przypisz'),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !mounted) {
      return;
    }

    setState(() {
      _assigningBridgeId = bridge.id;
    });

    try {
      final count = await _bridgeService.assignCamerasToBridge(bridge.id);

      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Przypisano '
            '${_cameraCountLabel(count)}.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_errorDescription(error))));
    } finally {
      if (mounted) {
        setState(() {
          _assigningBridgeId = null;
        });
      }
    }
  }

  Future<void> _removeBridge(BridgeStatus bridge) async {
    if (_assigningBridgeId != null || _removingBridgeId != null) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final warning = bridge.isActive
            ? 'To jest aktualnie aktywny Bridge.\n\n'
                  'Usunięcie zatrzyma monitoring i odłączy '
                  'wszystkie przypisane do niego kamery.\n\n'
                  'Aby wznowić monitoring, trzeba będzie '
                  'sparować lub wybrać inny Bridge.'
            : 'Urządzenie "${bridge.name}" zostanie '
                  'usunięte z Twojego konta.\n\n'
                  'Jeżeli posiada prywatny sekret, zostanie '
                  'on trwale unieważniony.';

        return AlertDialog(
          title: const Text('Usunąć Bridge?'),
          content: Text(warning),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(false);
              },
              child: const Text('Anuluj'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(dialogContext).colorScheme.error,
                foregroundColor: Theme.of(dialogContext).colorScheme.onError,
              ),
              onPressed: () {
                Navigator.of(dialogContext).pop(true);
              },
              child: const Text('Usuń Bridge'),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !mounted) {
      return;
    }

    setState(() {
      _removingBridgeId = bridge.id;
    });

    try {
      final count = await _bridgeService.removeBridge(bridge.id);

      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Usunięto Bridge. '
            'Odpięto ${_cameraCountLabel(count)}.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_errorDescription(error))));
    } finally {
      if (mounted) {
        setState(() {
          _removingBridgeId = null;
        });
      }
    }
  }

  String _errorDescription(Object error) {
    if (error is FirebaseFunctionsException) {
      return error.message ?? 'Nie udało się wykonać operacji Bridge.';
    }

    return error.toString();
  }

  String _cameraCountLabel(int count) {
    if (count == 1) {
      return '1 kamerę';
    }

    return '$count kamer';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Urządzenia Bridge')),
      body: StreamBuilder<List<BridgeStatus>>(
        stream: _bridgesStream,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting &&
              !snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError && !snapshot.hasData) {
            return Center(
              child: Text(
                'Nie udało się wczytać '
                'urządzeń Bridge.\n'
                '${snapshot.error}',
                textAlign: TextAlign.center,
              ),
            );
          }

          final bridges = snapshot.data ?? [];

          if (bridges.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Nie sparowano jeszcze '
                  'żadnego urządzenia Bridge.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
            itemCount: bridges.length,
            separatorBuilder: (_, _) {
              return const SizedBox(height: 12);
            },
            itemBuilder: (context, index) {
              return _buildBridgeCard(bridges[index]);
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'bridge_management_pair',
        onPressed: _openPairing,
        icon: const Icon(Icons.add_link),
        label: const Text('Sparuj Bridge'),
      ),
    );
  }

  Widget _buildBridgeCard(BridgeStatus bridge) {
    final isOnline = bridge.isOnlineAt(DateTime.now());

    final isAssigning = _assigningBridgeId == bridge.id;

    final isRemoving = _removingBridgeId == bridge.id;

    final operationInProgress =
        _assigningBridgeId != null || _removingBridgeId != null;

    final statusColor = isOnline
        ? Colors.green
        : Theme.of(context).colorScheme.error;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isOnline ? Icons.hub : Icons.hub_outlined,
                  color: statusColor,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        bridge.name,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        isOnline ? 'Online' : 'Offline',
                        style: TextStyle(color: statusColor),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.circle, size: 11, color: statusColor),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              'ID: ${bridge.id}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 6),
            Text(
              'Aktywne kamery: '
              '${bridge.activeCameraCount}',
            ),
            const SizedBox(height: 6),
            Text(
              bridge.isActive
                  ? 'Aktywny Bridge dla kamer'
                  : bridge.isSecurelyPaired
                  ? 'Bezpiecznie sparowany'
                  : 'Tryb deweloperski',
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                  onPressed: operationInProgress
                      ? null
                      : () {
                          _removeBridge(bridge);
                        },
                  icon: isRemoving
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.delete_outline),
                  label: Text(isRemoving ? 'Usuwanie...' : 'Usuń'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed:
                      bridge.isSecurelyPaired &&
                          !bridge.isActive &&
                          isOnline &&
                          !operationInProgress
                      ? () {
                          _assignCameras(bridge);
                        }
                      : null,
                  icon: isAssigning
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.videocam_outlined),
                  label: Text(
                    bridge.isActive
                        ? 'Aktywny Bridge'
                        : bridge.isSecurelyPaired
                        ? isOnline
                              ? 'Przypisz kamery'
                              : 'Bridge offline'
                        : 'Tryb deweloperski',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
