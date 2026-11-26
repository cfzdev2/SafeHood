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

The `safehood/camera_frame` method channel samples the surface of an existing
RTSP texture player for foreground motion detection. It uses Android
`PixelCopy` on a worker thread and does not copy the screen or start another
video connection. Stopping playback or disposing the player makes sampling
unavailable. The channel returns a small luma frame, or a bounded JPEG when
requested for a detected event.

On motion the app may request a single five-second silent H.264 clip from the
same surface. The encoder reads downscaled frames on the sampling thread and
removes its temporary MP4 after handing the bytes to the app. No second camera
stream is opened.

The same channel exposes decoder counters for the active RTSP player. The app
uses them to recognize an ongoing stream that renders too few frames or drops
many frames and can try a lighter profile. A stats request also attempts one
small surface sample to detect a narrow rainbow band on an otherwise black
image. If the sampler is busy, it returns counters without an image verdict.
Plain darkness, grayscale infrared images and a solid colored status line do
not match that signature. This is a conservative check, not a general test of
video correctness.

Rejected images are not used for visual motion alerts, JPEG snapshots or MP4
clips. A whole-frame luminance discontinuity resets the motion baseline. A
visual motion alert also requires a readable snapshot immediately before it
is sent. Camera-generated native alarms follow their separate path.

Two damaged-image probes trigger a new RTSP session with TCP and the internal
`X-SafeHood-Decoder: software` option. This option prioritizes Android software
video decoders and disables asynchronous codec queueing; it is never sent to
the camera. Hardware decoders remain available if software initialization
fails. Foreground recovery is bounded to two attempts until healthy playback
or a user retry. Background reception uses a slower retry after repeated
damage and applies the same frame check.

Validation covers synthetic corruption, ordinary color and infrared frames,
motion rebasing, rejected snapshots and the bounded recovery lifecycle. Android
sources are checked against the pinned Media3 APIs. A full APK build and a test
on the affected physical device are still needed to establish which decoder
and stream combination actually resolves its corruption.

When upgrading, replace the vendored source with the new upstream version and
carry forward this option until upstream offers an equivalent API. Retain
LICENSE and AUTHORS. This copy excludes the upstream example and tests.
