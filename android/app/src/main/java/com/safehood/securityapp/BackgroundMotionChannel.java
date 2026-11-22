package com.safehood.securityapp;

import android.app.NotificationManager;
import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.net.Network;
import android.os.Build;
import androidx.media3.common.util.UnstableApi;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import java.net.URI;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

@UnstableApi
public final class BackgroundMotionChannel implements AutoCloseable {
    private final Context context;
    private final MethodChannel channel;

    public BackgroundMotionChannel(Context context, BinaryMessenger messenger) {
        this.context = context.getApplicationContext();
        channel = new MethodChannel(messenger, "safehood/background_motion");
        channel.setMethodCallHandler(this::handle);
        BackgroundMotionService.setObserver(() ->
                channel.invokeMethod("statusChanged", BackgroundMotionService.status()));
    }

    private void handle(MethodCall call, MethodChannel.Result result) {
        try {
            switch (call.method) {
                case "status" -> result.success(BackgroundMotionService.status());
                case "start" -> {
                    if (Build.VERSION.SDK_INT < 24) {
                        result.error("unsupported", null, null);
                        return;
                    }
                    if (BackgroundMotionService.status().get("cameraId") != null) {
                        result.error("alreadyActive", null, null);
                        return;
                    }
                    BackgroundMotionService.start(context, request(call));
                    result.success(context.getSystemService(NotificationManager.class).areNotificationsEnabled());
                }
                case "stop" -> {
                    BackgroundMotionService.stop(context, call.argument("cameraId"));
                    result.success(null);
                }
                case "preview" -> {
                    Integer lease = call.argument("lease");
                    if (lease != null) BackgroundMotionService.preview(lease, call.argument("cameraId"));
                    result.success(null);
                }
                default -> result.notImplemented();
            }
        } catch (ReolinkLanWire.Failure error) {
            result.error(error.code, null, null);
        } catch (Exception error) {
            result.error("cannotStart", null, null);
        }
    }

    private BackgroundMotionService.Request request(MethodCall call) throws Exception {
        String owner = call.argument("owner");
        String camera = call.argument("cameraId");
        List<String> candidates = call.argument("streams");
        String emulator = call.argument("emulatorHost");
        if (!validKey(owner) || !validKey(camera) || candidates == null
                || candidates.isEmpty() || candidates.size() > 3) throw new IllegalArgumentException();
        if (emulator != null) {
            if ((context.getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) == 0) {
                throw new IllegalArgumentException();
            }
            if (!"127.0.0.1".equals(emulator) && !"localhost".equals(emulator)) {
                CameraLocalNetwork.ipv4(emulator);
            }
        }
        List<URI> streams = new ArrayList<>();
        Network network = null;
        for (String candidate : candidates) {
            URI uri = LocalCameraChannel.localUri(candidate);
            var link = CameraLocalNetwork.forHost(context, CameraLocalNetwork.ipv4(uri.getHost()));
            if (network == null) network = link.network();
            if (network.equals(link.network()) && !streams.contains(uri)) streams.add(uri);
        }
        return new BackgroundMotionService.Request(owner, camera, Collections.unmodifiableList(streams),
                network, emulator);
    }

    private static boolean validKey(String input) {
        return input != null && !input.isEmpty() && input.length() <= 150
                && input.indexOf('/') < 0 && !".".equals(input) && !"..".equals(input);
    }

    @Override public void close() {
        channel.setMethodCallHandler(null);
        BackgroundMotionService.setObserver(null);
        BackgroundMotionService.clearPreviews();
    }
}
