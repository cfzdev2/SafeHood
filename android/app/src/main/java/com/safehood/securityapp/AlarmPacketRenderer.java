package com.safehood.securityapp;

import android.os.SystemClock;
import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.common.MimeTypes;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.decoder.DecoderInputBuffer;
import androidx.media3.exoplayer.BaseRenderer;
import androidx.media3.exoplayer.FormatHolder;
import androidx.media3.exoplayer.Renderer;
import androidx.media3.exoplayer.RendererCapabilities;
import androidx.media3.exoplayer.RenderersFactory;
import androidx.media3.exoplayer.source.MediaSource;
import io.flutter.plugins.videoplayer.CameraVideoBuffer;

/**
 * Receives the original RTSP video for an alarm subscription when no display can be used. Runs on
 * the player's playback thread. There is no second socket, decoder, or fake video frame.
 */
@UnstableApi
final class AlarmPacketRenderer extends BaseRenderer {
  static RenderersFactory factory(CameraVideoBuffer buffer) {
    return (handler, video, audio, text, metadata) ->
        new Renderer[] {new AlarmPacketRenderer(buffer)};
  }

  private final CameraVideoBuffer buffer;
  private final DecoderInputBuffer input =
      new DecoderInputBuffer(DecoderInputBuffer.BUFFER_REPLACEMENT_MODE_NORMAL) {
        @Override
        public void ensureSpaceForWrite(int size) {
          int position = data == null ? 0 : data.position();
          if (size < 0 || size > CameraVideoBuffer.MAX_BYTES - position)
            throw new IllegalArgumentException("Camera frame exceeds recording limit");
          super.ensureSpaceForWrite(size);
        }
      };
  private boolean ended;

  private AlarmPacketRenderer(CameraVideoBuffer buffer) {
    super(C.TRACK_TYPE_VIDEO);
    this.buffer = buffer;
  }

  @Override
  public String getName() {
    return "SafeHoodAlarmVideo";
  }

  @Override
  public int supportsFormat(Format format) {
    int support =
        !MimeTypes.isVideo(format.sampleMimeType)
            ? C.FORMAT_UNSUPPORTED_TYPE
            : !CameraVideoBuffer.supportsClipMime(format.sampleMimeType)
                ? C.FORMAT_UNSUPPORTED_SUBTYPE
                : format.drmInitData != null ? C.FORMAT_UNSUPPORTED_DRM : C.FORMAT_HANDLED;
    return RendererCapabilities.create(support);
  }

  @Override
  public boolean isReady() {
    return true;
  }

  @Override
  public boolean isEnded() {
    return ended;
  }

  @Override
  protected void onStreamChanged(
      Format[] formats, long startUs, long offsetUs, MediaSource.MediaPeriodId period) {
    ended = false;
    buffer.invalidate();
  }

  @Override
  protected void onPositionReset(long positionUs, boolean joining, boolean resetToKeyFrame) {
    ended = false;
    buffer.invalidate();
  }

  @Override
  public void render(long positionUs, long elapsedRealtimeUs) {
    // Read only what the RTSP source already has. Bound each turn of the playback loop.
    for (int i = 0; !ended && i < 32; i++) {
      input.clear();
      FormatHolder holder = getFormatHolder();
      int result = readSource(holder, input, 0);
      if (result == C.RESULT_FORMAT_READ) {
        Format f = holder.format;
        if (f != null && f.sampleMimeType != null)
          buffer.configure(
              new CameraVideoBuffer.StreamFormat(
                  f.sampleMimeType, f.width, f.height, f.initializationData));
      } else if (result == C.RESULT_BUFFER_READ) {
        if (input.isEndOfStream()) {
          ended = true;
          return;
        }
        if (input.isEncrypted()) {
          buffer.invalidate();
          continue;
        }
        input.flip();
        buffer.append(input.data, input.timeUs, input.isKeyFrame(), SystemClock.elapsedRealtime());
      } else return;
    }
  }
}
