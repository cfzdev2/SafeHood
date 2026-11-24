import 'package:xml/xml.dart';

import '../domain/camera.dart';
import 'local_camera_connection.dart';
import 'onvif_media_resolver.dart';
import 'onvif_soap_client.dart';
import 'rtsp_probe.dart';

Future<CameraAvailability> checkLocalCameraAvailability(
  Camera camera, {
  LocalCameraConnection? connection,
}) async {
  if (!camera.usesLocalConnection) return CameraAvailability.unknown;
  if (connection == null) {
    try {
      connection = await const LocalCameraConnectionStore()
          .read(camera.id)
          .timeout(const Duration(seconds: 1));
    } on Exception {
      // Some platforms have no local credentials store. The saved ONVIF
      // address can still be checked without logging in.
      connection = const LocalCameraConnection();
    }
  }

  connection = connection.forCamera(camera);
  final localCamera = connection.cameraWithLocalEndpoint(camera);
  final onvif = localCamera.connectionType == CameraConnectionType.onvif
      ? cameraOnvifEndpoints(localCamera).firstOrNull
      : null;
  final rtsp = connection.rtspUri;
  if (onvif == null && rtsp == null) return CameraAvailability.unknown;

  if (onvif != null &&
      await _onvifResponds(
        onvif,
        savedEndpoint:
            parseManualOnvifUri(localCamera.onvifServiceUrl ?? '') != null,
      )) {
    return CameraAvailability.online;
  }
  if (rtsp != null &&
      await probeRtsp(
        rtsp,
        connectTimeout: const Duration(seconds: 1),
        replyTimeout: const Duration(seconds: 1),
      )) {
    return CameraAvailability.online;
  }
  return CameraAvailability.offline;
}

Future<bool> _onvifResponds(Uri endpoint, {required bool savedEndpoint}) async {
  try {
    final reply = await OnvifSoapClient(endpoint.host).call(
      endpoint,
      onvifDeviceNamespace,
      'GetSystemDateAndTime',
      timeout: const Duration(seconds: 2),
      authenticated: false,
    );
    return reply.response('GetSystemDateAndTime') != null ||
        onvifElements(
          reply.fault,
          'Value',
        ).any((element) => element.innerText.trim().startsWith('ter:')) ||
        (savedEndpoint && reply.requiresLogin);
  } on Exception {
    return false;
  }
}
