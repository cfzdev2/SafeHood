package com.safehood.securityapp;

import java.io.StringReader;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.time.Instant;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.Arrays;
import java.util.Base64;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import javax.xml.parsers.DocumentBuilderFactory;
import org.w3c.dom.Element;
import org.w3c.dom.Node;
import org.xml.sax.InputSource;
import org.xml.sax.SAXException;
import org.xml.sax.helpers.DefaultHandler;

/** The ONVIF operations used before a camera has joined the home network. */
final class CameraPairingOnvif {
    static final String PATH = "/onvif/device_service";
    static final String DEVICE = "http://www.onvif.org/ver10/device/wsdl";
    static final String SCHEMA = "http://www.onvif.org/ver10/schema";
    private static final String SOAP = "http://www.w3.org/2003/05/soap-envelope";
    private static final String LEGACY_SOAP = "http://schemas.xmlsoap.org/soap/envelope/";
    private static final String WSSE = "http://docs.oasis-open.org/wss/2004/01/"
            + "oasis-200401-wss-wssecurity-secext-1.0.xsd";
    private static final String WSU = "http://docs.oasis-open.org/wss/2004/01/"
            + "oasis-200401-wss-wssecurity-utility-1.0.xsd";
    private static final String DIGEST_TYPE = "http://docs.oasis-open.org/wss/2004/01/"
            + "oasis-200401-wss-username-token-profile-1.0#PasswordDigest";
    private static final String NONCE_ENCODING = "http://docs.oasis-open.org/wss/2004/01/"
            + "oasis-200401-wss-soap-message-security-1.0#Base64Binary";
    private static final SecureRandom RANDOM = new SecureRandom();
    private static final Pattern AUTH_PARAM = Pattern.compile(
            "([\\w-]+)\\s*=\\s*(?:\"((?:[^\"\\\\]|\\\\.)*)\"|([^,\\s]+))");

    interface Transport {
        Reply post(String action, byte[] body, String authorization) throws IOException;
        default String path() { return PATH; }
    }

    record Reply(int status, List<String> challenges, byte[] body) {}
    record Device(String label, String wirelessToken, String alias) {}
    record Credentials(String user, String password) {}
    enum Outcome { ACCEPTED, REBOOT_NEEDED, UNCONFIRMED }

    static final class PairingException extends Exception {
        final String code;

        PairingException(String code) {
            super(code);
            this.code = code;
        }
    }

    private final Transport transport;
    private List<String> challenges = Collections.emptyList();
    private String digestNonce;
    private String digestClientNonce;
    private int digestNonceCount;
    private long clockOffsetSeconds;

    CameraPairingOnvif(Transport transport) {
        this.transport = transport;
    }

    CameraPairingOnvif media(Transport mediaTransport) {
        final var media = new CameraPairingOnvif(mediaTransport);
        media.clockOffsetSeconds = clockOffsetSeconds;
        return media;
    }

    /** Does not send any credentials while locating the service. */
    boolean probe() throws IOException {
        final String operation = "GetSystemDateAndTime";
        final Reply reply = transport.post(DEVICE + "/" + operation, envelope(operation, "", null), null);
        final Element body = soapPayload(reply);
        if (reply.status() == 200 && matches(body, DEVICE, operation + "Response")) {
            clockOffsetSeconds = cameraClockOffset(body);
            return true;
        }
        if (reply.status() == 401 && !reply.challenges().isEmpty()) {
            challenges = reply.challenges();
            return true;
        }
        return isAuthFault(body);
    }

    Device inspect(Credentials credentials) throws IOException, PairingException {
        final Element info = request("GetDeviceInformation", "", credentials, true);
        final Element interfaces = request("GetNetworkInterfaces", "", credentials, true);
        Element wireless = null;
        for (Node node = interfaces.getFirstChild(); node != null; node = node.getNextSibling()) {
            if (!(node instanceof Element iface) || !matches(iface, DEVICE, "NetworkInterfaces")) {
                continue;
            }
            final String token = iface.getAttribute("token");
            final Element extension = child(iface, SCHEMA, "Extension");
            final String type = value(child(extension, SCHEMA, "InterfaceType"));
            final Element dot11 = child(extension, SCHEMA, "Dot11");
            // Explicit wired interface type always wins over inconsistent extensions.
            if (token.trim().isEmpty() || !(type.equals("71") || (type.isEmpty() && dot11 != null))) {
                continue;
            }
            if (wireless != null) {
                throw new PairingException("ambiguousWifi");
            }
            wireless = iface;
        }
        if (wireless == null) {
            throw new PairingException("noOnvifWifi");
        }
        final Element extension = child(wireless, SCHEMA, "Extension");
        final Element dot11 = child(extension, SCHEMA, "Dot11");
        if (extension != null && extension.getElementsByTagNameNS(SCHEMA, "Dot11").getLength() > 1) {
            throw new PairingException("ambiguousWifi");
        }
        final String alias = value(child(dot11, SCHEMA, "Alias"));
        final String label = (value(child(info, DEVICE, "Manufacturer")) + " "
                + value(child(info, DEVICE, "Model"))).trim();
        return new Device(label.isEmpty() ? "Kamera ONVIF" : label.substring(0, Math.min(100, label.length())),
                wireless.getAttribute("token"), alias.isEmpty() ? "SafeHood" : alias);
    }

