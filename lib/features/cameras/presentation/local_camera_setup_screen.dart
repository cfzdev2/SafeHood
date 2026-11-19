import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/camera_discovery_service.dart';
import '../data/local_camera_auto_setup.dart';
import '../data/local_camera_registration.dart';
import '../data/local_camera_store.dart';
import 'automatic_local_camera_connection.dart';
import 'camera_pairing_screen.dart';
import 'focus72_direct_check_screen.dart';
import 'local_camera_preview.dart';

enum LocalCameraSetupResult { saved }

class LocalCameraSetupScreen extends StatefulWidget {
  const LocalCameraSetupScreen({
    super.key,
    required this.onSave,
    this.savedSource,
    this.onAdvanced,
    this.discovery,
  });

  final SaveLocalCamera onSave;
  final LocalCameraSource? savedSource;
  final Future<void> Function(BuildContext context)? onAdvanced;
  final CameraDiscoveryService? discovery;

  @override
  State<LocalCameraSetupScreen> createState() => _LocalCameraSetupScreenState();
}

class _LocalCameraSetupScreenState extends State<LocalCameraSetupScreen> {
  late final _discovery = widget.discovery ?? CameraDiscoveryService();
  List<DetectedCamera> _cameras = const [];
  Set<String> _previousAddresses = const {};
  bool _afterPairing = false;
  bool _searching = false;
  int _scanId = 0;

  @override
  void initState() {
    super.initState();
    if (widget.savedSource == null) _startScan();
  }

  void _startScan({
    bool afterPairing = false,
    Set<String> previousAddresses = const {},
  }) {
    final scanId = ++_scanId;
    setState(() {
      _cameras = const [];
      _afterPairing = afterPairing;
      _previousAddresses = previousAddresses;
      _searching = true;
    });
    unawaited(_scan(scanId));
  }

  Future<void> _scan(int scanId) async {
    final afterPairing = _afterPairing;
    final previous = _previousAddresses;
    final byAddress = <String, DetectedCamera>{};
    bool cancelled() => !mounted || scanId != _scanId;

    void publish(List<DetectedCamera> results) {
      if (cancelled()) return;
      for (final device in results.where(canTryLocalCamera)) {
        byAddress[device.ipAddress!] = device;
      }
      setState(() {
        // Keep each result in place as more information arrives. After
        // pairing, cameras not seen before are listed first.
        _cameras = [
          if (afterPairing)
            ...byAddress.values.where(
              (device) => !previous.contains(device.ipAddress),
            ),
          ...byAddress.values.where(
            (device) => !afterPairing || previous.contains(device.ipAddress),
          ),
        ];
      });
    }

    Future<void> scan() async {
      publish(
        await _discovery.discoverCameras(
          onResults: publish,
          isCancelled: cancelled,
        ),
      );
    }

    try {
      await scan();
      if (!cancelled() &&
          afterPairing &&
          !byAddress.keys.any((address) => !previous.contains(address))) {
        // A camera can take another moment to reconnect after restart.
        await Future<void>.delayed(const Duration(seconds: 2));
        if (!cancelled()) await scan();
      }
    } catch (error) {
      debugPrint('CAMERA SETUP DISCOVERY: ${error.runtimeType}');
    } finally {
      if (!cancelled()) {
        setState(() {
          _searching = false;
        });
      }
    }
  }

  void _retry() {
    if (_searching) return;
    _startScan(
      afterPairing: _afterPairing,
      previousAddresses: _previousAddresses,
    );
  }

  void _done() {
    if (mounted) Navigator.of(context).pop(LocalCameraSetupResult.saved);
  }

