import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/local_camera_store.dart';

/// Shared player for the add flow and previously saved local cameras.
/// Saving is only possible after the Android player renders a video frame.
class LocalCameraPreview extends StatefulWidget {
  const LocalCameraPreview({
    super.key,
    required this.source,
    required this.store,
    this.existingId,
    this.allowSave = false,
  });

  final LocalCameraSource source;
  final LocalCameraStore store;
  final String? existingId;
  final bool allowSave;

  @override
  State<LocalCameraPreview> createState() => _LocalCameraPreviewState();
}

class _LocalCameraPreviewState extends State<LocalCameraPreview>
    with WidgetsBindingObserver {
  late final _name = TextEditingController(text: widget.source.name);
  final _player = const LocalCameraPlayer();
  int? _texture;
  Timer? _timer;
  int _generation = 0;
  double _aspect = 16 / 9;
  bool _connecting = false;
  bool _confirmed = false;
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
    _confirmed = false;
    if (texture != null) unawaited(_stop(texture));
  }

  Future<void> _stop(int texture) async {
    try {
      await _player.stop(texture);
    } catch (_) {
      // The native player may already have been released with the activity.
    }
  }

  Future<void> _connect({bool tryUdp = false}) async {
    _release();
    final generation = _generation;
    setState(() {
      _connecting = true;
      _problem = null;
    });
    try {
      var uri = widget.source.uri;
      final uid = widget.source.reolinkUid;
      if (!widget.allowSave && uid != null) {
        uri = await _player.refreshReolink(uid, uri);
      }
      if (!mounted || generation != _generation) return;
      final texture = await _player.open(uri, tryUdp: tryUdp);
      if (!mounted || generation != _generation) {
        await _stop(texture);
        return;
      }
      _texture = texture;
      final startup = Stopwatch()..start();
      _schedulePoll(texture, generation, startup);
    } on PlatformException catch (error) {
      if (!mounted || generation != _generation) return;
      _fail(switch (error.code) {
        'notLocalNetwork' =>
          'Połącz telefon z Wi-Fi kamery i spróbuj ponownie.',
        'notFoundLan' => 'Nie znaleziono tej kamery Reolink w Wi-Fi.',
        'authFailed' => 'Hasło kamery nie działa. Zaktualizuj dane dostępu.',
        'udpNeedsDefaultWifi' =>
          'Aby użyć UDP, ustaw Wi-Fi kamery jako główną sieć telefonu.',
        _ =>
          'Nie udało się otworzyć RTSP. Sprawdź adres, dostęp do kamery i H.264.',
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      _fail(
        'Nie udało się odebrać obrazu. Sprawdź adres, dostęp do kamery i Wi-Fi.',
      );
    }
  }

  void _schedulePoll(int texture, int generation, Stopwatch startup) {
    _timer = Timer(const Duration(milliseconds: 300), () async {
      try {
        final state = await _player.state(texture);
        if (!mounted || generation != _generation) return;
        final ready = state['rendered'] == true;
        if (state['failed'] == true ||
            (!ready &&
                !_confirmed &&
                startup.elapsed > const Duration(seconds: 14))) {
          _fail(
            'Nie udało się odebrać obrazu. Sprawdź Wi-Fi i strumień H.264.',
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
        if (ready) startup.reset();
        _schedulePoll(texture, generation, startup);
      } catch (_) {
        if (mounted && generation == _generation) {
          _fail('Podgląd przerwany. Połącz ponownie.');
        }
      }
    });
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
    if (!_confirmed || _saving || name.isEmpty) return;
    setState(() => _saving = true);
    try {
      await widget.store.save(
        LocalCameraSource(
          name: name,
          uri: widget.source.uri,
          reolinkUid: widget.source.reolinkUid,
        ),
        id: widget.existingId,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Nie udało się zapisać kamery na telefonie.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final texture = _texture;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.allowSave ? 'Sprawdź obraz' : widget.source.name),
      ),
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
              onPressed: _saving ? null : () => _connect(tryUdp: true),
              child: const Text('Spróbuj przez UDP'),
            ),
          ] else
            Text(_confirmed ? 'Podgląd na żywo' : 'Czekam na obraz…'),
          if (widget.allowSave) ...[
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              maxLength: 80,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Nazwa kamery'),
            ),
            const Text(
              'Sprawdź, czy obraz się porusza, zanim zapiszesz kamerę.',
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _confirmed && !_saving && _name.text.trim().isNotEmpty
                  ? _save
                  : null,
              icon: const Icon(Icons.check),
              label: Text(_saving ? 'Zapisuję…' : 'Zapisz na telefonie'),
            ),
          ],
        ],
      ),
    );
  }
}
