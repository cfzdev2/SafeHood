# First setup of a camera without Ethernet

In the Android app, use **Dodaj kamerę → Skonfiguruj kamerę lub sprawdź obraz
→ Hotspot kamery ONVIF**.
Put the camera into its pairing mode as described by its manufacturer. Tap
**Wyszukaj sieć kamery** and select the network belonging to the camera.
Android asks for permission to scan nearby Wi-Fi and to temporarily join
the selected hotspot. The scan lists Wi-Fi access points; an access point
is identified as an ONVIF camera only after it responds to ONVIF.

SafeHood tries the camera's gateway or other on-link IPv4 address. The
ONVIF service must be available over HTTP on the hotspot, and it must
report exactly one wireless interface that the app can configure.
If the camera asks for authentication, enter its ONVIF credentials.
You can specify a local IP and port if the automatic check cannot find it.

After the app identifies the camera, enter the SSID and password of a
supported **WPA2-Personal** network. The app requests DHCP and changes
only the verified wireless interface. If the camera requires a reboot,
the app offers it as a separate action. A lost reply is treated as
unconfirmed: check the home network before attempting the write again.
Wait for the phone to reconnect to home Wi-Fi, choose **Wykryj kamerę w
sieci domowej**, then select the camera and verify that video plays before saving.

The app does not store Wi-Fi passwords or send them to Firebase or Bridge.
The setup socket is scoped to the selected Android network and on-link
IPv4 addresses; other SafeHood connections keep their regular routes.
SOAP over HTTP is not encrypted by TLS. On an open camera hotspot, the
Wi-Fi password is not encrypted in transit, so only use the feature with
a trusted camera in a trusted setting. Credentials stay in memory for the
current step and are dropped when setup ends or is cancelled.

A camera that does not expose ONVIF Wi-Fi configuration in its setup mode
needs a separate provisioning integration to be set up entirely in
SafeHood. Support for local ONVIF or RTSP video does not imply support for
Wi-Fi setup. Android 10+ is required for this wizard. The existing discovery
and settings flows still apply to cameras already in the home network.

## When a camera counts as supported

Starting with a camera in pairing mode and disconnected from Ethernet,
the phone uses only SafeHood to send the Wi-Fi settings, find the same
camera on the home network and open a moving LIVE image. Close and reopen
LIVE to confirm the feed can start again without the camera hotspot. A
manufacturer app, vendor account, USB forward or SafeHood Bridge cannot
be a prerequisite for this test. Bridge monitoring and AI are separate.

| Test camera | Confirmed | Still to verify |
| --- | --- | --- |
| Motorola FOCUS72-W (03.10.34) | SafeHood joined the camera hotspot; its ONVIF probe did not find a setup service. In Safari at `192.168.193.1`, `get_rt_list` listed the test network, `setup_wireless_save` returned `0`, and Xiaomi's `ap0` DHCP log assigned and renewed `192.168.247.169` for the known camera MAC after `restart_system`. Address resolution failed later, and the hotspot client count fell to zero. The camera was not found by MAC at its previous home IP after a probe. The result does not establish why the camera disconnected. | Check whether a test access point with verified internet access stays associated and reachable without the Hubble app. Verify a direct LIVE stream, then separately verify operation with the camera's internet access blocked. The earlier Hubble relay only proved that the relayed video could be decoded. |
| NVT | SafeHood discovered its ONVIF endpoint with Ethernet connected. | Whether its pairing mode broadcasts a hotspot with ONVIF Wi-Fi configuration, and whether LIVE works over Wi-Fi after this setup. |

## Verification

- Run `flutter analyze` and
  `flutter test test/features/cameras/presentation/camera_pairing_screen_test.dart`.
- The standalone JVM check in `test/native/CameraPairingOnvifTest.java`
  exercises the SOAP request, authentication, rejection of wired and
  ambiguous interfaces, lost reply handling and HTTP framing.
- On Android hardware, start with a supported camera in pairing mode and
  no Ethernet. Join the camera hotspot, configure a test Wi-Fi network,
  then verify the camera appears there and opens LIVE. Also try cancelling
  at the Android confirmation dialog and verify home Wi-Fi stays usable.

References: [Android Wi-Fi scan](https://developer.android.com/develop/connectivity/wifi/wifi-scan),
[Android local-only Wi-Fi connection](https://developer.android.com/develop/connectivity/wifi/wifi-bootstrap),
[ONVIF Core Specification, 8.2.11 and 8.2.22](https://www.onvif.org/specs/core/ONVIF-Core-Specification.pdf).
