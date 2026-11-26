package com.safehood.securityapp;

import static org.junit.Assert.*;

import io.flutter.plugins.videoplayer.CameraFramePixels;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import org.junit.Test;

public final class CameraFramePixelsTest {
  @Test
  public void usesExplicitRgbaAndFlipsGlRowsWithoutChangingInputPosition() {
    for (ByteOrder order : new ByteOrder[] {ByteOrder.BIG_ENDIAN, ByteOrder.LITTLE_ENDIAN}) {
      ByteBuffer rgba =
          ByteBuffer.wrap(
                  new byte[] {
                    9, 9, 0, 0, (byte) 255, (byte) 255, (byte) 255, (byte) 255, (byte) 255,
                    (byte) 255, (byte) 255, 0, 0, (byte) 255, 0, (byte) 255, 0, (byte) 255
                  })
              .order(order);
      rgba.position(2);
      int[] argb = new int[4];
      CameraFramePixels.rgbaToArgb(rgba, 2, 2, argb);
      assertArrayEquals(new int[] {0xffff0000, 0xff00ff00, 0xff0000ff, 0xffffffff}, argb);
      assertEquals(2, rgba.position());
    }
  }

  @Test
  public void rejectsTruncatedFrames() {
    assertThrows(
        IllegalArgumentException.class,
        () -> CameraFramePixels.rgbaToArgb(ByteBuffer.allocate(15), 2, 2, new int[4]));
  }
}
