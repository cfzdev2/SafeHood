package io.flutter.plugins.videoplayer;

import android.content.Context;
import android.os.Handler;
import android.os.SystemClock;
import android.util.Log;
import androidx.media3.common.Format;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.decoder.DecoderInputBuffer;
import androidx.media3.exoplayer.DecoderReuseEvaluation;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.ExoPlaybackException;
import androidx.media3.exoplayer.FormatHolder;
import androidx.media3.exoplayer.Renderer;
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo;
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector;
import androidx.media3.exoplayer.mediacodec.MediaCodecUtil;
import androidx.media3.exoplayer.video.MediaCodecVideoRenderer;
import androidx.media3.exoplayer.video.VideoRendererEventListener;
import java.util.ArrayList;
import java.util.Comparator;

/** Local RTSP recovery option; never transmitted as a camera request or setting. */
@UnstableApi
public final class CameraRtspRenderers {
  private CameraRtspRenderers() {}

  public static DefaultRenderersFactory create(Context context, boolean preferSoftware) {
    return create(context, preferSoftware, null);
  }

  public static DefaultRenderersFactory create(
      Context context, boolean preferSoftware, CameraVideoBuffer buffer) {
    var factory =
        new DefaultRenderersFactory(context) {
          @Override
          protected void buildVideoRenderers(
              Context context,
              int extensionMode,
              MediaCodecSelector selector,
              boolean fallback,
              Handler handler,
              VideoRendererEventListener listener,
              long joiningMs,
              ArrayList<Renderer> out) {
            if (buffer == null) {
              super.buildVideoRenderers(
                  context, extensionMode, selector, fallback, handler, listener, joiningMs, out);
              return;
            }
            var builder =
                new MediaCodecVideoRenderer.Builder(context)
                    .setCodecAdapterFactory(getCodecAdapterFactory())
                    .setMediaCodecSelector(selector)
                    .setAllowedJoiningTimeMs(joiningMs)
                    .setEnableDecoderFallback(fallback)
                    .setEventHandler(handler)
                    .setEventListener(listener)
                    .setMaxDroppedFramesToNotify(50);
            out.add(new BufferedVideoRenderer(builder, buffer));
          }
        }.setEnableDecoderFallback(true);
    // Avoid vendor asynchronous queueing bugs while retaining hardware decoding as the first
    // choice.
    factory.forceDisableMediaCodecAsynchronousQueueing();
    if (preferSoftware) {
      Log.i("SafeHoodVideo", "RTSP recovery: prioritizing software video decoders");
      factory.forceDisableMediaCodecAsynchronousQueueing();
      factory.setMediaCodecSelector(
          (mime, secure, tunneling) -> {
            var codecs = new ArrayList<>(MediaCodecUtil.getDecoderInfos(mime, secure, tunneling));
            if (mime.startsWith("video/")) {
              codecs.sort(
                  Comparator.comparingInt((MediaCodecInfo codec) -> codec.softwareOnly ? 0 : 1));
            }
            return codecs;
          });
    }
    return factory;
  }

  private static final class BufferedVideoRenderer extends MediaCodecVideoRenderer {
    private final CameraVideoBuffer buffer;

    BufferedVideoRenderer(Builder builder, CameraVideoBuffer buffer) {
      super(builder);
      this.buffer = buffer;
    }

    @Override
    protected DecoderReuseEvaluation onInputFormatChanged(FormatHolder holder)
        throws ExoPlaybackException {
      Format format = holder.format;
      if (format != null && format.sampleMimeType != null)
        buffer.configure(
            new CameraVideoBuffer.StreamFormat(
                format.sampleMimeType, format.width, format.height, format.initializationData));
      return super.onInputFormatChanged(holder);
    }

    @Override
    protected void onQueueInputBuffer(DecoderInputBuffer input) throws ExoPlaybackException {
      super.onQueueInputBuffer(input);
      if (input.isEncrypted()) buffer.invalidate();
      else
        buffer.append(input.data, input.timeUs, input.isKeyFrame(), SystemClock.elapsedRealtime());
    }

    @Override
    protected void onPositionReset(long positionUs, boolean joining, boolean resetToKeyFrame)
        throws ExoPlaybackException {
      buffer.invalidate();
      super.onPositionReset(positionUs, joining, resetToKeyFrame);
    }
  }
}
