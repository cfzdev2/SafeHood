import 'package:flutter/material.dart';

import '../data/camera_discovery_service.dart';
import '../data/local_camera_connection.dart';
import 'camera_wifi_setup_screen.dart';
import 'local_camera_connection_dialog.dart';
import '../domain/camera.dart';
import 'safe_ark_connection_screen.dart';
import '../domain/manufacturer_cloud.dart';
import 'camera_pairing_screen.dart';

class AddCameraSelection {
  const AddCameraSelection(this.camera, this.connection);
  final Camera camera;
  final LocalCameraConnection connection;
}



class AddCameraScreen extends StatefulWidget {
  const AddCameraScreen({super.key});

  @override
  State<AddCameraScreen> createState() => _AddCameraScreenState();
}

class _AddCameraScreenState extends State<AddCameraScreen> {
  final nameController = TextEditingController();

  final locationController = TextEditingController();

  final CameraDiscoveryService discoveryService = CameraDiscoveryService();

  DetectedCamera? selectedCamera;
  LocalCameraConnection _localConnection = const LocalCameraConnection();

  ManufacturerCloudDevice? selectedCloudDevice;

  bool isDekcoSafeArkSelected = false;
  bool isScanning = false;

  CameraDiscoveryProgress? scanProgress;

  @override
  void dispose() {
    nameController.dispose();
    locationController.dispose();

    super.dispose();
  }

  Future<void> _selectDekcoSafeArk() async {
    final device = await Navigator.of(context).push<ManufacturerCloudDevice>(
      MaterialPageRoute<ManufacturerCloudDevice>(
        builder: (_) => const SafeArkConnectionScreen(),
      ),
    );

    if (device == null || !mounted) {
      return;
    }

    setState(() {
      selectedCamera = null;
      _localConnection = const LocalCameraConnection();
      selectedCloudDevice = device;
      isDekcoSafeArkSelected = true;
      scanProgress = null;

      nameController.text = device.name;
      locationController.clear();
    });
  }

  Future<void> _detectCameras() async {
    if (isScanning) {
      return;
    }

    setState(() {
      isScanning = true;
      selectedCamera = null;
      _localConnection = const LocalCameraConnection();
      selectedCloudDevice = null;
      isDekcoSafeArkSelected = false;
      scanProgress = null;
    });

    try {
      final cameras = await discoveryService.discoverCameras(
        onProgress: (progress) {
          if (!mounted) {
            return;
          }

          setState(() {
            scanProgress = progress;
          });
        },
      );

      if (!mounted) {
        return;
      }

      setState(() {
        isScanning = false;
      });

      if (cameras.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Nie znaleziono żadnej '
              'kompatybilnej kamery '
              'w tej sieci Wi-Fi.',
            ),
          ),
        );

