# SafeHood's Android video player

Source-only copy of Flutter's `video_player_android` 2.12.0 from the
[official pub archive](https://pub.dev/packages/video_player_android/versions/2.12.0).
Original archive SHA-256:
`e229676f8fade3e0124482495aaa2b548872cc4018b6268adfca4868be16aa74`.

For RTSP URLs the local changes translate the in-process
`X-SafeHood-Rtsp-Transport: tcp` playback option into Media3's
`setForceUseRtpTcp(true)`. It is not a network header. Without this option
the player keeps upstream's UDP-first behavior. HTTP/HLS and event recordings
are unaffected. No developer package cache is modified.

RTSP playback uses one decoder. `CameraFrameReader` consumes its external OES
texture, applies the `SurfaceTexture` transform and renders to Flutter's output
surface. Motion samples and JPEGs are read from a small RGBA framebuffer with
explicit byte order and vertical row conversion. Direct `PixelCopy` of the
vendor decoder surface is no longer used. RGB readback is throttled separately
from preview rendering. The background receiver uses the same frame reader.
If GL capture fails, the preview returns to the direct surface and visual-only
events wait for readable evidence.

`CameraVideoBuffer` copies compressed H.264 access units before decoder input
ownership changes. It retains at most eight seconds / six MiB, discards
incomplete GOPs and clears on seek, format change, discontinuity or disposal.
On an event, `CameraStreamRecorder` remuxes a key-frame-aligned prefix of up to
five seconds plus five seconds of new camera video into a silent MP4. It does
not start another camera connection, decoder or encoder, reduce frame rate,
resize the recording or block frame sampling while it waits. A warm-up period,
long GOP or the byte cap can shorten the available prefix; its actual duration
is returned through the channel and stored in the event, never hard-coded to
zero or five seconds. Stream interruption, an unprimed buffer or oversized
media results in no clip. Current phone clip validation accepts H.264 up to
1280 x 720, fifteen seconds and six MiB. Other formats remain playable but do
not get this recording path. The pre-event buffer is scoped to the active
preview session; native camera alarms without an active video receiver still
use their separate snapshot path.

The same channel exposes decoder counters for the active RTSP player. The app
uses them to recognize an ongoing stream that renders too few frames or drops
many frames and can try a lighter profile. Stats may include a verdict from
the shared RGB frame. Plain darkness, grayscale infrared images and a solid
colored status line do not match the narrow-rainbow-on-black signature. This
is a conservative check, not a general test of video correctness.

Rejected images are not used for visual motion alerts or JPEG snapshots and
invalidate the pending compressed recording. A whole-frame luminance discontinuity resets the motion baseline. A
visual motion alert also requires a readable snapshot immediately before it
is sent. Camera-generated native alarms follow their separate path.

Two damaged-image probes trigger a new RTSP session with TCP and the internal
`X-SafeHood-Decoder: software` option. This option prioritizes Android software
video decoders; it is never sent to the camera. RTSP uses synchronous codec
queueing with hardware decoding as its initial preference. Hardware decoders remain available if software initialization
fails. Foreground recovery is bounded to two attempts until healthy playback
or a user retry. Background reception uses a slower retry after repeated
damage and applies the same frame check.

Validation covers RGBA byte order/orientation, GOP boundaries, true prebuffer,
buffer ownership and limits, discontinuities, synthetic corruption, ordinary
color and infrared frames, motion rebasing and the recovery lifecycle. Backend
checks cover timing, private ownership and idempotent attachment. Android
sources are checked against the pinned Media3 APIs. A full APK build and a test
on the affected physical device are still needed to establish which decoder
and stream combination actually resolves its corruption.

When upgrading, replace the vendored source with the new upstream version and
carry forward this option until upstream offers an equivalent API. Retain
LICENSE and AUTHORS. This copy excludes the upstream example and tests.