    Outcome configure(Device device, Credentials credentials, String ssid, String secret)
            throws PairingException {
        final String config = configuration(device, ssid, secret);
        try {
            final Element result = request("SetNetworkInterfaces", config, credentials, false);
            final String reboot = value(child(result, DEVICE, "RebootNeeded"));
            return switch (reboot) {
                case "true", "1" -> Outcome.REBOOT_NEEDED;
                case "false", "0" -> Outcome.ACCEPTED;
                default -> Outcome.UNCONFIRMED;
            };
        } catch (IOException disconnected) {
            // The AP can disappear as soon as the camera applies the new network.
            // Never replay a write when its outcome is unknown.
            return Outcome.UNCONFIRMED;
        }
    }

    Outcome reboot(Credentials credentials) throws PairingException {
        try {
            request("SystemReboot", "", credentials, false);
            return Outcome.ACCEPTED;
        } catch (IOException disconnected) {
            return Outcome.UNCONFIRMED;
        }
    }

    static boolean validWpaSecret(String secret) {
        return secret.matches("[ -~]{8,63}") || secret.matches("[0-9A-Fa-f]{64}");
    }

    static String configuration(Device device, String ssid, String secret) throws PairingException {
        final byte[] ssidBytes = ssid.getBytes(StandardCharsets.UTF_8);
        if (ssid.trim().isEmpty() || ssidBytes.length > 32 || !validWpaSecret(secret)) {
            throw new PairingException("invalidHomeWifi");
        }
        final String psk = secret.length() == 64 ? "Key" : "Passphrase";
        return "<tds:InterfaceToken>" + xml(device.wirelessToken()) + "</tds:InterfaceToken>"
                + "<tds:NetworkInterface><tt:Enabled>true</tt:Enabled>"
                + "<tt:IPv4><tt:Enabled>true</tt:Enabled><tt:DHCP>true</tt:DHCP></tt:IPv4>"
                + "<tt:Extension><tt:Dot11><tt:SSID>" + hex(ssidBytes) + "</tt:SSID>"
                + "<tt:Mode>Infrastructure</tt:Mode><tt:Alias>" + xml(device.alias()) + "</tt:Alias>"
                + "<tt:Priority>1</tt:Priority><tt:Security><tt:Mode>PSK</tt:Mode>"
                + "<tt:Algorithm>CCMP</tt:Algorithm><tt:PSK><tt:" + psk + ">"
                + xml(secret) + "</tt:" + psk + "></tt:PSK></tt:Security>"
                + "</tt:Dot11></tt:Extension></tds:NetworkInterface>";
    }

    private Element request(String operation, String content, Credentials credentials, boolean read)
            throws IOException, PairingException {
        return request(DEVICE, operation, content, credentials, read);
    }

    Element request(String namespace, String operation, String content, Credentials credentials, boolean read)
            throws IOException, PairingException {
        final String action = namespace + "/" + operation;
        Reply reply = transport.post(action, envelope(namespace, operation, content, credentials),
                authorization(credentials));
        if (read && reply.status() == 401 && !credentials.user().isEmpty()
                && !reply.challenges().isEmpty()) {
            challenges = reply.challenges();
            reply = transport.post(action, envelope(namespace, operation, content, credentials),
                    authorization(credentials));
        }
        final Element payload = soapPayload(reply);
        if (reply.status() == 401 || reply.status() == 403 || isAuthFault(payload)) {
            throw new PairingException("cameraAuth");
        }
        if (reply.status() != 200 || !matches(payload, namespace, operation + "Response")) {
            throw new PairingException(read ? "onvifRead" : "onvifWrite");
        }
        return payload;
    }

