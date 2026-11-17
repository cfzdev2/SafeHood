package com.safehood.securityapp;

// Android GATT exchange adapted from cmolson/reolink-provisioning (MIT).

import android.annotation.SuppressLint;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCallback;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattDescriptor;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothProfile;
import android.bluetooth.BluetoothStatusCodes;
import android.bluetooth.le.BluetoothLeScanner;
import android.bluetooth.le.ScanCallback;
import android.bluetooth.le.ScanResult;
import android.bluetooth.le.ScanSettings;
import android.content.Context;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.ArrayDeque;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import javax.crypto.Cipher;
import org.json.JSONObject;

/** Each operation belongs to a single screen; callbacks never carry credentials to logs. */
@SuppressLint("MissingPermission")
final class ReolinkBluetooth implements AutoCloseable {
    private static final UUID SERVICE = UUID.fromString("3d24bfff-0bcb-08bd-e5fc-0647025b2dce");
    private static final UUID CHARACTERISTIC = UUID.fromString("0000aaaa-0000-1000-8000-00805f9b34fb");
    private static final UUID CCCD = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb");
    private static final SecureRandom RANDOM = new SecureRandom();
    private final Context context;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService crypto = Executors.newSingleThreadExecutor();
    private Scan scan;
    private Session session;

    interface Reply<T> {
        void complete(T result, String error);
    }

    ReolinkBluetooth(Context context) {
        this.context = context.getApplicationContext();
    }

    void find(String uid, Reply<BluetoothDevice> reply) {
        if (scan != null || session != null) {
            reply.complete(null, "busy");
            return;
        }
        final var manager = context.getSystemService(BluetoothManager.class);
        final var adapter = manager == null ? null : manager.getAdapter();
        final var scanner = adapter == null || !adapter.isEnabled()
                ? null : adapter.getBluetoothLeScanner();
        if (scanner == null) {
            reply.complete(null, "bluetoothOff");
            return;
        }
        try {
            scan = new Scan(scanner, ReolinkBleWire.advertisedName(uid), reply);
            scan.start();
        } catch (Exception failed) {
            if (scan != null) scan.finish("scanFailed");
            else reply.complete(null, "scanFailed");
        }
    }

    @SuppressWarnings("deprecation")
    private final class Scan extends ScanCallback {
        final BluetoothLeScanner scanner;
        final String target;
        final Reply<BluetoothDevice> reply;
        final Map<String, BluetoothDevice> matches = new HashMap<>();
        final Runnable deadline = () -> finish(null);

        Scan(BluetoothLeScanner scanner, String target, Reply<BluetoothDevice> reply) {
            this.scanner = scanner;
            this.target = target;
            this.reply = reply;
        }

        void start() {
            scanner.startScan(null, new ScanSettings.Builder()
                    .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), this);
            main.postDelayed(deadline, 7000);
        }

        private void record(ScanResult result) {
            if (scan != this || result.getScanRecord() == null
                    || !target.equals(result.getScanRecord().getDeviceName())) return;
            final var device = result.getDevice();
            matches.put(device.getAddress(), device);
            if (matches.size() > 1) finish("ambiguous");
        }

        @Override public void onScanResult(int type, ScanResult result) {
            main.post(() -> record(result));
        }

        @Override public void onBatchScanResults(List<ScanResult> results) {
            main.post(() -> results.forEach(this::record));
        }

        @Override public void onScanFailed(int error) {
            main.post(() -> finish("scanFailed"));
        }

