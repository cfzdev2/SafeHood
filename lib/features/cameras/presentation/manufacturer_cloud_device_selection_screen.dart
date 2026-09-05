import 'package:flutter/material.dart';

import '../domain/manufacturer_cloud.dart';

class ManufacturerCloudDeviceSelectionScreen extends StatefulWidget {
  final ManufacturerCloudGateway gateway;

  const ManufacturerCloudDeviceSelectionScreen({
    super.key,
    required this.gateway,
  });

  @override
  State<ManufacturerCloudDeviceSelectionScreen> createState() =>
      _ManufacturerCloudDeviceSelectionScreenState();
}

class _ManufacturerCloudDeviceSelectionScreenState
    extends State<ManufacturerCloudDeviceSelectionScreen> {
  late Future<List<ManufacturerCloudDevice>> _devicesFuture;

  @override
  void initState() {
    super.initState();

    _loadDevices();
  }

  void _loadDevices() {
    _devicesFuture = widget.gateway.getDevices();
  }

  void _retry() {
    setState(() {
      _loadDevices();
    });
  }

  String _deviceSubtitle(ManufacturerCloudDevice device) {
    final status = device.isOnline ? 'Online' : 'Offline';

    return '${device.brand} '
        '${device.model}\n$status';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Wybierz kamerę')),
      body: FutureBuilder<List<ManufacturerCloudDevice>>(
        future: _devicesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting &&
              !snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.cloud_off_outlined, size: 48),
                    const SizedBox(height: 16),
                    Text(
                      'Nie udało się pobrać '
                      'kamer.\n'
                      '${snapshot.error}',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 18),
                    OutlinedButton.icon(
                      onPressed: _retry,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Spróbuj ponownie'),
                    ),
                  ],
                ),
              ),
            );
          }

          final devices = snapshot.data ?? [];

          if (devices.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Na tym koncie nie '
                  'znaleziono żadnych kamer.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: devices.length,
            separatorBuilder: (_, _) {
              return const SizedBox(height: 10);
            },
            itemBuilder: (context, index) {
              final device = devices[index];

              return Card(
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  contentPadding: const EdgeInsets.all(14),
                  leading: CircleAvatar(
                    child: Icon(
                      device.isOnline
                          ? Icons.videocam_outlined
                          : Icons.videocam_off_outlined,
                    ),
                  ),
                  title: Text(
                    device.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Text(_deviceSubtitle(device)),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).pop(device);
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}
