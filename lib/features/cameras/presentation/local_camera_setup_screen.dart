import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/camera_discovery_service.dart';
import '../data/local_camera_connection.dart';
import '../data/local_camera_registration.dart';
import '../data/local_camera_store.dart';
import '../domain/camera.dart';
import 'camera_pairing_screen.dart';
import 'local_camera_preview.dart';

enum LocalCameraSetupResult { saved }

class LocalCameraSetupScreen extends StatelessWidget {
  const LocalCameraSetupScreen({
    super.key,
    required this.onSave,
    this.savedSource,
  });

  final SaveLocalCamera onSave;
  final LocalCameraSource? savedSource;

  Future<void> _open(BuildContext context, Widget child) async {
    final saved = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute<bool>(builder: (_) => child));
    if (saved == true && context.mounted) {
      Navigator.of(context).pop(LocalCameraSetupResult.saved);
    }
  }

  @override
  Widget build(BuildContext context) {
    final saved = savedSource;
    if (saved != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Przenieś kamerę')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(saved.name, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text('Zapisany podgląd: ${saved.uri.host}'),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.wifi_find),
              title: const Text('Wykryj ONVIF tej kamery'),
              subtitle: const Text(
                'Zachowaj obraz i umożliw przypisanie kamery do Bridge.',
              ),
              onTap: () => _open(
                context,
                _LocalOnvifScreen(onSave: onSave, savedSource: saved),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.videocam_outlined),
              title: const Text('Przenieś sam podgląd RTSP'),
              subtitle: const Text('Obraz bez monitoringu przez Bridge.'),
              onTap: () => _open(
                context,
                LocalCameraPreview(
                  source: saved,
                  refreshSource: true,
                  onSave: (source, location) => onSave(
                    LocalCameraRegistration.fromPreview(
                      source: source,
                      location: location,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Skonfiguruj kamerę')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Nowa kamera', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.bluetooth),
              title: const Text('Reolink przez Bluetooth'),
              subtitle: const Text(
                'E1 Pro / E330 w wersji z Bluetooth · pilotaż',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _open(context, _ReolinkSetupScreen(onSave: onSave)),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.wifi_protected_setup),
              title: const Text('Hotspot kamery (ONVIF lub DVRIP)'),
              subtitle: const Text(
                'Połącz kamerę z domowym Wi-Fi i sprawdź obraz',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                final discover = await Navigator.of(context).push<bool>(
                  MaterialPageRoute<bool>(
                    builder: (_) => const CameraPairingScreen(),
                  ),
                );
                if (discover == true && context.mounted) {
                  await _open(context, _LocalOnvifScreen(onSave: onSave));
                }
              },
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Kamera już w domowej sieci',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.wifi_find),
              title: const Text('Wykryj kamerę ONVIF'),
              subtitle: const Text('Znajdź kamerę połączoną z tą samą siecią'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _open(context, _LocalOnvifScreen(onSave: onSave)),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.link),
              title: const Text('Wpisz adres RTSP'),
              subtitle: const Text(
                'Sprawdź obraz i dodaj kamerę do swojej listy',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () =>
                  _open(context, _ManualLocalCameraScreen(onSave: onSave)),
            ),
          ),
        ],
      ),
    );
  }
}

class _LocalOnvifScreen extends StatefulWidget {
  const _LocalOnvifScreen({required this.onSave, this.savedSource});

  final SaveLocalCamera onSave;
  final LocalCameraSource? savedSource;

  @override
  State<_LocalOnvifScreen> createState() => _LocalOnvifScreenState();
}

class _LocalOnvifScreenState extends State<_LocalOnvifScreen> {
  late Future<List<DetectedCamera>> _cameras = _discover();

  Future<List<DetectedCamera>> _discover() async {
    final savedHost = widget.savedSource?.uri.host;
    final devices = await CameraDiscoveryService().discoverCameras();
    return devices
        .where((camera) {
          final address = camera.ipAddress;
          return address != null &&
              (savedHost == null || address == savedHost) &&
              parseLocalRtsp('rtsp://$address/') != null &&
              camera.connectionType == CameraConnectionType.onvif;
        })
        .toList(growable: false);
  }

  Future<void> _open(DetectedCamera camera) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => _LocalOnvifConnection(
          onSave: widget.onSave,
          camera: camera,
          savedSource: widget.savedSource,
        ),
      ),
    );
    if (saved == true && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Kamery ONVIF w sieci')),
    body: FutureBuilder<List<DetectedCamera>>(
      future: _cameras,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final cameras = snapshot.data ?? [];
        final saved = widget.savedSource;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (cameras.isEmpty)
              const Text(
                'Nie znaleziono kamery ONVIF. Sprawdź Wi-Fi i włącz ONVIF w kamerze.',
              ),
            for (final camera in cameras)
              ListTile(
                leading: const Icon(Icons.videocam_outlined),
                title: Text(camera.displayName),
                subtitle: Text(camera.ipAddress!),
                onTap: () => _open(camera),
              ),
            OutlinedButton(
              onPressed: () => setState(() => _cameras = _discover()),
              child: const Text('Szukaj ponownie'),
            ),
            if (saved != null)
              TextButton(
                onPressed: () => _open(
                  DetectedCamera(
                    deviceId: 'onvif-${saved.uri.host}',
                    displayName: saved.name,
                    brand: 'Nieznany producent',
                    model: 'Nieznany model',
                    ipAddress: saved.uri.host,
                    connectionType: CameraConnectionType.onvif,
                  ),
                ),
                child: const Text('Podaj adres ONVIF tej kamery'),
              ),
          ],
        );
      },
    ),
  );
}