        void finish(String error) {
            if (scan != this) return;
            scan = null;
            main.removeCallbacks(deadline);
            try { scanner.stopScan(this); } catch (RuntimeException ignored) { }
            if (error != null) reply.complete(null, error);
            else if (matches.isEmpty()) reply.complete(null, "notFoundBle");
            else reply.complete(matches.values().iterator().next(), null);
        }
    }

    void provision(BluetoothDevice device, String ssid, String password, String country,
            Reply<String> reply) {
        if (scan != null || session != null) {
            reply.complete(null, "busy");
            return;
        }
        session = new Session(device, ssid, password, country, reply);
        main.postDelayed(session.start, 600);
    }

    void cancel() {
        if (scan != null) scan.finish("cancelled");
        if (session != null) session.finish(null, "cancelled");
    }

    @Override public void close() {
        cancel();
        crypto.shutdownNow();
    }

    @SuppressWarnings("deprecation")
    private final class Session extends BluetoothGattCallback {
        private final BluetoothDevice device;
        private final Reply<String> reply;
        private final String ssid;
        private String wifiPassword;
        private final String country;
        private final int commandId = RANDOM.nextInt(1_000_000) + 1;
        private final ReolinkBleWire.Frames incoming = new ReolinkBleWire.Frames();
        private final ArrayDeque<byte[]> writes = new ArrayDeque<>();
        private final Runnable start = this::connect;
        private final Runnable timeout = this::connectionLost;
        private BluetoothGatt gatt;
        private BluetoothGattCharacteristic characteristic;
        private int mtu = 23;
        private boolean mtuKnown;
        private boolean requestedNotifications;
        private boolean runningWrite;
        private boolean negotiating;
        private boolean configStarted;
        private boolean configMayHaveArrived;
        private byte[] deviceRandom;
        private byte[] deviceKey;
        private byte[] sessionKey;

        Session(BluetoothDevice device, String ssid, String wifiPassword,
                String country, Reply<String> reply) {
            this.device = device;
            this.ssid = ssid;
            this.wifiPassword = wifiPassword;
            this.country = country;
            this.reply = reply;
        }

        void connect() {
            if (session != this) return;
            main.postDelayed(timeout, 25_000);
            try {
                gatt = device.connectGatt(context, false, this, BluetoothDevice.TRANSPORT_LE);
                if (gatt == null) connectionLost();
            } catch (RuntimeException refused) {
                connectionLost();
            }
        }

        private void dispatch(BluetoothGatt peer, Runnable action) {
            main.post(() -> {
                if (session != this || gatt != peer) return;
                try { action.run(); } catch (RuntimeException failed) { connectionLost(); }
            });
        }

        @Override public void onConnectionStateChange(BluetoothGatt peer, int status, int state) {
            dispatch(peer, () -> {
                if (status != BluetoothGatt.GATT_SUCCESS
                        || state == BluetoothProfile.STATE_DISCONNECTED) connectionLost();
                else if (state == BluetoothProfile.STATE_CONNECTED && !peer.discoverServices()) {
                    connectionLost();
                }
            });
        }

        @Override public void onServicesDiscovered(BluetoothGatt peer, int status) {
            dispatch(peer, () -> {
                final var service = peer.getService(SERVICE);
                characteristic = service == null ? null : service.getCharacteristic(CHARACTERISTIC);
                if (status != BluetoothGatt.GATT_SUCCESS || characteristic == null) {
                    connectionLost();
                } else if (mtuKnown || !peer.requestMtu(247)) {
                    enableNotifications();
                }
            });
        }

        @Override public void onMtuChanged(BluetoothGatt peer, int response, int status) {
            dispatch(peer, () -> {
                mtuKnown = status == BluetoothGatt.GATT_SUCCESS && response >= 23;
                if (mtuKnown) mtu = response;
                if (characteristic != null) enableNotifications();
            });
        }

        private void enableNotifications() {
            if (requestedNotifications) return;
            requestedNotifications = true;
            final var descriptor = characteristic.getDescriptor(CCCD);
            if (descriptor == null || !gatt.setCharacteristicNotification(characteristic, true)) {
                connectionLost();
                return;
            }
            final byte[] value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE;
            if (Build.VERSION.SDK_INT >= 33) {
                if (gatt.writeDescriptor(descriptor, value) != BluetoothStatusCodes.SUCCESS) {
                    connectionLost();
                }
            } else {
                descriptor.setValue(value);
                if (!gatt.writeDescriptor(descriptor)) connectionLost();
            }
        }

        @Override public void onDescriptorWrite(
                BluetoothGatt peer, BluetoothGattDescriptor desc, int status) {
            dispatch(peer, () -> {
                if (!CCCD.equals(desc.getUuid())) return;
                if (status != BluetoothGatt.GATT_SUCCESS) connectionLost();
                else enqueue(ReolinkBleWire.join(
                        ReolinkBleWire.tlv(1, ReolinkBleWire.intLe(1)),
                        ReolinkBleWire.tlv(6, ReolinkBleWire.intLe(mtu))));
            });
        }

        @Override public void onCharacteristicWrite(
                BluetoothGatt peer, BluetoothGattCharacteristic ch, int status) {
            dispatch(peer, () -> {
                if (!CHARACTERISTIC.equals(ch.getUuid()) || !runningWrite) return;
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    connectionLost();
                    return;
                }
                runningWrite = false;
                writeNext();
            });
        }

        @Override public void onCharacteristicChanged(
                BluetoothGatt peer, BluetoothGattCharacteristic ch, byte[] value) {
            if (CHARACTERISTIC.equals(ch.getUuid())) receive(peer, value.clone());
        }

        @Override public void onCharacteristicChanged(
                BluetoothGatt peer, BluetoothGattCharacteristic ch) {
            final byte[] value = ch.getValue();
            if (CHARACTERISTIC.equals(ch.getUuid()) && value != null) receive(peer, value.clone());
        }

        private void receive(BluetoothGatt peer, byte[] value) {
            dispatch(peer, () -> {
                try {
                    for (byte[] message : incoming.push(value)) {
                        if (session != this) return;
                        if (configMayHaveArrived) readWifiReply(message);
                        else if (!negotiating) readHandshake(message);
                    }
                } catch (Exception invalid) {
                    connectionLost();
                }
            });
        }

        private void readHandshake(byte[] message) throws IOException {
            for (var tlv : ReolinkBleWire.tlvs(message)) {
                if (tlv.type == 2 && tlv.value.length == 64) deviceRandom = tlv.value;
                else if (tlv.type == 3 && tlv.value.length == 65) deviceKey = tlv.value;
            }
            if (deviceRandom == null || deviceKey == null) return;
            negotiating = true;
            final byte[] firstRandom = deviceRandom;
            final byte[] publicKey = deviceKey;
            crypto.execute(() -> {
                try {
                    final var localKey = ReolinkBleWire.generateKey();
                    final byte[] localRandom = new byte[64];
                    RANDOM.nextBytes(localRandom);
                    final byte[] shared = ReolinkBleWire.shared(localKey, publicKey);
                    final byte[] key = ReolinkBleWire.derive(firstRandom, localRandom, shared);
                    Arrays.fill(shared, (byte) 0);
                    final byte[] handshake = ReolinkBleWire.join(
                            ReolinkBleWire.tlv(4, localRandom),
                            ReolinkBleWire.tlv(5, ReolinkBleWire.publicKey(localKey)));
                    main.post(() -> {
                        if (session != this) {
                            Arrays.fill(key, (byte) 0);
                            return;
                        }
                        sessionKey = key;
                        try { enqueue(handshake); } catch (RuntimeException error) { connectionLost(); }
                    });
                } catch (Exception error) {
                    main.post(this::connectionLost);
                }
            });
        }

        private void sendWifi() {
            try {
                final var params = new JSONObject().put("s", ssid).put("p", wifiPassword)
                        .put("c", country);
                wifiPassword = null;
                final var command = new JSONObject().put("cmd", 4).put("id", commandId)
                        .put("data", params);
                final byte[] clear = ReolinkBleWire.tlv(ReolinkBleWire.WIFI,
                        ReolinkBleWire.utf8(command.toString()));
                final byte[] encrypted = ReolinkBleWire.cfb(Cipher.ENCRYPT_MODE, sessionKey, clear);
                Arrays.fill(clear, (byte) 0);
                configStarted = true;
                main.removeCallbacks(timeout);
                main.postDelayed(timeout, 45_000);
                enqueue(encrypted);
            } catch (Exception error) {
                connectionLost();
            }
        }

        private void readWifiReply(byte[] message) {
            try {
                final byte[] clear = ReolinkBleWire.cfb(Cipher.DECRYPT_MODE, sessionKey, message);
                for (var tlv : ReolinkBleWire.tlvs(clear)) {
                    if (tlv.type != ReolinkBleWire.WIFI) continue;
                    final var json = new JSONObject(new String(tlv.value, StandardCharsets.UTF_8));
                    if (json.optInt("rep", -1) != 4 || json.optInt("id", -1) != commandId) continue;
                    final var status = json.optJSONObject("data");
                    if (status == null || !status.has("code") || !status.has("result")) continue;
                    if (status.optInt("code", -1) == 0 && status.optInt("result", -1) == 0) {
                        finish("accepted", null);
                    } else {
                        finish(null, "wifiRejected");
                    }
                    return;
                }
            } catch (Exception ignored) {
                // Some firmware interleaves a plaintext version ack. Only
                // a correlated encrypted reply decides success/failure.
            }
        }

        private void enqueue(byte[] payload) {
            final byte[] frame = ReolinkBleWire.frame(payload);
            final int chunk = Math.min(244, mtu - 3);
            for (int i = 0; i < frame.length; i += chunk) {
                writes.add(Arrays.copyOfRange(frame, i, Math.min(frame.length, i + chunk)));
            }
            writeNext();
        }

        private void writeNext() {
            if (runningWrite || session != this) return;
            final byte[] bytes = writes.poll();
            if (bytes == null) {
                if (sessionKey != null && !configStarted) sendWifi();
                return;
            }
            runningWrite = true;
            final int mode = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT;
            final boolean accepted;
            if (Build.VERSION.SDK_INT >= 33) {
                accepted = gatt.writeCharacteristic(characteristic, bytes, mode)
                        == BluetoothStatusCodes.SUCCESS;
            } else {
                characteristic.setWriteType(mode);
                characteristic.setValue(bytes);
                accepted = gatt.writeCharacteristic(characteristic);
            }
            if (!accepted) connectionLost();
            else if (configStarted && writes.isEmpty()) configMayHaveArrived = true;
        }

        private void connectionLost() {
            if (configMayHaveArrived) finish("unconfirmed", null);
            else finish(null, "bleConnection");
        }

        private void finish(String result, String error) {
            if (session != this) return;
            session = null;
            main.removeCallbacks(start);
            main.removeCallbacks(timeout);
            wifiPassword = null;
            writes.clear();
            if (sessionKey != null) Arrays.fill(sessionKey, (byte) 0);
            if (gatt != null) {
                try { gatt.disconnect(); } catch (RuntimeException ignored) { }
                try { gatt.close(); } catch (RuntimeException ignored) { }
                gatt = null;
            }
            reply.complete(result, error);
        }
    }
}
