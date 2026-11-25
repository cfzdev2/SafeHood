package com.safehood.securityapp;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import java.io.ByteArrayOutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.SocketTimeoutException;
import javax.net.SocketFactory;

/** Receives camera-generated motion; it never decodes a continuous video stream. */
final class DvripAlarmReceiver implements AutoCloseable {
    record Credentials(String host, String username, String password) { }
    interface Listener {
        void onMotion(long occurredAt, byte[] jpeg);
        void onClosed();
    }
    private final SocketFactory sockets;
    private final Credentials credentials;
    private final Listener listener;
    private volatile boolean closed;
    private volatile Socket socket;

    DvripAlarmReceiver(SocketFactory sockets, Credentials credentials, Listener listener) {
        this.sockets = sockets;
        this.credentials = credentials;
        this.listener = listener;
    }

    void start() {
        Thread worker = new Thread(this::run, "SafeHoodCameraAlarm");
        worker.setDaemon(true);
        worker.start();
    }

    private void run() {
        try {
            Socket peer = sockets.createSocket();
            socket = peer;
            if (closed) { peer.close(); return; }
            peer.connect(new InetSocketAddress(credentials.host(), 34567), 2500);
            try (DvripClient client = new DvripClient(peer)) {
                client.login(credentials.username(), credentials.password());
                client.configureMotion(true);
                client.subscribe();
                long keepAliveAt = System.nanoTime();
                long lastMotionAt = 0;
                while (!closed) {
                    DvripClient.Alarm alarm = client.pendingAlarm();
                    if (alarm == null) {
                        try { alarm = client.readAlarm(1200); }
                        catch (SocketTimeoutException quiet) { /* A quiet camera is normal. */ }
                    }
                    if (closed) break;
                    long now = System.nanoTime();
                    if (alarm != null && alarm.isMotionStart()
                            && (lastMotionAt == 0 || now - lastMotionAt >= 30_000_000_000L)) {
                        lastMotionAt = now;
                        long occurredAt = System.currentTimeMillis();
                        byte[] photo = null;
                        try { photo = smallJpeg(client.snapshot()); }
                        catch (Exception unavailable) { /* The alarm is still useful without a JPEG. */ }
                        if (!closed) listener.onMotion(occurredAt, photo);
                    }
                    if (now - keepAliveAt >= client.aliveSeconds() * 1_000_000_000L) {
                        client.keepAlive();
                        keepAliveAt = System.nanoTime();
                    }
                }
            }
        } catch (Exception unavailable) {
            // Credentials, addresses and camera-supplied error text never enter logs.
        } finally {
            try { if (socket != null) socket.close(); } catch (Exception ignored) { }
            if (!closed) listener.onClosed();
        }
    }

    private static byte[] smallJpeg(byte[] source) {
        BitmapFactory.Options bounds = new BitmapFactory.Options();
        bounds.inJustDecodeBounds = true;
        BitmapFactory.decodeByteArray(source, 0, source.length, bounds);
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0
                || bounds.outWidth > 8192 || bounds.outHeight > 8192
                || (long) bounds.outWidth * bounds.outHeight > 32_000_000) return null;
        BitmapFactory.Options options = new BitmapFactory.Options();
        options.inSampleSize = 1;
        while (Math.max(bounds.outWidth, bounds.outHeight) / options.inSampleSize > 640) {
            options.inSampleSize *= 2;
        }
        Bitmap original = BitmapFactory.decodeByteArray(source, 0, source.length, options);
        if (original == null) return null;
        Bitmap resized = original;
        try {
            double scale = Math.min(1, 320.0 / Math.max(original.getWidth(), original.getHeight()));
            if (scale < 1) resized = Bitmap.createScaledBitmap(original,
                    Math.max(1, (int) (original.getWidth() * scale)),
                    Math.max(1, (int) (original.getHeight() * scale)), true);
            ByteArrayOutputStream output = new ByteArrayOutputStream();
            return resized.compress(Bitmap.CompressFormat.JPEG, 75, output)
                    && output.size() <= 256 * 1024 ? output.toByteArray() : null;
        } finally {
            if (resized != original) resized.recycle();
            original.recycle();
        }
    }

    @Override public void close() {
        closed = true;
        try { if (socket != null) socket.close(); } catch (Exception ignored) { }
    }
}
