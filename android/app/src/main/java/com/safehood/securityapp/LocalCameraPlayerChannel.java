package com.safehood.securityapp;

import android.content.Context;
import android.net.Uri;
import androidx.media3.common.MediaItem;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import androidx.media3.common.VideoSize;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.rtsp.RtspMediaSource;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.view.TextureRegistry;
import java.io.IOException;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.util.Map;
import java.util.HashMap;
import java.util.concurrent.Executors;
import javax.net.SocketFactory;

/** One foreground player. Sockets belong to the identified local Wi-Fi, not the process. */
@UnstableApi
public final class LocalCameraPlayerChannel implements AutoCloseable {
    private final Context context;
    private final TextureRegistry textures;
    private final MethodChannel channel;
    private final java.util.concurrent.ExecutorService resolver = Executors.newSingleThreadExecutor();
    private final android.os.Handler main = new android.os.Handler(android.os.Looper.getMainLooper());
    private Preview preview;

    public LocalCameraPlayerChannel(Context context, BinaryMessenger messenger, TextureRegistry textures) {
        this.context = context.getApplicationContext();
        this.textures = textures;
        channel = new MethodChannel(messenger, "safehood/local_camera_player");
        channel.setMethodCallHandler(this::handle);
    }

    private void handle(MethodCall call, MethodChannel.Result reply) {
        try {
            switch (call.method) {
                case "refreshReolink" -> {
                    final String uid = call.argument("uid");
                    final var stored = LocalCameraChannel.localUri(call.argument("uri"));
                    final String login = stored.getUserInfo();
                    if (uid == null || !uid.matches("[A-Z0-9]{16}") || login == null
                            || !login.startsWith("admin:") || login.length() <= 6) {
                        reply.error("authFailed", null, null);
                        return;
                    }
                    resolver.execute(() -> {
                        try {
                            final String rtsp = new ReolinkLanSetup(context).refreshRtsp(uid, login.substring(6));
                            main.post(() -> reply.success(rtsp));
                        } catch (ReolinkLanWire.Failure error) {
                            main.post(() -> reply.error(error.code, null, null));
                        } catch (Exception error) {
                            main.post(() -> reply.error("notFoundLan", null, null));
                        }
                    });
                }
                case "resolveOnvif" -> {
                    final String endpoint = call.argument("endpoint");
                    final String username = call.argument("username");
                    final String password = call.argument("password");
                    resolver.execute(() -> {
                        try {
                            final String uri = LocalOnvifResolver.resolve(context, endpoint, username, password);
                            main.post(() -> reply.success(uri));
                        } catch (ReolinkLanWire.Failure error) {
                            main.post(() -> reply.error(error.code, null, null));
                        } catch (Exception error) {
                            main.post(() -> reply.error("noOnvifStream", null, null));
                        }
                    });
                }
                case "open" -> {
                    final var uri = LocalCameraChannel.localUri(call.argument("uri"));
                    final var host = CameraLocalNetwork.ipv4(uri.getHost());
                    final var link = CameraLocalNetwork.forHost(context, host);
                    final boolean udp = Boolean.TRUE.equals(call.argument("tryUdp"));
                    // The UDP socket is opened by Media3, outside our TCP socket factory.
                    if (udp && !CameraLocalNetwork.isDefault(context, link)) {
                        throw new ReolinkLanWire.Failure("udpNeedsDefaultWifi");
                    }
                    final int port = uri.getPort() == -1 ? 554 : uri.getPort();
                    release();
                    preview = new Preview(uri.toASCIIString(), new CameraSockets(
                            link.network().getSocketFactory(), host, port), udp);
                    reply.success(preview.texture.id());
                }
                case "state" -> {
                    final Number id = call.argument("id");
                    if (preview == null || id == null || id.longValue() != preview.texture.id()) {
                        reply.error("stopped", null, null);
                    } else {
                        reply.success(preview.state());
                    }
                }
                case "stop" -> {
                    final Number id = call.argument("id");
                    if (preview != null && id != null && id.longValue() == preview.texture.id()) release();
                    reply.success(null);
                }
                default -> reply.notImplemented();
            }
        } catch (ReolinkLanWire.Failure error) {
            reply.error(error.code, null, null);
        } catch (Exception error) {
            reply.error("playback", null, null);
        }
    }

