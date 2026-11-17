import 'package:flutter/material.dart';

import '../data/local_camera_connection.dart';

Future<LocalCameraConnection?> showLocalCameraConnectionDialog(
  BuildContext context, {
  LocalCameraConnection initial = const LocalCameraConnection(),
  bool requireRtsp = false,
  bool allowOnvifOverride = false,
  String? rtspHint,
}) => showDialog<LocalCameraConnection>(
  context: context,
  builder: (_) => _ConnectionDialog(
    initial: initial,
    requireRtsp: requireRtsp,
    allowOnvifOverride: allowOnvifOverride,
    rtspHint: rtspHint,
  ),
);

class _ConnectionDialog extends StatefulWidget {
  const _ConnectionDialog({
    required this.initial,
    required this.requireRtsp,
    required this.allowOnvifOverride,
    required this.rtspHint,
  });

  final LocalCameraConnection initial;
  final bool requireRtsp;
  final bool allowOnvifOverride;
  final String? rtspHint;

  @override
  State<_ConnectionDialog> createState() => _ConnectionDialogState();
}

class _ConnectionDialogState extends State<_ConnectionDialog> {
  late final _username = TextEditingController(
    text: widget.initial.login?.username,
  );
  late final _password = TextEditingController(
    text: widget.initial.login?.password,
  );
  late final _rtsp = TextEditingController(
    text: widget.initial.rtspUri?.toString(),
  );
  late final _onvif = TextEditingController(
    text: widget.initial.onvifUri?.toString(),
  );
  final _form = GlobalKey<FormState>();
  bool _hide = true;
  bool _hideRtsp = true;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _rtsp.dispose();
    _onvif.dispose();
    super.dispose();
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    final user = _username.text.trim();
    Navigator.pop(
      context,
      LocalCameraConnection(
        login: user.isEmpty ? null : CameraLogin(user, _password.text),
        rtspUri: parseManualRtspUri(_rtsp.text),
        onvifUri: widget.allowOnvifOverride
            ? parseManualOnvifUri(_onvif.text)
            : widget.initial.onvifUri,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Ustawienia połączenia'),
    scrollable: true,
    content: Form(
      key: _form,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Dane logowania kamery i adres RTSP są zapisywane tylko na tym telefonie.',
          ),
          if (widget.allowOnvifOverride)
            TextFormField(
              controller: _onvif,
              decoration: const InputDecoration(
                labelText: 'Nowy adres ONVIF (opcjonalnie)',
                hintText: '192.168.1.6:8899',
              ),
              keyboardType: TextInputType.url,
              validator: (value) =>
                  value != null &&
                      value.trim().isNotEmpty &&
                      parseManualOnvifUri(value) == null
                  ? 'Podaj lokalny adres ONVIF bez danych logowania.'
                  : null,
            ),
          TextFormField(
            controller: _username,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'Użytkownik kamery (opcjonalnie)',
            ),
            validator: (value) =>
                (value == null || value.trim().isEmpty) &&
                    _password.text.isNotEmpty
                ? 'Wpisz nazwę użytkownika kamery.'
                : null,
          ),
          TextFormField(
            controller: _password,
            obscureText: _hide,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'Hasło kamery',
              suffixIcon: IconButton(
                tooltip: _hide ? 'Pokaż hasło' : 'Ukryj hasło',
                onPressed: () => setState(() => _hide = !_hide),
                icon: Icon(_hide ? Icons.visibility : Icons.visibility_off),
              ),
            ),
          ),
          TextFormField(
            controller: _rtsp,
            obscureText: _hideRtsp,
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: widget.requireRtsp
                  ? 'Adres RTSP'
                  : 'Własny adres RTSP (opcjonalnie)',
              hintText: widget.rtspHint ?? 'rtsp://192.168.1.6:554/stream',
              suffixIcon: IconButton(
                tooltip: _hideRtsp ? 'Pokaż adres' : 'Ukryj adres',
                onPressed: () => setState(() => _hideRtsp = !_hideRtsp),
                icon: Icon(_hideRtsp ? Icons.visibility : Icons.visibility_off),
              ),
            ),
            validator: (value) {
              if (!widget.requireRtsp &&
                  (value == null || value.trim().isEmpty)) {
                return null;
              }
              return parseManualRtspUri(value ?? '') == null
                  ? 'Podaj pełny adres rtsp:// w sieci lokalnej.'
                  : null;
            },
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Anuluj'),
      ),
      FilledButton(onPressed: _save, child: const Text('Zatwierdź')),
    ],
  );
}
