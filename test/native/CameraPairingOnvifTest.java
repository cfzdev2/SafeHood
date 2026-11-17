package com.safehood.securityapp;

import java.io.ByteArrayOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.FutureTask;
import java.util.concurrent.TimeUnit;
import javax.net.SocketFactory;

public final class CameraPairingOnvifTest {
    private static final String BODY_START =
            "<s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\" "
            + "xmlns:d=\"http://www.onvif.org/ver10/device/wsdl\" "
            + "xmlns:t=\"http://www.onvif.org/ver10/schema\"><s:Body>";
    private static final String WIRED = "<d:NetworkInterfaces token=\"eth\"><t:Extension>"
            + "<t:InterfaceType>6</t:InterfaceType></t:Extension></d:NetworkInterfaces>";
    private static final String WIRELESS = "<d:NetworkInterfaces token=\"wifi&amp;1\"><t:Extension>"
            + "<t:InterfaceType>71</t:InterfaceType><t:Dot11><t:Alias>Home &amp; Office</t:Alias>"
            + "</t:Dot11></t:Extension></d:NetworkInterfaces>";
    private static final CameraPairingOnvif.Credentials LOGIN =
            new CameraPairingOnvif.Credentials("admin", "camera-password");

    private static CameraPairingOnvif.Reply response(String op, String body) {
        return new CameraPairingOnvif.Reply(200, List.of(),
                bytes(BODY_START + "<d:" + op + "Response>" + body + "</d:" + op
                    + "Response></s:Body></s:Envelope>"));
    }

    private static byte[] bytes(String text) {
        return text.getBytes(StandardCharsets.UTF_8);
    }

    private static void require(boolean condition, String problem) {
        if (!condition) throw new AssertionError(problem);
    }

    private static String operation(String action) {
        return action.substring(action.lastIndexOf('/') + 1);
    }

    private static CameraPairingOnvif.Reply info() {
        return response("GetDeviceInformation", "<d:Manufacturer>Test</d:Manufacturer><d:Model>NVT</d:Model>");
    }

    private static void configuresOnlyWifiAndHandlesReboot() throws Exception {
        List<String> operations = new ArrayList<>();
        final CameraPairingOnvif client = new CameraPairingOnvif((action, body, authorization) -> {
            final String op = operation(action);
            operations.add(op);
            final String soap = new String(body, StandardCharsets.UTF_8);
            return switch (op) {
                case "GetSystemDateAndTime" -> {
                    require(!soap.contains("UsernameToken"), "discovery used credentials");
                    yield response(op, "");
                }
                case "GetDeviceInformation" -> {
                    require(soap.contains("PasswordDigest") && !soap.contains(LOGIN.password()),
                            "camera login must use a digest");
                    yield info();
                }
                case "GetNetworkInterfaces" -> response(op, WIRED + WIRELESS);
                case "SetNetworkInterfaces" -> {
                    require(soap.contains("<tds:InterfaceToken>wifi&amp;1</tds:InterfaceToken>"),
                            "the verified wireless interface must be selected");
                    require(soap.contains("<tt:SSID>446f6d5fc581c3b364c5ba</tt:SSID>"),
                            "SSID must contain hex UTF-8 bytes");
                    require(soap.contains("<tt:DHCP>true</tt:DHCP>"), "enable DHCP on Wi-Fi");
                    require(soap.contains("<tt:Alias>Home &amp; Office</tt:Alias>"),
                            "preserve the existing wireless configuration alias");
                    require(soap.contains("<tt:Passphrase>abc&amp;&lt;XYZ1</tt:Passphrase>"),
                            "PSK must be XML escaped without altering it");
                    yield response(op, "<d:RebootNeeded>true</d:RebootNeeded>");
                }
                case "SystemReboot" -> {
                    require(!soap.contains("Passphrase"), "reboot must not send home Wi-Fi credentials");
                    yield response(op, "");
                }
                default -> throw new AssertionError(op);
            };
        });
        require(client.probe(), "find the ONVIF service");
        final var device = client.inspect(LOGIN);
        require(device.label().equals("Test NVT"), "show camera model before configuration");
        require(client.configure(device, LOGIN, "Dom_Łódź", "abc&<XYZ1")
                == CameraPairingOnvif.Outcome.REBOOT_NEEDED, "read reboot flag");
        require(operations.size() == 4, "do not reboot without an explicit user action");
        require(client.reboot(LOGIN) == CameraPairingOnvif.Outcome.ACCEPTED, "can reboot");
    }

    private static void rejectsWiredAndAmbiguousInterfaces() throws Exception {
        for (final String interfaces : List.of(WIRED, WIRELESS + WIRELESS)) {
            final CameraPairingOnvif client = new CameraPairingOnvif((action, body, auth) ->
                    switch (operation(action)) {
                        case "GetDeviceInformation" -> info();
                        case "GetNetworkInterfaces" -> response("GetNetworkInterfaces", interfaces);
                        default -> throw new AssertionError("unexpected write");
                    });
            try {
                client.inspect(LOGIN);
                throw new AssertionError("must require one explicitly wireless interface");
            } catch (CameraPairingOnvif.PairingException error) {
                require(error.code.equals(interfaces.equals(WIRED) ? "noOnvifWifi" : "ambiguousWifi"),
                        "use correct error code");
            }
        }
    }

