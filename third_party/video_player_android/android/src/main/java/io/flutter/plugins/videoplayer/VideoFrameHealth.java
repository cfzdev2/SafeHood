package io.flutter.plugins.videoplayer;

/** Conservative signature of a rainbow decoder band over an otherwise empty black image. */
public final class VideoFrameHealth {
  private VideoFrameHealth() {}

  public static boolean isCorrupt(int[] argb, int width, int height) {
    if (width < 16 || height < 16 || (long) width * height != argb.length) return false;
    // Inspect the same bounded grid for preview, snapshots and background frames.
    int columns = 64;
    int rows = 36;
    int black = 0;
    int colorful = 0;
    int firstColorRow = rows;
    int lastColorRow = -1;
    int red = 0;
    int green = 0;
    int blue = 0;
    int edges = 0;
    for (int y = 0; y < rows; y++) {
      int previous = 0;
      for (int x = 0; x < columns; x++) {
        int pixel = argb[(y * height / rows) * width + x * width / columns];
        int r = (pixel >> 16) & 255;
        int g = (pixel >> 8) & 255;
        int b = pixel & 255;
        int high = Math.max(r, Math.max(g, b));
        int low = Math.min(r, Math.min(g, b));
        if (high <= 18) black++;
        if (high >= 110 && high - low >= 90) {
          colorful++;
          firstColorRow = Math.min(firstColorRow, y);
          lastColorRow = Math.max(lastColorRow, y);
          if (r > g + 35) red++;
          if (g > b + 35) green++;
          if (b > r + 35) blue++;
          if (x > 0
              && (Math.abs(r - ((previous >> 16) & 255))
                      + Math.abs(g - ((previous >> 8) & 255))
                      + Math.abs(b - (previous & 255)))
                  > 180) edges++;
        }
        previous = pixel;
      }
    }
    int count = columns * rows;
    return black * 100 >= count * 85
        && colorful * 100 >= count
        && red >= 3
        && green >= 3
        && blue >= 3
        && edges >= 8
        && lastColorRow - firstColorRow < rows / 4
        && (lastColorRow < rows / 4 || firstColorRow >= rows * 3 / 4);
  }
}
