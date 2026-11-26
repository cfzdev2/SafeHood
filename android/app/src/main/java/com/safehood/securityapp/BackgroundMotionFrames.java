package com.safehood.securityapp;

import android.graphics.Bitmap;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.view.Surface;
import io.flutter.plugins.videoplayer.CameraFrameReader;
import io.flutter.plugins.videoplayer.VideoFrameHealth;
import java.io.ByteArrayOutputStream;

/** Shares the same OES-to-RGB frame reader as the preview, without a visible window. */
final class BackgroundMotionFrames implements AutoCloseable {
  interface Listener {
    void onSurface(Surface surface);

    void onMotion(long occurredAt, byte[] jpeg);

    void onError();

    void onCorruptFrame();
  }

  private final Handler main = new Handler(Looper.getMainLooper());
  private final BackgroundMotionDetector detector = new BackgroundMotionDetector();
  private final Listener listener;
  private final CameraFrameReader reader;
  private long lastMotion;
  private int corruptFrames;
  private volatile long lastSample;
  private volatile boolean closed;

  BackgroundMotionFrames(Listener listener) {
    this.listener = listener;
    reader =
        new CameraFrameReader(
            new CameraFrameReader.Listener() {
              @Override
              public void onSurface(Surface surface) {
                if (!closed) listener.onSurface(surface);
              }

              @Override
              public void onFrame(Bitmap frame) {
                analyze(frame);
              }

              @Override
              public void onError() {
                if (!closed) listener.onError();
              }
            });
  }

  void start() {
    reader.start();
  }

  long lastSampleAt() {
    return lastSample;
  }

  void setVideoSize(int width, int height) {
    reader.setVideoSize(width, height);
  }

  private void analyze(Bitmap frame) {
    if (closed) return;
    int width = frame.getWidth();
    int height = frame.getHeight();
    int[] pixels = new int[width * height];
    frame.getPixels(pixels, 0, width, 0, 0, width, height);
    if (VideoFrameHealth.isCorrupt(pixels, width, height)) {
      detector.reset();
      if (++corruptFrames == 2)
        main.post(
            () -> {
              if (!closed) listener.onCorruptFrame();
            });
      return;
    }
    corruptFrames = 0;
    long now = SystemClock.elapsedRealtime();
    lastSample = now;
    Bitmap small =
        Bitmap.createScaledBitmap(
            frame, BackgroundMotionDetector.WIDTH, BackgroundMotionDetector.HEIGHT, true);
    int[] argb = new int[BackgroundMotionDetector.PIXELS];
    small.getPixels(argb, 0, small.getWidth(), 0, 0, small.getWidth(), small.getHeight());
    if (small != frame) small.recycle();
    byte[] luma = new byte[argb.length];
    for (int i = 0; i < argb.length; i++) {
      int rgb = argb[i];
      luma[i] =
          (byte) ((77 * ((rgb >> 16) & 255) + 150 * ((rgb >> 8) & 255) + 29 * (rgb & 255)) >> 8);
    }
    if (!detector.add(luma) || (lastMotion != 0 && now - lastMotion < 30_000)) return;
    ByteArrayOutputStream bytes = new ByteArrayOutputStream();
    if (!frame.compress(Bitmap.CompressFormat.JPEG, 75, bytes) || bytes.size() > 256 * 1024) return;
    lastMotion = now;
    long occurredAt = System.currentTimeMillis();
    byte[] jpeg = bytes.toByteArray();
    main.post(
        () -> {
          if (!closed) listener.onMotion(occurredAt, jpeg);
        });
  }

  @Override
  public void close() {
    closed = true;
    reader.close();
  }
}
