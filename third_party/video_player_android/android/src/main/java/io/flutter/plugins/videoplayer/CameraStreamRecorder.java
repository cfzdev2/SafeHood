package io.flutter.plugins.videoplayer;

import android.media.MediaCodec;
import android.media.MediaFormat;
import android.media.MediaMuxer;
import android.os.Handler;
import android.os.SystemClock;
import android.util.Log;
import java.io.DataInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.nio.ByteBuffer;
import java.util.HashMap;
import java.util.Map;
import java.util.function.BooleanSupplier;
import java.util.function.Consumer;

/** Remuxes the camera's original H.264, without another connection, decoder or encoder. */
public final class CameraStreamRecorder {
  public static void start(
      File cache,
      CameraVideoBuffer buffer,
      Handler worker,
      BooleanSupplier cancelled,
      Consumer<Map<String, Object>> completion) {
    start(cache, buffer, buffer.anchorAt(System.nanoTime()), worker, cancelled, completion);
  }

  public static void start(
      File cache,
      CameraVideoBuffer buffer,
      CameraVideoBuffer.Anchor anchor,
      Handler worker,
      BooleanSupplier cancelled,
      Consumer<Map<String, Object>> completion) {
    CameraVideoBuffer.Recording recording = buffer.begin(SystemClock.elapsedRealtime(), anchor);
    if (recording == null) {
      completion.accept(null);
      return;
    }
    long deadline = SystemClock.elapsedRealtime() + 6000;
    Runnable poll =
        new Runnable() {
          @Override
          public void run() {
            if (!cancelled.getAsBoolean()
                && !buffer.ready(recording)
                && SystemClock.elapsedRealtime() < deadline) {
              worker.postDelayed(this, 100);
              return;
            }
            CameraVideoBuffer.Recording ready =
                buffer.finish(recording, SystemClock.elapsedRealtime());
            completion.accept(cancelled.getAsBoolean() || ready == null ? null : mux(cache, ready));
          }
        };
    worker.post(poll);
  }

  private static Map<String, Object> mux(File cache, CameraVideoBuffer.Recording recording) {
    File temporary = null;
    MediaMuxer muxer = null;
    try {
      temporary = File.createTempFile("safehood-stream-", ".mp4", cache);
      CameraVideoBuffer.StreamFormat stream = recording.format;
      MediaFormat format = MediaFormat.createVideoFormat(stream.mime, stream.width, stream.height);
      for (int i = 0; i < stream.initializationData.size(); i++) {
        format.setByteBuffer("csd-" + i, ByteBuffer.wrap(stream.initializationData.get(i)));
      }
      muxer =
          new MediaMuxer(temporary.getAbsolutePath(), MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);
      int track = muxer.addTrack(format);
      muxer.start();
      MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
      long firstUs = recording.samples.get(0).timeUs;
      for (CameraVideoBuffer.Sample sample : recording.samples) {
        if (sample.timeUs < firstUs) continue;
        info.set(
            0,
            sample.data.length,
            sample.timeUs - firstUs,
            sample.keyFrame ? MediaCodec.BUFFER_FLAG_KEY_FRAME : 0);
        muxer.writeSampleData(track, ByteBuffer.wrap(sample.data), info);
      }
      muxer.stop();
      long size = temporary.length();
      if (size < 100 || size > CameraVideoBuffer.MAX_BYTES) return null;
      Map<String, Object> result = new HashMap<>();
      byte[] bytes = new byte[(int) size];
      try (DataInputStream input = new DataInputStream(new FileInputStream(temporary))) {
        input.readFully(bytes);
      }
      result.put("bytes", bytes);
      result.put("prebufferMillis", recording.prebufferMillis);
      Log.i(
          "SafeHoodVideo",
          "Original stream clip: bytes=" + size + ", prebufferMillis=" + recording.prebufferMillis);
      return result;
    } catch (Exception unavailable) {
      return null;
    } finally {
      if (muxer != null)
        try {
          muxer.release();
        } catch (RuntimeException ignored) {
        }
      if (temporary != null) temporary.delete();
    }
  }
}
