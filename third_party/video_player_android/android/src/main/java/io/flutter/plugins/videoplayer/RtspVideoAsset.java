// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer;

import android.content.Context;
import androidx.annotation.NonNull;
import androidx.annotation.OptIn;
import androidx.media3.common.MediaItem;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.rtsp.RtspMediaSource;
import androidx.media3.exoplayer.source.MediaSource;

final class RtspVideoAsset extends VideoAsset {
  private final boolean forceRtpTcp;
  private final boolean preferSoftware;
  private final CameraVideoBuffer videoBuffer = new CameraVideoBuffer();

  RtspVideoAsset(@NonNull String assetUrl, boolean forceRtpTcp) {
    this(assetUrl, forceRtpTcp, false);
  }

  RtspVideoAsset(@NonNull String assetUrl, boolean forceRtpTcp, boolean software) {
    super(assetUrl);
    this.forceRtpTcp = forceRtpTcp;
    this.preferSoftware = software;
  }

  @Override
  @OptIn(markerClass = UnstableApi.class)
  public ExoPlayer.Builder createPlayerBuilder(@NonNull Context context) {
    return new ExoPlayer.Builder(
        context, CameraRtspRenderers.create(context, preferSoftware, videoBuffer));
  }

  @Override
  public CameraVideoBuffer getCameraVideoBuffer() {
    return videoBuffer;
  }

  @NonNull
  @Override
  public MediaItem getMediaItem() {
    return new MediaItem.Builder().setUri(assetUrl).build();
  }

  // TODO: Migrate to stable API, see https://github.com/flutter/flutter/issues/147039.
  @OptIn(markerClass = UnstableApi.class)
  @Override
  @NonNull
  public MediaSource.Factory getMediaSourceFactory(@NonNull Context context) {
    return new RtspMediaSource.Factory().setForceUseRtpTcp(forceRtpTcp);
  }
}
