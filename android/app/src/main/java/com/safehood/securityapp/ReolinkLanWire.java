package com.safehood.securityapp;

// Baichuan framing/commands based on reolink_aio (MIT); see docs/third_party.

import java.io.IOException;
import java.io.InputStream;
import java.io.StringReader;
import java.net.Inet4Address;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.util.Arrays;
import javax.crypto.Cipher;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import javax.net.SocketFactory;
import javax.xml.parsers.DocumentBuilderFactory;
import org.w3c.dom.Document;
import org.w3c.dom.Element;
import org.xml.sax.InputSource;
import org.xml.sax.SAXException;
import org.xml.sax.helpers.DefaultHandler;

final class ReolinkLanWire implements AutoCloseable {
    static final int NET_PORT = 9000;
    static final int DISCOVERY_PORT = 2015;
    static final int DISCOVERY_MAGIC = 0x2a87cf3a;
    static final int TCP_MAGIC = 0x0abcdef0;
    private static final int MAX_BODY = 64 * 1024;
    private static final String XML = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>";
    private static final int[] UDP_KEY = {
        0x1f2d3c4b, 0x5a6c7f8d, 0x38172e4b, 0x8271635a,
        0x863f1a2b, 0xa5c6f7d8, 0x8371e1b4, 0x17f2d3a5
    };
    private static final int[] TCP_KEY = {0x1f, 0x2d, 0x3c, 0x4b, 0x5a, 0x69, 0x78, 0xff};
    private final Socket socket;
    private int nextId;
    private byte[] aesKey;
    private boolean loggedIn;

    record Port(int number, boolean enabled) { }

    static final class Failure extends IOException {
        final String code;

        Failure(String code) {
            super(code);
            this.code = code;
        }
    }

    ReolinkLanWire(SocketFactory sockets, Inet4Address host) throws IOException {
        socket = sockets.createSocket();
        try {
            socket.connect(new InetSocketAddress(host, NET_PORT), 2000);
        } catch (IOException failed) {
            socket.close();
            throw failed;
        }
    }