class _LocalOnvifConnection extends StatefulWidget {
  const _LocalOnvifConnection({
    required this.onSave,
    required this.camera,
    this.savedSource,
  });

  final SaveLocalCamera onSave;
  final DetectedCamera camera;
  final LocalCameraSource? savedSource;

  @override
  State<_LocalOnvifConnection> createState() => _LocalOnvifConnectionState();
}

class _LocalOnvifConnectionState extends State<_LocalOnvifConnection> {
  final _user = TextEditingController();
  final _password = TextEditingController();
  late final _endpoint = TextEditingController(text: _defaultEndpoint());
  bool _busy = false;
  String? _problem;

  String _defaultEndpoint() {
    final camera = widget.camera;
    final advertised = parseManualOnvifUri(camera.onvifServiceUrl ?? '');
    if (advertised != null &&
        advertised.scheme == 'http' &&
        advertised.host == camera.ipAddress &&
        advertised.userInfo.isEmpty) {
      return advertised.toString();
    }
    final port = [
      8899,
      80,
      8080,
      8000,
    ].firstWhere(camera.openPorts.contains, orElse: () => 80);
    return 'http://${camera.ipAddress}:$port/onvif/device_service';
  }

  @override
  void dispose() {
    _user.dispose();
    _password.dispose();
    _endpoint.dispose();
    super.dispose();
  }

  Future<void> _preview() async {
    if (_busy) return;
    final endpoint = parseManualOnvifUri(_endpoint.text);
    if (endpoint == null ||
        endpoint.scheme != 'http' ||
        endpoint.host != widget.camera.ipAddress) {
      setState(
        () => _problem = 'Wpisz adres HTTP usługi ONVIF dla tej kamery.',
      );
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      final user = _user.text.trim();
      final password = _password.text;
      final uri = await const LocalCameraPlayer()
          .resolveOnvif(endpoint, user, password)
          .timeout(const Duration(seconds: 24));
      if (!mounted) return;
      final saved = await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (_) => LocalCameraPreview(
            source:
                widget.savedSource ??
                LocalCameraSource(name: widget.camera.displayName, uri: uri),
            onSave: (source, location) => widget.onSave(
              LocalCameraRegistration.fromPreview(
                source: source,
                location: location,
                detected: widget.camera,
                onvifEndpoint: endpoint,
                login: user.isEmpty ? null : CameraLogin(user, password),
              ),
            ),
          ),
        ),
      );
      if (saved == true && mounted) Navigator.of(context).pop(true);
    } on PlatformException catch (error) {
      if (mounted) {
        setState(
          () => _problem = switch (error.code) {
            'cameraAuth' => 'Sprawdź lokalny login i hasło ONVIF kamery.',
            'notLocalNetwork' => 'Połącz telefon z Wi-Fi kamery.',
            _ =>
              'Kamera nie podała adresu RTSP. Sprawdź ustawienia ONVIF lub wpisz adres RTSP ręcznie.',
          },
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _problem = 'Nie udało się znaleźć obrazu z tej kamery.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.camera.displayName)),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Jeśli kamera wymaga logowania, wpisz dane jej lokalnego konta ONVIF.',
        ),
        TextField(
          controller: _user,
          enabled: !_busy,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'Użytkownik ONVIF'),
        ),
        TextField(
          controller: _password,
          enabled: !_busy,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(labelText: 'Hasło ONVIF'),
        ),
        const SizedBox(height: 8),
        ExpansionTile(
          title: const Text('Adres usługi ONVIF'),
          initiallyExpanded:
              widget.camera.onvifServiceUrl == null &&
              widget.savedSource != null,
          children: [
            TextField(
              controller: _endpoint,
              enabled: !_busy,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Adres HTTP kamery'),
            ),
          ],
        ),
        if (_problem case final problem?) Text(problem),
        if (_busy) const LinearProgressIndicator(),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _busy ? null : _preview,
          child: const Text('Sprawdź obraz'),
        ),
      ],
    ),
  );
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
      'Nie znaleziono tego UID przez Bluetooth. Sprawdź etykietę i tryb parowania kamery.',
    'ambiguous' =>
      'Więcej niż jedno urządzenie zgłasza ten UID. Wyłącz pozostałe kamery i ponów próbę.',
    'selectionExpired' =>
      'Wybór kamery wygasł. Wróć do wyszukiwania przez Bluetooth.',
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
    'differentCamera' =>
      'Identyfikator w domowej sieci nie zgadza się z UID z etykiety.',
    _ =>
      'Nie udało się połączyć z kamerą. Sprawdź, czy jest włączona i blisko telefonu.',
  };

  Future<void> _select() async {
    if (!isReolinkUid(_uid.text)) {
      setState(() => _problem = 'Wpisz 16 znaków UID z etykiety kamery.');
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
      _ReolinkStep.identify => ('Znajdź kamerę po UID', _select),
      _ReolinkStep.wifi => ('Połącz kamerę z Wi-Fi', _connectWifi),
      _ReolinkStep.live => ('Znajdź kamerę i pokaż obraz', _openLive),
    };
    return Scaffold(
      appBar: AppBar(title: const Text('Konfiguracja Reolink')),
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
              decoration: const InputDecoration(labelText: 'UID z etykiety'),
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
              '(dla tego pilotażu użyj sieci 2,4 GHz).',
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
