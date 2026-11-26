package io.flutter.plugins.videoplayer;

import android.graphics.Bitmap;
import android.graphics.SurfaceTexture;
import android.opengl.EGL14;
import android.opengl.EGLConfig;
import android.opengl.EGLContext;
import android.opengl.EGLDisplay;
import android.opengl.EGLExt;
import android.opengl.EGLSurface;
import android.opengl.GLES11Ext;
import android.opengl.GLES20;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;
import android.view.Surface;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import java.util.function.Consumer;

/** One decoder surface, sampled through its OES texture and optionally rendered to the preview. */
public final class CameraFrameReader implements AutoCloseable {
  public interface Listener {
    void onSurface(Surface surface);

    /** Called on the GL thread. The bitmap is borrowed for this callback only. */
    default void onFrame(Bitmap frame) {}

    void onError();
  }

  private static final String VERTEX =
      "attribute vec2 aPosition;attribute vec2 aTexCoord;uniform mat4 uTransform;varying vec2"
          + " vTexCoord;void main(){"
          + "gl_Position=vec4(aPosition,0.0,1.0);vTexCoord=(uTransform*vec4(aTexCoord,0.0,1.0)).xy;}";
  private static final String FRAGMENT =
      "#extension GL_OES_EGL_image_external : require\n"
          + "precision mediump float;uniform samplerExternalOES uTexture;varying vec2 vTexCoord;"
          + "void main(){gl_FragColor=texture2D(uTexture,vTexCoord);}";
  private final Listener listener;
  private final HandlerThread thread = new HandlerThread("SafeHoodCameraGL");
  private final Handler worker;
  private final Handler main = new Handler(Looper.getMainLooper());
  private final FloatBuffer vertices = floats(-1, -1, 1, -1, -1, 1, 1, 1);
  private final FloatBuffer coordinates = floats(0, 0, 1, 0, 0, 1, 1, 1);
  private final float[] transform = new float[16];
  private EGLDisplay display = EGL14.EGL_NO_DISPLAY;
  private EGLContext context = EGL14.EGL_NO_CONTEXT;
  private EGLSurface pbuffer = EGL14.EGL_NO_SURFACE;
  private EGLSurface window = EGL14.EGL_NO_SURFACE;
  private EGLConfig config;
  private SurfaceTexture texture;
  private Surface decoderSurface;
  private Surface output;
  private int program;
  private int oes;
  private int framebuffer;
  private int rgbTexture;
  private int captureWidth;
  private int captureHeight;
  private int[] pixels;
  private ByteBuffer rgba;
  private Bitmap latest;
  private long lastSample;
  private int width = 640;
  private int height = 360;
  private volatile boolean closed;
  private boolean failed;

  public CameraFrameReader(Listener listener) {
    this.listener = listener;
    thread.start();
    worker = new Handler(thread.getLooper());
  }

  public void start() {
    worker.post(this::open);
  }

  public void setVideoSize(int width, int height) {
    if (width < 1 || height < 1) return;
    worker.post(
        () -> {
          if (closed) return;
          this.width = width;
          this.height = height;
          if (texture != null) texture.setDefaultBufferSize(width, height);
        });
  }

  /** Does not take ownership of the Flutter surface. */
  public void setOutput(Surface surface) {
    worker.post(
        () -> {
          if (closed) return;
          if (display != EGL14.EGL_NO_DISPLAY) {
            makeCurrent(pbuffer);
            destroyWindow();
          }
          output = surface;
        });
  }

  public void read(int width, int height, Consumer<Bitmap> completion) {
    if (closed) {
      completion.accept(null);
      return;
    }
    worker.post(
        () -> {
          Bitmap copy = null;
          if (!closed
              && !failed
              && latest != null
              && SystemClock.elapsedRealtime() - lastSample <= 1500) {
            Bitmap scaled = Bitmap.createScaledBitmap(latest, width, height, true);
            copy = scaled == latest ? latest.copy(Bitmap.Config.ARGB_8888, false) : scaled;
          }
          completion.accept(copy);
        });
  }

