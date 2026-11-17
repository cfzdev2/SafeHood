package com.safehood.securityapp;

import android.content.Context;
import android.net.Uri;
import java.io.IOException;
import java.net.Inet4Address;
import java.net.URI;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Arrays;
import javax.net.SocketFactory;
import org.w3c.dom.Element;

/** Read-only ONVIF Media/Media2 discovery. All requests remain on the original LAN peer. */
final class LocalOnvifResolver {
    static final String MEDIA1 = "http://www.onvif.org/ver10/media/wsdl";
    static final String MEDIA2 = "http://www.onvif.org/ver20/media/wsdl";

    private interface TransportProvider {
        CameraPairingOnvif.Transport create(URI endpoint);
    }

    private record Profile(String token, int quality) { }

    private LocalOnvifResolver() { }

    static String resolve(Context context, String device, String username, String password)
            throws Exception {
        final URI endpoint = new URI(device);
        final Inet4Address address = CameraLocalNetwork.ipv4(endpoint.getHost());
        final SocketFactory sockets = CameraLocalNetwork.forHost(context, address)
                .network().getSocketFactory();
        if (!http(endpoint) || username.length() > 128 || password.length() > 128
                || username.contains(":") || username.indexOf(0) != -1 || password.indexOf(0) != -1) {
            throw new ReolinkLanWire.Failure("badRequest");
        }
        return resolve(endpoint, username, password,
                uri -> new CameraPairingHttp(sockets, address,
                        uri.getPort() == -1 ? 80 : uri.getPort(), 2500, uri.getPath()));
    }

    private static String resolve(URI endpoint, String username, String password,
            TransportProvider transports) throws Exception {
        final var login = new CameraPairingOnvif.Credentials(username, password);
        final var device = new CameraPairingOnvif(transports.create(endpoint));
        try { device.probe(); } catch (IOException ignored) {
            // Some devices expose Media without supporting the clock probe.
        }
        final var services = new LinkedHashMap<String, URI>();
        CameraPairingOnvif.PairingException lastAuth = null;
        try {
            final var list = device.request(CameraPairingOnvif.DEVICE, "GetServices",
                    "<tds:IncludeCapability>false</tds:IncludeCapability>", login, true);
            final var nodes = list.getElementsByTagNameNS(CameraPairingOnvif.DEVICE, "Service");
            for (int i = 0; i < nodes.getLength() && i < 64; i++) {
                if (!(nodes.item(i) instanceof Element service)) continue;
                final String ns = value(service, CameraPairingOnvif.DEVICE, "Namespace");
                if (MEDIA1.equals(ns) || MEDIA2.equals(ns)) {
                    final URI uri = sameHostHttp(endpoint, value(service, CameraPairingOnvif.DEVICE, "XAddr"));
                    if (uri != null) services.putIfAbsent(ns, uri);
                }
            }
        } catch (CameraPairingOnvif.PairingException unavailable) {
            if ("cameraAuth".equals(unavailable.code)) lastAuth = unavailable;
        } catch (IOException ignored) { }
        if (!services.containsKey(MEDIA1)) {
            try {
                final var result = device.request(CameraPairingOnvif.DEVICE, "GetCapabilities",
                        "<tds:Category>Media</tds:Category>", login, true);
                final var media = result.getElementsByTagNameNS(CameraPairingOnvif.SCHEMA, "Media");
                if (media.getLength() == 1 && media.item(0) instanceof Element element) {
                    final URI uri = sameHostHttp(endpoint, value(element, CameraPairingOnvif.SCHEMA, "XAddr"));
                    if (uri != null) services.put(MEDIA1, uri);
                }
            } catch (CameraPairingOnvif.PairingException unavailable) {
                if ("cameraAuth".equals(unavailable.code)) lastAuth = unavailable;
            } catch (IOException ignored) { }
        }
        for (var entry : services.entrySet()) {
            final String ns = entry.getKey();
            final var media = device.media(transports.create(entry.getValue()));
            try {
                final var profiles = profiles(media.request(ns, "GetProfiles",
                        MEDIA2.equals(ns) ? "<tds:Type>VideoEncoder</tds:Type>" : "", login, true), ns);
                for (var profile : profiles) {
                    final String token = CameraPairingOnvif.xml(profile.token);
                    final List<String> protocols = MEDIA2.equals(ns)
                            ? Arrays.asList("RTSP", "RtspUnicast") : Arrays.asList("RTSP", "UDP", "TCP");
                    for (String protocol : protocols) {
                        final String query = MEDIA2.equals(ns)
                                ? "<tds:Protocol>" + protocol + "</tds:Protocol>"
                                : "<tds:StreamSetup><tt:Stream>RTP-Unicast</tt:Stream>"
                                    + "<tt:Transport><tt:Protocol>" + protocol
                                    + "</tt:Protocol></tt:Transport></tds:StreamSetup>";
                        try {
                            final var response = media.request(ns, "GetStreamUri", query
                                    + "<tds:ProfileToken>" + token + "</tds:ProfileToken>", login, true);
                            final var uri = response.getElementsByTagNameNS("*", "Uri");
                            if (uri.getLength() != 1) continue;
                            final String stream = onPeer(endpoint, uri.item(0).getTextContent().trim(),
                                    username, password);
                            if (stream != null) return stream;
                        } catch (CameraPairingOnvif.PairingException unavailable) {
                            if ("cameraAuth".equals(unavailable.code)) throw unavailable;
                        }
                    }
                }
            } catch (CameraPairingOnvif.PairingException unavailable) {
                if ("cameraAuth".equals(unavailable.code)) lastAuth = unavailable;
            } catch (IOException ignored) { }
        }
        throw new ReolinkLanWire.Failure(lastAuth == null ? "noOnvifStream" : "cameraAuth");
    }

