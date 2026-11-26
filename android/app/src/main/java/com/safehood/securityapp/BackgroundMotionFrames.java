package com.safehood.securityapp;

import android.graphics.Bitmap;
import android.graphics.SurfaceTexture;
import android.opengl.EGL14;
import android.opengl.EGLConfig;
import android.opengl.EGLContext;
import android.opengl.EGLDisplay;
import android.opengl.EGLSurface;
import android.opengl.GLES20;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;
import android.os.SystemClock;
import android.view.PixelCopy;
import android.view.Surface;
import java.io.ByteArrayOutputStream;
import io.flutter.plugins.videoplayer.VideoFrameHealth;

/** A decoder surface whose consumer remains available with no Activity or window. */
final class BackgroundMotionFrames implements AutoCloseable {
    interface Listener {
        void onSurface(Surface surface);
        void onMotion(long occurredAt, byte[] jpeg);
        void onError();
        void onCorruptFrame();
    }

    private final HandlerThread thread = new HandlerThread("SafeHoodBackgroundFrames");
    private final Handler worker;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final BackgroundMotionDetector detector = new BackgroundMotionDetector();
    private final int[] argb = new int[BackgroundMotionDetector.PIXELS];
    private final Listener listener;
    private EGLDisplay display = EGL14.EGL_NO_DISPLAY;
    private EGLContext context = EGL14.EGL_NO_CONTEXT;
    private EGLSurface pbuffer = EGL14.EGL_NO_SURFACE;
    private SurfaceTexture texture;
    private Surface surface;
    private boolean copying;
    private long lastCopy;
    private long lastMotion;
    private int corruptFrames;
    private volatile long lastSample;
    private volatile int videoWidth = 320;
    private volatile int videoHeight = 180;
    private volatile boolean closed;

    BackgroundMotionFrames(Listener listener) {
        this.listener = listener;
        thread.start();
        worker = new Handler(thread.getLooper());
    }

    void start() { worker.post(this::open); }

    long lastSampleAt() { return lastSample; }

    void setVideoSize(int width, int height) {
        if (width > 0 && height > 0) {
            videoWidth = width;
            videoHeight = height;
        }
    }

    private void open() {
        if (closed) return;
        try {
            display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY);
            int[] version = new int[2];
            int[] count = new int[1];
            EGLConfig[] configurations = new EGLConfig[1];
            int[] attributes = {
                EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
                EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8,
                EGL14.EGL_NONE,
            };
            if (!EGL14.eglInitialize(display, version, 0, version, 1)
                    || !EGL14.eglChooseConfig(display, attributes, 0, configurations, 0, 1, count, 0)
                    || count[0] == 0) throw new IllegalStateException("No EGL configuration");
            context = EGL14.eglCreateContext(display, configurations[0], EGL14.EGL_NO_CONTEXT,
                    new int[]{EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE}, 0);
            pbuffer = EGL14.eglCreatePbufferSurface(display, configurations[0],
                    new int[]{EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE}, 0);
            if (context == EGL14.EGL_NO_CONTEXT || pbuffer == EGL14.EGL_NO_SURFACE
                    || !EGL14.eglMakeCurrent(display, pbuffer, pbuffer, context)) {
                throw new IllegalStateException("No EGL context");
            }
            int[] name = new int[1];
            GLES20.glGenTextures(1, name, 0);
            texture = new SurfaceTexture(name[0]);
            texture.setOnFrameAvailableListener(this::readFrame, worker);
            Surface output = new Surface(texture);
            surface = output;
            main.post(() -> { if (!closed) listener.onSurface(output); });
        } catch (RuntimeException error) {
            main.post(() -> { if (!closed) listener.onError(); });
        }
    }

    private void readFrame(SurfaceTexture source) {
        if (closed) return;
        try {
            // Drain the decoder queue even when we skip a sample.
            source.updateTexImage();
        } catch (RuntimeException error) {
            main.post(() -> { if (!closed) listener.onError(); });
            return;
        }
        long now = SystemClock.elapsedRealtime();
        if (copying || (lastCopy != 0 && now - lastCopy < 650)) return;
        lastCopy = now;
        Bitmap sample = Bitmap.createBitmap(BackgroundMotionDetector.WIDTH,
                BackgroundMotionDetector.HEIGHT, Bitmap.Config.ARGB_8888);
        copying = true;
        copy(sample, success -> {
            try {
                if (!success || closed) return;
                sample.getPixels(argb, 0, sample.getWidth(), 0, 0, sample.getWidth(), sample.getHeight());
                if (VideoFrameHealth.isCorrupt(argb, sample.getWidth(), sample.getHeight())) {
                    detector.reset();
                    if (++corruptFrames == 2) {
                        main.post(() -> { if (!closed) listener.onCorruptFrame(); });
                    }
                    return;
                }
                corruptFrames = 0;
                lastSample = SystemClock.elapsedRealtime();
                byte[] luma = new byte[argb.length];
                for (int i = 0; i < argb.length; i++) {
                    int rgb = argb[i];
                    luma[i] = (byte) ((77 * ((rgb >> 16) & 255) + 150 * ((rgb >> 8) & 255)
                            + 29 * (rgb & 255)) >> 8);
                }
                if (detector.add(luma) && (lastMotion == 0 || now - lastMotion >= 30_000)) {
                    lastMotion = now;
                    snapshot(System.currentTimeMillis());
                    return;
                }
            } finally {
                sample.recycle();
            }
        });
    }

    private void snapshot(long occurredAt) {
        int width = videoWidth;
        int height = videoHeight;
        double scale = Math.min(1, 320.0 / Math.max(width, height));
        Bitmap photo = Bitmap.createBitmap(Math.max(1, (int) (width * scale)),
                Math.max(1, (int) (height * scale)), Bitmap.Config.ARGB_8888);
        copying = true;
        copy(photo, success -> {
            byte[] data = null;
            try {
                if (!closed && success) {
                    int[] pixels = new int[photo.getWidth() * photo.getHeight()];
                    photo.getPixels(pixels, 0, photo.getWidth(), 0, 0, photo.getWidth(), photo.getHeight());
                    if (VideoFrameHealth.isCorrupt(pixels, photo.getWidth(), photo.getHeight())) {
                        detector.reset();
                        main.post(() -> { if (!closed) listener.onCorruptFrame(); });
                        return;
                    }
                    ByteArrayOutputStream encoded = new ByteArrayOutputStream();
                    if (photo.compress(Bitmap.CompressFormat.JPEG, 75, encoded)
                            && encoded.size() <= 256 * 1024) data = encoded.toByteArray();
                }
            } finally {
                photo.recycle();
            }
            byte[] jpeg = data;
            if (jpeg != null) main.post(() -> { if (!closed) listener.onMotion(occurredAt, jpeg); });
        });
    }

    private void copy(Bitmap bitmap, java.util.function.Consumer<Boolean> completion) {
        try {
            PixelCopy.request(surface, bitmap, status -> {
                copying = false;
                completion.accept(status == PixelCopy.SUCCESS);
            }, worker);
        } catch (RuntimeException error) {
            copying = false;
            completion.accept(false);
        }
    }

    @Override public void close() {
        if (closed) return;
        closed = true;
        worker.post(() -> {
            if (surface != null) surface.release();
            if (texture != null) texture.release();
            if (display != EGL14.EGL_NO_DISPLAY) {
                EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE,
                        EGL14.EGL_NO_CONTEXT);
                if (pbuffer != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, pbuffer);
                if (context != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, context);
                EGL14.eglTerminate(display);
            }
            EGL14.eglReleaseThread();
            thread.quitSafely();
        });
    }
}
