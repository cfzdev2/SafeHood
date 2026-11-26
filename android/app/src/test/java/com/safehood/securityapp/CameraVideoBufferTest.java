package com.safehood.securityapp;

import static org.junit.Assert.*;

import io.flutter.plugins.videoplayer.CameraVideoBuffer;
import java.nio.ByteBuffer;
import java.util.List;
import org.junit.Test;

public final class CameraVideoBufferTest {
  private CameraVideoBuffer buffer() {
    var buffer = new CameraVideoBuffer();
    buffer.configure(
        new CameraVideoBuffer.StreamFormat(
            "video/avc",
            640,
            360,
            List.of(new byte[] {0, 0, 0, 1, 103}, new byte[] {0, 0, 0, 1, 104})));
    return buffer;
  }

  private void frame(CameraVideoBuffer buffer, int step) {
    buffer.append(
        ByteBuffer.wrap(new byte[] {0, 0, 0, 1, (byte) step}),
        step * 100_000L,
        step % 10 == 0,
        10_000 + step * 100L);
  }

  @Test
  public void retainsRealPreEventFramesAndOriginalPostEventFrames() {
    var buffer = buffer();
    for (int i = 0; i <= 62; i++) frame(buffer, i);
    var recording = buffer.begin(16_200);
    assertNotNull(recording);
    assertEquals(4200, recording.prebufferMillis);
    assertEquals(2_000_000, recording.samples.get(0).timeUs);
    assertTrue(recording.samples.get(0).keyFrame);
    for (int i = 63; i <= 112; i++) frame(buffer, i);
    var finished = buffer.finish(recording, 21_200);
    assertNotNull(finished);
    assertEquals(93, finished.samples.size());
    assertArrayEquals(new byte[] {0, 0, 0, 1, 112}, finished.samples.get(92).data);
  }

  @Test
  public void copiesOnlyTheReadableBufferWithoutChangingItsPosition() {
    var buffer = buffer();
    byte[] bytes = {9, 8, 7, 6};
    var input = ByteBuffer.wrap(bytes);
    input.position(1);
    input.limit(3);
    buffer.append(input, 0, true, 10_000);
    bytes[1] = 99;
    assertEquals(1, input.position());
    assertEquals(3, input.limit());
    var recording = buffer.begin(10_000);
    assertArrayEquals(new byte[] {8, 7}, recording.samples.get(0).data);
  }

  @Test
  public void aBrokenOrRestartedStreamCannotAttachAPartialRecording() {
    var buffer = buffer();
    for (int i = 0; i <= 30; i++) frame(buffer, i);
    var recording = buffer.begin(13_000);
    buffer.invalidate();
    assertNull(buffer.finish(recording, 13_000));
    buffer.append(ByteBuffer.wrap(new byte[] {1}), 3_100_000, false, 13_100);
    assertNull(buffer.begin(13_100));
    buffer.append(ByteBuffer.wrap(new byte[] {1}), 3_200_000, true, 13_200);
    assertNotNull(buffer.begin(13_200));
  }

  @Test
  public void byteAndTimeLimitsPreserveKeyFrameBoundaries() {
    var buffer = buffer();
    for (int i = 0; i < 150; i++) {
      buffer.append(
          ByteBuffer.wrap(new byte[100_000]), i * 100_000L, i % 10 == 0, 10_000 + i * 100L);
      assertTrue(buffer.retainedBytes() <= CameraVideoBuffer.MAX_BYTES);
    }
    var recording = buffer.begin(24_900);
    assertNotNull(recording);
    assertTrue(recording.samples.get(0).keyFrame);
    assertTrue(recording.prebufferMillis <= 5000);
    buffer.close();
    assertEquals(0, buffer.retainedBytes());
    assertNull(buffer.begin(24_900));
  }

  @Test
  public void formatChangeOrTimestampJumpInvalidatesHistory() {
    var buffer = buffer();
    for (int i = 0; i <= 30; i++) frame(buffer, i);
    var old = buffer.begin(13_000);
    buffer.configure(
        new CameraVideoBuffer.StreamFormat("video/avc", 320, 180, List.of(new byte[] {1})));
    assertNull(buffer.finish(old, 13_000));
    assertNull(buffer.begin(13_000));
    buffer.append(ByteBuffer.wrap(new byte[] {1}), 0, true, 14_000);
    assertEquals(0, buffer.begin(14_000).prebufferMillis);
    buffer.append(ByteBuffer.wrap(new byte[] {2}), 9_000_000, false, 14_100);
    assertNull(buffer.begin(14_100));
  }

  @Test
  public void stalledAndOversizedRecordingsAreRejected() {
    var buffer = buffer();
    frame(buffer, 0);
    assertNull(buffer.begin(12_000));
    frame(buffer, 10);
    var recording = buffer.begin(11_000);
    assertNull(buffer.finish(recording, 13_000));
    frame(buffer, 20);
    recording = buffer.begin(12_000);
    for (int i = 21; i <= 30; i++)
      buffer.append(
          ByteBuffer.wrap(new byte[800_000]), i * 100_000L, i % 10 == 0, 10_000 + i * 100L);
    assertNull(buffer.finish(recording, 13_000));
  }
}