    private static List<Profile> profiles(Element reply, String namespace) {
        final var list = reply.getElementsByTagNameNS(namespace, "Profiles");
        final var result = new ArrayList<Profile>();
        for (int i = 0; i < list.getLength() && i < 16; i++) {
            if (!(list.item(i) instanceof Element profile)) continue;
            final String token = profile.getAttribute("token");
            final String encoding = value(profile, CameraPairingOnvif.SCHEMA, "Encoding");
            if (token.isEmpty() || token.length() > 128) continue;
            result.add(new Profile(token, "H264".equalsIgnoreCase(encoding) ? 0
                    : encoding == null ? 1 : 2));
        }
        result.sort(java.util.Comparator.comparingInt(Profile::quality));
        return result.subList(0, Math.min(result.size(), 3));
    }

    private static boolean http(URI uri) {
        return "http".equals(uri.getScheme()) && uri.getHost() != null && uri.getRawUserInfo() == null
                && uri.getRawFragment() == null && uri.getRawQuery() == null
                && uri.getPort() != 0 && uri.getPort() <= 65535 && uri.getPath() != null
                && uri.getPath().matches("/[A-Za-z0-9._/-]{1,255}") && !uri.getPath().contains("..");
    }

    private static URI sameHostHttp(URI original, String text) {
        if (text == null) return null;
        try {
            final URI address = original.resolve(text);
            // Firmware sometimes advertises 0.0.0.0 or a factory hostname.
            // Reuse the discovered peer; never contact the advertised host.
            final URI pinned = new URI(address.getScheme(), null, original.getHost(),
                    address.getPort(), address.getPath(), address.getQuery(), address.getFragment());
            return address.getRawUserInfo() == null && http(pinned) ? pinned : null;
        } catch (Exception invalid) {
            return null;
        }
    }

    private static String onPeer(URI endpoint, String text, String username, String password) {
        try {
            if (text.length() > 2048) return null;
            final URI reply = new URI(text);
            if (!"rtsp".equals(reply.getScheme()) || reply.getHost() == null
                    || reply.getRawFragment() != null || reply.getPort() > 65535 || reply.getPort() == 0) {
                return null;
            }
            return "rtsp://" + (username.isEmpty() ? "" : Uri.encode(username) + ":"
                    + Uri.encode(password) + "@") + endpoint.getHost()
                    + (reply.getPort() == -1 ? "" : ":" + reply.getPort())
                    + (reply.getRawPath() == null ? "" : reply.getRawPath())
                    + (reply.getRawQuery() == null ? "" : "?" + reply.getRawQuery());
        } catch (Exception invalid) {
            return null;
        }
    }

    private static String value(Element parent, String namespace, String tag) {
        final var nodes = parent.getElementsByTagNameNS(namespace, tag);
        return nodes.getLength() == 1 ? nodes.item(0).getTextContent().trim() : null;
    }
}