  Future<void> _openCamera(DetectedCamera device) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (page) => AutomaticLocalCameraConnection(
          discovery: _discovery,
          device: device,
          onSave: widget.onSave,
          onSaved: () => Navigator.of(page).pop(true),
        ),
      ),
    );
    if (saved == true) _done();
  }

  Future<void> _pair() async {
    final known = _cameras.map((device) => device.ipAddress!).toSet();
    final wasSearching = _searching;
    if (wasSearching) {
      // Stop probing the current LAN before the phone switches Wi-Fi.
      ++_scanId;
      setState(() {
        _searching = false;
      });
    }
    final outcome = await Navigator.of(context).push<CameraPairingResult>(
      MaterialPageRoute<CameraPairingResult>(
        builder: (_) => CameraPairingScreen(
          startImmediately: true,
          setupWithLabel: (_) => _ReolinkSetupScreen(onSave: widget.onSave),
        ),
      ),
    );
    if (!mounted) return;
    if (outcome == CameraPairingResult.saved) {
      _done();
    } else if (outcome == CameraPairingResult.findOnHomeNetwork) {
      _startScan(afterPairing: true, previousAddresses: known);
    } else if (wasSearching) {
      _retry();
    }
  }

  Future<void> _manual() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => _ManualLocalCameraScreen(onSave: widget.onSave),
      ),
    );
    if (saved == true) _done();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.savedSource case final source?) {
      return AutomaticLocalCameraConnection(
        discovery: _discovery,
        savedSource: source,
        onSave: widget.onSave,
        onSaved: _done,
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Dodaj kamerę')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_searching) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 12),
              Text(
                _cameras.isNotEmpty
                    ? 'Szukam kolejnych kamer…'
                    : _afterPairing
                    ? 'Szukam kamery w domowym Wi‑Fi…'
                    : 'Szukam kamer w Twojej sieci…',
              ),
              const SizedBox(height: 12),
            ],
            if (_cameras.isNotEmpty) ...[
              const Text(
                'Wybierz swoją kamerę. SafeHood sprawdzi, jak się z nią połączyć.',
              ),
              const SizedBox(height: 12),
              for (final camera in _cameras)
                Card(
                  key: ValueKey(camera.ipAddress),
                  child: ListTile(
                    leading: const Icon(Icons.videocam_outlined),
                    title: Text(localCameraDisplayName(camera)),
                    subtitle: Text(
                      _afterPairing &&
                              !_previousAddresses.contains(camera.ipAddress)
                          ? 'Nowa w sieci · ${camera.ipAddress}'
                          : camera.ipAddress!,
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _openCamera(camera),
                  ),
                ),
            ] else if (!_searching)
              Text(
                _afterPairing
                    ? 'Kamera może jeszcze łączyć się z Wi‑Fi. Odczekaj chwilę i spróbuj ponownie.'
                    : 'Nie znaleziono kamer. Sprawdź, czy kamera jest włączona.',
              ),
            const SizedBox(height: 12),
            if (!_searching)
              OutlinedButton(
                onPressed: _retry,
                child: const Text('Szukaj ponownie'),
              ),
            FilledButton.tonalIcon(
              onPressed: _pair,
              icon: const Icon(Icons.wifi),
              label: const Text('Połącz nową kamerę z Wi‑Fi'),
            ),
            const SizedBox(height: 8),
            if (!_searching)
              ExpansionTile(
                title: const Text('Opcje zaawansowane'),
                children: [
                  ListTile(
                    leading: const Icon(Icons.link),
                    title: const Text('Mam adres strumienia'),
                    onTap: _manual,
                  ),
                  ListTile(
                    leading: const Icon(Icons.videocam_outlined),
                    title: const Text('Sprawdź obraz Motoroli'),
                    subtitle: const Text('FOCUS72-W'),
                    onTap: () => Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) => const Focus72DirectCheckScreen(),
                      ),
                    ),
                  ),
                  if (widget.onAdvanced case final open?)
                    ListTile(
                      leading: const Icon(Icons.hub_outlined),
                      title: const Text(
                        'Integracja producenta lub konfiguracja ręczna',
                      ),
                      onTap: () => open(context),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _ManualLocalCameraScreen extends StatefulWidget {
  const _ManualLocalCameraScreen({required this.onSave});

  final SaveLocalCamera onSave;

  @override
  State<_ManualLocalCameraScreen> createState() =>
      _ManualLocalCameraScreenState();
}

class _ManualLocalCameraScreenState extends State<_ManualLocalCameraScreen> {
  final _address = TextEditingController();
  String? _problem;

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _preview() async {
    final uri = parseLocalRtsp(_address.text);
    if (uri == null) {
      setState(() => _problem = 'Podaj adres rtsp:// z lokalnym adresem IPv4.');
      return;
    }
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => LocalCameraPreview(
          source: LocalCameraSource(name: 'Kamera', uri: uri),
          onSave: (source, location) => widget.onSave(
            LocalCameraRegistration.fromPreview(
              source: source,
              location: location,
            ),
          ),
        ),
      ),
    );
    if (saved == true && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Adres RTSP')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Telefon i kamera muszą być w tej samej sieci. Wybierz strumień H.264.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _address,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: 'Pełny adres RTSP',
              hintText: 'rtsp://192.168.1.50:554/live',
              errorText: _problem,
            ),
            onChanged: (_) {
              if (_problem != null) setState(() => _problem = null);
            },
            onSubmitted: (_) => _preview(),
          ),
          const SizedBox(height: 8),
          const Text(
            'Jeśli kamera wymaga logowania, użyj adresu z loginem i hasłem kamery.',
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _preview, child: const Text('Sprawdź obraz')),
        ],
      ),
    );
  }
}

class _ReolinkSetupScreen extends StatefulWidget {
  const _ReolinkSetupScreen({required this.onSave});