    private byte[] envelope(String operation, String content, Credentials credentials) {
        return envelope(DEVICE, operation, content, credentials);
    }

    private byte[] envelope(String namespace, String operation, String content, Credentials credentials) {
        String security = "";
        if (credentials != null && !credentials.user().isEmpty()) {
            final byte[] nonce = randomBytes(16);
            final String created = Instant.ofEpochSecond(
                    Instant.now().getEpochSecond() + clockOffsetSeconds).toString();
            final MessageDigest hash = hash("SHA-1");
            hash.update(nonce);
            hash.update(created.getBytes(StandardCharsets.UTF_8));
            final String digest = b64(hash.digest(credentials.password().getBytes(StandardCharsets.UTF_8)));
            security = "<s:Header><wsse:Security xmlns:wsse=\"" + WSSE + "\" xmlns:wsu=\"" + WSU
                    + "\"><wsse:UsernameToken><wsse:Username>" + xml(credentials.user())
                    + "</wsse:Username><wsse:Password Type=\"" + DIGEST_TYPE + "\">" + digest
                    + "</wsse:Password><wsse:Nonce EncodingType=\"" + NONCE_ENCODING + "\">"
                    + b64(nonce) + "</wsse:Nonce>"
                    + "<wsu:Created>" + created + "</wsu:Created></wsse:UsernameToken>"
                    + "</wsse:Security></s:Header>";
        }
        return ("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
                + "<s:Envelope xmlns:s=\"" + SOAP + "\" xmlns:tds=\"" + namespace
                + "\" xmlns:tt=\"" + SCHEMA + "\">" + security + "<s:Body>"
                + "<tds:" + operation + ">" + content + "</tds:" + operation
                + "></s:Body></s:Envelope>").getBytes(StandardCharsets.UTF_8);
    }

    private String authorization(Credentials credentials) throws PairingException {
        if (credentials.user().isEmpty() || challenges.isEmpty()) {
            return null;
        }
        boolean basic = false;
        for (String challenge : challenges) {
            if (challenge.regionMatches(true, 0, "Basic ", 0, 6)) {
                basic = true;
            } else if (challenge.regionMatches(true, 0, "Digest ", 0, 7)) {
                final String digest = digestAuthorization(challenge.substring(7), credentials);
                if (digest != null) {
                    return digest;
                }
            }
        }
        if (basic) {
            return "Basic " + b64((credentials.user() + ":" + credentials.password())
                    .getBytes(StandardCharsets.UTF_8));
        }
        throw new PairingException("cameraAuth");
    }

    private String digestAuthorization(String challenge, Credentials credentials) {
        final Map<String, String> fields = new HashMap<>();
        final Matcher matcher = AUTH_PARAM.matcher(challenge);
        while (matcher.find()) {
            fields.put(matcher.group(1).toLowerCase(Locale.ROOT), matcher.group(2) == null
                    ? matcher.group(3) : matcher.group(2).replaceAll("\\\\(.)", "$1"));
        }
        final String algorithm = fields.getOrDefault("algorithm", "MD5").toUpperCase(Locale.ROOT);
        final String realm = fields.get("realm");
        final String nonce = fields.get("nonce");
        if (!(algorithm.equals("MD5") || algorithm.equals("SHA-256"))
                || realm == null || nonce == null || nonce.isEmpty()
                || "true".equalsIgnoreCase(fields.get("userhash"))) {
            return null;
        }
        final String qop = fields.get("qop");
        if (qop != null && !Arrays.asList(qop.toLowerCase(Locale.ROOT).split("\\s*,\\s*")).contains("auth")) {
            return null;
        }
        if (!nonce.equals(digestNonce)) {
            digestNonce = nonce;
            digestClientNonce = hex(randomBytes(16));
            digestNonceCount = 0;
        }
        final String nc = String.format(Locale.ROOT, "%08x", ++digestNonceCount);
        final String cnonce = digestClientNonce;
        final String ha1 = digest(algorithm, credentials.user() + ":" + realm + ":" + credentials.password());
        final String ha2 = digest(algorithm, "POST:" + transport.path());
        final String response = digest(algorithm, ha1 + ":" + nonce
                + (qop == null ? ":" : ":" + nc + ":" + cnonce + ":auth:") + ha2);
        final String opaque = fields.get("opaque");
        return "Digest username=\"" + headerQuote(credentials.user()) + "\", realm=\"" + headerQuote(realm)
                + "\", nonce=\"" + headerQuote(nonce) + "\", uri=\"" + transport.path() + "\", algorithm=" + algorithm
                + ", response=\"" + response + "\""
                + (qop == null ? "" : ", qop=auth, nc=" + nc + ", cnonce=\"" + cnonce + "\"")
                + (opaque == null ? "" : ", opaque=\"" + headerQuote(opaque) + "\"");
    }

