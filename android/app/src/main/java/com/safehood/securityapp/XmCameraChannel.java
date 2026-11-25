package com.safehood.securityapp;

import android.content.Context;
import android.os.Build;
import com.google.firebase.auth.FirebaseAuth;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import java.util.Arrays;
import java.util.Map;

/** Optional vendor SDK. A normal build and x86 emulators keep local camera support. */
public final class XmCameraChannel implements AutoCloseable {
    public interface Adapter extends AutoCloseable {
        void handle(MethodCall call, MethodChannel.Result result);
        @Override void close();
    }
    private final Context context;
    private final MethodChannel channel;
    private final FirebaseAuth auth;
    private final FirebaseAuth.AuthStateListener authListener;
    private Adapter adapter;
    private String owner;
    private boolean tried;

    public XmCameraChannel(Context context, BinaryMessenger messenger) {
        this.context = context.getApplicationContext();
        channel = new MethodChannel(messenger, "safehood/xm_camera");
        channel.setMethodCallHandler(this::handle);
        auth = FirebaseAuth.getInstance();
        authListener = changed -> {
            var user = changed.getCurrentUser();
            if (owner != null && (user == null || !user.isEmailVerified()
                    || !owner.equals(user.getUid()))) releaseAdapter();
        };
        auth.addAuthStateListener(authListener);
    }

    private Adapter adapter() {
        if (tried) return adapter;
        tried = true;
        if (Arrays.stream(Build.SUPPORTED_ABIS).noneMatch(abi ->
                "arm64-v8a".equals(abi) || "armeabi-v7a".equals(abi))) return null;
        try {
            adapter = (Adapter) Class.forName("com.safehood.securityapp.XmFunSdkAdapter")
                    .getConstructor(Context.class).newInstance(context);
        } catch (ReflectiveOperationException | LinkageError | RuntimeException unavailable) {
            adapter = null;
        }
        return adapter;
    }

    private void handle(MethodCall call, MethodChannel.Result result) {
        if ("available".equals(call.method)) {
            result.success(Map.of("available", adapter() != null));
            return;
        }
        var user = FirebaseAuth.getInstance().getCurrentUser();
        if (user == null || !user.isEmailVerified() || !user.getUid().equals(call.argument("owner"))) {
            result.error("signInRequired", null, null);
            return;
        }
        if (owner != null && !owner.equals(user.getUid())) {
            releaseAdapter();
        }
        owner = user.getUid();
        Adapter current = adapter();
        if (current == null) result.error("cameraServiceUnavailable", null, null);
        else current.handle(call, result);
    }

    private void releaseAdapter() {
        Adapter previous = adapter;
        adapter = null;
        owner = null;
        tried = false;
        if (previous != null) {
            try { previous.close(); }
            catch (RuntimeException | LinkageError unavailable) { /* Local playback remains usable. */ }
        }
    }

    @Override public void close() {
        channel.setMethodCallHandler(null);
        auth.removeAuthStateListener(authListener);
        releaseAdapter();
    }
}
