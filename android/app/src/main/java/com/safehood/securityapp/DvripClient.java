package com.safehood.securityapp;

import java.io.ByteArrayOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/** A bounded, single-reader DVRIP session. No Wi-Fi, firmware or user changes. */
final class DvripClient implements AutoCloseable {
    static final int MAX_JSON = 128 * 1024;
    static final int MAX_JPEG = 2 * 1024 * 1024;
    private final Socket socket;
    private int session;
    private int sequence;
    private int aliveSeconds = 20;
    private boolean subscribed;

    record Packet(int session, int sequence, int command, byte[] body) { }
    record Alarm(String event, int channel, String status) {
        boolean isMotionStart() {
            return channel == 0 && ("Start".equalsIgnoreCase(status)
                    || "appEventStart".equalsIgnoreCase(status))
                    && ("MotionDetect".equalsIgnoreCase(event)
                        || "Motion_detection".equalsIgnoreCase(event)
                        || "VideoMotion".equalsIgnoreCase(event));
        }
    }
    static final class Failure extends IOException {
        final String code;
        Failure(String code) { super(code); this.code = code; }
    }

    DvripClient(Socket socket) { this.socket = socket; }

    static String passwordHash(String password) throws Exception {
        byte[] bytes = MessageDigest.getInstance("MD5")
                .digest(password.getBytes(StandardCharsets.UTF_8));
        String alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
        StringBuilder result = new StringBuilder(8);
        for (int i = 0; i < 16; i += 2) {
            result.append(alphabet.charAt(((bytes[i] & 255) + (bytes[i + 1] & 255)) % 62));
        }
        return result.toString();
    }

    void login(String username, String password) throws Exception {
        if (username == null || username.isEmpty() || username.length() > 128
                || password == null || password.length() > 128) throw new Failure("cameraAuth");
        JSONObject reply = request(1000, new JSONObject().put("EncryptType", "MD5")
                .put("LoginType", "DVRIP-Web").put("UserName", username)
                .put("PassWord", passwordHash(password)));
        if (reply.optInt("Ret") != 100) throw new Failure("cameraAuth");
        String token = reply.optString("SessionID").replaceFirst("^0[xX]", "");
        if (!token.isEmpty()) {
            try {
                long value = Long.parseUnsignedLong(token, 16);
                if (value == 0 || value > 0xffffffffL) throw new NumberFormatException();
                session = (int) value;
            } catch (NumberFormatException error) { throw new Failure("cameraProtocol"); }
        }
        if (session == 0) throw new Failure("cameraProtocol");
        aliveSeconds = Math.max(5, Math.min(30, reply.optInt("AliveInterval", 20)));
    }

    private JSONObject envelope(String name) throws JSONException {
        return new JSONObject().put("Name", name)
                .put("SessionID", String.format(Locale.ROOT, "0x%08X", session));
    }

    private JSONObject get(int command, String name) throws Exception {
        JSONObject reply = request(command, envelope(name));
        if (reply.optInt("Ret") != 100 || !reply.has(name)) throw new Failure("cameraUnsupported");
        return reply;
    }

    Map<String, Object> inspect() throws Exception {
        JSONObject info = get(1020, "SystemInfo").getJSONObject("SystemInfo");
        Map<String, Object> result = new HashMap<>();
        result.put("protocol", "dvrip");
        String serial = info.optString("SerialNo", "").trim();
        if (serial.matches("[a-zA-Z0-9_-]{8,64}")) result.put("serialNumber", serial);
        String model = info.optString("Hardware", info.optString("DeviceType", ""));
        if (model.length() <= 100) result.put("model", model);
        boolean motion = false;
        boolean motionEnabled = false;
        try {
            Object config = get(1042, "Detect.MotionDetect").get("Detect.MotionDetect");
            JSONObject channel = channelZero(config);
            motion = channel != null && channel.opt("Enable") instanceof Boolean;
            motionEnabled = motion && channel.optBoolean("Enable");
        } catch (Failure error) {
            if (!"cameraUnsupported".equals(error.code)) throw error;
        }
        result.put("motionSupported", motion);
        result.put("motionEnabled", motionEnabled);
        return result;
    }

