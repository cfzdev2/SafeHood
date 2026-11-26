package io.flutter.plugins.videoplayer;

import java.nio.ByteBuffer;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** Bounded, session-owned compressed video. Never retains a decoder's mutable input buffer. */
public final class CameraVideoBuffer implements AutoCloseable {
  public static final int MAX_BYTES = 6 * 1024 * 1024;
  private static final long WINDOW_US = 8_000_000;
  private static final long PREBUFFER_US = 5_000_000;
  private final ArrayDeque<Sample> samples = new ArrayDeque<>();
  private StreamFormat format;
  private Recording recording;
  private int bytes;
  private long newestUs = Long.MIN_VALUE;
  private long newestAt;
  private boolean closed;

  public static final class StreamFormat {
    public final String mime;
    public final int width;
    public final int height;
    public final List<byte[]> initializationData;

    public StreamFormat(String mime, int width, int height, List<byte[]> initializationData) {
      this.mime = mime;
      this.width = width;
      this.height = height;
      this.initializationData = new ArrayList<>();
      for (byte[] data : initializationData) this.initializationData.add(data.clone());
    }

    boolean same(StreamFormat other) {
      if (other == null
          || !mime.equals(other.mime)
          || width != other.width
          || height != other.height
          || initializationData.size() != other.initializationData.size()) return false;
      for (int i = 0; i < initializationData.size(); i++) {
        if (!Arrays.equals(initializationData.get(i), other.initializationData.get(i)))
          return false;
      }
      return true;
    }
  }

  public static final class Sample {
    public final long timeUs;
    public final boolean keyFrame;
    public final byte[] data;

    Sample(long timeUs, boolean keyFrame, byte[] data) {
      this.timeUs = timeUs;
      this.keyFrame = keyFrame;
      this.data = data;
    }
  }

  public static final class Recording {
    public final StreamFormat format;
    public final List<Sample> samples;
    public final int prebufferMillis;
    private final long triggerUs;
    private int bytes;
    private boolean valid = true;

    Recording(StreamFormat format, List<Sample> samples, long triggerUs) {
      this.format = format;
      this.samples = samples;
      this.triggerUs = triggerUs;
      this.prebufferMillis = (int) Math.max(0, (triggerUs - samples.get(0).timeUs) / 1000);
      for (Sample sample : samples) bytes += sample.data.length;
    }
  }

  public synchronized void configure(StreamFormat next) {
    if (closed) return;
    if (!next.same(format)) invalidate();
    format = next;
  }

  public synchronized void append(ByteBuffer input, long timeUs, boolean keyFrame, long atMillis) {
    if (closed || format == null || !"video/avc".equals(format.mime) || input == null) return;
    int size = input.remaining();
    if (size == 0) return;
    if (size > MAX_BYTES
        || (newestUs != Long.MIN_VALUE
            && (timeUs < newestUs - 2_000_000
                || timeUs > newestUs + 3_000_000
                || atMillis - newestAt > 3000))) invalidate();
    if (size > MAX_BYTES) return;
    // After a reset, wait for an independently decodable GOP.
    if (samples.isEmpty() && !keyFrame) return;
    byte[] copy = new byte[size];
    input.duplicate().get(copy);
    Sample sample = new Sample(timeUs, keyFrame, copy);
    samples.addLast(sample);
    bytes += size;
    newestUs = Math.max(newestUs, timeUs);
    newestAt = atMillis;
    if (recording != null && recording.valid) {
      recording.bytes += size;
      if (recording.bytes > MAX_BYTES || recording.samples.size() >= 2400) {
        recording.valid = false;
        recording.samples.clear();
      } else if (timeUs <= recording.triggerUs + 5_500_000) {
        recording.samples.add(sample);
      }
    }
    while (!samples.isEmpty()
        && (bytes > MAX_BYTES
            || samples.size() > 2400
            || newestUs - samples.peekFirst().timeUs > WINDOW_US)) {
      bytes -= samples.removeFirst().data.length;
    }
    while (!samples.isEmpty() && !samples.peekFirst().keyFrame) {
      bytes -= samples.removeFirst().data.length;
    }
  }

  public synchronized Recording begin(long nowMillis) {
    if (closed
        || recording != null
        || samples.isEmpty()
        || nowMillis - newestAt > 1500
        || format == null
        || format.initializationData.isEmpty()
        || format.width < 1
        || format.height < 1
        || format.width > 1280
        || format.height > 720) return null;
    // Pick a real key frame inside the prebuffer window; never invent missing history.
    Sample first = null;
    for (Sample sample : samples) {
      if (sample.keyFrame && sample.timeUs >= newestUs - PREBUFFER_US) {
        first = sample;
        break;
      }
    }
    if (first == null) return null;
    List<Sample> selected = new ArrayList<>();
    boolean include = false;
    for (Sample sample : samples) {
      if (sample == first) include = true;
      if (include) selected.add(sample);
    }
    recording = new Recording(format, selected, newestUs);
    return recording;
  }

  public synchronized Recording finish(Recording target, long nowMillis) {
    if (target == null || recording != target) return null;
    recording = null;
    if (closed
        || !target.valid
        || nowMillis - newestAt > 1500
        || target.samples.size() < 2
        || target.samples.get(target.samples.size() - 1).timeUs - target.triggerUs < 1_000_000)
      return null;
    return target;
  }

  public synchronized void invalidate() {
    samples.clear();
    bytes = 0;
    newestUs = Long.MIN_VALUE;
    if (recording != null) {
      recording.valid = false;
      recording.samples.clear();
      recording = null;
    }
  }

  public synchronized int retainedBytes() {
    return bytes;
  }

  @Override
  public synchronized void close() {
    closed = true;
    invalidate();
    format = null;
  }
}