        return;
      }

      await _showDetectedCameras(cameras);
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        isScanning = false;
        scanProgress = null;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Nie udało się przeskanować '
            'sieci. Spróbuj ponownie.',
          ),
        ),
      );
    }
  }

  Future<void> _showDetectedCameras(List<DetectedCamera> cameras) async {
    final result = await showModalBottomSheet<DetectedCamera>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Znalezione kamery',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  cameras.length == 1
                      ? 'Znaleziono 1 kamerę.'
                      : 'Znaleziono '
                            '${cameras.length} kamery.',
                ),
                const SizedBox(height: 16),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: cameras.length,
                    separatorBuilder: (_, _) {
                      return const SizedBox(height: 8);
                    },
                    itemBuilder: (context, index) {
                      final camera = cameras[index];

                      return Card(
                        child: ListTile(
                          leading: const CircleAvatar(
                            child: Icon(Icons.videocam_outlined),
                          ),
                          title: Text(_cameraTitle(camera)),
                          subtitle: Text(_cameraSubtitle(camera)),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            Navigator.of(context).pop(camera);
                          },
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (result == null || !mounted) {
      return;
    }

    setState(() {
      selectedCamera =
          result.connectionType == CameraConnectionType.unknown &&
              result.ipAddress != null &&
              isCameraLanHost(result.ipAddress!)
          ? result.copyWith(connectionType: CameraConnectionType.onvif)
          : result;
      _localConnection = const LocalCameraConnection();
      isDekcoSafeArkSelected = false;
      selectedCloudDevice = null;
      nameController.clear();
      locationController.clear();
    });
  }

  String _cameraTitle(DetectedCamera camera) {
    final brand = camera.brand.trim();
    final model = camera.model.trim();

    if (brand == 'Nieznany producent' && model == 'Nieznany model') {
      return camera.displayName;
    }

    if (brand == 'Nieznany producent') {
      return model;
    }

    if (model == 'Nieznany model') {
      return brand;
    }

    return '$brand $model';
  }

  String _cameraSubtitle(DetectedCamera camera) {
    final parts = <String>[];

    if (camera.ipAddress != null) {
      parts.add(camera.ipAddress!);
    }

    switch (camera.connectionType) {
      case CameraConnectionType.onvif:
        parts.add('ONVIF');

      case CameraConnectionType.rtsp:
        parts.add('RTSP');

      case CameraConnectionType.manufacturerCloud:
        parts.add('Usługa producenta');

      case CameraConnectionType.mock:
        parts.add('Tryb testowy');

      case CameraConnectionType.unknown:
        parts.add(
          'Sposób połączenia '
          'do ustalenia',
        );
    }

    return parts.join(' • ');
  }

  void _changeCamera() {
    setState(() {
      selectedCamera = null;
      _localConnection = const LocalCameraConnection();
      selectedCloudDevice = null;
      isDekcoSafeArkSelected = false;

      nameController.clear();
      locationController.clear();
    });
  }

  Future<void> _enterOnvifAddress() async {
    final endpoint = await showDialog<Uri>(
      context: context,
      builder: (_) => const _OnvifAddressDialog(),
    );
    if (!mounted || endpoint == null) return;
    setState(() {
      selectedCamera = DetectedCamera(
        deviceId: 'onvif-${endpoint.host}',
        displayName: 'Kamera ONVIF',
        brand: 'Nieznany producent',
        model: 'Nieznany model',
        ipAddress: endpoint.host,
        onvifServiceUrl: endpoint.toString(),
        openPorts: {endpoint.port},
        connectionType: CameraConnectionType.onvif,
      );
      _localConnection = const LocalCameraConnection();
      selectedCloudDevice = null;
      isDekcoSafeArkSelected = false;
    });
  }

  Future<void> _addRtspManually() async {
    final connection = await showLocalCameraConnectionDialog(
      context,
      requireRtsp: true,
    );
    if (!mounted || connection?.rtspUri == null) return;
    final uri = connection!.rtspUri!;
    setState(() {
      _localConnection = connection;
      selectedCamera = DetectedCamera(
        deviceId: 'rtsp-${uri.host}',
        displayName: 'Kamera RTSP',
        brand: 'Nieznany producent',
        model: 'Nieznany model',
        ipAddress: uri.host,
        openPorts: {uri.hasPort ? uri.port : 554},
        connectionType: CameraConnectionType.rtsp,
      );
      selectedCloudDevice = null;
      isDekcoSafeArkSelected = false;
    });
  }

  Future<bool> _editLocalConnection() async {
    final camera = selectedCamera;
    if (camera == null) return false;
    final ip = camera.ipAddress;
    final rtspHint = ip == null
        ? null
        : Uri(
            scheme: 'rtsp',
            host: ip,
            port:
                camera.openPorts
                    .where((port) => port == 554 || port == 8554)
                    .firstOrNull ??
                554,
            path: '/stream',
          ).toString();
    final connection = await showLocalCameraConnectionDialog(
      context,
      initial: _localConnection,
      requireRtsp: camera.connectionType == CameraConnectionType.rtsp,
      rtspHint: rtspHint,
    );
    if (!mounted || connection == null) return false;
    setState(() => _localConnection = connection);
    return true;
  }

  Camera _localCamera(
    DetectedCamera detectedCamera,
    String name,
    String location,
  ) => Camera(
    id: DateTime.now().millisecondsSinceEpoch.toString(),
    name: name,
    locationName: location,
    brand: detectedCamera.brand,
    model: detectedCamera.model,
    ipAddress: detectedCamera.ipAddress,
    macAddress: detectedCamera.macAddress,
    onvifServiceUrl: parseManualOnvifUri(
      detectedCamera.onvifServiceUrl ?? '',
    )?.toString(),
    openPorts: detectedCamera.openPorts,
    discoverySources: detectedCamera.discoverySources,
    isOnline: false,
    motionDetectionEnabled:
        detectedCamera.connectionType == CameraConnectionType.onvif,
    hasSdCard: false,
    connectionType: detectedCamera.connectionType,
    monitoringMode: CameraMonitoringMode.bridge,
  );

  Future<void> _openWifiSetup() async {
    final camera = selectedCamera;
    if (camera == null) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => CameraWifiSetupScreen(
          camera: _localCamera(camera, '', ''),
          connection: _localConnection,
        ),
      ),
    );
    if (!mounted || changed != true) return;
    // Keep the entered name and credentials until the user reselects or saves.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Po zmianie sieci sprawdź nowy adres kamery.'),
        action: SnackBarAction(
          label: 'Wykryj ponownie',
          onPressed: _detectCameras,
        ),
      ),
    );
  }

  Future<void> _addCamera() async {
    final detectedCamera = selectedCamera;
    final cloudDevice = selectedCloudDevice;

    if (detectedCamera == null && cloudDevice == null) {
      return;
    }

    final name = nameController.text.trim();

    final location = locationController.text.trim();

    if (name.isEmpty || location.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Podaj nazwę kamery '
            'i miejsce, w którym '
            'się znajduje.',
          ),
        ),
      );

      return;
    }

    if (detectedCamera?.connectionType == CameraConnectionType.rtsp &&
        _localConnection.rtspUri == null) {
      if (!await _editLocalConnection() || !mounted) return;
    }

    final camera = cloudDevice != null
        ? cloudDevice.toCamera(name: name, locationName: location)
        : _localCamera(detectedCamera!, name, location);
    Navigator.of(context).pop(AddCameraSelection(camera, _localConnection));
  }

  @override
  Widget build(BuildContext context) {
    final camera = selectedCamera;

    final hasSelectedCamera = camera != null || isDekcoSafeArkSelected;

    return Scaffold(
      appBar: AppBar(title: const Text('Dodaj kamerę')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (!hasSelectedCamera) ...[
            FilledButton.tonalIcon(
              onPressed: isScanning
                  ? null
                  : () async {
                      final discover = await Navigator.of(context).push<bool>(
                        MaterialPageRoute<bool>(
                          builder: (_) => const CameraPairingScreen(),
                        ),
                      );
                      if (discover == true && mounted) await _detectCameras();
                    },
              icon: const Icon(Icons.wifi_protected_setup),
              label: const Text('Sparuj nową kamerę bez kabla'),
            ),
            const SizedBox(height: 16),
            Text(
              'Połącz kamerę z SafeHood',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Wybierz obsługiwaną kamerę '
              'producenta albo wyszukaj '
              'kamerę w lokalnej sieci.',
            ),
            const SizedBox(height: 24),
            Text(
              'Kamery producentów',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            Card(
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                contentPadding: const EdgeInsets.all(16),
                leading: const CircleAvatar(child: Icon(Icons.cloud_outlined)),
                title: const Text(
                  'DEKCO SafeArk',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: const Padding(
                  padding: EdgeInsets.only(top: 5),
                  child: Text(
                    'Floodlight Camera Pro '
                    'L5P/DL5P',
                  ),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: isScanning ? null : _selectDekcoSafeArk,
              ),
            ),
            const SizedBox(height: 28),
            Text(
              'Kamery ONVIF i RTSP',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text(
              'Telefon i kamera muszą być w tej samej sieci lokalnej. '
              'Kamera może być podłączona do routera przez Wi-Fi albo kabel LAN.',
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: isScanning ? null : _detectCameras,
              icon: isScanning
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.wifi_find),
              label: Padding(
                padding: const EdgeInsets.symmetric(vertical: 15),
                child: Text(
                  isScanning
                      ? 'Szukam kamer...'
                      : 'Wykryj kamerę '
                            'automatycznie',
                  style: const TextStyle(fontSize: 16),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: isScanning ? null : _enterOnvifAddress,
                  child: const Text('Wpisz adres ONVIF'),
                ),
                OutlinedButton(
                  onPressed: isScanning ? null : _addRtspManually,
                  child: const Text('Wpisz adres RTSP'),
                ),
              ],
            ),
            ExpansionTile(
              leading: const Icon(Icons.wifi),
              title: const Text('Kamera nie jest jeszcze w sieci?'),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              children: const [
                Text(
                  'Podłącz kamerę tymczasowo do routera kablem albo połącz telefon '
                  'z własną siecią Wi-Fi kamery w ustawieniach telefonu. Wykryj kamerę '
                  'i wybierz „Połącz kamerę z Wi-Fi”. Jeśli kamera nie udostępnia '
                  'konfiguracji przez ONVIF, ustaw jej Wi-Fi w aplikacji producenta, '
                  'potem wróć do SafeHood.',
                ),
              ],
            ),
            if (isScanning) ...[
              const SizedBox(height: 20),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Skanowanie kamer',
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        scanProgress?.message ??
                            'Przygotowuję '
                                'skanowanie...',
                      ),
                      const SizedBox(height: 12),
                      LinearProgressIndicator(
                        value: scanProgress == null
                            ? null
                            : scanProgress!.step / scanProgress!.totalSteps,
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          scanProgress == null
                              ? ''
                              : '${scanProgress!.step}'
                                    '/${scanProgress!.totalSteps}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline, size: 20),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'SafeHood przeskanuje '
                      'lokalną sieć i spróbuje '
                      'sam rozpoznać kamerę.',
                    ),
                  ),
                ],
              ),
            ),
          ] else ...[
            Text(
              'Wybrana kamera',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Card(
              child: ListTile(
                leading: CircleAvatar(
                  child: Icon(
                    isDekcoSafeArkSelected
                        ? Icons.cloud_outlined
                        : Icons.videocam,
                  ),
                ),
                title: Text(
                  isDekcoSafeArkSelected
                      ? 'DEKCO Floodlight '
                            'Camera Pro'
                      : _cameraTitle(camera!),
                ),
                subtitle: Text(
                  isDekcoSafeArkSelected
                      ? 'SafeArk • L5P/DL5P • '
                            'Chmura producenta'
                      : _cameraSubtitle(camera!),
                ),
                trailing: TextButton(
                  onPressed: _changeCamera,
                  child: const Text('Zmień'),
                ),
              ),
            ),
            if (camera != null) ...[
              ListTile(
                leading: const Icon(Icons.vpn_key_outlined),
                title: const Text('Dane logowania i adres RTSP'),
                subtitle: Text(
                  _localConnection.isEmpty
                      ? 'Opcjonalnie, gdy kamera wymaga konta lub własnego adresu obrazu'
                      : 'Ustawiono dane połączenia',
                ),
                onTap: _editLocalConnection,
              ),
              if (camera.connectionType == CameraConnectionType.onvif)
                ListTile(
                  leading: const Icon(Icons.wifi),
                  title: const Text('Połącz kamerę z Wi-Fi'),
                  subtitle: const Text(
                    'Dla kamer z konfiguracją Wi-Fi przez ONVIF',
                  ),
                  onTap: _openWifiSetup,
                ),
            ],
            if (isDekcoSafeArkSelected) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, size: 20),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Przygotowujemy '
                        'połączenie z SafeArk. '
                        'Do uruchomienia LIVE, '
                        'powiadomień i sterowania '
                        'kamerą potrzebny będzie '
                        'dostęp do oficjalnego '
                        'API producenta.',
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 28),
            Text(
              'Nazwij kamerę',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text(
              'Nazwa i miejsce są tylko '
              'dla Ciebie, żeby łatwo '
              'rozpoznawać kamerę.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Nazwa kamery',
                hintText: 'np. Podjazd',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.edit_outlined),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: locationController,
              decoration: const InputDecoration(
                labelText: 'Miejsce',
                hintText: 'np. Przed domem',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.location_on_outlined),
              ),
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: _addCamera,
              icon: const Icon(Icons.check),
              label: const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Text('Dodaj kamerę', style: TextStyle(fontSize: 16)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _OnvifAddressDialog extends StatefulWidget {
  const _OnvifAddressDialog();

  @override
  State<_OnvifAddressDialog> createState() => _OnvifAddressDialogState();
}

class _OnvifAddressDialogState extends State<_OnvifAddressDialog> {
  final _form = GlobalKey<FormState>();
  final _address = TextEditingController();

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  void _confirm() {
    if (_form.currentState!.validate()) {
      Navigator.pop(context, parseManualOnvifUri(_address.text));
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Dodaj kamerę po adresie ONVIF'),
    content: Form(
      key: _form,
      child: TextFormField(
        controller: _address,
        autofocus: true,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(
          labelText: 'Adres IP lub adres usługi ONVIF',
          hintText: '192.168.1.6:8899',
        ),
        onFieldSubmitted: (_) => _confirm(),
        validator: (value) => parseManualOnvifUri(value ?? '') == null
            ? 'Podaj poprawny adres w sieci lokalnej.'
            : null,
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Anuluj'),
      ),
      FilledButton(onPressed: _confirm, child: const Text('Wybierz kamerę')),
    ],
  );
}
