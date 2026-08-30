import 'package:cloud_functions/cloud_functions.dart';

class BridgePairingCode {
  final String code;
  final DateTime expiresAt;

  const BridgePairingCode({required this.code, required this.expiresAt});
}

class BridgePairingService {
  final FirebaseFunctions _functions;

  BridgePairingService({FirebaseFunctions? functions})
    : _functions =
          functions ?? FirebaseFunctions.instanceFor(region: 'europe-central2');

  Future<BridgePairingCode> createPairingCode() async {
    final callable = _functions.httpsCallable('createBridgePairingCode');

    final result = await callable.call();

    final rawData = result.data;

    if (rawData is! Map) {
      throw StateError('Backend zwrócił nieprawidłowe dane.');
    }

    final code = rawData['code'];
    final expiresAt = rawData['expiresAt'];

    if (code is! String || expiresAt is! num) {
      throw StateError('Backend nie zwrócił kodu parowania.');
    }

    return BridgePairingCode(
      code: code,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAt.toInt()),
    );
  }
}
