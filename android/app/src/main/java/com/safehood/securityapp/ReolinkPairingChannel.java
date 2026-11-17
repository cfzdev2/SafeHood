package com.safehood.securityapp;

import android.Manifest;
import android.app.Activity;
import android.bluetooth.BluetoothDevice;
import android.content.pm.PackageManager;
import android.location.LocationManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import java.util.Locale;
import java.util.concurrent.CancellationException;
import java.util.concurrent.Executors;

public final class ReolinkPairingChannel implements AutoCloseable {
    private static final int PERMISSION_REQUEST = 6042;
    private final Activity activity;
    private final MethodChannel channel;
    private final ReolinkBluetooth ble;
    private final ReolinkLanSetup lan;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final java.util.concurrent.ExecutorService worker = Executors.newSingleThreadExecutor();
    private BluetoothDevice selected;
    private long selectedUntil;
    private volatile Operation operation;
    private String awaitingPermissions;
    private boolean closed;

    private record Operation(MethodChannel.Result reply) { }

    public ReolinkPairingChannel(Activity activity, BinaryMessenger messenger) {
        this.activity = activity;
        ble = new ReolinkBluetooth(activity);
        lan = new ReolinkLanSetup(activity);
        channel = new MethodChannel(messenger, "safehood/reolink_pairing");
        channel.setMethodCallHandler(this::handle);
    }

    private void handle(MethodCall call, MethodChannel.Result reply) {
        if (call.method.equals("cancel")) {
            cancel();
            reply.success(null);
            return;
        }
        if (closed || Build.VERSION.SDK_INT < 29) {
            fail(reply, "unsupported");
            return;
        }
        if (operation != null) {
            fail(reply, "busy");
            return;
        }
        try {
            switch (call.method) {
                case "select" -> select(call.argument("uid"), reply);
                case "connectWifi" -> join(call.argument("ssid"), call.argument("password"), reply);
                case "prepareStream" -> prepare(call.argument("uid"), call.argument("password"),
                        Boolean.TRUE.equals(call.argument("factory")), reply);
                default -> reply.notImplemented();
            }
        } catch (RuntimeException error) {
            if (operation != null && operation.reply == reply) operation = null;
            awaitingPermissions = null;
            fail(reply, "badRequest");
        }
    }

    private void select(String uid, MethodChannel.Result reply) {
        if (!validUid(uid)) {
            fail(reply, "badRequest");
            return;
        }
        selected = null;
        final var task = new Operation(reply);
        operation = task;
        if (!hasBlePermission()) {
            awaitingPermissions = uid;
            activity.requestPermissions(Build.VERSION.SDK_INT >= 31
                    ? new String[]{Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT}
                    : new String[]{Manifest.permission.ACCESS_COARSE_LOCATION,
                        Manifest.permission.ACCESS_FINE_LOCATION}, PERMISSION_REQUEST);
            return;
        }
        find(uid, task);
    }

    private void find(String uid, Operation task) {
        if (Build.VERSION.SDK_INT < 31
                && !activity.getSystemService(LocationManager.class).isLocationEnabled()) {
            finish(task, null, "permissions");
            return;
        }
        ble.find(uid, (device, problem) -> {
            if (operation != task) return;
            if (device != null) {
                selected = device;
                selectedUntil = SystemClock.elapsedRealtime() + 180_000;
            }
            finish(task, true, problem);
        });
    }

    private boolean hasBlePermission() {
        if (Build.VERSION.SDK_INT >= 31) {
            return granted(Manifest.permission.BLUETOOTH_SCAN)
                    && granted(Manifest.permission.BLUETOOTH_CONNECT);
        }
        return granted(Manifest.permission.ACCESS_FINE_LOCATION);
    }

    private boolean granted(String permission) {
        return activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED;
    }

    public void onPermissionResult(int requestCode) {
        if (requestCode != PERMISSION_REQUEST || awaitingPermissions == null || operation == null) return;
        final var task = operation;
        final String uid = awaitingPermissions;
        awaitingPermissions = null;
        if (!hasBlePermission()) finish(task, null, "permissions");
        else {
            try { find(uid, task); } catch (RuntimeException denied) {
                finish(task, null, "permissions");
            }
        }
    }

    private void join(String ssid, String password, MethodChannel.Result reply) {
        if (!hasBlePermission()) {
            fail(reply, "permissions");
            return;
        }
        if (selected == null || SystemClock.elapsedRealtime() > selectedUntil) {
            fail(reply, "selectionExpired");
            return;
        }
        final int ssidLength = ssid == null ? 0 : ReolinkBleWire.utf8(ssid).length;
        if (ssidLength < 1 || ssidLength > 32 || ssid.indexOf(0) != -1 || !validWifiPassword(password)) {
            fail(reply, "badRequest");
            return;
        }
        final String region = Locale.getDefault().getCountry();
        final var task = new Operation(reply);
        operation = task;
        ble.provision(selected, ssid, password, region.matches("[A-Z]{2}") ? region : "",
                (state, problem) -> {
                    if (operation != task) return;
                    if (problem == null) selected = null;
                    finish(task, state, problem);
                });
    }

    private void prepare(String uid, String password, boolean factory, MethodChannel.Result reply) {
        if (!validUid(uid) || password == null || password.isEmpty()
                || password.length() > 128 || password.indexOf(0) != -1
                || (factory && !password.matches("(?=.*[a-zA-Z])(?=.*[0-9])[!-~]{8,31}"))) {
            fail(reply, "badRequest");
            return;
        }
        final var task = new Operation(reply);
        operation = task;
        worker.execute(() -> {
            try {
                final var source = lan.prepare(uid, password, factory, () -> operation != task);
                main.post(() -> finish(task, source, null));
            } catch (ReolinkLanWire.Failure error) {
                main.post(() -> finish(task, null, error.code));
            } catch (CancellationException cancelled) {
                main.post(() -> finish(task, null, "cancelled"));
            } catch (Exception error) {
                main.post(() -> finish(task, null, "unsupportedFirmware"));
            }
        });
    }

    private static boolean validUid(String uid) {
        return uid != null && uid.matches("[A-Z0-9]{16}");
    }

    private static boolean validWifiPassword(String password) {
        if (password == null || password.indexOf(0) != -1) return false;
        final int count = ReolinkBleWire.utf8(password).length;
        return count == 0 || (count >= 8 && count <= 63) || password.matches("[0-9a-fA-F]{64}");
    }

    private static void fail(MethodChannel.Result reply, String code) {
        reply.error(code, null, null);
    }

    private void finish(Operation task, Object value, String error) {
        if (operation != task) return;
        operation = null;
        if (error != null) fail(task.reply, error);
        else task.reply.success(value);
    }

    private void cancel() {
        final var task = operation;
        operation = null;
        awaitingPermissions = null;
        selected = null;
        ble.cancel();
        if (task != null) fail(task.reply, "cancelled");
    }

    @Override public void close() {
        closed = true;
        cancel();
        channel.setMethodCallHandler(null);
        ble.close();
        // Let a camera operation finish restoring temporary settings if needed.
        worker.shutdown();
    }
}