  private void open() {
    if (closed) return;
    try {
      display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY);
      int[] version = new int[2];
      int[] count = new int[1];
      EGLConfig[] configs = new EGLConfig[1];
      int[] attributes = {
        EGL14.EGL_SURFACE_TYPE,
        EGL14.EGL_WINDOW_BIT | EGL14.EGL_PBUFFER_BIT,
        EGL14.EGL_RENDERABLE_TYPE,
        EGL14.EGL_OPENGL_ES2_BIT,
        EGL14.EGL_RED_SIZE,
        8,
        EGL14.EGL_GREEN_SIZE,
        8,
        EGL14.EGL_BLUE_SIZE,
        8,
        EGL14.EGL_ALPHA_SIZE,
        8,
        EGL14.EGL_NONE
      };
      if (!EGL14.eglInitialize(display, version, 0, version, 1)
          || !EGL14.eglChooseConfig(display, attributes, 0, configs, 0, 1, count, 0)
          || count[0] == 0) throw new IllegalStateException("EGL configuration unavailable");
      config = configs[0];
      context =
          EGL14.eglCreateContext(
              display,
              config,
              EGL14.EGL_NO_CONTEXT,
              new int[] {EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE},
              0);
      pbuffer =
          EGL14.eglCreatePbufferSurface(
              display,
              config,
              new int[] {EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE},
              0);
      if (context == EGL14.EGL_NO_CONTEXT
          || pbuffer == EGL14.EGL_NO_SURFACE
          || !makeCurrent(pbuffer)) throw new IllegalStateException("EGL context unavailable");
      program = GLES20.glCreateProgram();
      int vertex = shader(GLES20.GL_VERTEX_SHADER, VERTEX);
      int fragment = shader(GLES20.GL_FRAGMENT_SHADER, FRAGMENT);
      GLES20.glAttachShader(program, vertex);
      GLES20.glAttachShader(program, fragment);
      GLES20.glLinkProgram(program);
      GLES20.glDeleteShader(vertex);
      GLES20.glDeleteShader(fragment);
      int[] linked = new int[1];
      GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, linked, 0);
      if (linked[0] == 0) throw new IllegalStateException("OES program unavailable");
      int[] names = new int[1];
      GLES20.glGenTextures(1, names, 0);
      oes = names[0];
      GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oes);
      GLES20.glTexParameteri(
          GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR);
      GLES20.glTexParameteri(
          GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR);
      GLES20.glTexParameteri(
          GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE);
      GLES20.glTexParameteri(
          GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE);
      texture = new SurfaceTexture(oes);
      texture.setDefaultBufferSize(width, height);
      texture.setOnFrameAvailableListener(this::frame, worker);
      decoderSurface = new Surface(texture);
      main.post(
          () -> {
            if (!closed && !failed) listener.onSurface(decoderSurface);
          });
    } catch (RuntimeException error) {
      fail();
    }
  }

  private void frame(SurfaceTexture source) {
    if (closed || failed) return;
    try {
      if (!makeCurrent(pbuffer)) throw new IllegalStateException("EGL context lost");
      source.updateTexImage();
      source.getTransformMatrix(transform);
      long now = SystemClock.elapsedRealtime();
      // Only the small RGB readback is throttled; every preview frame is rendered.
      if (lastSample == 0 || now - lastSample >= 650) capture(now);
      if (output != null && output.isValid()) {
        if (window == EGL14.EGL_NO_SURFACE)
          window =
              EGL14.eglCreateWindowSurface(display, config, output, new int[] {EGL14.EGL_NONE}, 0);
        if (window != EGL14.EGL_NO_SURFACE && makeCurrent(window)) {
          int[] w = new int[1];
          int[] h = new int[1];
          EGL14.eglQuerySurface(display, window, EGL14.EGL_WIDTH, w, 0);
          EGL14.eglQuerySurface(display, window, EGL14.EGL_HEIGHT, h, 0);
          draw(w[0], h[0]);
          EGLExt.eglPresentationTimeANDROID(display, window, source.getTimestamp());
          if (!EGL14.eglSwapBuffers(display, window)) {
            makeCurrent(pbuffer);
            destroyWindow();
          }
        }
      }
    } catch (RuntimeException error) {
      fail();
    }
  }

  private void capture(long now) {
    double scale = Math.min(1, 480.0 / Math.max(width, height));
    int w = Math.max(1, (int) (width * scale));
    int h = Math.max(1, (int) (height * scale));
    if (framebuffer == 0 || captureWidth != w || captureHeight != h) {
      deleteCapture();
      captureWidth = w;
      captureHeight = h;
      int[] names = new int[1];
      GLES20.glGenTextures(1, names, 0);
      rgbTexture = names[0];
      GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, rgbTexture);
      GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR);
      GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR);
      GLES20.glTexParameteri(
          GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE);
      GLES20.glTexParameteri(
          GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE);
      GLES20.glTexImage2D(
          GLES20.GL_TEXTURE_2D,
          0,
          GLES20.GL_RGBA,
          w,
          h,
          0,
          GLES20.GL_RGBA,
          GLES20.GL_UNSIGNED_BYTE,
          null);
      GLES20.glGenFramebuffers(1, names, 0);
      framebuffer = names[0];
      GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, framebuffer);
      GLES20.glFramebufferTexture2D(
          GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0, GLES20.GL_TEXTURE_2D, rgbTexture, 0);
      if (GLES20.glCheckFramebufferStatus(GLES20.GL_FRAMEBUFFER) != GLES20.GL_FRAMEBUFFER_COMPLETE)
        throw new IllegalStateException("RGB framebuffer unavailable");
      pixels = new int[w * h];
      rgba = ByteBuffer.allocateDirect(w * h * 4);
      latest = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
    }
    GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, framebuffer);
    draw(w, h);
    rgba.clear();
    GLES20.glReadPixels(0, 0, w, h, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, rgba);
    if (GLES20.glGetError() != GLES20.GL_NO_ERROR)
      throw new IllegalStateException("RGB readback failed");
    CameraFramePixels.rgbaToArgb(rgba, w, h, pixels);
    latest.setPixels(pixels, 0, w, 0, 0, w, h);
    lastSample = now;
    GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0);
    listener.onFrame(latest);
  }

  private void draw(int width, int height) {
    GLES20.glViewport(0, 0, width, height);
    GLES20.glUseProgram(program);
    int position = GLES20.glGetAttribLocation(program, "aPosition");
    int uv = GLES20.glGetAttribLocation(program, "aTexCoord");
    GLES20.glEnableVertexAttribArray(position);
    GLES20.glEnableVertexAttribArray(uv);
    vertices.position(0);
    coordinates.position(0);
    GLES20.glVertexAttribPointer(position, 2, GLES20.GL_FLOAT, false, 0, vertices);
    GLES20.glVertexAttribPointer(uv, 2, GLES20.GL_FLOAT, false, 0, coordinates);
    GLES20.glUniformMatrix4fv(
        GLES20.glGetUniformLocation(program, "uTransform"), 1, false, transform, 0);
    GLES20.glActiveTexture(GLES20.GL_TEXTURE0);
    GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oes);
    GLES20.glUniform1i(GLES20.glGetUniformLocation(program, "uTexture"), 0);
    GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4);
  }

  private boolean makeCurrent(EGLSurface surface) {
    return EGL14.eglMakeCurrent(display, surface, surface, context);
  }

  private void destroyWindow() {
    if (window != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, window);
    window = EGL14.EGL_NO_SURFACE;
  }

  private void fail() {
    if (failed || closed) return;
    failed = true;
    Log.w("SafeHoodVideo", "OES RGB capture unavailable; stopping visual-only sampling");
    main.post(
        () -> {
          if (!closed) listener.onError();
        });
  }

  private void deleteCapture() {
    if (framebuffer != 0) GLES20.glDeleteFramebuffers(1, new int[] {framebuffer}, 0);
    if (rgbTexture != 0) GLES20.glDeleteTextures(1, new int[] {rgbTexture}, 0);
    framebuffer = 0;
    rgbTexture = 0;
    if (latest != null) latest.recycle();
    latest = null;
  }

  private static FloatBuffer floats(float... values) {
    FloatBuffer result =
        ByteBuffer.allocateDirect(values.length * 4).order(ByteOrder.nativeOrder()).asFloatBuffer();
    result.put(values).position(0);
    return result;
  }

  private static int shader(int kind, String source) {
    int shader = GLES20.glCreateShader(kind);
    GLES20.glShaderSource(shader, source);
    GLES20.glCompileShader(shader);
    int[] compiled = new int[1];
    GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, compiled, 0);
    if (compiled[0] == 0) {
      GLES20.glDeleteShader(shader);
      throw new IllegalStateException("OES shader unavailable");
    }
    return shader;
  }

  @Override
  public void close() {
    if (closed) return;
    closed = true;
    worker.post(
        () -> {
          if (display != EGL14.EGL_NO_DISPLAY && context != EGL14.EGL_NO_CONTEXT) {
            makeCurrent(pbuffer);
            if (texture != null) texture.setOnFrameAvailableListener(null);
            if (decoderSurface != null) decoderSurface.release();
            if (texture != null) texture.release();
            deleteCapture();
            if (oes != 0) GLES20.glDeleteTextures(1, new int[] {oes}, 0);
            if (program != 0) GLES20.glDeleteProgram(program);
            destroyWindow();
            EGL14.eglMakeCurrent(
                display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT);
            if (pbuffer != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, pbuffer);
            EGL14.eglDestroyContext(display, context);
            // EGLDisplay is process-shared; do not terminate another Flutter engine's display.
            EGL14.eglReleaseThread();
          }
          thread.quitSafely();
        });
  }
}
