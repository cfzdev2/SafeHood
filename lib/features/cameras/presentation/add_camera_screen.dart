import 'package:flutter/material.dart';

import '../data/camera_discovery_service.dart';
import '../domain/camera.dart';
import 'safe_ark_connection_screen.dart';

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
    final shouldContinue = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => const SafeArkConnectionScreen()),
    );

    if (shouldContinue != true || !mounted) {
      return;
    }

    setState(() {
      selectedCamera = null;
      isDekcoSafeArkSelected = true;
      scanProgress = null;

      nameController.clear();
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
            'sieci.\n$error',
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
      selectedCamera = result;
      isDekcoSafeArkSelected = false;

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
      isDekcoSafeArkSelected = false;

      nameController.clear();
      locationController.clear();
    });
  }

  void _addCamera() {
    final detectedCamera = selectedCamera;

    if (detectedCamera == null && !isDekcoSafeArkSelected) {
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

    final camera = isDekcoSafeArkSelected
        ? Camera(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            name: name,
            locationName: location,
            brand: 'DEKCO',
            model: 'Floodlight Camera Pro L5P/DL5P',
            isOnline: false,
            motionDetectionEnabled: true,
            hasSdCard: false,
            connectionType: CameraConnectionType.manufacturerCloud,
            cloudProvider: CameraCloudProvider.safeArk,
            monitoringMode: CameraMonitoringMode.cloud,
            discoverySources: const {'manufacturer-cloud', 'safeark'},
          )
        : Camera(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            name: name,
            locationName: location,
            brand: detectedCamera!.brand,
            model: detectedCamera.model,
            ipAddress: detectedCamera.ipAddress,
            macAddress: detectedCamera.macAddress,
            onvifServiceUrl: detectedCamera.onvifServiceUrl,
            openPorts: detectedCamera.openPorts,
            discoverySources: detectedCamera.discoverySources,
            isOnline: false,
            motionDetectionEnabled: true,
            hasSdCard: false,
            connectionType: detectedCamera.connectionType,
            monitoringMode:
                detectedCamera.connectionType ==
                    CameraConnectionType.manufacturerCloud
                ? CameraMonitoringMode.cloud
                : CameraMonitoringMode.bridge,
          );

    Navigator.of(context).pop(camera);
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
              'Upewnij się, że telefon '
              'i kamera są połączone '
              'z tą samą siecią Wi-Fi.',
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
