import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum _Step { discover, join, inspect, configure, reboot, finish }

enum CameraPairingResult { findOnHomeNetwork, saved }

class _Hotspot {
  const _Hotspot(this.name, this.bssid, this.security);

  final String name;
  final String bssid;
  final String security;

  bool get isOpen => security == 'open';

  bool get isRobotCamera => RegExp(
    r'^robot[_-]?[0-9a-f]{4,12}$',
    caseSensitive: false,
  ).hasMatch(name);

  bool get resemblesCamera =>
      isRobotCamera ||
      RegExp(
        r'^(?:camerahd|camera|ipcam|ipc|reolink|nvt|tapo)[-_][\w-]+$',
        caseSensitive: false,
      ).hasMatch(name);
}

class CameraPairingScreen extends StatefulWidget {
  const CameraPairingScreen({
    super.key,
    this.startImmediately = false,
    this.setupWithLabel,
  });

  final bool startImmediately;
  final WidgetBuilder? setupWithLabel;

  @override
  State<CameraPairingScreen> createState() => _CameraPairingScreenState();
}

class _CameraPairingScreenState extends State<CameraPairingScreen> {
  static const _channel = MethodChannel('safehood/camera_hotspot_pairing');

  final _hotspotPassword = TextEditingController();
  final _cameraUser = TextEditingController();
  final _cameraPassword = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _homeName = TextEditingController();
  final _homePassword = TextEditingController();

  _Step _step = _Step.discover;
  List<_Hotspot> _networks = const [];
  _Hotspot? _selected;
  bool _scanned = false;
  bool _fresh = false;
  bool _acknowledged = false;
  String _cameraLabel = 'Kamera';
  String? _progress;
  String? _error;
  String? _errorCode;

  bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    if (widget.startImmediately && _supported) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_scan());
      });
    }
  }

  @override
  void dispose() {
    if (_supported) {
      unawaited(_disconnect());
    }
    for (final controller in [
      _hotspotPassword,
      _cameraUser,
      _cameraPassword,
      _host,
      _port,
      _homeName,
      _homePassword,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _disconnect() async {
    try {
      await _channel.invokeMethod<void>('disconnect');
    } on MissingPluginException {
      // For example, during a Flutter restart before the native channel exists.
    } on PlatformException {
      // Android also releases the connection when its Flutter engine closes.
    }
  }

  Future<void> _run(String label, Future<void> Function() action) async {
    if (_progress != null) return;
    setState(() {
      _progress = label;
      _error = null;
      _errorCode = null;
    });
    try {
      await action();
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _errorCode = error.code;
        _error = _message(error.code);
        if (_step == _Step.configure) {
          if (error.code == 'hotspotLost') _step = _Step.join;
          if (error.code == 'cameraAuth' || error.code == 'dvripAuth') {
            _step = _Step.inspect;
          }
        }
      });
    } on MissingPluginException {
      if (mounted) {
        setState(() => _error = _message('unsupportedPlatform'));
      }
    } finally {
      if (mounted) {
        setState(() => _progress = null);
      }
    }
  }

  Future<void> _scan() => _run('Szukam sieci w pobliżu…', () async {
    final result = await _channel.invokeMapMethod<String, Object?>('scan');
    if (!mounted || result == null) return;

    final networks = <_Hotspot>[];
    for (final item in result['networks'] as List<Object?>? ?? const []) {
      if (item is Map<Object?, Object?>) {
        final ssid = item['ssid'];
        final bssid = item['bssid'];
        final security = item['security'];
        if (ssid is String && bssid is String && security is String) {
          networks.add(_Hotspot(ssid, bssid, security));
        }
      }
    }
    setState(() {
      _scanned = true;
      _fresh = result['fresh'] == true;
      _networks = networks;
      _homeName.text = result['homeSsid'] as String? ?? '';
    });
  });

  void _select(_Hotspot network) {
    _hotspotPassword.clear();
    _cameraUser.clear();
    _cameraPassword.clear();
    _host.clear();
    _port.clear();
    _homePassword.clear();
    setState(() {
      _selected = network;
      _step = _Step.join;
      _error = null;
      _errorCode = null;
    });
    if (network.isOpen && widget.startImmediately) unawaited(_connect());
  }

  Future<void> _connect() => _run('Czekam na połączenie z kamerą…', () async {
    final network = _selected!;
    final password = _hotspotPassword.text;
    _hotspotPassword.clear();
    await _channel.invokeMethod<void>('connect', {
      'bssid': network.bssid,
      'password': password,
    });
    if (!mounted) return;
    setState(() {
      _step = _Step.inspect;
      _progress = 'Sprawdzam, jak połączyć kamerę z Wi‑Fi…';
    });
    await _inspectCamera();
  });

  Future<void> _inspectCamera() async {
    final portText = _port.text.trim();
    final port = int.tryParse(portText);
    if (portText.isNotEmpty && (port == null || port < 1 || port > 65535)) {
      throw PlatformException(code: 'invalidAddress');
    }
    final password = _cameraPassword.text;
    _cameraPassword.clear();
    final host = _host.text.trim();
    final args = {
      'username': _cameraUser.text.trim(),
      'password': password,
      'host': host,
      'port': port,
    };
    String? label;
    if (host.isEmpty && port == null && _selected?.isRobotCamera == true) {
      try {
        // Read-only: firmware using this pairing profile is verified again by
        // the native client before it is allowed to receive home Wi-Fi data.
        label = await _channel.invokeMethod<String>('inspectDvrip', args);
      } on PlatformException catch (error) {
        if (!const {
          'dvripProfile',
          'dvripRead',
          'cameraConnection',
        }.contains(error.code)) {
          rethrow;
        }
      }
    }
    if (!mounted) return;
    label ??= await _channel.invokeMethod<String>('inspect', args);
    if (!mounted || label == null) return;
    setState(() {
      _cameraLabel = label!.replaceAll(RegExp(r'\s*\((?:ONVIF|DVRIP)\)$'), '');
      _step = _Step.configure;
    });
  }

  Future<void> _configure() => _run('Przekazuję ustawienia kamerze…', () async {
    final ssid = _homeName.text;
    final password = _homePassword.text;
    if (ssid.trim().isEmpty ||
        utf8.encode(ssid).length > 32 ||
        !RegExp(r'^(?:[ -~]{8,63}|[0-9a-fA-F]{64})$').hasMatch(password)) {
      throw PlatformException(code: 'invalidHomeWifi');
    }
    if (ssid == _selected?.name) {
      throw PlatformException(code: 'sameSsid');
    }
    _homePassword.clear();
    final result = await _channel.invokeMethod<String>('configure', {
      'ssid': ssid,
      'password': password,
    });
    if (!mounted) return;
    setState(() {
      _acknowledged = result == 'ACCEPTED' || result == 'REBOOT_NEEDED';
      _step = result == 'REBOOT_NEEDED' ? _Step.reboot : _Step.finish;
    });
    if (widget.startImmediately) {
      if (result == 'REBOOT_NEEDED') {
        setState(() => _progress = 'Uruchamiam ponownie kamerę…');
        await _channel.invokeMethod<String>('reboot');
        if (!mounted) return;
      }
      await _findInHomeNetwork();
    }
  });

  Future<void> _reboot() => _run('Uruchamiam ponownie kamerę…', () async {
    await _channel.invokeMethod<String>('reboot');
    if (!mounted) return;
    if (widget.startImmediately) {
      await _findInHomeNetwork();
    } else {
      setState(() => _step = _Step.finish);
    }
  });

  Future<void> _findInHomeNetwork() async {
    await _disconnect();
    if (mounted) {
      Navigator.of(context).pop(CameraPairingResult.findOnHomeNetwork);
    }
  }

  Future<void> _useLabel() async {
    final builder = widget.setupWithLabel;
    if (builder == null) return;
    final saved = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute<bool>(builder: builder));
    if (saved == true && mounted) {
      Navigator.of(context).pop(CameraPairingResult.saved);
    }
  }

  Future<void> _openSettings({bool location = false}) =>
      _run('Otwieram ustawienia…', () async {
        await _channel.invokeMethod<void>(
          location ? 'locationSettings' : 'wifiSettings',
        );
      });

  String _message(String code) => switch (code) {
    'wifiOff' => 'Włącz Wi-Fi na telefonie i ponów wyszukiwanie.',
    'locationOff' =>
      'Włącz lokalizację telefonu. Android wymaga jej do skanowania Wi-Fi.',
    'locationPermission' =>
      'Zezwól SafeHood na dokładną lokalizację podczas używania aplikacji. '
          'Android wymaga tego uprawnienia do pokazania listy sieci.',
    'nearbyPermission' =>
      'Zezwól na dostęp do urządzeń w pobliżu, aby połączyć się z kamerą.',
    'hotspotUnavailable' =>
      'Telefon nie połączył się z hotspotem. Sprawdź tryb parowania kamery '
          'i zaakceptuj połączenie w oknie Androida.',
    'hotspotLost' =>
      'Utracono połączenie z hotspotem. Sprawdź, czy kamera nadal '
          'jest w trybie parowania.',
    'apPassword' => 'Wpisz hasło do hotspotu z instrukcji kamery.',
    'scanAgain' => 'Odśwież listę sieci i wybierz ponownie hotspot kamery.',
    'onvifNotFound' =>
      'Nie rozpoznano kamery w wybranej sieci. Sprawdź, czy to sieć Twojej kamery.',
    'cameraAuth' || 'dvripAuth' => 'Kamera wymaga poprawnego loginu i hasła.',
    'dvripRead' || 'onvifRead' => 'Nie udało się odczytać ustawień kamery.',
    'dvripProfile' ||
    'noOnvifWifi' => 'SafeHood nie może ustawić Wi‑Fi w tej wersji kamery.',
    'dvripDhcp' => 'Nie potwierdzono oczekiwanych ustawień DHCP kamery.',
    'dvripWrite' => 'Kamera odrzuciła zapis ustawień Wi‑Fi.',
    'ambiguousWifi' =>
      'Kamera zgłasza kilka konfiguracji Wi-Fi. Wybierz właściwą sieć '
          'w konfiguratorze producenta.',
    'invalidAddress' =>
      'Podaj lokalny adres IPv4 kamery w jej hotspocie oraz poprawny port.',
    'invalidHomeWifi' =>
      'Wpisz nazwę sieci (do 32 bajtów) i hasło WPA2 (8–63 znaki ASCII '
          'lub klucz z 64 znaków szesnastkowych).',
    'sameSsid' => 'Wpisz nazwę domowego Wi-Fi, inną niż hotspot kamery.',
    'onvifWrite' =>
      'Kamera odrzuciła ustawienia. Sprawdź, czy obsługuje domowe Wi-Fi '
          'i czy dane logowania pozwalają zmienić jej ustawienia.',
    'unsupportedPlatform' =>
      'Wyszukiwanie hotspotów w SafeHood jest dostępne od Androida 10. '
          'Skonfiguruj Wi-Fi w aplikacji producenta, potem wykryj kamerę '
          'w domowej sieci.',
    _ => 'Nie udało się zakończyć tego kroku. Spróbuj ponownie.',
  };

  @override
  Widget build(BuildContext context) {
    final busy = _progress != null;
    final theme = Theme.of(context);
    return PopScope(
      canPop: !busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Sparuj nową kamerę')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              if (!_supported)
                Text(_message('unsupportedPlatform'))
              else ...[
                if (_progress case final String progress) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(progress),
                  const SizedBox(height: 16),
                ],
                if (_error case final String error) ...[
                  Text(error, style: TextStyle(color: theme.colorScheme.error)),
                  const SizedBox(height: 12),
                  if (_errorCode == 'wifiOff')
                    OutlinedButton(
                      onPressed: busy ? null : () => _openSettings(),
                      child: const Text('Otwórz ustawienia Wi-Fi'),
                    ),
                  if (_errorCode == 'locationOff')
                    OutlinedButton(
                      onPressed: busy
                          ? null
                          : () => _openSettings(location: true),
                      child: const Text('Otwórz ustawienia lokalizacji'),
                    ),
                ],
                ...switch (_step) {
                  _Step.discover => _discovery(busy),
                  _Step.join => _join(busy),
                  _Step.inspect => _inspection(busy),
                  _Step.configure => _configuration(busy),
                  _Step.reboot => _restart(busy),
                  _Step.finish => _finish(busy),
                },
              ],
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _discovery(bool busy) {
    final suggested = _networks.where((network) => network.resemblesCamera);
    final others = _networks.where((network) => !network.resemblesCamera);
    return [
      const Text(
        'Włącz w kamerze tryb parowania zgodnie z jej instrukcją. '
        'Jeśli kamera tworzy własną sieć Wi-Fi, znajdziesz ją na liście.',
      ),
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: busy ? null : _scan,
        icon: const Icon(Icons.wifi_find),
        label: Text(_scanned ? 'Odśwież sieci' : 'Wyszukaj sieć kamery'),
      ),
      if (_scanned && !_fresh)
        const Text('Android zwrócił poprzednią listę. Odśwież ją za chwilę.'),
      if (_networks.isNotEmpty) ...[
        const SizedBox(height: 16),
        const Text(
          'Sieci w pobliżu. Wybierz tylko tę, która należy do Twojej kamery.',
        ),
        for (final network in suggested) _networkTile(network, busy),
        if (others.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Pokaż inne sieci w pobliżu'),
            children: [
              for (final network in others) _networkTile(network, busy),
            ],
          ),
      ] else if (_scanned) ...[
        const SizedBox(height: 16),
        const Text(
          'Nie znaleziono sieci kamery. Zbliż telefon do kamery i ponów wyszukiwanie.',
        ),
      ],
      const SizedBox(height: 12),
      if (widget.setupWithLabel != null)
        TextButton.icon(
          onPressed: busy ? null : _useLabel,
          icon: const Icon(Icons.qr_code),
          label: const Text('Mam kod z etykiety kamery'),
        ),
    ];
  }

  Widget _networkTile(_Hotspot network, bool busy) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(network.isOpen ? Icons.wifi : Icons.wifi_lock),
    title: Text(network.name),
    subtitle: _networks.where((item) => item.name == network.name).length > 1
        ? Text(network.bssid)
        : null,
    trailing: const Icon(Icons.chevron_right),
    enabled: !busy,
    onTap: busy ? null : () => _select(network),
  );

  List<Widget> _join(bool busy) => [
    Text('Sieć kamery: ${_selected!.name}'),
    const SizedBox(height: 12),
    if (!_selected!.isOpen)
      _input(_hotspotPassword, 'Hasło do sieci kamery', busy, secret: true),
    const Text('Zaakceptuj tymczasowe połączenie w oknie Androida.'),
    FilledButton(
      onPressed: busy ? null : _connect,
      child: const Text('Połącz z siecią kamery'),
    ),
    TextButton(
      onPressed: busy
          ? null
          : () => setState(() {
              _step = _Step.discover;
              _error = null;
              _errorCode = null;
            }),
      child: const Text('Wybierz inną sieć'),
    ),
  ];

  List<Widget> _inspection(bool busy) {
    if (busy) return const [];
    final credentials = [
      _input(_cameraUser, 'Użytkownik kamery', busy),
      _input(_cameraPassword, 'Hasło kamery', busy, secret: true),
    ];
    return [
      if (_errorCode == 'cameraAuth' || _errorCode == 'dvripAuth') ...[
        const Text(
          'Użyj danych ustawionych w kamerze lub podanych w jej instrukcji.',
        ),
        const SizedBox(height: 12),
        ...credentials,
      ] else
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Mam dane do kamery'),
          children: credentials,
        ),
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: const Text('Adres kamery (zaawansowane)'),
        children: [
          _input(_host, 'Adres IPv4 kamery', busy),
          _input(_port, 'Port (opcjonalnie)', busy, number: true),
        ],
      ),
      FilledButton(
        onPressed: busy
            ? null
            : () => _run('Sprawdzam kamerę…', _inspectCamera),
        child: const Text('Sprawdź kamerę'),
      ),
      if (_errorCode == 'hotspotLost')
        TextButton(
          onPressed: busy
              ? null
              : () => setState(() {
                  _step = _Step.join;
                  _error = null;
                  _errorCode = null;
                }),
          child: const Text('Połącz ponownie z siecią kamery'),
        ),
    ];
  }

  List<Widget> _configuration(bool busy) => [
    Text('Kamera: $_cameraLabel'),
    const SizedBox(height: 8),
    const Text(
      'Wpisz hasło sieci, z której ma korzystać kamera. Podczas łączenia '
      'kamera może się na chwilę rozłączyć lub uruchomić ponownie.',
    ),
    const SizedBox(height: 16),
    _input(_homeName, 'Nazwa domowego Wi-Fi', busy),
    _input(_homePassword, 'Hasło domowego Wi-Fi', busy, secret: true),
    Text(
      _selected!.isOpen
          ? 'Hasło zostanie wysłane bezpośrednio do kamery przez otwarty '
                'hotspot. Dane nie są szyfrowane podczas tej operacji.'
          : 'Hasło zostanie wysłane bezpośrednio do kamery przez jej sieć. '
                'SafeHood go nie zapisuje.',
    ),
    const SizedBox(height: 8),
    FilledButton(
      onPressed: busy ? null : _configure,
      child: const Text('Połącz kamerę z Wi‑Fi'),
    ),
  ];

  List<Widget> _restart(bool busy) => [
    const Text('Kamera przyjęła ustawienia i wymaga ponownego uruchomienia.'),
    FilledButton(
      onPressed: busy ? null : _reboot,
      child: const Text('Uruchom kamerę ponownie'),
    ),
    TextButton(
      onPressed: busy
          ? null
          : () => _run('Rozłączam hotspot kamery…', () async {
              await _disconnect();
              if (mounted) setState(() => _step = _Step.finish);
            }),
      child: const Text('Uruchomiłem ją ponownie samodzielnie'),
    ),
  ];

  List<Widget> _finish(bool busy) => [
    Text(
      _acknowledged
          ? 'Kamera przyjęła konfigurację.'
          : 'Nie otrzymaliśmy potwierdzenia. Kamera mogła wyłączyć hotspot '
                'podczas zmiany sieci.',
    ),
    const SizedBox(height: 8),
    const Text(
      'Sprawdź, czy telefon wrócił do domowego Wi-Fi. Daj kamerze chwilę '
      'na dołączenie, a następnie ją wyszukaj.',
    ),
    TextButton(
      onPressed: busy ? null : () => _openSettings(),
      child: const Text('Otwórz ustawienia Wi-Fi'),
    ),
    FilledButton.icon(
      onPressed: busy ? null : _findInHomeNetwork,
      icon: const Icon(Icons.search),
      label: const Text('Wykryj kamerę w sieci domowej'),
    ),
  ];

  Widget _input(
    TextEditingController controller,
    String label,
    bool busy, {
    bool secret = false,
    bool number = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: controller,
      enabled: !busy,
      obscureText: secret,
      enableSuggestions: false,
      autocorrect: false,
      keyboardType: number ? TextInputType.number : TextInputType.text,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    ),
  );
}
