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

Foreground RTSP video renders directly to Flutter's `SurfaceProducer`, as in
the upstream player. Sampling and evidence never replace the decoder's preview
surface. The experimental foreground OES relay has been removed; a GPU capture
failure cannot take away an otherwise working preview.

The foreground sampler uses the previous asynchronous `PixelCopy` path only
for motion samples and JPEGs. Decoder statistics return counters directly and
do not probe RGB buffers or switch codecs because a copied image looks wrong.
Some vendor surfaces may still return damaged evidence copies; this rollback
restores direct display and does not establish a general solution to capture
corruption. Unreadable/rejected samples do not produce visual motion alerts.
The windowless background receiver retains its separate OES reader.

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
many frames and can try a lighter profile. Foreground counters are independent
of image sampling. Plain darkness, grayscale infrared images and a solid
colored status line do not match the narrow-rainbow-on-black signature. This
is a conservative check, not a general test of video correctness.

Rejected images are not used for visual motion alerts or JPEG snapshots. A
foreground evidence copy does not invalidate independently buffered stream
data. A whole-frame luminance discontinuity resets the motion baseline. A
visual motion alert also requires a readable snapshot immediately before it
is sent. Camera-generated native alarms follow their separate path.

RTSP uses synchronous codec queueing with hardware decoding as its initial
preference. The local `X-SafeHood-Decoder: software` option remains available
to the recovery controller and is never sent to the camera. Foreground stats
no longer infer decoder corruption from evidence copies. Background reception
uses a slower retry after repeated damaged samples.

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
