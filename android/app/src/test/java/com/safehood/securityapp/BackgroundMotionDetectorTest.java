package com.safehood.securityapp;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import java.util.Arrays;
import org.junit.Test;

public final class BackgroundMotionDetectorTest {
    private static byte[] picture(int light, boolean movement) {
        byte[] frame = new byte[BackgroundMotionDetector.PIXELS];
        Arrays.fill(frame, (byte) light);
        if (movement) Arrays.fill(frame, 0, 360, (byte) (light + 90));
        return frame;
    }

    @Test public void rejectsExposureChangesAndConfirmsOneEventPerEpisode() {
        var detector = new BackgroundMotionDetector();
        assertFalse(detector.add(picture(80, false)));
        assertFalse(detector.add(picture(150, false)));
        assertFalse(detector.add(picture(120, false)));
        assertFalse(detector.add(picture(120, true)));
        assertTrue(detector.add(picture(120, true)));
        assertFalse(detector.add(picture(120, false)));
        for (int i = 0; i < 3; i++) assertFalse(detector.add(picture(120, false)));
        assertFalse(detector.add(picture(120, true)));
        assertTrue(detector.add(picture(120, true)));
    }

    @Test public void wholeFrameDiscontinuityDoesNotProduceMotionOnTheReturnToVideo() {
        var detector = new BackgroundMotionDetector();
        byte[] first = new byte[BackgroundMotionDetector.PIXELS];
        byte[] second = new byte[first.length];
        for (int i = 0; i < first.length; i++) {
            first[i] = (byte) ((i & 1) == 0 ? 35 : 200);
            second[i] = (byte) ((i & 1) == 0 ? 200 : 35);
        }
        assertFalse(detector.add(first));
        assertFalse(detector.add(second));
        assertFalse(detector.add(second));
        assertFalse(detector.add(first));
        assertFalse(detector.add(first));
    }

    @Test public void decoderBlankResetsUnconfirmedMotion() {
        var detector = new BackgroundMotionDetector();
        assertFalse(detector.add(picture(80, false)));
        assertFalse(detector.add(picture(80, true)));
        assertFalse(detector.add(picture(0, false)));
        assertFalse(detector.add(picture(80, true)));
        assertFalse(detector.add(picture(80, true)));
    }
}
