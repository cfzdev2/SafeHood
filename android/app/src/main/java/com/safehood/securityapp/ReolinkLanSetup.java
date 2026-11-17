package com.safehood.securityapp;

// Factory activation uses the ModifyUser sequence documented by reolink-init (MIT).

import android.content.Context;
import android.net.Uri;
import java.io.IOException;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.Inet4Address;
import java.net.InetSocketAddress;
import java.net.SocketTimeoutException;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.HashSet;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.CancellationException;
import java.util.function.BooleanSupplier;
import org.json.JSONArray;
import org.json.JSONObject;

final class ReolinkLanSetup {
    private static final SecureRandom RANDOM = new SecureRandom();
    private final Context context;

    record Target(CameraLocalNetwork.Link link, Inet4Address host) { }

    ReolinkLanSetup(Context context) {
        this.context = context.getApplicationContext();
    }

    String refreshRtsp(String uid, String password) throws Exception {
        final var target = find(uid, 4500, () -> Thread.currentThread().isInterrupted());
        if (target == null) throw new ReolinkLanWire.Failure("notFoundLan");
        try (var camera = new ReolinkLanWire(target.link.network().getSocketFactory(), target.host)) {
            camera.login(password);
            sameCamera(camera, uid);
            final var rtsp = ReolinkLanWire.readPort(camera.ports(), "Rtsp");
            if (!rtsp.enabled()) throw new ReolinkLanWire.Failure("rtspNotReady");
            return streamUri(target, rtsp, password);
        }
    }

    private static String streamUri(Target target, ReolinkLanWire.Port rtsp, String password) {
        return "rtsp://admin:" + encodeUserInfo(password) + "@"
                + target.host.getHostAddress() + ":" + rtsp.number() + "/h264Preview_01_sub";
    }

    Map<String, Object> prepare(String uid, String password, boolean factory,
            BooleanSupplier cancelled) throws Exception {
        final Target target = find(uid, 18_000, cancelled);
        if (target == null) throw new ReolinkLanWire.Failure("notFoundLan");
        final var sockets = target.link.network().getSocketFactory();
        String model;
        check(cancelled);
        if (factory) {
            // The only factory write is explicit, and restricted to the pilot models.
            // Re-check identity inside the TCP session before any settings changes.
            ReolinkLanWire.Port http = null;
            boolean restoreHttp = false;
            try {
                try (var fresh = new ReolinkLanWire(sockets, target.host)) {
                    fresh.login("");
                    sameCamera(fresh, uid);
                    model = fresh.model();
                    if (!pilot(model)) throw new ReolinkLanWire.Failure("unsupportedFirmware");
                    http = ReolinkLanWire.readPort(fresh.ports(), "Http");
                    check(cancelled);
                    if (!http.enabled()) {
                        restoreHttp = true;
                        fresh.setPort("Http", true);
                    }
                }
                check(cancelled);
                updatePassword(target, uid, http.number(), password, cancelled);
            } finally {
                if (restoreHttp) restoreHttp(target, uid, password);
            }
        }
        check(cancelled);
        try (var camera = new ReolinkLanWire(sockets, target.host)) {
            camera.login(password);
            sameCamera(camera, uid);
            model = camera.model();
            var rtsp = ReolinkLanWire.readPort(camera.ports(), "Rtsp");
            if (!rtsp.enabled()) {
                check(cancelled);
                camera.setPort("Rtsp", true);
                rtsp = ReolinkLanWire.readPort(camera.ports(), "Rtsp");
                if (!rtsp.enabled()) throw new ReolinkLanWire.Failure("rtspNotReady");
            }
            final var source = new HashMap<String, Object>();
            source.put("name", pilot(model) ? "Reolink " + model : "Reolink");
            source.put("uri", streamUri(target, rtsp, password));
            return source;
        }
    }

    private static String encodeUserInfo(String text) {
        // Android Media3 reads decoded userInfo and splits at the first colon.
        return Uri.encode(text);
    }

