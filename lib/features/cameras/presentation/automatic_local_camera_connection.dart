import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/camera_discovery_service.dart';
import '../data/local_camera_auto_setup.dart';
import '../data/local_camera_connection.dart';
import '../data/local_camera_registration.dart';
import '../data/local_camera_store.dart';
import 'local_camera_preview.dart';

class AutomaticLocalCameraConnection extends StatefulWidget {
  const AutomaticLocalCameraConnection({
    super.key,
    required this.discovery,
    required this.onSave,
    required this.onSaved,
    this.device,
    this.savedSource,
  }) : assert(device != null || savedSource != null);

  final CameraDiscoveryService discovery;
  final SaveLocalCamera onSave;
  final VoidCallback onSaved;
  final DetectedCamera? device;
  final LocalCameraSource? savedSource;

  @override
  State<AutomaticLocalCameraConnection> createState() =>
      _AutomaticLocalCameraConnectionState();
}

class _ConnectionPlan {
  const _ConnectionPlan({
    required this.source,
    required this.alternatives,
    required this.device,
    required this.endpoint,
    required this.login,
  });

  final LocalCameraSource source;
  final List<Uri> alternatives;
  final DetectedCamera? device;
  final Uri? endpoint;
  final CameraLogin? login;
}

class _AutomaticLocalCameraConnectionState
    extends State<AutomaticLocalCameraConnection> {
  final _user = TextEditingController();
  final _password = TextEditingController();
  final _player = const LocalCameraPlayer();
  late final Future<DetectedCamera?> _device = _findDevice();
  _ConnectionPlan? _plan;
  bool _busy = false;
  bool _askForLogin = false;
  String? _problem;

  String get _name =>
      widget.savedSource?.name ?? localCameraDisplayName(widget.device!);

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  @override
  void dispose() {
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<DetectedCamera?> _findDevice() async {
    if (widget.device case final device?) return device;
    final saved = widget.savedSource!;
    // A device with a known identifier may have moved to another address.
    // Leave that discovery to the player, which verifies the identifier.
    if (saved.reolinkUid != null) return null;
    try {
      return await widget.discovery
          .findLocalCamera(saved.uri.host)
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      return null;
    }
  }

  Future<void> _prepare({CameraLogin? enteredLogin}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _askForLogin = false;
      _problem = null;
      _plan = null;
    });
    final saved = widget.savedSource;
    try {
      final login = enteredLogin ?? localCameraStoredLogin(saved?.uri);
      final device = await _device;
      if (!mounted) return;
      // Only use discovered data for the selected peer. Never try stored
      // credentials on addresses belonging to other cameras in the list.
      final sameDevice =
          saved == null ||
          (device != null && device.ipAddress == saved.uri.host);
      final selected = sameDevice ? device : null;
      final endpoint = selected == null
          ? null
          : localCameraOnvifEndpoint(selected);
      Uri? resolved;
      if (endpoint != null) {
        try {
          final result = await _player
              .resolveOnvif(
                endpoint,
                login?.username ?? '',
                login?.password ?? '',
              )
              .timeout(const Duration(seconds: 24));
          if (result.host == endpoint.host) resolved = result;
        } on PlatformException catch (error) {
          if (error.code == 'cameraAuth' &&
              saved == null &&
              enteredLogin == null) {
            if (mounted) setState(() => _askForLogin = true);
            return;
          }
        } catch (_) {
          // A saved or independently verified stream may still work.
        }
      }
      if (!mounted) return;
      final streams = <Uri>{
        if (saved != null)
          enteredLogin == null
              ? saved.uri
              : applyCameraLogin(saved.uri.replace(userInfo: ''), enteredLogin),
        ?resolved,
        if (saved == null && selected != null)
          ...localCameraStreamCandidates(selected, login),
      };
      if (streams.isEmpty) {
        setState(() {
          _problem =
              'Nie udało się znaleźć obrazu. Sprawdź zasilanie i Wi‑Fi kamery.';
          _askForLogin = true;
        });
        return;
      }
      setState(() {
        _plan = _ConnectionPlan(
          source: LocalCameraSource(
            name: _name,
            uri: streams.first,
            reolinkUid: saved?.reolinkUid,
          ),
          alternatives: streams.skip(1).toList(),
          device: selected,
          endpoint: resolved == null ? null : endpoint,
          login: login?.username.isNotEmpty == true ? login : null,
        );
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _problem =
              'Nie udało się połączyć. Sprawdź zasilanie i Wi‑Fi kamery.';
          _askForLogin = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _editLogin() => setState(() {
    _plan = null;
    _askForLogin = true;
    _problem = null;
  });

  void _submitLogin() {
    final username = _user.text.trim();
    final password = _password.text;
    if (username.isEmpty) {
      setState(() => _problem = 'Wpisz nazwę użytkownika kamery.');
      return;
    }
    FocusScope.of(context).unfocus();
    _password.clear();
    unawaited(_prepare(enteredLogin: CameraLogin(username, password)));
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    if (plan != null) {
      return LocalCameraPreview(
        key: ValueKey(plan),
        source: plan.source,
        fallbackUris: plan.alternatives,
        refreshSource: plan.source.reolinkUid != null,
        onEditLogin: _editLogin,
        onSaved: widget.onSaved,
        onSave: (source, location) => widget.onSave(
          LocalCameraRegistration.fromPreview(
            source: source,
            location: location,
            detected: plan.device,
            onvifEndpoint: plan.endpoint,
            login: plan.login,
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(_name)),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (_busy) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
            const Text('Sprawdzam kamerę i szukam obrazu…'),
          ] else if (_askForLogin) ...[
            const Text(
              'Jeśli kamera jest zabezpieczona, wpisz jej dane logowania. '
              'To są dane kamery, osobne od konta SafeHood i domowego Wi‑Fi.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _user,
              autocorrect: false,
              enableSuggestions: false,
              maxLength: 128,
              decoration: const InputDecoration(labelText: 'Użytkownik kamery'),
            ),
            TextField(
              controller: _password,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              maxLength: 128,
              decoration: const InputDecoration(labelText: 'Hasło kamery'),
            ),
            FilledButton(
              onPressed: _submitLogin,
              child: const Text('Połącz z kamerą'),
            ),
            TextButton(
              onPressed: () =>
                  _prepare(enteredLogin: const CameraLogin('', '')),
              child: const Text('Spróbuj bez hasła'),
            ),
          ],
          if (_problem case final problem?) Text(problem),
        ],
      ),
    );
  }
}
