package io.flutter.plugins.videoplayer;

import android.graphics.Bitmap;
import android.media.Image;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.media.MediaMuxer;
import android.os.Handler;
import android.os.SystemClock;
import android.view.PixelCopy;
import android.view.Surface;
import androidx.annotation.RequiresApi;
import java.io.DataInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.util.function.BooleanSupplier;
import java.util.function.Consumer;

/** Makes one short, silent recording from the existing preview surface. */
@RequiresApi(24)
final class MotionClipRecorder {
  static final int MAX_EDGE = 320;
  private static final int MAX_BYTES = 1024 * 1024;
  private static final int FPS = 6;
  private static final int FRAME_LIMIT = 5 * FPS;
  private static final long DEADLINE_MS = 6000;

  private final File cacheDirectory;
  private final Surface surface;
  private final int width;
  private final int height;
  private final Handler worker;
  private final BooleanSupplier cancelled;
  private final Consumer<byte[]> complete;
  private final int[] pixels;
  private final MediaCodec.BufferInfo output = new MediaCodec.BufferInfo();
  private Bitmap bitmap;
  private File temporary;
  private MediaCodec encoder;
  private MediaMuxer muxer;
  private int track = -1;
  private int frames;
  private int attempts;
  private long startedAt;
  private long firstFrameAt;
  private long lastPresentationUs;
  private boolean finished;

  MotionClipRecorder(
      File cacheDirectory,
      Surface surface,
      int width,
      int height,
      Handler worker,
      BooleanSupplier cancelled,
      Consumer<byte[]> complete) {
    this.cacheDirectory = cacheDirectory;
    this.surface = surface;
    this.width = width;
    this.height = height;
    this.worker = worker;
    this.cancelled = cancelled;
    this.complete = complete;
    pixels = new int[width * height];
  }