    void configureMotion(boolean enabled) throws Exception {
        String name = "Detect.MotionDetect";
        Object original = get(1042, name).get(name);
        Object copy = original instanceof JSONArray ? new JSONArray(original.toString())
                : original instanceof JSONObject ? new JSONObject(original.toString()) : null;
        JSONObject channel = channelZero(copy);
        if (channel == null || !(channel.opt("Enable") instanceof Boolean)) {
            throw new Failure("cameraUnsupported");
        }
        channel.put("Enable", enabled);
        JSONObject handler = channel.optJSONObject("EventHandler");
        // Preserve schedules, regions, recording, sirens and other channels.
        // These flags route an existing motion alarm to local/cloud subscribers.
        if (enabled && handler != null) {
            handler.put("MsgtoNetEnable", true);
        }
        JSONObject reply = request(1040, envelope(name).put(name, copy));
        if (reply.optInt("Ret") != 100) throw new Failure("cameraConfiguration");
    }

    private static JSONObject channelZero(Object config) {
        if (config instanceof JSONArray channels) return channels.optJSONObject(0);
        return config instanceof JSONObject object ? object : null;
    }

    void subscribe() throws Exception {
        JSONObject reply = request(1500, envelope(""));
        if (reply.optInt("Ret") != 100) throw new Failure("cameraUnsupported");
        subscribed = true;
    }

    int aliveSeconds() { return aliveSeconds; }

    void keepAlive() throws Exception {
        JSONObject reply = request(1006, envelope("KeepAlive"));
        if (reply.optInt("Ret") != 100) throw new Failure("cameraProtocol");
    }

    Alarm readAlarm(int timeoutMillis) throws Exception {
        Packet packet = readPacket(timeoutMillis, MAX_JSON);
        if (packet.session() != session) throw new Failure("cameraProtocol");
        return packet.command() == 1504 ? alarm(json(packet.body())) : null;
    }

    private final java.util.ArrayDeque<Alarm> pendingAlarms = new java.util.ArrayDeque<>();
    Alarm pendingAlarm() { return pendingAlarms.pollFirst(); }

    private static Alarm alarm(JSONObject reply) {
        JSONObject alarm = reply.optJSONObject("AlarmInfo");
        if (alarm == null) return null;
        String event = alarm.optString("Event");
        String status = alarm.optString("Status");
        if (event.length() > 64 || status.length() > 32) return null;
        return new Alarm(event, alarm.optInt("Channel", -1), status);
    }

    byte[] snapshot() throws Exception {
        int seq = write(1560, envelope("OPSNAP").put("OPSNAP", new JSONObject().put("Channel", 0)));
        ByteArrayOutputStream jpeg = new ByteArrayOutputStream();
        int remaining = -1;
        long deadline = System.nanoTime() + 4_000_000_000L;
        for (int part = 0; part < 64 && System.nanoTime() < deadline; part++) {
            Packet packet = readPacket(leftMillis(deadline), MAX_JPEG + 16);
            if (packet.session() != session) throw new Failure("cameraProtocol");
            if (packet.command() == 1504) { rememberAlarm(json(packet.body())); continue; }
            if (packet.command() != 1561 && packet.command() != 1560) continue;
            if (packet.sequence() != seq) throw new Failure("cameraProtocol");
            byte[] body = packet.body();
            int offset = 0;
            if (remaining < 0) {
                if (body.length >= 2 && (body[0] & 255) == 255 && (body[1] & 255) == 216) {
                    remaining = body.length;
                } else if (body.length >= 16 && body[0] == 0 && body[1] == 0
                        && body[2] == 1 && (body[3] & 255) == 254 && body[4] == 0) {
                    remaining = ByteBuffer.wrap(body).order(ByteOrder.LITTLE_ENDIAN).getInt(12);
                    offset = 16;
                } else throw new Failure("snapshotUnavailable");
                if (remaining < 4 || remaining > MAX_JPEG) throw new Failure("snapshotUnavailable");
            }
            int length = body.length - offset;
            if (length > remaining) throw new Failure("snapshotUnavailable");
            jpeg.write(body, offset, length);
            remaining -= length;
            if (remaining == 0) {
                byte[] data = jpeg.toByteArray();
                if (data.length >= 4 && (data[0] & 255) == 255 && (data[1] & 255) == 216
                        && (data[data.length - 2] & 255) == 255
                        && (data[data.length - 1] & 255) == 217) return data;
                throw new Failure("snapshotUnavailable");
            }
        }
        throw new Failure("snapshotUnavailable");
    }

