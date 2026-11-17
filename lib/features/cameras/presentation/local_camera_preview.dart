import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/local_camera_store.dart';

/// Verifies the stream before adding the camera to the account.
/// Saving is only possible after the Android player renders a video frame.
class LocalCameraPreview extends StatefulWidget {
  const LocalCameraPreview({
    super.key,
    required this.source,
    required this.onSave,
    this.refreshSource = false,
    this.fallbackUris = const [],
    this.onEditLogin,
    this.onSaved,
  });

  final LocalCameraSource source;
  final Future<void> Function(LocalCameraSource source, String location) onSave;
  final bool refreshSource;
  final List<Uri> fallbackUris;
  final VoidCallback? onEditLogin;
  final VoidCallback? onSaved;

  @override
  State<LocalCameraPreview> createState() => _LocalCameraPreviewState();
}

class _LocalCameraPreviewState extends State<LocalCameraPreview>
    with WidgetsBindingObserver {
  late final _name = TextEditingController(text: widget.source.name);
  late final _streams = [widget.source.uri, ...widget.fallbackUris];
  final _location = TextEditingController(text: 'Dom');
  final _player = const LocalCameraPlayer();
  Uri? _openedUri;
  int? _texture;
  Timer? _timer;
  int _generation = 0;
  double _aspect = 16 / 9;
  bool _connecting = false;
  bool _confirmed = false;
  bool _hadFrame = false;
  bool _saving = false;
  String? _problem;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_connect());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _release();
    _name.dispose();
    _location.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _release();
      setState(() {
        _connecting = false;
        _problem = 'Podgląd wstrzymany. Połącz ponownie, aby go wznowić.';
      });
    }
  }

  void _release() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    final texture = _texture;
    _texture = null;
    _openedUri = null;
    _confirmed = false;
    _hadFrame = false;
    if (texture != null) unawaited(_stop(texture));
  }

  Future<void> _stop(int texture) async {
    try {
      await _player.stop(texture);
    } catch (_) {
      // The native player may already have been released with the activity.
    }
  }

  Future<void> _connect({int candidate = 0, bool tryUdp = false}) async {
    _release();
    final generation = _generation;
    setState(() {
      _connecting = true;
      _problem = null;
    });
    try {
      var uri = _streams[candidate];
      final uid = widget.source.reolinkUid;
      if (widget.refreshSource && uid != null) {
        uri = await _player.refreshReolink(uid, uri);
      }
      if (!mounted || generation != _generation) return;
      final texture = await _player.open(uri, tryUdp: tryUdp);
      if (!mounted || generation != _generation) {
        await _stop(texture);
        return;
      }
      _texture = texture;
      _openedUri = uri;
      final startup = Stopwatch()..start();
      _schedulePoll(texture, generation, startup, candidate);
    } on PlatformException catch (error) {
      if (!mounted || generation != _generation) return;
      final problem = switch (error.code) {
        'notLocalNetwork' =>
          'Połącz telefon z Wi-Fi kamery i spróbuj ponownie.',
        'notFoundLan' => 'Nie znaleziono tej kamery Reolink w Wi-Fi.',
        'authFailed' => 'Hasło kamery nie działa. Zaktualizuj dane dostępu.',
        'udpNeedsDefaultWifi' =>
          'Aby użyć UDP, ustaw Wi-Fi kamery jako główną sieć telefonu.',
        _ =>
          'Nie udało się otworzyć podglądu. Sprawdź, czy kamera jest włączona.',
      };
      if (error.code == 'notLocalNetwork' || error.code == 'authFailed') {
        _fail(problem);
      } else {
        _tryNext(candidate, problem);
      }
    } catch (_) {
      if (!mounted || generation != _generation) return;
      _tryNext(
        candidate,
        'Nie udało się odebrać obrazu. Sprawdź adres, dostęp do kamery i Wi-Fi.',
      );
    }
  }

  void _schedulePoll(
    int texture,
    int generation,
    Stopwatch startup,
    int candidate,
  ) {
    _timer = Timer(const Duration(milliseconds: 300), () async {
      try {
        final state = await _player.state(texture);
        if (!mounted || generation != _generation) return;
        final ready = state['rendered'] == true;
        if (state['failed'] == true ||
            (!ready &&
                !_confirmed &&
                startup.elapsed >
                    Duration(seconds: _streams.length > 1 ? 7 : 14))) {
          _tryNext(
            candidate,
            'Nie udało się odebrać obrazu. Sprawdź Wi‑Fi i dane logowania kamery.',
          );
          return;
        }
        final width = state['width'] as int? ?? 16;
        final height = state['height'] as int? ?? 9;
        final aspect = width > 0 && height > 0 ? width / height : 16 / 9;
        if (_confirmed != ready || _aspect != aspect) {
          setState(() {
            _confirmed = ready;
            _connecting = !ready;
            _aspect = aspect;
          });
        }
        if (ready) {
          _hadFrame = true;
          startup.reset();
        }
        _schedulePoll(texture, generation, startup, candidate);
      } catch (_) {
        if (mounted && generation == _generation) {
          _tryNext(candidate, 'Podgląd przerwany. Połącz ponownie.');
        }
      }
    });
  }

  void _tryNext(int candidate, String problem) {
    if (!_hadFrame && candidate + 1 < _streams.length) {
      unawaited(_connect(candidate: candidate + 1));
    } else {
      _fail(problem);
    }
  }

  void _fail(String message) {
    _release();
    if (!mounted) return;
    setState(() {
      _connecting = false;
      _problem = message;
    });
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final location = _location.text.trim();
    final uri = _openedUri;
    if (!_confirmed ||
        _saving ||
        uri == null ||
        name.isEmpty ||
        location.isEmpty) {
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.onSave(
        LocalCameraSource(
          name: name,
          uri: uri,
          reolinkUid: widget.source.reolinkUid,
        ),
        location,
      );
      if (!mounted) return;
      final onSaved = widget.onSaved;
      if (onSaved != null) {
        onSaved();
      } else {
        Navigator.of(context).pop(true);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Nie udało się dodać kamery do konta. Spróbuj ponownie.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final texture = _texture;
    return Scaffold(
      appBar: AppBar(title: const Text('Sprawdź obraz')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          AspectRatio(
            aspectRatio: _aspect,
            child: ColoredBox(
              color: Colors.black,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (texture != null) Texture(textureId: texture),
                  if (_connecting)
                    const Center(child: CircularProgressIndicator())
                  else if (texture == null)
                    const Icon(
                      Icons.videocam_off_outlined,
                      color: Colors.white,
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (_problem case final problem?) ...[
            Text(
              problem,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _saving ? null : () => _connect(),
              icon: const Icon(Icons.refresh),
              label: const Text('Połącz ponownie'),
            ),
            TextButton(
              onPressed: _saving
                  ? null
                  : widget.onEditLogin ?? () => _connect(tryUdp: true),
              child: Text(
                widget.onEditLogin == null
                    ? 'Spróbuj przez UDP'
                    : 'Wpisz dane logowania kamery',
              ),
            ),
          ] else
            Text(_confirmed ? 'Podgląd na żywo' : 'Czekam na obraz…'),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            enabled: !_saving,
            maxLength: 60,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Nazwa kamery'),
          ),
          TextField(
            controller: _location,
            enabled: !_saving,
            maxLength: 100,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Lokalizacja'),
          ),
          const Text('Sprawdź, czy obraz się porusza, zanim zapiszesz kamerę.'),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed:
                _confirmed &&
                    !_saving &&
                    _name.text.trim().isNotEmpty &&
                    _location.text.trim().isNotEmpty
                ? _save
                : null,
            icon: const Icon(Icons.check),
            label: Text(_saving ? 'Zapisuję…' : 'Dodaj kamerę'),
          ),
        ],
      ),
    );
  }
}
