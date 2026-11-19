import 'package:flutter/material.dart';

import '../data/focus72_direct_probe.dart';

class Focus72DirectCheckScreen extends StatefulWidget {
  const Focus72DirectCheckScreen({super.key});

  @override
  State<Focus72DirectCheckScreen> createState() =>
      _Focus72DirectCheckScreenState();
}

class _Focus72DirectCheckScreenState extends State<Focus72DirectCheckScreen>
    with WidgetsBindingObserver {
  final _address = TextEditingController();
  Focus72DirectProbe? _probe;
  Focus72DirectResult? _result;
  String? _addressError;
  bool _interrupted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _probe?.close();
    _address.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed || _probe == null) return;
    _probe?.close();
    setState(() {
      _probe = null;
      _interrupted = true;
    });
  }

  Future<void> _check() async {
    if (_probe != null) return;
    final address = _address.text.trim();
    if (focus72DirectCandidates(address).isEmpty) {
      setState(() {
        _addressError = 'Wpisz lokalny adres IPv4 kamery, np. 192.168.1.20.';
      });
      return;
    }
    FocusScope.of(context).unfocus();
    final probe = Focus72DirectProbe();
    setState(() {
      _probe = probe;
      _result = null;
      _addressError = null;
      _interrupted = false;
    });
    var result = const Focus72DirectResult(Focus72DirectStatus.unavailable);
    try {
      result = await probe.check(address);
    } catch (_) {
      // The device may close the connection before returning an image.
    } finally {
      probe.close();
    }
    if (!mounted || !identical(_probe, probe)) return;
    setState(() {
      _result = result;
      _probe = null;
    });
  }

  String _description(Focus72DirectStatus status) => switch (status) {
    Focus72DirectStatus.video =>
      'Potwierdzono bezpośredni obraz: SafeHood odebrał różne klatki z kamery.',
    Focus72DirectStatus.sameFrames =>
      'Odebrano klatki, ale obraz się nie zmienił. Porusz dłonią przed kamerą i powtórz próbę.',
    Focus72DirectStatus.photo =>
      'Odebrano jedno zdjęcie. Nie potwierdzono obrazu na żywo.',
    Focus72DirectStatus.loginRequired =>
      'Urządzenie żąda logowania. Nie udało się potwierdzić obrazu.',
    Focus72DirectStatus.unavailable =>
      'Nie udało się odebrać obrazu. Sprawdź adres kamery i połączenie z domowym Wi‑Fi.',
  };

  @override
  Widget build(BuildContext context) {
    final busy = _probe != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Sprawdź obraz Motoroli')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              'FOCUS72-W · próba podglądu',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            const Text(
              'Połącz telefon i kamerę z tym samym domowym Wi‑Fi. Zamknij Hubble, '
              'wpisz adres kamery z listy urządzeń routera i porusz dłonią przed '
              'obiektywem w trakcie próby.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _address,
              enabled: !busy,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.go,
              autocorrect: false,
              onSubmitted: (_) => _check(),
              onChanged: (_) {
                if (_addressError != null || _result != null || _interrupted) {
                  setState(() {
                    _addressError = null;
                    _result = null;
                    _interrupted = false;
                  });
                }
              },
              decoration: InputDecoration(
                labelText: 'Adres IP kamery',
                hintText: '192.168.1.20',
                errorText: _addressError,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: busy ? null : _check,
              child: const Text('Sprawdź obraz'),
            ),
            if (busy) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              const Text('Sprawdzam bezpośredni obraz z kamery…'),
            ],
            if (_interrupted) ...[
              const SizedBox(height: 16),
              const Text('Próba przerwana. Możesz ją uruchomić ponownie.'),
            ],
            if (_result case final result?) ...[
              const SizedBox(height: 16),
              Semantics(
                liveRegion: true,
                child: Text(_description(result.status)),
              ),
              if (result.image case final image?) ...[
                const SizedBox(height: 12),
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Image.memory(
                    image,
                    cacheWidth: 640,
                    fit: BoxFit.contain,
                    semanticLabel: 'Klatka odebrana w próbie podglądu',
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