    private static Element soapPayload(Reply reply) {
        final String xml = new String(reply.body(), StandardCharsets.UTF_8);
        // Camera data is untrusted. No DTDs, entities or other external resources.
        if (xml.trim().isEmpty() || xml.contains("<!DOCTYPE") || xml.contains("<!ENTITY")) {
            return null;
        }
        try {
            final DocumentBuilderFactory factory = DocumentBuilderFactory.newInstance();
            factory.setNamespaceAware(true);
            factory.setExpandEntityReferences(false);
            final var builder = factory.newDocumentBuilder();
            builder.setEntityResolver((publicId, systemId) -> {
                throw new SAXException("External entity not allowed");
            });
            builder.setErrorHandler(new DefaultHandler());
            final Element envelope = builder.parse(new InputSource(new StringReader(xml))).getDocumentElement();
            final String namespace = envelope.getNamespaceURI();
            if (!matches(envelope, SOAP, "Envelope") && !matches(envelope, LEGACY_SOAP, "Envelope")) {
                return null;
            }
            final Element body = child(envelope, namespace, "Body");
            if (body != null) {
                for (Node node = body.getFirstChild(); node != null; node = node.getNextSibling()) {
                    if (node instanceof Element element) {
                        return element;
                    }
                }
            }
        } catch (Exception invalid) {
            return null;
        }
        return null;
    }

    private static long cameraClockOffset(Element response) {
        try {
            final Element utc = child(child(response, DEVICE, "SystemDateAndTime"), SCHEMA, "UTCDateTime");
            final Element date = child(utc, SCHEMA, "Date");
            final Element time = child(utc, SCHEMA, "Time");
            final long camera = LocalDateTime.of(number(date, "Year"), number(date, "Month"),
                    number(date, "Day"), number(time, "Hour"), number(time, "Minute"),
                    number(time, "Second")).toEpochSecond(ZoneOffset.UTC);
            return camera - Instant.now().getEpochSecond();
        } catch (RuntimeException invalidClock) {
            return 0;
        }
    }

    private static int number(Element parent, String name) {
        return Integer.parseInt(value(child(parent, SCHEMA, name)));
    }

    private static boolean isAuthFault(Element payload) {
        return (matches(payload, SOAP, "Fault") || matches(payload, LEGACY_SOAP, "Fault"))
                && value(payload).contains("NotAuthorized");
    }

    private static boolean matches(Element element, String ns, String name) {
        return element != null && name.equals(element.getLocalName()) && ns.equals(element.getNamespaceURI());
    }

    private static Element child(Element parent, String ns, String name) {
        if (parent != null) {
            for (Node node = parent.getFirstChild(); node != null; node = node.getNextSibling()) {
                if (node instanceof Element element && matches(element, ns, name)) {
                    return element;
                }
            }
        }
        return null;
    }

    private static String value(Element element) {
        return element == null ? "" : element.getTextContent().trim();
    }

    private static byte[] randomBytes(int length) {
        final byte[] bytes = new byte[length];
        RANDOM.nextBytes(bytes);
        return bytes;
    }

    private static String digest(String algorithm, String text) {
        return hex(hash(algorithm).digest(text.getBytes(StandardCharsets.UTF_8)));
    }

    private static MessageDigest hash(String algorithm) {
        try {
            return MessageDigest.getInstance(algorithm);
        } catch (java.security.NoSuchAlgorithmException impossible) {
            throw new IllegalStateException(impossible);
        }
    }

    private static String hex(byte[] bytes) {
        final StringBuilder text = new StringBuilder(bytes.length * 2);
        for (byte item : bytes) {
            text.append(Character.forDigit((item & 255) >>> 4, 16));
            text.append(Character.forDigit(item & 15, 16));
        }
        return text.toString();
    }

    private static String b64(byte[] bytes) {
        return Base64.getEncoder().encodeToString(bytes);
    }

    private static String headerQuote(String value) {
        return value.replace("\\", "\\\\").replace("\"", "\\\"")
                .replace("\r", "").replace("\n", "");
    }

    static String xml(String value) {
        return value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
                .replace("\"", "&quot;").replace("'", "&apos;");
    }
}
