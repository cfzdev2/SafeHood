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
    buffer.presented(step * 100_000L, (10_000 + step * 100L) * 1_000_000L);
  }

  private CameraVideoBuffer.Recording begin(CameraVideoBuffer buffer, long now) {
    return buffer.begin(now, buffer.anchorAt(now * 1_000_000L));
  }

  @Test
  public void anchorsToDisplayedVideoInsteadOfQueuedFutureFrames() {
    var buffer = buffer();
    for (int i = 0; i <= 130; i++) frame(buffer, i);
    // The decoder has queued 13 s, while the sampled display was at 8.2 s.
    var anchor = buffer.anchorAt(18_200_000_000L);
    assertNotNull(anchor);
    assertEquals(8_200_000L, anchor.timeUs);
    var clip = buffer.begin(23_000, anchor);
    assertNotNull(clip);
    assertEquals(4200, clip.prebufferMillis);
    assertEquals(4_000_000, clip.samples.get(0).timeUs);
  }

  @Test
  public void scheduledFutureDisplayCannotAdvanceTheMotionAnchor() {
    var buffer = buffer();
    frame(buffer, 0);
    frame(buffer, 10);
    assertEquals(0, buffer.anchorAt(10_500_000_000L).timeUs);
    assertEquals(1_000_000, buffer.anchorAt(11_000_000_000L).timeUs);
  }

  @Test
  public void staleAnchorCannotCrossAStreamResetEvenIfTimestampsRepeat() {
    var buffer = buffer();
    frame(buffer, 0);
    var old = buffer.anchorAt(10_000_000_000L);
    buffer.invalidate();
    frame(buffer, 0);
    assertNull(buffer.begin(10_000, old));
  }

  @Test
  public void retainsRealPreEventFramesAndOriginalPostEventFrames() {
    var buffer = buffer();
    for (int i = 0; i <= 62; i++) frame(buffer, i);
    var recording = begin(buffer, 16_200);
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
    buffer.presented(0, 10_000_000_000L);
    var recording = begin(buffer, 10_000);
    assertArrayEquals(new byte[] {8, 7}, recording.samples.get(0).data);
  }

  @Test
  public void aBrokenOrRestartedStreamCannotAttachAPartialRecording() {
    var buffer = buffer();
    for (int i = 0; i <= 30; i++) frame(buffer, i);
    var recording = begin(buffer, 13_000);
    buffer.invalidate();
    assertNull(buffer.finish(recording, 13_000));
    buffer.append(ByteBuffer.wrap(new byte[] {1}), 3_100_000, false, 13_100);
    assertNull(begin(buffer, 13_100));
    buffer.append(ByteBuffer.wrap(new byte[] {1}), 3_200_000, true, 13_200);
    buffer.presented(3_200_000, 13_200_000_000L);
    assertNotNull(begin(buffer, 13_200));
  }

  @Test
  public void byteAndTimeLimitsPreserveKeyFrameBoundaries() {
    var buffer = buffer();
    for (int i = 0; i < 150; i++) {
      buffer.append(
          ByteBuffer.wrap(new byte[100_000]), i * 100_000L, i % 10 == 0, 10_000 + i * 100L);
      buffer.presented(i * 100_000L, (10_000 + i * 100L) * 1_000_000L);
      assertTrue(buffer.retainedBytes() <= CameraVideoBuffer.MAX_BYTES);
    }
    var recording = begin(buffer, 24_900);
    assertNotNull(recording);
    assertTrue(recording.samples.get(0).keyFrame);
    assertTrue(recording.prebufferMillis <= 5000);
    buffer.close();
    assertEquals(0, buffer.retainedBytes());
    assertNull(begin(buffer, 24_900));
  }

  @Test
  public void formatChangeOrTimestampJumpInvalidatesHistory() {
    var buffer = buffer();
    for (int i = 0; i <= 30; i++) frame(buffer, i);
    var old = begin(buffer, 13_000);
    buffer.configure(
        new CameraVideoBuffer.StreamFormat("video/avc", 320, 180, List.of(new byte[] {1})));
    assertNull(buffer.finish(old, 13_000));
    assertNull(begin(buffer, 13_000));
    buffer.append(ByteBuffer.wrap(new byte[] {1}), 0, true, 14_000);
    buffer.presented(0, 14_000_000_000L);
    assertEquals(0, begin(buffer, 14_000).prebufferMillis);
    buffer.append(ByteBuffer.wrap(new byte[] {2}), 9_000_000, false, 14_100);
    assertNull(begin(buffer, 14_100));
  }

  @Test
  public void stalledAndOversizedRecordingsAreRejected() {
    var buffer = buffer();
    frame(buffer, 0);
    assertNull(begin(buffer, 12_000));
    frame(buffer, 10);
    var recording = begin(buffer, 11_000);
    assertNull(buffer.finish(recording, 13_000));
    frame(buffer, 20);
    recording = begin(buffer, 12_000);
    for (int i = 21; i <= 30; i++)
      buffer.append(
          ByteBuffer.wrap(new byte[800_000]), i * 100_000L, i % 10 == 0, 10_000 + i * 100L);
    assertNull(buffer.finish(recording, 13_000));
  }

  private void receive(CameraVideoBuffer buffer, int i) {
    buffer.append(
        ByteBuffer.wrap(new byte[] {(byte) i}), i * 100_000L, i % 10 == 0, 10_000 + i * 100L);
  }

  @Test
  public void nativeAlarmWithNoDisplayKeepsActualVideoBeforeAndAfterMotion() {
    var buffer = buffer();
    // The alarm photo arrived 3 seconds after the alarm. No frames went to a display.
    for (int i = 0; i <= 100; i++) receive(buffer, i);
    assertNull(buffer.anchorAt(17_000_000_000L));
    var atMotion = buffer.backgroundAnchorAt(17_000_000_000L, 17_000);
    assertNotNull(atMotion);
    assertEquals(7_000_000L, atMotion.timeUs);
    var job = buffer.begin(20_000, atMotion);
    assertNotNull(job);
    for (int i = 101; i <= 120; i++) receive(buffer, i);
    var clip = buffer.finish(job, 22_000);
    assertNotNull(clip);
    assertEquals(5000, clip.prebufferMillis);
    assertArrayEquals(new byte[] {20}, clip.samples.get(0).data);
    assertArrayEquals(new byte[] {120}, clip.samples.get(clip.samples.size() - 1).data);
  }

  @Test
  public void aRealDisplayAnchorStillWinsOverDecoderLookAheadInBackground() {
    var buffer = buffer();
    for (int i = 0; i <= 100; i++) receive(buffer, i);
    buffer.presented(6_000_000L, 20_000_000_000L);
    // The camera has delivered 10s, but only 6s was on screen at detection.
    assertEquals(6_000_000L, buffer.backgroundAnchorAt(20_000_000_000L, 20_000).timeUs);
  }

  @Test
  public void packetFallbackNeverUsesFutureStaleOrPreviousSessionEvidence() {
    var buffer = buffer();
    receive(buffer, 0);
    assertNull(buffer.backgroundAnchorAt(0, 9999));
    assertNull(buffer.backgroundAnchorAt(0, 12_000));
    var old = buffer.backgroundAnchorAt(0, 10_000);
    buffer.invalidate();
    assertEquals(-1L, buffer.lastRecordablePacketAt());
    receive(buffer, 30);
    assertNull(buffer.backgroundAnchorAt(0, 10_000));
    assertEquals("stream_changed", buffer.startProblem(13_000, old));
    buffer.close();
    assertNull(buffer.backgroundAnchorAt(0, 13_000));
  }

  @Test
  public void hevcMuxerGetsOneAnnexBConfigurationInCameraOrder() {
    byte[] vps = {0, 0, 0, 1, 64, 1};
    byte[] sps = {0, 0, 0, 1, 66, 1};
    byte[] pps = {0, 0, 0, 1, 68, 1};
    byte[] expected = {0, 0, 0, 1, 64, 1, 0, 0, 0, 1, 66, 1, 0, 0, 0, 1, 68, 1};
    for (List<byte[]> config : List.of(List.of(vps, sps, pps), List.of(expected))) {
      var format = new CameraVideoBuffer.StreamFormat("video/hevc", 1920, 1080, config);
      var combined = format.hevcConfig();
      byte[] bytes = new byte[combined.remaining()];
      combined.get(bytes);
      assertArrayEquals(expected, bytes);
    }
  }

  @Test
  public void fullHdAvcAndHevcKeepBothSidesOfAnAlarmWithoutDisplay() {
    for (String mime : List.of("video/avc", "video/hevc")) {
      var buffer = new CameraVideoBuffer();
      buffer.configure(new CameraVideoBuffer.StreamFormat(mime, 1920, 1080, List.of(new byte[]{1})));
      for (int i = 0; i <= 70; i++) receive(buffer, i);
      var anchor = buffer.backgroundAnchorAt(0, 17_000);
      var job = buffer.begin(17_000, anchor);
      assertNotNull(job);
      for (int i = 71; i <= 120; i++) receive(buffer, i);
      var clip = buffer.finish(job, 22_000);
      assertNotNull(clip);
      assertEquals(5000, clip.prebufferMillis);
      assertEquals(mime, clip.format.mime);
      assertEquals(101, clip.samples.size());
      buffer.configure(new CameraVideoBuffer.StreamFormat(mime, 7680, 4320, List.of()));
      assertTrue(buffer.unsupportedClipFormat());
    }
  }

  @Test
  public void incompatibleProfileAndMissingKeyframeAreDistinguished() {
    var buffer = new CameraVideoBuffer();
    assertEquals("waiting_for_format", buffer.startProblem(10_000, null));
    buffer.configure(new CameraVideoBuffer.StreamFormat("video/unknown", 640, 360, List.of()));
    assertTrue(buffer.unsupportedClipFormat());
    assertEquals("unsupported_profile", buffer.startProblem(10_000, null));
    buffer.close();
    buffer = buffer();
    assertFalse(buffer.unsupportedClipFormat());
    receive(buffer, 1);
    assertEquals("waiting_for_keyframe", buffer.startProblem(10_100, null));
    receive(buffer, 10);
    assertTrue(buffer.hasRecentRecordablePackets(11_000));
    assertFalse(buffer.hasRecentRecordablePackets(14_000));
  }
}
