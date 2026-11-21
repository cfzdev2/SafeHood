import 'camera.dart';
import 'camera_notification_settings.dart';

enum CameraMotionPreference {
  off,
  history,
  historyAndAlert;

  bool get detects => this != off;
  bool get sendsAlert => this == historyAndAlert;

  static CameraMotionPreference fromSettings(
    Camera camera,
    CameraNotificationSettings notifications,
  ) {
    final detects =
        camera.usesLocalConnection &&
        (camera.liveMotionEnabled ||
            (camera.connectionType == CameraConnectionType.onvif &&
                camera.motionDetectionEnabled));
    if (!detects) return off;
    return notifications.sendsMotionAlert ? historyAndAlert : history;
  }
}
