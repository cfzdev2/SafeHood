package com.safehood.securityapp;

import java.io.DataInputStream;
import java.io.IOException;
import java.math.BigInteger;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.AlgorithmParameters;
import java.security.KeyFactory;
import java.security.KeyPair;
import java.security.MessageDigest;
import java.security.spec.ECGenParameterSpec;
import java.security.spec.ECParameterSpec;
import java.security.spec.ECPrivateKeySpec;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HexFormat;
import java.util.Locale;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;
import javax.crypto.Cipher;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import javax.net.SocketFactory;

final class ReolinkWireTest {
    private static final String UID = "9527000NBAKA1H1U";
    private static final String NONCE = "test-device-nonce";
    private static final String PASSWORD = "example9";
    private static final String XML = "<?xml version=\"1.0\"?>";
    private static final HexFormat HEX = HexFormat.of();

    private static void expect(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    private static void bleVectors() throws Exception {
        final var params = AlgorithmParameters.getInstance("EC");
        params.init(new ECGenParameterSpec("secp256r1"));
        final var client = new KeyPair(null, KeyFactory.getInstance("EC").generatePrivate(
                new ECPrivateKeySpec(new BigInteger("11".repeat(32), 16),
                        params.getParameterSpec(ECParameterSpec.class))));
        final byte[] camera = HEX.parseHex(
                "04d65a93977caa3d1b081852ff57a79e465f1660577304baead505dd3a48589cf"
                + "350185e895372df6221ea3a137557e473fddb6755f05bd507c3c533fce9c91285");
        final byte[] shared = ReolinkBleWire.shared(client, camera);
        expect(HEX.formatHex(shared).equals(
                "ccfc261f58193c98ca4ad4a53bbac6f0ee29bc4d48438090446908622ca79af6"), "ECDH");
        final byte[] first = new byte[64];
        final byte[] second = new byte[64];
        for (int i = 0; i < 64; i++) {
            first[i] = (byte) i;
            second[i] = (byte) (255 - i);
        }
        final byte[] key = ReolinkBleWire.derive(first, second, shared);
        expect(HEX.formatHex(key).equals(
                "68e554ef38cfc21accf5bf4e1a9dbd9bd68cf656689b3ea2845d003ed2da9a97"), "PBKDF2");
        final byte[] clear = ReolinkBleWire.tlv(100001, ReolinkBleWire.utf8(
                "{\"cmd\":4,\"id\":1,\"data\":{\"s\":\"TestNetwork\",\"p\":\"hunter2\",\"c\":\"CA\"}}"));
        final byte[] frame = ReolinkBleWire.frame(ReolinkBleWire.cfb(Cipher.ENCRYPT_MODE, key, clear));
        expect(HEX.formatHex(frame).equals(
                "4a0000000ab7d1ff30f3f366f1d73f7e39f91199078512512efea5a1b6e71e9d5381ff851f20f2ba"
                + "243cbb0231817093aae4fbd8645b23e83ea52aaf282b1ea8d423d5839b334c43f0929c58a919"), "frame");
        final var decoder = new ReolinkBleWire.Frames();
        final var received = new ArrayList<byte[]>();
        for (byte next : ReolinkBleWire.join(frame, frame)) {
            received.addAll(decoder.push(new byte[]{next}));
        }
        expect(received.size() == 2, "fragmented BLE notification");
        expect(Arrays.equals(ReolinkBleWire.cfb(Cipher.DECRYPT_MODE, key, received.get(1)), clear),
                "decrypt fragmented frame");
        expect(ReolinkBleWire.advertisedName(UID).equals("Reolink_t1olgEqnUTlNCi6c"), "UID match");
        invalid(() -> new ReolinkBleWire.Frames().push(ReolinkBleWire.intLe(Integer.MAX_VALUE)));
        invalid(() -> ReolinkBleWire.tlvs(HEX.parseHex("01000000ffffffff")));
    }

    private interface Throws {
        void run() throws Exception;
    }

    private static void invalid(Throws example) throws Exception {
        try {
            example.run();
            throw new AssertionError("accepted invalid frame");
        } catch (IOException expected) { }
    }

    private static void discovery() throws Exception {
        final int id = 724932;
        final String response = "<P2P><D2C_S_R><uid>" + UID + "</uid></D2C_S_R></P2P>";
        final byte[] selected = ReolinkLanWire.packet(id, response);
        expect(UID.equals(ReolinkLanWire.discoveredUid(selected, selected.length, id)), "UID discovery");
        expect(ReolinkLanWire.discoveredUid(selected, selected.length, id - 1) == null, "old reply");
        selected[selected.length - 1] ^= 1;
        expect(ReolinkLanWire.discoveredUid(selected, selected.length, id) == null, "CRC verification");
        final String reply = "<P2P><D2C_C_R><rsp>0</rsp><cid>93</cid><did>65</did></D2C_C_R></P2P>";
        final byte[] targeted = ReolinkLanWire.packet(id, reply);
        expect(Integer.valueOf(65).equals(ReolinkLanWire.targetedReply(targeted, targeted.length, id, 93)),
                "targeted probe");
        expect(ReolinkLanWire.targetedReply(targeted, targeted.length, id, 94) == null,
                "another client's discovery reply");
        invalid(() -> ReolinkLanWire.xml(ReolinkBleWire.utf8(
                "<!DOCTYPE body [<!ENTITY foo SYSTEM 'file:///tmp/unread'>]><body>&foo;</body>")));
        final var ports = ReolinkLanWire.xml(ReolinkBleWire.utf8(
                "<body><RtspPort><port>8554</port><enable>0</enable></RtspPort></body>"));
        expect(ReolinkLanWire.readPort(ports, "Rtsp").equals(new ReolinkLanWire.Port(8554, false)),
                "preserve configured RTSP port");
    }

    private static String md5(String input) throws Exception {
        return HEX.formatHex(MessageDigest.getInstance("MD5").digest(ReolinkBleWire.utf8(input)))
                .substring(0, 31).toUpperCase(Locale.ROOT);
    }

    private static byte[] cipher(byte[] clear, int mode) throws Exception {
        final var aes = Cipher.getInstance("AES/CFB/NoPadding");
        aes.init(mode, new SecretKeySpec(ReolinkBleWire.utf8(
                md5(NONCE + "-" + PASSWORD).substring(0, 16)), "AES"),
                new IvParameterSpec(ReolinkBleWire.utf8("0123456789abcdef")));
        return aes.doFinal(clear);
    }

    private static void tcp() throws Exception {
        try (var server = new ServerSocket(0, 1, InetAddress.getLoopbackAddress())) {
            final var peer = CompletableFuture.runAsync(() -> {
                try (var connection = server.accept()) {
                    connection.setSoTimeout(3000);
                    final var in = new DataInputStream(connection.getInputStream());
                    boolean rtsp = false;
                    final int[] sequence = {1, 1, 114, 80, 37, 36, 37, 2};
                    for (int step = 0; step < sequence.length; step++) {
                        final var request = ReolinkLanWire.little(in.readNBytes(20));
                        expect(request.getInt() == 0x0abcdef0, "TCP magic");
                        final int command = request.getInt();
                        final int len = request.getInt();
                        final int id = request.getInt();
                        expect(command == sequence[step], "command order");
                        expect((id & 255) == 250, "host channel");
                        if (step == 0) {
                            expect(request.getShort() == (short) 0xdc12 &&
                                    request.getShort() == (short) 0x6514 && len == 0, "nonce header");
                        } else {
                            expect(request.getShort() == 0 &&
                                    request.getShort() == 0x6414 && in.readInt() == 0, "modern header");
                        }
                        final byte[] payload = in.readNBytes(len);
                        String body = "";
                        if (step == 0) body = XML + "<body><nonce>" + NONCE + "</nonce></body>";
                        if (step == 1) {
                            final String login = new String(ReolinkLanWire.tcpXor(payload, 250),
                                    StandardCharsets.UTF_8);
                            expect(login.contains("<password>" + md5(PASSWORD + NONCE) + "</password>"),
                                    "local challenge response");
                        }
                        if (command == 114) body = XML + "<body><uid>" + UID + "</uid></body>";
                        if (command == 80) body = XML + "<body><type>E330</type></body>";
                        if (command == 36) {
                            final String xml = new String(cipher(payload, Cipher.DECRYPT_MODE),
                                    StandardCharsets.UTF_8);
                            expect(xml.contains("<RtspPort version=\"1.1\"><enable>1</enable>"),
                                    "only enable RTSP");
                            rtsp = true;
                        }
                        if (command == 37) body = XML
                                + "<body><RtspPort><port>8554</port><enable>"
                                + (rtsp ? "1" : "0") + "</enable></RtspPort></body>";
                        byte[] response = ReolinkBleWire.utf8(body);
                        if (step == 0) response = ReolinkLanWire.tcpXor(response, 250);
                        else if (response.length > 0) response = cipher(response, Cipher.ENCRYPT_MODE);
                        final var header = ReolinkBleWire.little(step == 0 ? 20 : 24)
                                .putInt(0x0abcdef0).putInt(command).putInt(response.length).putInt(id);
                        if (step == 0) header.putShort((short) 0xdd12).putShort((short) 0x6614);
                        else header.putShort((short) 200).putShort((short) 0x6414).putInt(0);
                        connection.getOutputStream().write(header.array());
                        connection.getOutputStream().write(response);
                    }
                } catch (Exception error) {
                    throw new RuntimeException(error);
                }
            });
            // A socket factory that maps the client's fixed camera port to the
            // ephemeral mock port while keeping the protocol class unmodified.
            final var sockets = new SocketFactory() {
                @Override public Socket createSocket() {
                    return new Socket() {
                        @Override public void connect(java.net.SocketAddress endpoint, int timeout)
                                throws IOException {
                            super.connect(server.getLocalSocketAddress(), timeout);
                        }
                    };
                }
                @Override public Socket createSocket(String a, int b) { throw new AssertionError(); }
                @Override public Socket createSocket(InetAddress a, int b) { throw new AssertionError(); }
                @Override public Socket createSocket(String a, int b, InetAddress c, int d) { throw new AssertionError(); }
                @Override public Socket createSocket(InetAddress a, int b, InetAddress c, int d) { throw new AssertionError(); }
            };
            final var loopback = (Inet4Address) InetAddress.getByAddress(new byte[]{127, 0, 0, 1});
            try (var camera = new ReolinkLanWire(sockets, loopback)) {
                camera.login(PASSWORD);
                expect(UID.equals(camera.uid()) && camera.model().equals("E330"), "verify identity");
                expect(!ReolinkLanWire.readPort(camera.ports(), "Rtsp").enabled(), "initial RTSP");
                camera.setPort("Rtsp", true);
                expect(ReolinkLanWire.readPort(camera.ports(), "Rtsp").enabled(), "read-back");
            }
            peer.get(3, TimeUnit.SECONDS);
        }
    }

    public static void main(String[] args) throws Exception {
        bleVectors();
        discovery();
        tcp();
        System.out.println("OK: BLE vectors, framed discovery, authenticated TCP and RTSP");
    }
}
