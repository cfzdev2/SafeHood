import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

class LocationPickerResult {
  final double latitude;
  final double longitude;

  const LocationPickerResult({
    required this.latitude,
    required this.longitude,
  });
}

class LocationPickerScreen extends StatefulWidget {
  final double? initialLatitude;
  final double? initialLongitude;

  const LocationPickerScreen({
    super.key,
    this.initialLatitude,
    this.initialLongitude,
  });

  @override
  State<LocationPickerScreen> createState() =>
      _LocationPickerScreenState();
}

class _LocationPickerScreenState
    extends State<LocationPickerScreen> {
  LatLng? selectedPoint;

  late final LatLng initialCenter;
  late final double initialZoom;

  @override
  void initState() {
    super.initState();

    if (widget.initialLatitude != null &&
        widget.initialLongitude != null) {
      selectedPoint = LatLng(
        widget.initialLatitude!,
        widget.initialLongitude!,
      );

      initialCenter = selectedPoint!;
      initialZoom = 16;
    } else {
      // Startujemy mniej więcej na środku Polski.
      initialCenter = const LatLng(
        52.0693,
        19.4803,
      );

      initialZoom = 6.5;
    }
  }

  void selectPoint(LatLng point) {
    setState(() {
      selectedPoint = point;
    });
  }

  void confirmLocation() {
    final point = selectedPoint;

    if (point == null) {
      return;
    }

    Navigator.of(context).pop(
      LocationPickerResult(
        latitude: point.latitude,
        longitude: point.longitude,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final point = selectedPoint;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Wybierz lokalizację domu',
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: FlutterMap(
              options: MapOptions(
                initialCenter: initialCenter,
                initialZoom: initialZoom,
                minZoom: 4,
                maxZoom: 19,
                onTap: (_, tappedPoint) {
                  selectPoint(tappedPoint);
                },
              ),
              children: [
                TileLayer(
                  urlTemplate:
                      'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName:
                      'com.safehood.securityapp',
                ),

                if (point != null)
                  CircleLayer(
                    circles: [
                      CircleMarker(
                        point: point,
                        radius: 1000,
                        useRadiusInMeter: true,
                        color: const Color(
                          0x223F51B5,
                        ),
                        borderColor: const Color(
                          0xFF3F51B5,
                        ),
                        borderStrokeWidth: 2,
                      ),
                    ],
                  ),

                if (point != null)
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: point,
                        width: 50,
                        height: 50,
                        child: const Icon(
                          Icons.location_pin,
                          size: 48,
                          color: Colors.red,
                        ),
                      ),
                    ],
                  ),

                const SimpleAttributionWidget(
                  source: Text(
                    'OpenStreetMap contributors',
                  ),
                ),
              ],
            ),
          ),

          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.stretch,
                children: [
                  if (point == null)
                    const Text(
                      'Dotknij mapy w miejscu, '
                      'w którym znajduje się Twój dom.',
                      textAlign: TextAlign.center,
                    )
                  else
                    const Text(
                      'Niebieski okrąg pokazuje '
                      'obszar społeczności w promieniu 1 km.',
                      textAlign: TextAlign.center,
                    ),

                  const SizedBox(height: 12),

                  FilledButton.icon(
                    onPressed: point == null
                        ? null
                        : confirmLocation,
                    icon: const Icon(
                      Icons.check,
                    ),
                    label: const Text(
                      'Potwierdź lokalizację',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}