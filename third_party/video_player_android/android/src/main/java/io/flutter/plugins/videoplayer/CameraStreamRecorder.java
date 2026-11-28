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

/** Remuxes the camera's original AVC or HEVC, without another connection, decoder or encoder. */
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
    startWithResult(
        cache, buffer, anchor, worker, cancelled, result -> completion.accept(result.clip()));
  }

  public record Result(Map<String, Object> clip, String failure) {}

  public static void startWithResult(
      File cache,
      CameraVideoBuffer buffer,
      CameraVideoBuffer.Anchor anchor,
      Handler worker,
      BooleanSupplier cancelled,
      Consumer<Result> completion) {
    long now = SystemClock.elapsedRealtime();
    CameraVideoBuffer.Recording recording;
    String problem;
    synchronized (buffer) {
      recording = buffer.begin(now, anchor);
      problem = recording == null ? buffer.startProblem(now, anchor) : null;
    }
    if (recording == null) {
      completion.accept(new Result(null, problem == null ? "buffer_not_ready" : problem));
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
            if (cancelled.getAsBoolean()) completion.accept(new Result(null, "cancelled"));
            else if (ready == null) completion.accept(new Result(null, "interrupted_or_short"));
            else completion.accept(mux(cache, ready));
          }
        };
    worker.post(poll);
  }

  private static Result mux(File cache, CameraVideoBuffer.Recording recording) {
    File temporary = null;
    MediaMuxer muxer = null;
    try {
      temporary = File.createTempFile("safehood-stream-", ".mp4", cache);
      CameraVideoBuffer.StreamFormat stream = recording.format;
      MediaFormat format = MediaFormat.createVideoFormat(stream.mime, stream.width, stream.height);
      if ("video/hevc".equals(stream.mime)) {
        format.setByteBuffer("csd-0", stream.hevcConfig());
      } else {
        for (int i = 0; i < stream.initializationData.size(); i++) {
          format.setByteBuffer("csd-" + i, ByteBuffer.wrap(stream.initializationData.get(i)));
        }
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
      if (size < 100 || size > CameraVideoBuffer.MAX_BYTES) return new Result(null, "mp4_size");
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
      return new Result(result, null);
    } catch (Exception unavailable) {
      return new Result(null, "mp4_write_failed");
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
