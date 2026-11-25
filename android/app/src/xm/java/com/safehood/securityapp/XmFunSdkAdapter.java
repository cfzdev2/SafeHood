package com.safehood.securityapp;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.os.Message;
import com.google.firebase.auth.FirebaseAuth;
import com.lib.Mps.SMCInitInfoV2;
import com.lib.MsgContent;
import com.manager.XMFunSDKManager;
import com.manager.account.AccountManager;
import com.manager.account.BaseAccountManager;
import com.manager.account.XMAccountManager;
import com.manager.db.Define;
import com.manager.db.XMDevInfo;
import com.manager.push.XMPushManager;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Map;

/** FunSDK 5.1.4 adapter. Compiled only with this app's approved vendor keys. */
public final class XmFunSdkAdapter implements XmCameraChannel.Adapter {
    private final Context context;
    private final Handler main = new Handler(Looper.getMainLooper());
    private MethodChannel.Result pending;
    private XMPushManager push;
    private int generation;
    private String owner;
    private boolean closed;

    public XmFunSdkAdapter(Context context) {
        this.context = context.getApplicationContext();
        var sdk = XMFunSDKManager.getInstance();
        if (!sdk.isLoadLibrarySuccess() || BuildConfig.XM_APP_UUID.isEmpty()
                || BuildConfig.XM_APP_KEY.isEmpty() || BuildConfig.XM_APP_SECRET.isEmpty()) {
            throw new IllegalStateException("cameraServiceUnavailable");
        }
        // No vendor debug logs, shared external storage or bundled demo credentials.
        sdk.initXMCloudPlatform(this.context, BuildConfig.XM_APP_UUID, BuildConfig.XM_APP_KEY,
                BuildConfig.XM_APP_SECRET, BuildConfig.XM_APP_MOVECARD, false);
    }

    @Override public void handle(MethodCall call, MethodChannel.Result result) {
        var user = FirebaseAuth.getInstance().getCurrentUser();
        if (closed || user == null || !user.isEmailVerified()) {
            result.error("signInRequired", null, null); return;
        }
        if (pending != null) { result.error("cameraServiceBusy", null, null); return; }
        owner = user.getUid();
        pending = result;
        int request = ++generation;
        main.postDelayed(() -> fail(request, "cameraServiceTimeout"), 30_000);
        try {
            switch (call.method) {
                case "ensureAccount" -> {
                    String username = string(call, "username", 32);
                    String password = string(call, "password", 64);
                    if (Boolean.TRUE.equals(call.argument("needsRegistration"))) {
                        XMAccountManager.getInstance().register(username, password,
                                listener(request, () -> login(request, username, password),
                                    () -> login(request, username, password)));
                    } else login(request, username, password);
                }
                case "subscribe" -> prepareDevice(request, call);
                default -> fail(request, "cameraServiceUnsupported");
            }
        } catch (RuntimeException | LinkageError error) { fail(request, "cameraServiceFailed"); }
    }

    private void login(int request, String username, String password) {
        if (!current(request)) return;
        AccountManager.getInstance().xmLogin(username, password, Define.LOGIN_BY_INTERNET,
                listener(request, () -> succeed(request), () -> fail(request, "cameraServiceLogin")));
    }

    private void prepareDevice(int request, MethodCall call) {
        String serial = string(call, "serialNumber", 64);
        String username = string(call, "deviceUsername", 128);
        String password = nullablePassword(call, "devicePassword");
        String routeId = string(call, "routeId", 32);
        String callback = string(call, "callbackUrl", 240);
        URI address = URI.create(callback);
        if (!serial.matches("[a-zA-Z0-9_-]{8,64}") || !routeId.matches("[a-f0-9]{32}")
                || !"https".equals(address.getScheme()) || address.getHost() == null
                || address.getUserInfo() != null || address.getFragment() != null) {
            throw new IllegalArgumentException();
        }
        var account = XMAccountManager.getInstance();
        if (!account.hasLogin()) { fail(request, "cameraServiceLogin"); return; }
        account.updateDevListFromServer(listener(request, () -> {
            if (AccountManager.getInstance().getDevInfo(serial) != null) {
                initializePush(request, serial, routeId, callback);
                return;
            }
            XMDevInfo device = new XMDevInfo();
            device.setDevId(serial);
            device.setDevName("SafeHood camera");
            device.setDevUserName(username);
            device.setDevPassword(password);
            // Never take a camera away from another account automatically.
            AccountManager.getInstance().addDev(device, false, listener(request,
                () -> initializePush(request, serial, routeId, callback),
                () -> fail(request, "cameraServiceBinding")));
        }, () -> fail(request, "cameraServiceFailed")));
    }