    private static boolean pilot(String model) {
        if (model == null) return false;
        final String name = model.toUpperCase(Locale.ROOT);
        return name.equals("E330") || name.equals("E1 PRO");
    }

    private static void sameCamera(ReolinkLanWire camera, String uid) throws Exception {
        if (!uid.equals(camera.uid())) throw new ReolinkLanWire.Failure("differentCamera");
    }

    private void updatePassword(Target target, String uid, int port, String password,
            BooleanSupplier cancelled) throws Exception {
        final var transport = new CameraPairingHttp(
                target.link.network().getSocketFactory(), target.host, port, 3500);
        String token = null;
        boolean sent = false;
        try {
            for (int attempt = 0; attempt < 3; attempt++) {
                check(cancelled);
                try {
                    token = cgi(transport, "Login", "null",
                            new JSONObject().put("User", new JSONObject().put("Version", "0")
                                    .put("userName", "admin").put("password", "")))
                            .getJSONObject("value").getJSONObject("Token").getString("name");
                    break;
                } catch (IOException unavailable) {
                    if (attempt == 2) throw unavailable;
                    Thread.sleep(900);
                }
            }
            final var identity = cgi(transport, "GetP2p", token, new JSONObject())
                    .getJSONObject("value");
            final var p2p = identity.optJSONObject("P2p") == null
                    ? identity.optJSONObject("P2P") : identity.optJSONObject("P2p");
            if (p2p == null) throw new ReolinkLanWire.Failure("unsupportedFirmware");
            final String actualUid = p2p.getString("uid");
            if (!uid.equals(actualUid)) throw new ReolinkLanWire.Failure("differentCamera");
            check(cancelled);
            sent = true;
            cgi(transport, "ModifyUser", token, new JSONObject().put("User", new JSONObject()
                    .put("userName", "admin").put("newPassword", password).put("oldPassword", "")));
        } catch (Exception failure) {
            if (sent) throw new ReolinkLanWire.Failure("passwordUnconfirmed");
            if (failure instanceof CancellationException) throw failure;
            if (failure instanceof ReolinkLanWire.Failure) throw failure;
            throw new ReolinkLanWire.Failure("unsupportedFirmware");
        } finally {
            if (token != null) {
                try { cgi(transport, "Logout", token, new JSONObject()); }
                catch (Exception ignored) { }
            }
        }
        // A success response alone is insufficient; some devices accept a no-op.
        try (var camera = new ReolinkLanWire(target.link.network().getSocketFactory(), target.host)) {
            camera.login(password);
            sameCamera(camera, uid);
        } catch (Exception ignored) {
            throw new ReolinkLanWire.Failure("passwordUnconfirmed");
        }
    }

    private static JSONObject cgi(CameraPairingHttp http, String command, String token,
            JSONObject args) throws Exception {
        final byte[] request = ReolinkBleWire.utf8(new JSONArray().put(new JSONObject()
                .put("cmd", command).put("action", 0).put("param", args)).toString());
        final byte[] response;
        try {
            response = http.postJson("/cgi-bin/api.cgi?cmd=" + command + "&token=" + token, request);
        } finally {
            java.util.Arrays.fill(request, (byte) 0);
        }
        final JSONObject result = new JSONArray(new String(response, StandardCharsets.UTF_8))
                .getJSONObject(0);
        if (!command.equals(result.optString("cmd")) || result.optInt("code", -1) != 0) {
            throw new ReolinkLanWire.Failure("unsupportedFirmware");
        }
        final var value = result.optJSONObject("value");
        if (command.equals("ModifyUser") && (value == null || value.optInt("rspCode") != 200)) {
            throw new ReolinkLanWire.Failure("passwordUnconfirmed");
        }
        return result;
    }

