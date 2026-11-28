package io.flutter.plugins.videoplayer;

import java.nio.ByteBuffer;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** Bounded, session-owned compressed video. Never retains a decoder's mutable input buffer. */
public final class CameraVideoBuffer implements AutoCloseable {
  public static final int MAX_BYTES = 6 * 1024 * 1024;
  public static boolean supportsClipMime(String mime) {
    return "video/avc".equals(mime) || "video/hevc".equals(mime);
  }

  private static final long WINDOW_US = 15_000_000;
  private static final long PREBUFFER_US = 5_000_000;
  private final ArrayDeque<Sample> samples = new ArrayDeque<>();
  private final ArrayDeque<Presentation> presentations = new ArrayDeque<>();
  private long epoch;
  private StreamFormat format;
  private Recording recording;
  private int bytes;
  private long newestUs = Long.MIN_VALUE;
  private long newestAt;
  private boolean closed;

  public static final class Anchor {
    public final long timeUs;
    public final long epoch;

    public Anchor(long timeUs, long epoch) {
      this.timeUs = timeUs;
      this.epoch = epoch;
    }
  }

  private record Presentation(long timeUs, long releaseNs) {}

  /** Tracks output actually released for display, independently of decoder input look-ahead. */
  public synchronized void presented(long timeUs, long releaseNs) {
    if (closed || format == null) return;
    presentations.addLast(new Presentation(timeUs, releaseNs));
    while (presentations.size() > 2400
        || (!presentations.isEmpty()
            && releaseNs - presentations.peekFirst().releaseNs() > 20_000_000_000L))
      presentations.removeFirst();
  }

  public synchronized Anchor anchorAt(long atNs) {
    Presentation last = null;
    for (Presentation item : presentations) {
      if (item.releaseNs() <= atNs && (last == null || item.releaseNs() > last.releaseNs()))
        last = item;
    }
    return last == null || atNs - last.releaseNs() > 3_000_000_000L
        ? null
        : new Anchor(last.timeUs(), epoch);
  }

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

    // Android stores the Annex B VPS/SPS/PPS together under csd-0 for HEVC.
    // Media3 RTSP can provide them as three separate initialization buffers.
    public ByteBuffer hevcConfig() {
      int size = 0;
      for (byte[] data : initializationData) {
        if (data.length > MAX_BYTES - size) throw new IllegalArgumentException("HEVC config size");
        size += data.length;
      }
      if (size == 0) throw new IllegalArgumentException("Missing HEVC config");
      ByteBuffer combined = ByteBuffer.allocate(size);
      for (byte[] data : initializationData) combined.put(data);
      combined.flip();
      return combined;
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
    private final long receivedAtMillis;

    Sample(long timeUs, boolean keyFrame, byte[] data, long receivedAtMillis) {
      this.timeUs = timeUs;
      this.keyFrame = keyFrame;
      this.data = data;
      this.receivedAtMillis = receivedAtMillis;
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
    if (closed || format == null || unsupportedClipFormat() || input == null) return;
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
    Sample sample = new Sample(timeUs, keyFrame, copy, atMillis);
    samples.addLast(sample);
    bytes += size;
    newestUs = Math.max(newestUs, timeUs);
    newestAt = atMillis;
    if (recording != null && recording.valid) {
      if (timeUs <= recording.triggerUs + 5_000_000) {
        recording.bytes += size;
        if (recording.bytes > MAX_BYTES || recording.samples.size() >= 2400) {
          recording.valid = false;
          recording.samples.clear();
        } else {
          recording.samples.add(sample);
        }
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
    return begin(nowMillis, anchorAt(System.nanoTime()));
  }

  // A camera alarm has no displayed frame of its own. Prefer the presentation timeline
  // when available, otherwise map the alarm to an actual packet already received at that
  // instant. Both histories belong to this stream epoch; never use a later packet.
  public synchronized Anchor backgroundAnchorAt(long presentationNs, long arrivalMillis) {
    Anchor displayed = anchorAt(presentationNs);
    if (displayed != null && displayed.timeUs <= newestUs && firstKeyAt(displayed.timeUs) != null)
      return displayed;
    for (var it = samples.descendingIterator(); it.hasNext(); ) {
      Sample sample = it.next();
      if (sample.receivedAtMillis > arrivalMillis) continue;
      if (arrivalMillis - sample.receivedAtMillis > 1500) return null;
      return new Anchor(sample.timeUs, epoch);
    }
    return null;
  }

  public synchronized boolean unsupportedClipFormat() {
    return format != null
        && (!supportsClipMime(format.mime)
            || Math.max(format.width, format.height) > 4096
            || Math.min(format.width, format.height) > 2160);
  }

  public synchronized String profileDescription() {
    if (format == null) return "unknown";
    String mime = format.mime != null && format.mime.matches("video/[a-zA-Z0-9.+_-]{1,32}")
        ? format.mime : "other";
    return mime + ":" + format.width + "x" + format.height;
  }

  public synchronized long lastRecordablePacketAt() {
    if (closed
        || format == null
        || unsupportedClipFormat()
        || format.width < 1
        || format.height < 1
        || format.initializationData.isEmpty()
        || samples.isEmpty()) return -1;
    return newestAt;
  }

  public synchronized boolean hasRecentRecordablePackets(long nowMillis) {
    long last = lastRecordablePacketAt();
    return last >= 0 && nowMillis >= last && nowMillis - last <= 1500;
  }

  private Sample firstKeyAt(long timeUs) {
    for (Sample sample : samples) {
      if (sample.keyFrame && sample.timeUs >= timeUs - PREBUFFER_US && sample.timeUs <= timeUs)
        return sample;
    }
    return null;
  }

  /** Coarse recording diagnostics only. Never includes a camera address or media. */
  public synchronized String startProblem(long nowMillis, Anchor anchor) {
    if (closed) return "receiver_closed";
    if (format == null) return "waiting_for_format";
    if (unsupportedClipFormat()) return "unsupported_profile";
    if (format.width < 1 || format.height < 1 || format.initializationData.isEmpty())
      return "incomplete_format";
    if (samples.isEmpty()) return "waiting_for_keyframe";
    if (!hasRecentRecordablePackets(nowMillis)) return "stale_packets";
    if (anchor == null) return "no_frame_at_alarm";
    if (anchor.epoch != epoch || anchor.timeUs > newestUs) return "stream_changed";
    if (recording != null) return "already_recording";
    if (firstKeyAt(anchor.timeUs) == null) return "no_keyframe_before_alarm";
    return null;
  }

  public synchronized Recording begin(long nowMillis, Anchor anchor) {
    if (startProblem(nowMillis, anchor) != null) return null;
    Sample first = firstKeyAt(anchor.timeUs);
    List<Sample> selected = new ArrayList<>();
    boolean include = false;
    for (Sample sample : samples) {
      if (sample == first) include = true;
      if (include && sample.timeUs <= anchor.timeUs + 5_000_000) selected.add(sample);
    }
    recording = new Recording(format, selected, anchor.timeUs);
    return recording;
  }

  public synchronized boolean ready(Recording target) {
    return target == null
        || recording != target
        || !target.valid
        || newestUs >= target.triggerUs + 5_000_000;
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
    epoch++;
    presentations.clear();
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