    private void initializePush(int request, String serial, String routeId, String callback) {
        if (!current(request)) return;
        var account = XMAccountManager.getInstance();
        Runnable ready = () -> {
            if (!current(request)) return;
            var info = new SMCInitInfoV2();
            copy(info.st_0_user, account.getAccountName());
            copy(info.st_1_password, account.getPassword());
            copy(info.st_2_userID, account.getXmUserInfo().getUserId());
            copy(info.st_3_token, routeId);
            copy(info.st_6_szAppType, "Third:" + callback);
            if (push != null) { push.setOnXMPushLinkListener(null); push.unInit(); }
            push = new XMPushManager(new XMPushManager.OnXMPushLinkListener() {
                @Override public void onPushInit(int type, int errorId) {
                    dispatch(request, () -> {
                        if (errorId < 0) fail(request, "cameraServicePush");
                        else push.linkAlarm(serial, request);
                    });
                }
                @Override public void onPushLink(int type, String device, int sequence, int errorId) {
                    dispatch(request, () -> {
                        if (!serial.equalsIgnoreCase(device) || sequence != request) return;
                        if (errorId < 0) fail(request, "cameraServicePush");
                        else succeed(request);
                    });
                }
            });
            if (!push.initFunSDKPush(context, info, XMPushManager.PUSH_TYPE_XM)) {
                fail(request, "cameraServicePush");
            }
        };
        if (account.getXmUserInfo() != null && account.getXmUserInfo().getUserId() != null) ready.run();
        else account.getUserInfo(listener(request, ready, () -> fail(request, "cameraServiceFailed")));
    }

    private BaseAccountManager.OnAccountManagerListener listener(
            int request, Runnable success, Runnable failure) {
        return new BaseAccountManager.OnAccountManagerListener() {
            @Override public void onSuccess(int messageId) {
                dispatch(request, success);
            }
            @Override public void onFailed(int messageId, int errorId) {
                dispatch(request, failure);
            }
            @Override public void onFunSDKResult(Message message, MsgContent content) { }
        };
    }

    private void dispatch(int request, Runnable action) {
        main.post(() -> {
            if (!current(request)) return;
            try { action.run(); }
            catch (RuntimeException | LinkageError unavailable) {
                fail(request, "cameraServiceFailed");
            }
        });
    }

    private boolean current(int request) {
        var user = FirebaseAuth.getInstance().getCurrentUser();
        return !closed && pending != null && generation == request && user != null
                && user.isEmailVerified() && user.getUid().equals(owner);
    }
    private void succeed(int request) {
        if (!current(request)) return;
        var result = pending;
        pending = null;
        main.removeCallbacksAndMessages(null);
        result.success(Map.of("ok", true));
    }
    private void fail(int request, String code) {
        if (pending == null || generation != request) return;
        var result = pending;
        pending = null;
        main.removeCallbacksAndMessages(null);
        result.error(code, null, null);
    }
    private static String string(MethodCall call, String key, int maximum) {
        Object value = call.argument(key);
        if (!(value instanceof String text) || text.isEmpty() || text.length() > maximum) {
            throw new IllegalArgumentException();
        }
        return text;
    }
    private static String nullablePassword(MethodCall call, String key) {
        Object value = call.argument(key);
        if (!(value instanceof String text) || text.length() > 128) throw new IllegalArgumentException();
        return text;
    }
    private static void copy(byte[] destination, String value) {
        if (value == null) throw new IllegalArgumentException();
        byte[] bytes = value.getBytes(StandardCharsets.UTF_8);
        if (bytes.length >= destination.length) throw new IllegalArgumentException();
        Arrays.fill(destination, (byte) 0);
        System.arraycopy(bytes, 0, destination, 0, bytes.length);
    }
    @Override public void close() {
        closed = true;
        if (pending != null) fail(generation, "cameraServiceClosed");
        main.removeCallbacksAndMessages(null);
        if (push != null) { push.setOnXMPushLinkListener(null); push.unInit(); }
        AccountManager.getInstance().logout();
    }
}
