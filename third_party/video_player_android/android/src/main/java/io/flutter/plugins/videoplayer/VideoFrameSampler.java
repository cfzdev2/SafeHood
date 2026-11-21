package io.flutter.plugins.videoplayer;

import android.graphics.Bitmap;
import android.os.Build;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;
import android.view.PixelCopy;
import android.view.Surface;
import androidx.annotation.RequiresApi;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugins.videoplayer.texture.TextureVideoPlayer;
import java.io.ByteArrayOutputStream;

/** Samples only an existing RTSP player's video surface. Owned by one Flutter engine. */
final class VideoFrameSampler {
  private static final String CHANNEL = "safehood/camera_frame";
  private static final int SAMPLE_WIDTH = 64;
  private static final int SAMPLE_HEIGHT = 36;
  private static final int SNAPSHOT_SIZE_LIMIT = 256 * 1024;
  private final MethodChannel channel;
  private final PlayerLookup lookup;
  private final Handler main = new Handler(Looper.getMainLooper());
  private HandlerThread thread;
  private boolean copying;
  private boolean closed;

  interface PlayerLookup {
    TextureVideoPlayer get(String session);
  }

  VideoFrameSampler(BinaryMessenger messenger, PlayerLookup lookup) {
    this.lookup = lookup;
    channel = new MethodChannel(messenger, CHANNEL);
    channel.setMethodCallHandler(this::handle);
  }

  private void handle(MethodCall call, MethodChannel.Result result) {
    boolean jpeg = "snapshot".equals(call.method);
    boolean stats = "frameStats".equals(call.method);
    if (!jpeg && !stats && !"sample".equals(call.method)) {
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
      result.success(player.getPlayingFrameStats());
      return;
    }
    if (copying || Build.VERSION.SDK_INT < 24) {
      result.success(null);
      return;
    }
    Surface surface = player.getPlayingSurface();
    if (surface == null || !surface.isValid()) {
      result.success(null);
      return;
    }
    Integer width = jpeg ? call.argument("width") : SAMPLE_WIDTH;
    Integer height = jpeg ? call.argument("height") : SAMPLE_HEIGHT;
    if (width == null || height == null || width < 1 || height < 1
        || width > 640 || height > 640) {
      result.success(null);
      return;
    }

    if (thread == null) {
      thread = new HandlerThread("SafeHoodCameraFrame");
      thread.start();
    }
    Handler worker = new Handler(thread.getLooper());
    copying = true;
    worker.post(() -> copy(surface, width, height, jpeg, worker, result));
  }

  @RequiresApi(24)
  private void copy(
      Surface surface, int width, int height, boolean jpeg,
      Handler worker, MethodChannel.Result result) {
    Bitmap bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
    try {
      PixelCopy.request(
          surface,
          bitmap,
          status -> {
            byte[] data = null;
            try {
              if (status == PixelCopy.SUCCESS) {
                data = jpeg ? encodeJpeg(bitmap) : luminance(bitmap);
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

  private void complete(MethodChannel.Result result, byte[] data) {
    main.post(() -> {
      copying = false;
      result.success(closed ? null : data);
      if (closed) stopThread();
    });
  }

  void close() {
    closed = true;
    channel.setMethodCallHandler(null);
    if (!copying) stopThread();
  }

  private void stopThread() {
    if (thread == null) return;
    thread.quitSafely();
    thread = null;
  }
}