    private void rememberAlarm(JSONObject reply) {
        Alarm value = alarm(reply);
        if (value != null && pendingAlarms.size() < 8) pendingAlarms.addLast(value);
    }

    private JSONObject request(int command, JSONObject data) throws Exception {
        int seq = write(command, data);
        long deadline = System.nanoTime() + 4_000_000_000L;
        for (int i = 0; i < 16; i++) {
            Packet packet = readPacket(leftMillis(deadline), MAX_JSON);
            if (command == 1000) {
                if (packet.command() != 1001) throw new Failure("cameraProtocol");
                session = packet.session();
            } else if (packet.session() != session) throw new Failure("cameraProtocol");
            if (packet.command() == 1504 && (subscribed || command == 1500)) {
                rememberAlarm(json(packet.body())); continue;
            }
            if ((packet.command() != command + 1 && packet.command() != command)
                    || packet.sequence() != seq) throw new Failure("cameraProtocol");
            return json(packet.body());
        }
        throw new Failure("cameraProtocol");
    }

    private int write(int command, JSONObject data) throws IOException {
        byte[] body = (data.toString() + "\n\0").getBytes(StandardCharsets.UTF_8);
        if (body.length > MAX_JSON) throw new Failure("cameraProtocol");
        int seq = sequence++;
        ByteBuffer header = ByteBuffer.allocate(20).order(ByteOrder.LITTLE_ENDIAN);
        header.put(0, (byte) 255).putInt(4, session).putInt(8, seq)
                .putShort(14, (short) command).putInt(16, body.length);
        socket.getOutputStream().write(header.array());
        socket.getOutputStream().write(body);
        socket.getOutputStream().flush();
        return seq;
    }

    private Packet readPacket(int timeoutMillis, int maximum) throws IOException {
        long deadline = System.nanoTime() + timeoutMillis * 1_000_000L;
        byte[] header = new byte[20];
        // Some firmware leaves one CR/LF/NUL after a length-delimited reply.
        for (int i = 0; ; i++) {
            readFully(header, 0, 1, deadline);
            int first = header[0] & 255;
            if (first == 255) break;
            if (i == 3 || (first != 0 && first != 10 && first != 13)) throw new Failure("cameraProtocol");
        }
        try { readFully(header, 1, 19, deadline); }
        catch (SocketTimeoutException partial) {
            socket.close();
            throw new Failure("cameraProtocol");
        }
        if ((header[1] & 255) > 1 || header[2] != 0 || header[3] != 0) throw new Failure("cameraProtocol");
        ByteBuffer h = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN);
        int length = h.getInt(16);
        if (length < 0 || length > maximum) throw new Failure("cameraProtocol");
        byte[] body = new byte[length];
        try { readFully(body, 0, length, deadline); }
        catch (SocketTimeoutException partial) {
            socket.close();
            throw new Failure("cameraProtocol");
        }
        return new Packet(h.getInt(4), h.getInt(8), h.getShort(14) & 65535, body);
    }

    private void readFully(byte[] data, int offset, int length, long deadline) throws IOException {
        for (int at = offset; at < offset + length; ) {
            socket.setSoTimeout(leftMillis(deadline));
            int size = socket.getInputStream().read(data, at, offset + length - at);
            if (size < 0) throw new EOFException();
            at += size;
        }
    }

    private static int leftMillis(long deadline) throws SocketTimeoutException {
        long left = (deadline - System.nanoTime()) / 1_000_000L;
        if (left <= 0) throw new SocketTimeoutException();
        return (int) Math.min(Integer.MAX_VALUE, Math.max(1, left));
    }

    private static JSONObject json(byte[] body) throws JSONException {
        return new JSONObject(new String(body, StandardCharsets.UTF_8).replaceAll("[\\x00\\r\\n\\s]+$", ""));
    }

    @Override public void close() throws IOException { socket.close(); }
}
