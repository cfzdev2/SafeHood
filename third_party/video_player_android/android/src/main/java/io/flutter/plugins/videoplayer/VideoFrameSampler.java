package io.flutter.plugins.videoplayer;

import android.graphics.Bitmap;
import android.os.Build;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;
import android.view.PixelCopy;
import android.view.Surface;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugins.videoplayer.texture.TextureVideoPlayer;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.util.Map;

/** Samples only an existing RTSP player's video surface. Owned by one Flutter engine. */
final class VideoFrameSampler {
  private static final String CHANNEL = "safehood/camera_frame";
  private static final int SAMPLE_WIDTH = 64;
  private static final int SAMPLE_HEIGHT = 36;
  private static final int SNAPSHOT_SIZE_LIMIT = 256 * 1024;
  private final MethodChannel channel;
  private final PlayerLookup lookup;
  private final File cacheDirectory;
  private final Handler main = new Handler(Looper.getMainLooper());
  private HandlerThread thread;
  private boolean copying;
  private boolean recording;
  private volatile boolean closed;

  interface PlayerLookup {
    TextureVideoPlayer get(String session);
  }

  VideoFrameSampler(BinaryMessenger messenger, PlayerLookup lookup, File cacheDirectory) {
    this.lookup = lookup;
    this.cacheDirectory = cacheDirectory;
    channel = new MethodChannel(messenger, CHANNEL);
    channel.setMethodCallHandler(this::handle);
  }

  private void handle(MethodCall call, MethodChannel.Result result) {
    boolean jpeg = "snapshot".equals(call.method);
    boolean clip = "clip".equals(call.method);
    boolean stats = "frameStats".equals(call.method);
    boolean timed = "sampleTimed".equals(call.method);
    if (!jpeg && !clip && !stats && !timed && !"sample".equals(call.method)) {
      result.notImplemented();
      return;
    }
    String session = call.argument("session");
    TextureVideoPlayer player = closed || session == null ? null : lookup.get(session);
    if (player == null) {
      result.success(null);
      return;
    }
    if (stats) {
      // Playback health must not depend on copying a vendor decoder buffer.
      result.success(player.getPlayingFrameStats());
      return;
    }
    if (clip) {
      CameraVideoBuffer buffer = player.getCameraVideoBuffer();
      if (recording || buffer == null) {
        result.success(null);
        return;
      }
      if (thread == null) {
        thread = new HandlerThread("SafeHoodCameraFrame");
        thread.start();
      }
      Number anchorUs = call.argument("anchorUs");
      Number anchorEpoch = call.argument("anchorEpoch");
      CameraVideoBuffer.Anchor anchor =
          anchorUs != null && anchorEpoch != null
              ? new CameraVideoBuffer.Anchor(anchorUs.longValue(), anchorEpoch.longValue())
              : buffer.anchorAt(System.nanoTime());
      recording = true;
      Handler worker = new Handler(thread.getLooper());
      worker.post(
          () ->
              CameraStreamRecorder.start(
                  cacheDirectory,
                  buffer,
                  anchor,
                  worker,
                  () -> closed,
                  data ->
                      main.post(
                          () -> {
                            recording = false;
                            result.success(closed ? null : data);
                            if (closed && !copying) stopThread();
                          })));
      return;
    }
    Surface surface = player.getPlayingSurface();
    if (copying || Build.VERSION.SDK_INT < 24 || surface == null || !surface.isValid()) {
      result.success(null);
      return;
    }
    Integer width = jpeg ? call.argument("width") : SAMPLE_WIDTH;
    Integer height = jpeg ? call.argument("height") : SAMPLE_HEIGHT;
    if (width == null || height == null || width < 1 || height < 1 || width > 640 || height > 640) {
      result.success(null);
      return;
    }
    if (thread == null) {
      thread = new HandlerThread("SafeHoodCameraFrame");
      thread.start();
    }
    Handler worker = new Handler(thread.getLooper());
    copying = true;
    worker.post(() -> copy(player, surface, width, height, jpeg, timed, worker, result));
  }

  private void copy(
      TextureVideoPlayer player,
      Surface surface,
      int width,
      int height,
      boolean jpeg,
      boolean timed,
      Handler worker,
      MethodChannel.Result result) {
    Bitmap bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
    try {
      PixelCopy.request(
          surface,
          bitmap,
          status -> {
            Object data = null;
            try {
              if (status == PixelCopy.SUCCESS) {
                boolean corrupt = isCorrupt(bitmap);
                if (!corrupt) {
                  byte[] bytes = jpeg ? encodeJpeg(bitmap) : luminance(bitmap);
                  if (timed) {
                    Map<String, Object> sample = new java.util.HashMap<>();
                    sample.put("pixels", bytes);
                    CameraVideoBuffer buffer = player.getCameraVideoBuffer();
                    CameraVideoBuffer.Anchor anchor =
                        buffer == null ? null : buffer.anchorAt(System.nanoTime());
                    if (anchor != null) {
                      sample.put("anchorUs", anchor.timeUs);
                      sample.put("anchorEpoch", anchor.epoch);
                    }
                    data = sample;
                  } else data = bytes;
                }
              }
            } catch (RuntimeException ignored) {
              // A device may invalidate the buffer during a reconnect.
            } finally {
              bitmap.recycle();
              complete(result, data);
            }
          },
          worker);
    } catch (RuntimeException ignored) {
      bitmap.recycle();
      complete(result, null);
    }
  }

  static boolean isCorrupt(Bitmap bitmap) {
    int[] pixels = new int[bitmap.getWidth() * bitmap.getHeight()];
    bitmap.getPixels(pixels, 0, bitmap.getWidth(), 0, 0, bitmap.getWidth(), bitmap.getHeight());
    return VideoFrameHealth.isCorrupt(pixels, bitmap.getWidth(), bitmap.getHeight());
  }

  private static byte[] luminance(Bitmap bitmap) {
    int[] argb = new int[SAMPLE_WIDTH * SAMPLE_HEIGHT];
    bitmap.getPixels(argb, 0, SAMPLE_WIDTH, 0, 0, SAMPLE_WIDTH, SAMPLE_HEIGHT);
    byte[] values = new byte[argb.length];
    for (int i = 0; i < argb.length; i++) {
      int pixel = argb[i];
      int r = (pixel >> 16) & 255;
      int g = (pixel >> 8) & 255;
      int b = pixel & 255;
      values[i] = (byte) ((77 * r + 150 * g + 29 * b) >> 8);
    }
    return values;
  }

  private static byte[] encodeJpeg(Bitmap bitmap) {
    ByteArrayOutputStream bytes = new ByteArrayOutputStream();
    return bitmap.compress(Bitmap.CompressFormat.JPEG, 75, bytes)
            && bytes.size() <= SNAPSHOT_SIZE_LIMIT
        ? bytes.toByteArray()
        : null;
  }

  private void complete(MethodChannel.Result result, Object data) {
    main.post(
        () -> {
          copying = false;
          result.success(closed ? null : data);
          if (closed && !recording) stopThread();
        });
  }

  void close() {
    closed = true;
    channel.setMethodCallHandler(null);
    if (!copying && !recording) stopThread();
  }

  private void stopThread() {
    if (thread == null) return;
    thread.quitSafely();
    thread = null;
  }
}