  final SaveLocalCamera onSave;

  @override
  State<_ReolinkSetupScreen> createState() => _ReolinkSetupScreenState();
}

enum _ReolinkStep { identify, wifi, live }

class _ReolinkSetupScreenState extends State<_ReolinkSetupScreen> {
  final _pairing = const ReolinkPairing();
  final _uid = TextEditingController();
  final _ssid = TextEditingController();
  final _wifiPassword = TextEditingController();
  final _cameraPassword = TextEditingController();
  _ReolinkStep _step = _ReolinkStep.identify;
  bool _factory = true;
  bool _busy = false;
  String? _problem;
  String? _wifiResult;

  @override
  void dispose() {
    unawaited(_pairing.cancel().catchError((Object _) {}));
    _uid.dispose();
    _ssid.dispose();
    _wifiPassword.dispose();
    _cameraPassword.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() work) async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      await work();
    } on PlatformException catch (error) {
      if (mounted) setState(() => _problem = _friendlyError(error.code));
    } catch (_) {
      if (mounted) {
        setState(() => _problem = 'Nie udało się wykonać tego kroku.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _friendlyError(String code) => switch (code) {
    'unsupported' => 'Parowanie Reolink wymaga Androida 10 lub nowszego.',
    'bluetoothOff' => 'Włącz Bluetooth i spróbuj ponownie.',
    'permissions' =>
      'Zezwól SafeHood na dostęp do urządzeń w pobliżu. Na starszym Androidzie włącz lokalizację i udziel zgody.',
    'scanFailed' =>
      'Android nie uruchomił wyszukiwania Bluetooth. Spróbuj za chwilę.',
    'notFoundBle' =>
      'Nie znaleziono kamery z tym kodem. Sprawdź etykietę i tryb konfiguracji kamery.',
    'ambiguous' =>
      'Więcej niż jedna kamera zgłasza ten kod. Wyłącz pozostałe kamery i spróbuj ponownie.',
    'selectionExpired' => 'Wybór kamery wygasł. Wyszukaj ją jeszcze raz.',
    'wifiRejected' =>
      'Kamera nie przyjęła ustawień Wi-Fi. Sprawdź nazwę sieci, hasło i pasmo 2,4 GHz.',
    'notLocalNetwork' => 'Połącz telefon z domowym Wi-Fi i spróbuj ponownie.',
    'notFoundLan' =>
      'Nie widzę tej kamery w domowym Wi-Fi. Odczekaj chwilę i spróbuj ponownie na tej samej sieci.',
    'authFailed' =>
      'Kamera odrzuciła logowanie lokalne. Jeśli hasło już ustawiono, wybierz tę opcję i wpisz je.',
    'unsupportedFirmware' =>
      'Ta wersja kamery nie odpowiedziała na lokalną konfigurację RTSP. Jeśli masz działający adres RTSP, dodaj go ręcznie.',
    'passwordUnconfirmed' =>
      'Nie udało się potwierdzić zmiany hasła. Jeśli kamera je przyjęła, wybierz „Mam hasło kamery” i wpisz to samo hasło.',
    'rtspNotReady' =>
      'Kamera nie potwierdziła włączenia RTSP. Spróbuj ponownie z jej aktualnym hasłem.',
    'httpRestoreFailed' =>
      'Nie udało się przywrócić poprzedniego stanu HTTP w kamerze. Sprawdź ustawienia portów przed dokończeniem konfiguracji.',
    'differentCamera' => 'Znalezione urządzenie nie pasuje do kodu z etykiety.',
    _ =>
      'Nie udało się połączyć z kamerą. Sprawdź, czy jest włączona i blisko telefonu.',
  };

  Future<void> _select() async {
    if (!isReolinkUid(_uid.text)) {
      setState(() => _problem = 'Wpisz 16-znakowy kod z etykiety kamery.');
      return;
    }
    await _run(() async {
      final found = await _pairing.select(normalizeReolinkUid(_uid.text));
      if (mounted && found) setState(() => _step = _ReolinkStep.wifi);
    });
  }

  Future<void> _connectWifi() async {
    if (!isCameraWifiSsid(_ssid.text) ||
        !isCameraWifiPassword(_wifiPassword.text)) {
      setState(
        () => _problem =
            'Sprawdź nazwę sieci i hasło Wi-Fi (minimum 8 znaków dla WPA).',
      );
      return;
    }
    await _run(() async {
      final reply = await _pairing.connectWifi(_ssid.text, _wifiPassword.text);
      if (!mounted) return;
      _wifiPassword.clear();
      setState(() {
        _step = _ReolinkStep.live;
        _wifiResult = reply == 'accepted'
            ? 'Kamera przyjęła ustawienia Wi-Fi. Teraz sprawdzimy ją w domowej sieci.'
            : 'Kamera rozłączyła Bluetooth bez potwierdzenia. Sprawdzimy, czy pojawiła się w domowej sieci.';
      });
    });
  }

  Future<void> _openLive() async {
    final password = _cameraPassword.text;
    if (_factory ? !isNewReolinkPassword(password) : password.isEmpty) {
      setState(
        () => _problem = _factory
            ? 'Ustaw 8–31 znaków ASCII, w tym literę i cyfrę, bez spacji.'
            : 'Wpisz lokalne hasło konta admin kamery.',
      );
      return;
    }
    await _run(() async {
      final source = await _pairing.prepareStream(
        normalizeReolinkUid(_uid.text),
        password,
        factory: _factory,
      );
      if (!mounted) return;
      _cameraPassword.clear();
      setState(() => _factory = false);
      final saved = await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (_) => LocalCameraPreview(
            source: source,
            onSave: (source, location) => widget.onSave(
              LocalCameraRegistration.fromPreview(
                source: source,
                location: location,
              ),
            ),
          ),
        ),
      );
      if (saved == true && mounted) Navigator.of(context).pop(true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final action = switch (_step) {
      _ReolinkStep.identify => ('Znajdź kamerę', _select),
      _ReolinkStep.wifi => ('Połącz kamerę z Wi-Fi', _connectWifi),
      _ReolinkStep.live => ('Znajdź kamerę i pokaż obraz', _openLive),
    };
    return Scaffold(
      appBar: AppBar(title: const Text('Znajdź kamerę z kodu')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(switch (_step) {
            _ReolinkStep.identify => '1 z 3 · Znajdź kamerę',
            _ReolinkStep.wifi => '2 z 3 · Domowe Wi-Fi',
            _ReolinkStep.live => '3 z 3 · Podgląd',
          }, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          if (_step == _ReolinkStep.identify) ...[
            const Text(
              'Włącz kamerę w trybie pierwszej konfiguracji. Trzymaj ją blisko telefonu. '
              'Jeśli kamera była już ustawiana, użyj trybu parowania opisanego w jej instrukcji.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _uid,
              enabled: !_busy,
              textCapitalization: TextCapitalization.characters,
              autocorrect: false,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Kod z etykiety'),
            ),
            TextButton(
              onPressed: _busy || !isReolinkUid(_uid.text)
                  ? null
                  : () => setState(() {
                      _step = _ReolinkStep.live;
                      _factory = false;
                      _wifiResult = null;
                    }),
              child: const Text('Kamera jest już w mojej sieci'),
            ),
          ],
          if (_step == _ReolinkStep.wifi) ...[
            const Text(
              'Kamera została znaleziona. Wpisz dokładną nazwę domowego Wi-Fi '
              '(użyj sieci 2,4 GHz, jeśli kamera jej wymaga).',
            ),
            TextField(
              controller: _ssid,
              enabled: !_busy,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Nazwa domowego Wi-Fi',
              ),
            ),
            _passwordField(_wifiPassword, 'Hasło do Wi-Fi'),
          ],
          if (_step == _ReolinkStep.live) ...[
            if (_wifiResult case final message?) Text(message),
            const Text('Telefon musi być w tej samej sieci Wi-Fi co kamera.'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Mam już lokalne hasło kamery'),
              value: !_factory,
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _factory = !value),
            ),
            if (_factory)
              const Text(
                'Ustaw nowe hasło konta admin kamery. Użyj zaufanej sieci domowej i hasła innego niż hasło Wi-Fi.',
              ),
            _passwordField(
              _cameraPassword,
              _factory ? 'Nowe hasło kamery' : 'Hasło kamery (admin)',
            ),
          ],
          if (_problem case final problem?) ...[
            const SizedBox(height: 12),
            Text(
              problem,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 16),
          if (_busy) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
            const Text('Łączę z kamerą…'),
          ],
          FilledButton(
            onPressed: _busy ? null : action.$2,
            child: Text(action.$1),
          ),
          if (_step != _ReolinkStep.identify)
            TextButton(
              onPressed: _busy
                  ? null
                  : () {
                      unawaited(_pairing.cancel().catchError((Object _) {}));
                      _wifiPassword.clear();
                      _cameraPassword.clear();
                      setState(() {
                        _step = _ReolinkStep.identify;
                        _factory = true;
                        _problem = null;
                      });
                    },
              child: const Text('Wróć do wyboru kamery'),
            ),
        ],
      ),
    );
  }

  Widget _passwordField(TextEditingController controller, String label) =>
      TextField(
        controller: controller,
        enabled: !_busy,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(labelText: label),
      );
}

bool get supportsLocalCameraSetup =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