    private final class Preview implements Player.Listener, TextureRegistry.SurfaceProducer.Callback {
        final TextureRegistry.SurfaceProducer texture;
        final ExoPlayer player;
        boolean firstFrame;
        boolean failed;
        boolean released;
        int width = 16;
        int height = 9;

        Preview(String uri, SocketFactory sockets, boolean udp) {
            texture = textures.createSurfaceProducer();
            ExoPlayer instance = null;
            try {
                texture.setSize(width, height);
                instance = new ExoPlayer.Builder(context).build();
                player = instance;
                player.addListener(this);
                texture.setCallback(this);
                player.setVideoSurface(texture.getSurface());
                player.setVolume(0);
                player.setMediaSource(new RtspMediaSource.Factory()
                        .setForceUseRtpTcp(!udp).setSocketFactory(sockets)
                        .setDebugLoggingEnabled(false).setTimeoutMs(8000)
                        .createMediaSource(MediaItem.fromUri(Uri.parse(uri))));
                player.prepare();
                player.play();
            } catch (RuntimeException failed) {
                if (instance != null) instance.release();
                texture.release();
                throw failed;
            }
        }

        @Override public void onVideoSizeChanged(VideoSize size) {
            if (!released && size.width > 0 && size.height > 0) {
                width = size.width;
                height = size.height;
                texture.setSize(width, height);
            }
        }

        @Override public void onRenderedFirstFrame() {
            if (!released) firstFrame = true;
        }

        @Override public void onPlayerError(PlaybackException error) {
            failed = true;
        }

        @Override public void onSurfaceAvailable() {
            if (!released) player.setVideoSurface(texture.getSurface());
        }

        @Override public void onSurfaceCleanup() {
            if (!released) {
                firstFrame = false;
                player.clearVideoSurface();
            }
        }

        Map<String, Object> state() {
            final var state = new HashMap<String, Object>();
            state.put("rendered", firstFrame && player.isPlaying());
            state.put("width", width);
            state.put("height", height);
            state.put("failed", failed || player.getPlaybackState() == Player.STATE_ENDED);
            return state;
        }

        void close() {
            released = true;
            texture.setCallback(null);
            player.removeListener(this);
            player.clearVideoSurface();
            player.release();
            texture.release();
        }
    }

    private static final class CameraSockets extends SocketFactory {
        private final SocketFactory base;
        private final InetAddress host;
        private final int port;

        CameraSockets(SocketFactory base, InetAddress host, int port) {
            this.base = base;
            this.host = host;
            this.port = port;
        }

        @Override public Socket createSocket(String address, int port) throws IOException {
            // Never resolve camera-supplied aliases or follow a redirect off target.
            return createSocket(CameraLocalNetwork.ipv4(address), port);
        }

        @Override public Socket createSocket(InetAddress address, int port) throws IOException {
            if (!host.equals(address) || this.port != port) throw new IOException("RTSP destination");
            final Socket socket = base.createSocket();
            try {
                socket.connect(new InetSocketAddress(host, port), 4000);
                return socket;
            } catch (IOException failed) {
                socket.close();
                throw failed;
            }
        }

        @Override public Socket createSocket() throws IOException { throw new IOException("RTSP destination"); }
        @Override public Socket createSocket(String host, int port, InetAddress local, int localPort)
                throws IOException { throw new IOException("RTSP destination"); }
        @Override public Socket createSocket(InetAddress host, int port, InetAddress local, int localPort)
                throws IOException { throw new IOException("RTSP destination"); }
    }

    private void release() {
        final Preview old = preview;
        preview = null;
        if (old != null) old.close();
    }

    @Override public void close() {
        channel.setMethodCallHandler(null);
        resolver.shutdownNow();
        release();
    }
}
