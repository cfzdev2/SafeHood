package io.flutter.plugins.videoplayer;

import java.nio.ByteBuffer;

/** Explicit RGBA byte order and GL's bottom-up rows; independent of native buffer strides. */
public final class CameraFramePixels {
  private CameraFramePixels() {}

  public static void rgbaToArgb(ByteBuffer rgba, int width, int height, int[] argb) {
    if (width < 1
        || height < 1
        || argb.length != width * height
        || rgba.remaining() < argb.length * 4)
      throw new IllegalArgumentException("Invalid RGBA frame");
    int start = rgba.position();
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = start + ((height - 1 - row) * width + col) * 4;
        argb[row * width + col] =
            0xff000000
                | (rgba.get(offset) & 255) << 16
                | (rgba.get(offset + 1) & 255) << 8
                | (rgba.get(offset + 2) & 255);
      }
    }
  }
}