  void start() {
    try {
      if (cancelled.getAsBoolean() || !surface.isValid()) {
        finish(false);
        return;
      }
      bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
      temporary = File.createTempFile("safehood-motion-", ".mp4", cacheDirectory);
      MediaFormat format =
          MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height);
      format.setInteger(
          MediaFormat.KEY_COLOR_FORMAT,
          MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible);
      format.setInteger(MediaFormat.KEY_FRAME_RATE, FPS);
      format.setInteger(MediaFormat.KEY_BIT_RATE, 300_000);
      format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1);
      encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC);
      encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
      muxer =
          new MediaMuxer(temporary.getAbsolutePath(), MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);
      encoder.start();
      startedAt = SystemClock.uptimeMillis();
      capture();
    } catch (IOException | RuntimeException unavailable) {
      finish(false);
    }
  }

  private void capture() {
    if (cancelled.getAsBoolean() || !surface.isValid()) {
      finish(false);
      return;
    }
    if (attempts >= FRAME_LIMIT || SystemClock.uptimeMillis() - startedAt >= DEADLINE_MS) {
      finish(true);
      return;
    }
    attempts++;
    try {
      PixelCopy.request(surface, bitmap, this::onCopy, worker);
    } catch (RuntimeException unavailable) {
      finish(false);
    }
  }

  private void onCopy(int status) {
    try {
      if (cancelled.getAsBoolean() || !surface.isValid()) {
        finish(false);
        return;
      }
      if (status == PixelCopy.SUCCESS) {
        if (VideoFrameSampler.isCorrupt(bitmap)) {
          finish(false);
          return;
        }
        queueFrame();
      }
      // Keep at most one copy in flight even if the decoder or encoder is slow.
      worker.postAtTime(
          this::capture,
          Math.max(SystemClock.uptimeMillis() + 16, startedAt + attempts * 1000L / FPS));
    } catch (RuntimeException unavailable) {
      finish(false);
    }
  }

  private void queueFrame() {
    drain(false);
    int input = encoder.dequeueInputBuffer(5000);
    if (input < 0) return;
    Image image = encoder.getInputImage(input);
    if (image == null || image.getWidth() < width || image.getHeight() < height) {
      throw new IllegalStateException("Unsupported encoder input");
    }
    Image.Plane[] planes = image.getPlanes();
    if (planes.length != 3) throw new IllegalStateException("Expected YUV420");
    bitmap.getPixels(pixels, 0, width, 0, 0, width, height);
    Plane luma = new Plane(planes[0]);
    Plane cb = new Plane(planes[1]);
    Plane cr = new Plane(planes[2]);
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int argb = pixels[row * width + col];
        int r = (argb >> 16) & 255;
        int g = (argb >> 8) & 255;
        int b = argb & 255;
        luma.set(row, col, ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16);
        if (((row | col) & 1) == 0) {
          cb.set(row / 2, col / 2, ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128);
          cr.set(row / 2, col / 2, ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128);
        }
      }
    }
    long now = SystemClock.uptimeMillis();
    if (frames == 0) firstFrameAt = now;
    long pts = Math.max(frames == 0 ? 0 : lastPresentationUs + 1, (now - firstFrameAt) * 1000);
    // Queueing returns ownership of the Image to MediaCodec.
    encoder.queueInputBuffer(input, 0, width * height * 3 / 2, pts, 0);
    lastPresentationUs = pts;
    frames++;
    drain(false);
  }

  private static final class Plane {
    final ByteBuffer buffer;
    final int start;
    final int rowStride;
    final int pixelStride;

    Plane(Image.Plane plane) {
      buffer = plane.getBuffer();
      start = buffer.position();
      rowStride = plane.getRowStride();
      pixelStride = plane.getPixelStride();
    }

    void set(int row, int col, int value) {
      buffer.put(start + row * rowStride + col * pixelStride, (byte) value);
    }
  }

  private boolean drain(boolean untilEnd) {
    long deadline = SystemClock.uptimeMillis() + 700;
    do {
      int index = encoder.dequeueOutputBuffer(output, untilEnd ? 10000 : 0);
      if (index == MediaCodec.INFO_TRY_AGAIN_LATER && !untilEnd) return false;
      if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
        track = muxer.addTrack(encoder.getOutputFormat());
        muxer.start();
      } else if (index >= 0) {
        boolean end = (output.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0;
        try {
          if (output.size > 0 && (output.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0) {
            ByteBuffer data = encoder.getOutputBuffer(index);
            if (data == null || track < 0) throw new IllegalStateException("No video track");
            data.position(output.offset);
            data.limit(output.offset + output.size);
            muxer.writeSampleData(track, data, output);
          }
        } finally {
          encoder.releaseOutputBuffer(index, false);
        }
        if (end) return true;
      }
    } while (SystemClock.uptimeMillis() < deadline);
    return false;
  }

  private void finish(boolean save) {
    if (finished) return;
    finished = true;
    byte[] result = null;
    try {
      if (save
          && frames >= 8
          && lastPresentationUs >= 1_000_000
          && !cancelled.getAsBoolean()
          && surface.isValid()) {
        drain(false);
        int input = encoder.dequeueInputBuffer(40000);
        if (input >= 0) {
          encoder.queueInputBuffer(
              input,
              0,
              0,
              lastPresentationUs + 1000000 / FPS,
              MediaCodec.BUFFER_FLAG_END_OF_STREAM);
          if (drain(true) && track >= 0) {
            muxer.stop();
            long size = temporary.length();
            if (size >= 100 && size <= MAX_BYTES) {
              byte[] bytes = new byte[(int) size];
              try (DataInputStream stream = new DataInputStream(new FileInputStream(temporary))) {
                stream.readFully(bytes);
                result = bytes;
              }
            }
          }
        }
      }
    } catch (IOException | RuntimeException unavailable) {
      // A failed recording should not affect the detection or its picture.
    } finally {
      if (bitmap != null) bitmap.recycle();
      if (encoder != null) {
        try {
          encoder.release();
        } catch (RuntimeException ignored) {
        }
      }
      if (muxer != null) {
        try {
          muxer.release();
        } catch (RuntimeException ignored) {
        }
      }
      if (temporary != null) temporary.delete();
      complete.accept(result);
    }
  }
}
