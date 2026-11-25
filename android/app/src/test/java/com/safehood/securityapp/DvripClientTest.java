package com.safehood.securityapp;

import static org.junit.Assert.*;
import java.io.DataInputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.concurrent.atomic.AtomicReference;
import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.Test;

public final class DvripClientTest {
    interface Session { void run(Socket socket) throws Exception; }
    interface Client { void run(DvripClient client) throws Exception; }
    private static final int TOKEN = 0x12345678;

    private void exchange(Session server, Client body) throws Exception {
        try (var listener = new ServerSocket(0, 1, InetAddress.getLoopbackAddress())) {
            var failure = new AtomicReference<Throwable>();
            Thread worker = new Thread(() -> {
                try (Socket socket = listener.accept()) { socket.setSoTimeout(5000); server.run(socket); }
                catch (Throwable error) { failure.set(error); }
            });
            worker.start();
            try (var socket = new Socket(listener.getInetAddress(), listener.getLocalPort());
                    var client = new DvripClient(socket)) { body.run(client); }
            worker.join(6000);
            assertFalse("Fixture server must terminate", worker.isAlive());
            if (failure.get() != null) throw new AssertionError(failure.get());
        }
    }

    private record Request(int command, int sequence, JSONObject data) { }
    private static Request request(Socket socket) throws Exception {
        var input = new DataInputStream(socket.getInputStream());
        byte[] raw = input.readNBytes(20);
        assertEquals(20, raw.length);
        var h = ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN);
        byte[] bytes = input.readNBytes(h.getInt(16));
        return new Request(h.getShort(14) & 65535, h.getInt(8),
                new JSONObject(new String(bytes, StandardCharsets.UTF_8).trim()));
    }
    private static void reply(Socket socket, int command, int sequence, byte[] body) throws Exception {
        var header = ByteBuffer.allocate(20).order(ByteOrder.LITTLE_ENDIAN);
        header.put(0, (byte) 255).put(1, (byte) 1).putInt(4, TOKEN).putInt(8, sequence)
                .putShort(14, (short) command).putInt(16, body.length);
        // Splitting every header byte exercises real TCP fragmentation.
        for (byte b : header.array()) { socket.getOutputStream().write(b); socket.getOutputStream().flush(); }
        socket.getOutputStream().write(body);
        socket.getOutputStream().flush();
    }
    private static void reply(Socket socket, Request request, JSONObject body) throws Exception {
        reply(socket, request.command() + 1, request.sequence(),
                (body + "\n\0").getBytes(StandardCharsets.UTF_8));
    }
    private static void login(Socket socket) throws Exception {
        var request = request(socket);
        assertEquals(1000, request.command());
        assertEquals("admin", request.data().getString("UserName"));
        assertEquals("tlJwpbo6", request.data().getString("PassWord"));
        reply(socket, request, new JSONObject().put("Ret", 100)
                .put("SessionID", "0x12345678").put("AliveInterval", 10));
    }
    private static byte[] motion() {
        return ("{\"Name\":\"AlarmInfo\",\"AlarmInfo\":{\"Event\":\"MotionDetect\","
                + "\"Channel\":0,\"Status\":\"Start\"}}\n\0").getBytes(StandardCharsets.UTF_8);
    }

    @Test public void readsActualProfileWithFragmentedHeadersAndPadding() throws Exception {
        exchange(socket -> {
            login(socket);
            var system = request(socket);
            assertEquals(1020, system.command());
            reply(socket, system, new JSONObject().put("Ret", 100).put("SystemInfo",
                    new JSONObject().put("SerialNo", "0123456789ABCDEF").put("Hardware", "test-camera")));
            socket.getOutputStream().write(0);
            var config = request(socket);
            assertEquals("Detect.MotionDetect", config.data().getString("Name"));
            reply(socket, config, new JSONObject().put("Ret", 100).put("Detect.MotionDetect",
                    new JSONArray().put(new JSONObject().put("Enable", false))));
        }, client -> {
            client.login("admin", "");
            var profile = client.inspect();
            assertEquals("0123456789ABCDEF", profile.get("serialNumber"));
            assertEquals(true, profile.get("motionSupported"));
            assertEquals(false, profile.get("motionEnabled"));
        });
    }

    @Test public void changesMotionWithoutChangingOtherChannelsOrSirenRecordingRegions() throws Exception {
        exchange(socket -> {
            login(socket);
            var get = request(socket);
            var handler = new JSONObject().put("RecordEnable", false).put("BeepEnable", true);
            var channels = new JSONArray().put(new JSONObject().put("Enable", false)
                    .put("Region", "keep").put("EventHandler", handler))
                    .put(new JSONObject().put("Enable", false));
            reply(socket, get, new JSONObject().put("Ret", 100).put("Detect.MotionDetect", channels));
            var set = request(socket);
            assertEquals(1040, set.command());
            var changed = set.data().getJSONArray("Detect.MotionDetect");
            assertTrue(changed.getJSONObject(0).getBoolean("Enable"));
            assertEquals("keep", changed.getJSONObject(0).getString("Region"));
            assertFalse(changed.getJSONObject(1).getBoolean("Enable"));
            assertFalse(changed.getJSONObject(0).getJSONObject("EventHandler").getBoolean("RecordEnable"));
            assertTrue(changed.getJSONObject(0).getJSONObject("EventHandler").getBoolean("BeepEnable"));
            assertTrue(changed.getJSONObject(0).getJSONObject("EventHandler").getBoolean("MsgtoNetEnable"));
            reply(socket, set, new JSONObject().put("Ret", 100));
        }, client -> { client.login("admin", ""); client.configureMotion(true); });
    }

    @Test public void receivesAlarmWhileWaitingForKeepAliveAndSnapshot() throws Exception {
        byte[] jpeg = {(byte) 255, (byte) 216, 1, 2, 3, 4, (byte) 255, (byte) 217};
        exchange(socket -> {
            login(socket);
            var subscribe = request(socket);
            assertEquals(1500, subscribe.command());
            reply(socket, 1504, 98, motion());
            reply(socket, subscribe, new JSONObject().put("Ret", 100));
            var keepAlive = request(socket);
            reply(socket, 1504, 99, motion());
            reply(socket, keepAlive, new JSONObject().put("Ret", 100));
            var snapshot = request(socket);
            assertEquals(1560, snapshot.command());
            byte[] first = new byte[20];
            first[2] = 1; first[3] = (byte) 254;
            ByteBuffer.wrap(first).order(ByteOrder.LITTLE_ENDIAN).putInt(12, jpeg.length);
            System.arraycopy(jpeg, 0, first, 16, 4);
            reply(socket, 1561, snapshot.sequence(), first);
            reply(socket, 1504, 100, motion());
            reply(socket, 1561, snapshot.sequence(), Arrays.copyOfRange(jpeg, 4, jpeg.length));
        }, client -> {
            client.login("admin", "");
            client.subscribe();
            assertTrue(client.pendingAlarm().isMotionStart());
            client.keepAlive();
            assertTrue(client.pendingAlarm().isMotionStart());
            assertArrayEquals(jpeg, client.snapshot());
            assertTrue(client.pendingAlarm().isMotionStart());
        });
    }

    @Test public void partialPacketTimeoutClosesTheSessionInsteadOfTreatingItAsQuiet() throws Exception {
        exchange(socket -> {
            login(socket);
            socket.getOutputStream().write(255);
            socket.getOutputStream().flush();
            assertEquals(-1, socket.getInputStream().read());
        }, client -> {
            client.login("admin", "");
            var failure = assertThrows(DvripClient.Failure.class, () -> client.readAlarm(100));
            assertEquals("cameraProtocol", failure.code);
        });
    }

    @Test public void rejectsWrongReplySequence() throws Exception {
        exchange(socket -> {
            var login = request(socket);
            reply(socket, 1001, login.sequence() + 1,
                    "{\"Ret\":100}".getBytes(StandardCharsets.UTF_8));
        }, client -> assertThrows(DvripClient.Failure.class, () -> client.login("admin", "")));
    }

    @Test public void rejectsOversizedPacketsBeforeAllocatingOrWaitingForBody() throws Exception {
        exchange(socket -> {
            request(socket);
            var h = ByteBuffer.allocate(20).order(ByteOrder.LITTLE_ENDIAN);
            h.put(0, (byte) 255).put(1, (byte) 1).putShort(14, (short) 1001)
                    .putInt(16, Integer.MAX_VALUE);
            socket.getOutputStream().write(h.array());
        }, client -> assertThrows(DvripClient.Failure.class, () -> client.login("admin", "")));
    }

    @Test public void rejectsAuthWithoutTryingOtherPasswords() throws Exception {
        exchange(socket -> {
            var request = request(socket);
            reply(socket, request, new JSONObject().put("Ret", 203));
        }, client -> {
            var error = assertThrows(DvripClient.Failure.class, () -> client.login("admin", ""));
            assertEquals("cameraAuth", error.code);
        });
    }
}