    static ByteBuffer little(byte[] data) {
        return ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN);
    }

    static byte[] udpXor(byte[] data, int id) {
        final var keys = ReolinkBleWire.little(32);
        for (int value : UDP_KEY) keys.putInt(value + id);
        final byte[] result = new byte[data.length];
        for (int i = 0; i < result.length; i++) result[i] = (byte) (data[i] ^ keys.get(i & 31));
        return result;
    }

    private static int crc(byte[] data) {
        int value = 0;
        for (byte item : data) {
            value ^= item & 255;
            for (int bit = 0; bit < 8; bit++) {
                value = (value >>> 1) ^ ((value & 1) == 0 ? 0 : 0xedb88320);
            }
        }
        return value;
    }

    static byte[] discovery(int port, int id) {
        return packet(id, "<P2P><C2D_S><to><port>" + port + "</port></to></C2D_S></P2P>");
    }

    static byte[] packet(int id, String xml) {
        final byte[] body = udpXor(ReolinkBleWire.utf8(xml), id);
        return ReolinkBleWire.little(20 + body.length).putInt(DISCOVERY_MAGIC).putInt(body.length)
                .putInt(1).putInt(id).putInt(crc(body)).put(body).array();
    }

    private static Document discoveryReply(byte[] packet, int size, int id) throws IOException {
        if (size < 20 || size > 4096 || size > packet.length) return null;
        final var header = little(packet);
        if (header.getInt() != DISCOVERY_MAGIC || header.getInt() != size - 20) return null;
        if (header.getInt() != 1 || header.getInt() != id) return null;
        final byte[] body = Arrays.copyOfRange(packet, 20, size);
        if (header.getInt() != crc(body)) return null;
        final Document doc = xml(udpXor(body, id));
        return doc.getDocumentElement().getTagName().equals("P2P") ? doc : null;
    }

    static String discoveredUid(byte[] packet, int size, int id) throws IOException {
        final var doc = discoveryReply(packet, size, id);
        final var reply = doc == null ? null : uniqueElement(doc, "D2C_S_R");
        final String uid = reply == null ? null : value(reply, "uid");
        return uid != null && uid.matches("[A-Z0-9]{16}") ? uid : null;
    }

    static byte[] targetedDiscovery(String uid, int port, int client, int tx) {
        if (!uid.matches("[A-Z0-9]{16}")) throw new IllegalArgumentException();
        return packet(tx, "<P2P><C2D_C><uid>" + uid + "</uid><cli><port>" + port
                + "</port></cli><cid>" + client + "</cid><mtu>1350</mtu>"
                + "<debug>false</debug><p>MAC</p></C2D_C></P2P>");
    }

    static Integer targetedReply(byte[] data, int size, int tx, int client) throws IOException {
        final var doc = discoveryReply(data, size, tx);
        final var reply = doc == null ? null : uniqueElement(doc, "D2C_C_R");
        try {
            if (reply != null && "0".equals(value(reply, "rsp"))
                    && Integer.parseInt(value(reply, "cid")) == client) {
                return Integer.valueOf(value(reply, "did"));
            }
        } catch (NumberFormatException invalid) {
            // Not a response to this probe.
        }
        return null;
    }

    private static Element uniqueElement(Document doc, String tag) {
        final var nodes = doc.getDocumentElement().getElementsByTagName(tag);
        return nodes.getLength() == 1 && nodes.item(0) instanceof Element node ? node : null;
    }

    static byte[] tcpXor(byte[] data, int offset) {
        final byte[] result = new byte[data.length];
        for (int i = 0; i < result.length; i++) {
            result[i] = (byte) (data[i] ^ TCP_KEY[(i + offset) & 7] ^ offset);
        }
        return result;
    }

    void login(String password) throws IOException, GeneralSecurityException {
        final var response = exchange(1, "", true, true, 4000);
        final String nonce = value(xml(response), "nonce");
        if (nonce == null || nonce.isEmpty() || nonce.length() > 128) {
            throw new Failure("unsupportedFirmware");
        }
        final byte[] key = ReolinkBleWire.utf8(md5(nonce + "-" + password).substring(0, 16));
        exchange(1, XML + "<body><LoginUser version=\"1.1\"><userName>" + md5("admin" + nonce)
                + "</userName><password>" + md5(password + nonce)
                + "</password><userVer>1</userVer></LoginUser><LoginNet version=\"1.1\">"
                + "<type>LAN</type><udpPort>0</udpPort></LoginNet></body>", false, true, 4000);
        aesKey = key;
        loggedIn = true;
    }

    private static String md5(String text) throws GeneralSecurityException {
        final byte[] digest = MessageDigest.getInstance("MD5").digest(ReolinkBleWire.utf8(text));
        final char[] out = new char[32];
        final String hex = "0123456789ABCDEF";
        for (int i = 0; i < digest.length; i++) {
            out[2 * i] = hex.charAt((digest[i] & 255) >>> 4);
            out[2 * i + 1] = hex.charAt(digest[i] & 15);
        }
        return new String(out, 0, 31);
    }

    String uid() throws IOException, GeneralSecurityException {
        return value(request(114), "uid");
    }

    String model() throws IOException, GeneralSecurityException {
        return value(request(80), "type");
    }

    Document ports() throws IOException, GeneralSecurityException {
        return request(37);
    }

    static Port readPort(Document doc, String service) throws Failure {
        if (!service.equals("Http") && !service.equals("Rtsp")) {
            throw new IllegalArgumentException();
        }
        final var nodes = doc.getElementsByTagName(service + "Port");
        if (nodes.getLength() != 1 || !(nodes.item(0) instanceof Element node)) {
            throw new Failure("unsupportedFirmware");
        }
        final String enabled = value(node, "enable");
        try {
            final int port = Integer.parseInt(value(node, "port"));
            if (port >= 1 && port <= 65535 && ("0".equals(enabled) || "1".equals(enabled))) {
                return new Port(port, "1".equals(enabled));
            }
        } catch (IllegalArgumentException ignored) { }
        throw new Failure("unsupportedFirmware");
    }

    void setPort(String service, boolean enabled) throws IOException, GeneralSecurityException {
        if (!service.equals("Http") && !service.equals("Rtsp")) {
            throw new IllegalArgumentException();
        }
        final String tag = service + "Port";
        exchange(36, XML + "<body><" + tag + " version=\"1.1\"><enable>"
                + (enabled ? "1" : "0") + "</enable></" + tag + "></body>", false, false, 4000);
    }

    private Document request(int command) throws IOException, GeneralSecurityException {
        return xml(exchange(command, "", false, false, 4000));
    }

    private byte[] exchange(int command, String body, boolean nonce, boolean xor, int timeout)
            throws IOException, GeneralSecurityException {
        final int channel = 250;
        final int id = (++nextId << 8) | channel;
        final byte[] clear = ReolinkBleWire.utf8(body);
        final byte[] encrypted = clear.length == 0 ? clear
                : xor ? tcpXor(clear, channel) : aes(Cipher.ENCRYPT_MODE, clear);
        final var header = ReolinkBleWire.little(nonce ? 20 : 24);
        header.putInt(TCP_MAGIC).putInt(command).putInt(encrypted.length).putInt(id);
        if (nonce) header.putShort((short) 0xdc12).putShort((short) 0x6514);
        else header.putShort((short) 0).putShort((short) 0x6414).putInt(0);
        final var output = socket.getOutputStream();
        output.write(header.array());
        if (encrypted.length != 0) output.write(encrypted);
        output.flush();
        final long deadline = System.nanoTime() + timeout * 1_000_000L;
        final var input = socket.getInputStream();
        for (int attempt = 0; attempt < 8; attempt++) {
            final var response = little(read(input, 20, deadline));
            if (response.getInt() != TCP_MAGIC) throw new Failure("unsupportedFirmware");
            final int actualCommand = response.getInt();
            final int count = response.getInt();
            final int actualId = response.getInt();
            final int code = response.getShort() & 0xffff;
            final int kind = response.getShort() & 0xffff;
            if (count < 0 || count > MAX_BODY) throw new Failure("unsupportedFirmware");
            final boolean modern = kind == 0x6414 || kind == 0;
            if (!modern && kind != 0x6614) throw new Failure("unsupportedFirmware");
            final int offset = modern ? little(read(input, 4, deadline)).getInt() : 0;
            if (offset < 0 || offset > count) throw new Failure("unsupportedFirmware");
            final byte[] payload = read(input, count, deadline);
            if (actualCommand != command || actualId != id) continue;
            if (modern && code == 401) throw new Failure("authFailed");
            if (modern && code != 200 && code != 201 && code != 300) {
                throw new Failure("unsupportedFirmware");
            }
            if (count == 0) return payload;
            final byte[] data = offset == 0 ? payload : Arrays.copyOf(payload, offset);
            if (!modern && code == 0xdd00) return data;
            if (xor || (!modern && (code == 0xdd01 || code == 0xdd12))) {
                return tcpXor(data, actualId & 255);
            }
            final byte[] decrypted = aes(Cipher.DECRYPT_MODE, data);
            if (!new String(decrypted, StandardCharsets.UTF_8).startsWith("<?xml")) {
                return tcpXor(data, actualId & 255);
            }
            return decrypted;
        }
        throw new Failure("unsupportedFirmware");
    }

    private byte[] read(InputStream input, int count, long deadline) throws IOException {
        final byte[] bytes = new byte[count];
        int offset = 0;
        while (offset < count) {
            final long left = (deadline - System.nanoTime()) / 1_000_000L;
            if (left < 1) throw new java.net.SocketTimeoutException();
            socket.setSoTimeout((int) left);
            final int read = input.read(bytes, offset, count - offset);
            if (read < 0) throw new java.io.EOFException();
            offset += read;
        }
        return bytes;
    }

    private byte[] aes(int mode, byte[] data) throws GeneralSecurityException {
        if (aesKey == null) throw new GeneralSecurityException();
        final var cipher = Cipher.getInstance("AES/CFB/NoPadding");
        cipher.init(mode, new SecretKeySpec(aesKey, "AES"),
                new IvParameterSpec(ReolinkBleWire.utf8("0123456789abcdef")));
        return cipher.doFinal(data);
    }

    static Document xml(byte[] source) throws IOException {
        final String text = new String(source, StandardCharsets.UTF_8);
        // Android's XML factory does not support every desktop parser flag.
        // Reject DTDs/declarations before parsing as well as refusing entities.
        if (source.length == 0 || source.length > MAX_BODY
                || text.contains("<!") || text.indexOf(0) != -1) throw new IOException("XML");
        try {
            final var parser = DocumentBuilderFactory.newInstance().newDocumentBuilder();
            parser.setEntityResolver((publicId, systemId) -> { throw new SAXException("Entity"); });
            parser.setErrorHandler(new DefaultHandler());
            return parser.parse(new InputSource(new StringReader(text)));
        } catch (Exception invalid) {
            throw new IOException("Invalid camera XML");
        }
    }

    static String value(Document doc, String name) {
        return value(doc.getDocumentElement(), name);
    }

    static String value(Element root, String name) {
        final var elements = root.getElementsByTagName(name);
        return elements.getLength() == 1 ? elements.item(0).getTextContent().trim() : null;
    }

    @Override public void close() {
        if (loggedIn) {
            try { exchange(2, "", false, false, 500); } catch (Exception ignored) { }
        }
        if (aesKey != null) Arrays.fill(aesKey, (byte) 0);
        try { socket.close(); } catch (IOException ignored) { }
    }
}
