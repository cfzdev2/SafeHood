package com.safehood.securityapp;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.UnknownHostException;
import java.util.ArrayList;
import java.util.List;

final class CameraLocalNetwork {
    record Link(Network network, Inet4Address address, int prefixLength) {
        boolean contains(Inet4Address destination) {
            final int mask = -1 << (32 - prefixLength);
            final int host = bits(destination);
            final int local = bits(address);
            return host != local && (host & mask) == (local & mask)
                    && host != (local & mask) && host != ((local & mask) | ~mask);
        }

        Inet4Address broadcast() throws UnknownHostException {
            final int mask = -1 << (32 - prefixLength);
            final int value = (bits(address) & mask) | ~mask;
            return (Inet4Address) InetAddress.getByAddress(new byte[]{
                (byte) (value >>> 24), (byte) (value >>> 16), (byte) (value >>> 8), (byte) value
            });
        }
    }

    private CameraLocalNetwork() { }

    @SuppressWarnings("deprecation")
    static List<Link> links(Context context) {
        final var manager = context.getSystemService(ConnectivityManager.class);
        final var links = new ArrayList<Link>();
        // This includes Wi-Fi without Internet validation (cell data can remain the default).
        for (Network network : manager.getAllNetworks()) {
            final var caps = manager.getNetworkCapabilities(network);
            final var info = manager.getLinkProperties(network);
            if (info == null || caps == null || !caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
                    || caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) continue;
            for (var address : info.getLinkAddresses()) {
                if (address.getPrefixLength() >= 8 && address.getPrefixLength() <= 30
                        && address.getAddress() instanceof Inet4Address ipv4 && privateIp(ipv4)) {
                    links.add(new Link(network, ipv4, address.getPrefixLength()));
                }
            }
        }
        return links;
    }

    static Link forHost(Context context, Inet4Address host) throws ReolinkLanWire.Failure {
        Link selected = null;
        for (Link link : links(context)) {
            if (!link.contains(host)) continue;
            if (selected != null && !selected.network.equals(link.network)) {
                throw new ReolinkLanWire.Failure("notLocalNetwork");
            }
            selected = link;
        }
        if (selected == null) throw new ReolinkLanWire.Failure("notLocalNetwork");
        return selected;
    }

    static boolean isDefault(Context context, Link link) {
        final var manager = context.getSystemService(ConnectivityManager.class);
        return link.network.equals(manager.getActiveNetwork());
    }

    static Inet4Address ipv4(String host) throws UnknownHostException {
        if (host == null || !host.matches("(0|[1-9][0-9]{0,2})(\\.(0|[1-9][0-9]{0,2})){3}")) {
            throw new UnknownHostException("Expected local IPv4");
        }
        final String[] parts = host.split("\\.");
        final byte[] address = new byte[4];
        for (int i = 0; i < 4; i++) {
            final int value = Integer.parseInt(parts[i]);
            if (value > 255) throw new UnknownHostException("Invalid IPv4");
            address[i] = (byte) value;
        }
        final var result = (Inet4Address) InetAddress.getByAddress(address);
        if (!privateIp(result)) throw new UnknownHostException("Expected local IPv4");
        return result;
    }

    static boolean privateIp(Inet4Address address) {
        final byte[] bytes = address.getAddress();
        final int a = bytes[0] & 255;
        final int b = bytes[1] & 255;
        return a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168);
    }

    private static int bits(Inet4Address address) {
        return java.nio.ByteBuffer.wrap(address.getAddress()).getInt();
    }
}
