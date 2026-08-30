import 'package:geocoding/geocoding.dart';

class LocationService {
  final Geocoding geocoding = Geocoding();

  Future<String> addressFromCoordinates(
    double latitude,
    double longitude,
  ) async {
    try {
      final placemarks =
          await geocoding.placemarkFromCoordinates(
        latitude,
        longitude,
      );

      if (placemarks.isEmpty) {
        return 'Lokalizacja wybrana na mapie';
      }

      final place = placemarks.first;

      final streetParts = [
        place.thoroughfare,
        place.subThoroughfare,
      ].where(
        (value) =>
            value != null &&
            value.trim().isNotEmpty,
      );

      final street =
          streetParts.map((e) => e!).join(' ');

      final city =
          place.locality?.trim() ?? '';

      final postalCode =
          place.postalCode?.trim() ?? '';

      final cityLine = [
        postalCode,
        city,
      ].where(
        (value) => value.isNotEmpty,
      ).join(' ');

      final parts = [
        street,
        cityLine,
      ].where(
        (value) => value.isNotEmpty,
      );

      final address = parts.join(', ');

      if (address.isEmpty) {
        return 'Lokalizacja wybrana na mapie';
      }

      return address;
    } catch (_) {
      return 'Lokalizacja wybrana na mapie';
    }
  }
}