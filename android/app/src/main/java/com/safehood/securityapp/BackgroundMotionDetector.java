package com.safehood.securityapp;

/** Same two-sample motion threshold as the SafeHood camera preview. */
final class BackgroundMotionDetector {
  static final int WIDTH = 64;
  static final int HEIGHT = 36;
  static final int PIXELS = WIDTH * HEIGHT;

  private byte[] reference;
  private int changedFrames;
  private int quietFrames;
  private boolean episode;

  boolean hasPendingMotion() {
    return changedFrames > 0 && !episode;
  }

  void reset() {
    reference = null;
    changedFrames = 0;
    quietFrames = 0;
    episode = false;
  }

  boolean add(byte[] frame) {
    if (frame.length != PIXELS) return false;
    int low = 255;
    int high = 0;
    for (byte sample : frame) {
      low = Math.min(low, sample & 255);
      high = Math.max(high, sample & 255);
    }
    if ((high < 6 || low > 249) && high - low <= 3) {
      reset();
      return false;
    }
    if (reference == null) {
      reference = frame;
      return false;
    }
    int delta = 0;
    for (int i = 0; i < PIXELS; i++) delta += (frame[i] & 255) - (reference[i] & 255);
    int exposure = delta / PIXELS;
    int changed = 0;
    for (int i = 0; i < PIXELS; i++) {
      if (Math.abs((frame[i] & 255) - (reference[i] & 255) - exposure) >= 24) changed++;
    }
    if (changed * 100 >= PIXELS * 80) {
      // A whole-image discontinuity (decoder/scene reset) is not a
      // localized motion track. Rebase before accepting another event.
      reset();
      reference = frame;
      return false;
    }
    boolean moving = changed * 100 >= PIXELS * 7;
    if (episode) {
      reference = frame;
      quietFrames = moving ? 0 : quietFrames + 1;
      if (quietFrames == 3) {
        quietFrames = 0;
        episode = false;
      }
      return false;
    }
    if (!moving) {
      reference = frame;
      changedFrames = 0;
      return false;
    }
    if (++changedFrames < 2) return false;
    changedFrames = 0;
    episode = true;
    reference = frame;
    return true;
  }
}