    private static void replaysDigestOnlyForReadsAndDoesNotRepeatUnconfirmedWrite() throws Exception {
        final List<String> operations = new ArrayList<>();
        final CameraPairingOnvif client = new CameraPairingOnvif((action, body, auth) -> {
            final String op = operation(action);
            operations.add(op);
            if (op.equals("GetSystemDateAndTime")) return response(op, "");
            if (op.equals("GetDeviceInformation") && auth == null) {
                return new CameraPairingOnvif.Reply(401,
                        List.of("Digest realm=\"camera\", nonce=\"n1\", qop=\"auth\", algorithm=SHA-256"),
                        new byte[0]);
            }
            final int count = operations.size() - 2;
            require(auth != null && auth.startsWith("Digest ")
                    && auth.contains("nc=0000000" + count)
                    && !auth.contains(LOGIN.password()), "authenticated request uses a new nonce count");
            return switch (op) {
                case "GetDeviceInformation" -> info();
                case "GetNetworkInterfaces" -> response(op, WIRELESS);
                case "SetNetworkInterfaces" -> throw new EOFException("hotspot disconnected");
                default -> throw new AssertionError(op);
            };
        });
        require(client.probe(), "find the ONVIF service");
        final var device = client.inspect(LOGIN);
        require(client.configure(device, LOGIN, "Home", "safe-pass-1") == CameraPairingOnvif.Outcome.UNCONFIRMED,
                "connection loss is an unknown result");
        require(operations.stream().filter("SetNetworkInterfaces"::equals).count() == 1,
                "do not replay an unconfirmed write");
    }

    private static void rejectsUntrustedXmlAndInvalidWifi() throws Exception {
        final var badXml = List.of(
                "<!DOCTYPE s:Envelope [<!ENTITY secret SYSTEM \"file:///not-readable\">]>"
                        + BODY_START + "<d:GetSystemDateAndTimeResponse>&secret;</d:GetSystemDateAndTimeResponse>"
                        + "</s:Body></s:Envelope>",
                BODY_START + "<fake:GetSystemDateAndTimeResponse xmlns:fake=\"http://other\"/>"
                        + "</s:Body></s:Envelope>");
        for (String malformed : badXml) {
            final CameraPairingOnvif client = new CameraPairingOnvif((action, body, auth) ->
                    new CameraPairingOnvif.Reply(200, List.of(), bytes(malformed)));
            require(!client.probe(), "reject invalid ONVIF reply");
        }
        require(!CameraPairingOnvif.validWpaSecret("short"), "reject short passphrase");
        require(!CameraPairingOnvif.validWpaSecret("a".repeat(63) + "x".repeat(2)), "reject long passphrase");
        require(CameraPairingOnvif.validWpaSecret("a".repeat(64)), "allow hex key");
    }

    private static void fixedLengthHttpAndChunkedResponse() throws Exception {
        final Inet4Address host = (Inet4Address) InetAddress.getByAddress(new byte[] {127, 0, 0, 1});
        try (ServerSocket server = new ServerSocket(0, 1, host)) {
            final FutureTask<Void> peer = new FutureTask<>(() -> {
                try (var connection = server.accept()) {
                    connection.setSoTimeout(2_000);
                    final var input = connection.getInputStream();
                    final var header = new ByteArrayOutputStream();
                    while (!header.toString(StandardCharsets.ISO_8859_1).endsWith("\r\n\r\n")) {
                        final int b = input.read();
                        if (b < 0 || header.size() > 4096) throw new IOException("invalid request");
                        header.write(b);
                    }
                    final String fields = header.toString(StandardCharsets.ISO_8859_1);
                    require(fields.startsWith("POST /onvif/device_service HTTP/1.0\r\n"), "fixed ONVIF endpoint");
                    require(fields.contains("Content-Length: 5\r\n"), "length uses UTF-8 bytes");
                    require(new String(input.readNBytes(5), StandardCharsets.UTF_8).equals("Łód"),
                            "body sent in full");
                    connection.getOutputStream().write(bytes("HTTP/1.1 200 OK\r\n"
                            + "Transfer-Encoding: chunked\r\n\r\n2\r\nOK\r\n0\r\n\r\n"));
                }
                return null;
            });
            final Thread thread = new Thread(peer);
            thread.setDaemon(true);
            thread.start();
            final var http = new CameraPairingHttp(SocketFactory.getDefault(), host, server.getLocalPort(), 2_000);
            final var reply = http.post("urn:test", bytes("Łód"), null);
            require(reply.status() == 200 && new String(reply.body(), StandardCharsets.UTF_8).equals("OK"),
                    "accept bounded chunked reply");
            peer.get(3, TimeUnit.SECONDS);
        }
    }

    public static void main(String[] args) throws Exception {
        configuresOnlyWifiAndHandlesReboot();
        rejectsWiredAndAmbiguousInterfaces();
        replaysDigestOnlyForReadsAndDoesNotRepeatUnconfirmedWrite();
        rejectsUntrustedXmlAndInvalidWifi();
        fixedLengthHttpAndChunkedResponse();
        System.out.println("Camera hotspot SOAP and HTTP: 5 checks passed");
    }
}
