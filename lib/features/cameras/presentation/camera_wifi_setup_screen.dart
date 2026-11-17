import 'package:flutter/material.dart';

import '../data/local_camera_connection.dart';
import '../data/onvif_media_resolver.dart';
import '../data/onvif_wifi_setup.dart';
import '../domain/camera.dart';

class CameraWifiSetupScreen extends StatefulWidget {
  const CameraWifiSetupScreen({
    super.key,
    required this.camera,
    this.connection,
  });
  final Camera camera;
  final LocalCameraConnection? connection;

  @override
  State<CameraWifiSetupScreen> createState() => _CameraWifiSetupScreenState();
}

class _CameraWifiSetupScreenState extends State<CameraWifiSetupScreen> {
  final _ssid = TextEditingController();
  final _password = TextEditingController();
  OnvifWifiSetup? _setup;
  List<OnvifWifiInterface> _interfaces = const [];
  OnvifWifiInterface? _selected;
  List<String> _networks = const [];
  bool _busy = false;
  bool _hidden = true;
  String? _message;

  @override
  void initState() {
    super.initState();
    _inspect();
  }

  @override
  void dispose() {
    _ssid.dispose();
    _password.dispose();
    super.dispose();
  }

  String _explain(Object error) => error is CameraConnectionIssue
      ? error.message
      : 'Kamera nie potwierdziła operacji. Jeśli właśnie zapisywała ustawienia, '
            'może już zmieniać sieć. Wróć i spróbuj wykryć ją ponownie.';

  Future<void> _run(Future<void> Function() action) async {
    if (_busy || !mounted) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _message = _explain(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _inspect() => _run(() async {
    final connection =
        widget.connection ??
        await const LocalCameraConnectionStore().read(widget.camera.id);
    final device = await openOnvifDevice(
      connection.cameraWithLocalEndpoint(widget.camera),
      connection.login,
    );
    final setup = OnvifWifiSetup(device);
    final interfaces = await setup.inspect();
    if (!mounted) return;
    setState(() {
      _setup = setup;
      _interfaces = interfaces;
      _selected = interfaces.first;
    });
  });

  Future<void> _scan() => _run(() async {
    final networks = await _setup!.scan(_selected!);
    if (!mounted) return;
    setState(() {
      _networks = networks;
      if (networks.isEmpty) {
        _message =
            'Kamera nie znalazła sieci WPA2. Możesz wpisać nazwę ręcznie.';
      }
    });
  });

  Future<void> _connect() => _run(() async {
    final rebootNeeded = await _setup!.connect(
      wireless: _selected!,
      ssid: _ssid.text,
      password: _password.text,
    );
    if (!mounted) return;
    _password.clear();
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Kamera przyjęła ustawienia'),
        content: Text(
          '${rebootNeeded ? 'Kamera zgłasza, że wymaga ponownego uruchomienia. ' : ''}'
          'Połącz telefon z domowym Wi-Fi. Jeśli kamera ma osobne zasilanie, '
          'odłącz kabel LAN i wykryj ją ponownie. Kamera może dostać nowy adres IP.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (mounted) Navigator.pop(context, true);
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Połącz kamerę z Wi-Fi')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'SafeHood łączy się z kamerą w sieci lokalnej. Na czas ustawiania '
          'zostaw ją podłączoną przez LAN albo połącz telefon z siecią kamery.',
        ),
        if (_busy) ...[
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
        ],
        if (_message != null) ...[const SizedBox(height: 16), Text(_message!)],
        if (_setup == null && !_busy)
          TextButton(
            onPressed: _inspect,
            child: const Text('Sprawdź ponownie'),
          ),
        if (_setup != null) ...[
          const SizedBox(height: 20),
          if (_interfaces.length > 1)
            DropdownButtonFormField<OnvifWifiInterface>(
              initialValue: _selected,
              decoration: const InputDecoration(
                labelText: 'Interfejs Wi-Fi kamery',
              ),
              items: [
                for (final item in _interfaces)
                  DropdownMenuItem(value: item, child: Text(item.label)),
              ],
              onChanged: _busy
                  ? null
                  : (value) => setState(() {
                      _selected = value;
                      _networks = const [];
                    }),
            ),
          if (_setup!.canScan)
            OutlinedButton.icon(
              onPressed: _busy ? null : _scan,
              icon: const Icon(Icons.wifi_find),
              label: const Text('Pokaż sieci widoczne dla kamery'),
            ),
          if (_networks.isNotEmpty)
            Wrap(
              spacing: 8,
              children: [
                for (final ssid in _networks.take(20))
                  ActionChip(
                    label: Text(ssid),
                    onPressed: _busy ? null : () => _ssid.text = ssid,
                  ),
              ],
            ),
          TextField(
            controller: _ssid,
            enabled: !_busy,
            decoration: const InputDecoration(
              labelText: 'Dokładna nazwa sieci (SSID)',
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _password,
            enabled: !_busy,
            obscureText: _hidden,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'Hasło Wi-Fi (WPA2)',
              suffixIcon: IconButton(
                tooltip: _hidden ? 'Pokaż hasło' : 'Ukryj hasło',
                onPressed: () => setState(() => _hidden = !_hidden),
                icon: Icon(_hidden ? Icons.visibility : Icons.visibility_off),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _setup!.device.endpoint.scheme == 'http'
                ? 'Ta kamera używa HTTP. Hasło zostanie przesłane do niej bez szyfrowania w sieci lokalnej. SafeHood go nie zapisze.'
                : 'SafeHood przekaże hasło bezpośrednio kamerze i go nie zapisze.',
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy || _selected == null ? null : _connect,
            child: const Text('Przekaż ustawienia kamerze'),
          ),
        ],
      ],
    ),
  );
}
