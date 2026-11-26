package com.safehood.securityapp;

import static org.junit.Assert.*;
import io.flutter.plugins.videoplayer.VideoFrameHealth;
import java.util.Arrays;
import org.junit.Test;

public final class VideoFrameHealthTest {
    private static final int WIDTH = 64;
    private static final int HEIGHT = 36;

    @Test public void rejectsChangingRainbowBandsOnAnEmptyDecoderImage() {
        for (int shift = 0; shift < 4; shift++) {
            int[] image = new int[WIDTH * HEIGHT];
            int[] colors = {0xffff00ff, 0xff00ff00, 0xff0000ff, 0xffffff00};
            for (int row = 0; row < 4; row++) {
                for (int col = 0; col < WIDTH; col++) image[row * WIDTH + col] = colors[(col + shift) % colors.length];
            }
            assertTrue(VideoFrameHealth.isCorrupt(image, WIDTH, HEIGHT));
        }
    }

    @Test public void infraredNightFramesAndAColoredObjectAreNotDecoderCorruption() {
        int[] image = new int[WIDTH * HEIGHT];
        for (int i = 0; i < image.length; i++) {
            int gray = i % WIDTH < 18 ? 170 : 5;
            image[i] = 0xff000000 | gray << 16 | gray << 8 | gray;
        }
        assertFalse(VideoFrameHealth.isCorrupt(image, WIDTH, HEIGHT));
        Arrays.fill(image, WIDTH * 12, WIDTH * 24, 0xffff0033);
        assertFalse(VideoFrameHealth.isCorrupt(image, WIDTH, HEIGHT));
    }

    @Test public void aDarkPictureOrASolidStatusLineDoesNotRestartTheDecoder() {
        int[] image = new int[WIDTH * HEIGHT];
        assertFalse(VideoFrameHealth.isCorrupt(image, WIDTH, HEIGHT));
        Arrays.fill(image, 0, WIDTH * 2, 0xff00ff00);
        assertFalse(VideoFrameHealth.isCorrupt(image, WIDTH, HEIGHT));
    }

    @Test public void ordinaryColorScenesAreNotRejected() {
        int[] image = new int[WIDTH * HEIGHT];
        for (int i = 0; i < image.length; i++) image[i] = 0xff000000 | (i * 9323 & 0xffffff);
        assertFalse(VideoFrameHealth.isCorrupt(image, WIDTH, HEIGHT));
    }
}