    private static void restoreHttp(Target target, String uid, String newPassword)
            throws ReolinkLanWire.Failure {
        // Restore the prior service state even if the CGI write or user cancellation
        // disconnected. Try each of the two known states once, only after UID check.
        final var sockets = target.link.network().getSocketFactory();
        for (String password : new String[]{newPassword, ""}) {
            try (var camera = new ReolinkLanWire(sockets, target.host)) {
                camera.login(password);
                sameCamera(camera, uid);
                camera.setPort("Http", false);
                if (ReolinkLanWire.readPort(camera.ports(), "Http").enabled()) continue;
                return;
            } catch (Exception ignored) { }
        }
        throw new ReolinkLanWire.Failure("httpRestoreFailed");
    }

    Target find(String uid, int timeout, BooleanSupplier cancelled) throws Exception {
        final var links = CameraLocalNetwork.links(context);
        if (links.isEmpty()) throw new ReolinkLanWire.Failure("notLocalNetwork");
        final long until = System.nanoTime() + timeout * 1_000_000L;
        do {
            for (var link : links) {
                check(cancelled);
                final var matches = discover(link, uid, Math.max(300,
                        (int) Math.min(1600, (until - System.nanoTime()) / 1_000_000L)), cancelled);
                if (matches.size() > 1) throw new ReolinkLanWire.Failure("ambiguous");
                if (matches.size() == 1) return new Target(link, matches.iterator().next());
            }
        } while (System.nanoTime() < until);
        return null;
    }

    private static HashSet<Inet4Address> discover(CameraLocalNetwork.Link link, String uid,
            int timeout, BooleanSupplier cancelled) throws IOException {
        final var matches = new HashSet<Inet4Address>();
        try (var socket = new DatagramSocket(null)) {
            link.network().bindSocket(socket);
            socket.bind(new InetSocketAddress(link.address(), 0));
            socket.setBroadcast(true);
            final int id = RANDOM.nextInt(999_001) + 1000;
            final int tx = id + 1;
            final int client = RANDOM.nextInt(Integer.MAX_VALUE - 1) + 1;
            final byte[] probe = ReolinkLanWire.discovery(socket.getLocalPort(), id);
            final var broadcast = link.broadcast();
            socket.send(new DatagramPacket(probe, probe.length, broadcast, ReolinkLanWire.DISCOVERY_PORT));
            final byte[] targeted = ReolinkLanWire.targetedDiscovery(uid, socket.getLocalPort(), client, tx);
            for (int port : new int[]{2015, 2018}) {
                socket.send(new DatagramPacket(targeted, targeted.length, broadcast, port));
            }
            final long until = System.nanoTime() + timeout * 1_000_000L;
            final byte[] buffer = new byte[4097];
            while (System.nanoTime() < until && !cancelled.getAsBoolean()) {
                final var packet = new DatagramPacket(buffer, buffer.length);
                socket.setSoTimeout(Math.max(1, Math.min(300,
                        (int) ((until - System.nanoTime()) / 1_000_000L))));
                try {
                    socket.receive(packet);
                } catch (SocketTimeoutException wait) {
                    continue;
                }
                if (!(packet.getAddress() instanceof Inet4Address ip)
                        || !CameraLocalNetwork.privateIp(ip) || !link.contains(ip)) continue;
                try {
                    final var remoteId = ReolinkLanWire.targetedReply(buffer, packet.getLength(), tx, client);
                    if (remoteId != null) {
                        // Discovery can allocate a temporary UDP session on the camera.
                        // We use only its endpoint and close that session before trying TCP.
                        final byte[] close = ReolinkLanWire.packet(tx + 1, "<P2P><C2D_DISC><cid>"
                                + client + "</cid><did>" + remoteId + "</did></C2D_DISC></P2P>");
                        socket.send(new DatagramPacket(close, close.length, ip, packet.getPort()));
                    }
                    if (remoteId != null
                            || uid.equals(ReolinkLanWire.discoveredUid(buffer, packet.getLength(), id))) {
                        matches.add(ip);
                        if (matches.size() > 1) break;
                    }
                } catch (IOException badPacket) {
                    // A different or malformed response cannot select a camera.
                }
            }
        }
        check(cancelled);
        return matches;
    }

    private static void check(BooleanSupplier cancelled) {
        if (cancelled.getAsBoolean()) throw new CancellationException();
    }
}
