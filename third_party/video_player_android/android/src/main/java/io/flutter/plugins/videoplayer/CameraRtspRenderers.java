package io.flutter.plugins.videoplayer;

import android.content.Context;
import android.util.Log;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo;
import androidx.media3.exoplayer.mediacodec.MediaCodecUtil;
import java.util.ArrayList;
import java.util.Comparator;

/** Local RTSP recovery option; never transmitted as a camera request or setting. */
@UnstableApi
public final class CameraRtspRenderers {
  private CameraRtspRenderers() {}

  public static DefaultRenderersFactory create(Context context, boolean preferSoftware) {
    var factory = new DefaultRenderersFactory(context).setEnableDecoderFallback(true);
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
}
