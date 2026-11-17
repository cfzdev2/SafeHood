package com.safehood.securityapp;

import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.net.Inet4Address;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import javax.net.SocketFactory;

/** Fixed endpoint SOAP over an explicitly selected, local-only Wi-Fi network. */
final class CameraPairingHttp implements CameraPairingOnvif.Transport {
    private static final int MAX_BODY = 128 * 1024;
    private static final int MAX_HEADER = 16 * 1024;
    private final SocketFactory sockets;
    private final Inet4Address host;
    private final int port;
    private final int timeoutMs;
    private final String path;

    CameraPairingHttp(SocketFactory sockets, Inet4Address host, int port, int timeoutMs) {
        this(sockets, host, port, timeoutMs, CameraPairingOnvif.PATH);
    }

    CameraPairingHttp(SocketFactory sockets, Inet4Address host, int port, int timeoutMs, String path) {
        if (!path.matches("/[A-Za-z0-9._/-]{1,255}") || path.contains("..")) {
            throw new IllegalArgumentException("ONVIF path");
        }
        this.sockets = sockets;
        this.host = host;
        this.port = port;
        this.timeoutMs = timeoutMs;
        this.path = path;
    }

    @Override
    public String path() {
        return path;
    }

    @Override
    public CameraPairingOnvif.Reply post(String action, byte[] body, String authorization)
            throws IOException {
        return post(path, "application/soap+xml; charset=utf-8; action=\""
                + action + "\"", body, authorization);
    }

    byte[] postJson(String endpoint, byte[] body) throws IOException {
        if (!endpoint.matches("/cgi-bin/api\\.cgi\\?cmd=[A-Za-z]+&token=[A-Za-z0-9_-]{1,128}")) {
            throw new IOException("Invalid camera CGI endpoint");
        }
        final var reply = post(endpoint, "application/json; charset=utf-8", body, null);
        if (reply.status() != 200) throw new IOException("Camera HTTP error");
        return reply.body();
    }

    private CameraPairingOnvif.Reply post(
            String path, String contentType, byte[] body, String authorization) throws IOException {
        final long deadline = System.nanoTime() + timeoutMs * 1_000_000L;
        try (Socket socket = sockets.createSocket()) {
            socket.connect(new InetSocketAddress(host, port), timeoutMs);
            final String headers = "POST " + path + " HTTP/1.0\r\n"
                    + "Host: " + host.getHostAddress() + ":" + port + "\r\n"
                    + "Content-Type: " + contentType + "\r\n"
                    + "Content-Length: " + body.length + "\r\n"
                    + "Connection: close\r\n"
                    + (authorization == null ? "" : "Authorization: " + authorization + "\r\n")
                    + "\r\n";
            final var output = socket.getOutputStream();
            output.write(headers.getBytes(StandardCharsets.UTF_8));
            output.write(body);
            output.flush();
            final Reader reader = new Reader(socket, deadline);
            final String statusLine = reader.line();
            if (!statusLine.matches("HTTP/1\\.[01] [1-5][0-9]{2}( .*)?")) {
                throw new IOException("Invalid HTTP status");
            }
            final int status = Integer.parseInt(statusLine.substring(9, 12));
            final List<String> challenges = new ArrayList<>();
            Integer length = null;
            boolean chunked = false;
            int headerBytes = statusLine.length();
            while (true) {
                final String line = reader.line();
                headerBytes += line.length() + 2;
                if (headerBytes > MAX_HEADER) {
                    throw new IOException("HTTP headers too large");
                }
                if (line.isEmpty()) {
                    break;
                }
                final int separator = line.indexOf(':');
                if (separator < 1) {
                    throw new IOException("Invalid HTTP header");
                }
                final String name = line.substring(0, separator).toLowerCase(Locale.ROOT);
                final String value = line.substring(separator + 1).trim();
                switch (name) {
                    case "content-length" -> {
                        final int candidate = size(value, 10);
                        if (length != null && length != candidate) {
                            throw new IOException("Conflicting Content-Length");
                        }
                        length = candidate;
                    }
                    case "transfer-encoding" -> {
                        if (!value.equalsIgnoreCase("chunked")) {
                            throw new IOException("Unsupported transfer encoding");
                        }
                        chunked = true;
                    }
                    case "www-authenticate" -> challenges.add(value);
                    default -> { }
                }
            }
            // Never follow redirects or forward credentials to a URI supplied by the device.
            final byte[] response;
            if (status >= 300 && status < 500 && status != 401) {
                response = new byte[0];
            } else if (chunked) {
                response = reader.chunkedBody();
            } else {
                response = reader.body(length);
            }
            return new CameraPairingOnvif.Reply(status, challenges, response);
        }
    }

    private static int size(String value, int radix) throws IOException {
        try {
            final int bytes = Integer.parseInt(value, radix);
            if (bytes >= 0 && bytes <= MAX_BODY) {
                return bytes;
            }
        } catch (NumberFormatException malformed) {
            // Report without including peer data.
        }
        throw new IOException("Invalid HTTP size");
    }

    private static final class Reader {
        private final InputStream input;
        private final long deadline;

        Reader(Socket socket, long deadline) throws IOException {
            this.deadline = deadline;
            final InputStream source = socket.getInputStream();
            input = new BufferedInputStream(new InputStream() {
                @Override
                public int read() throws IOException {
                    socket.setSoTimeout(remainingMs());
                    return source.read();
                }

                @Override
                public int read(byte[] buffer, int offset, int length) throws IOException {
                    socket.setSoTimeout(remainingMs());
                    return source.read(buffer, offset, length);
                }
            });
        }

        private int remainingMs() throws SocketTimeoutException {
            final long nanos = deadline - System.nanoTime();
            if (nanos <= 0) {
                throw new SocketTimeoutException("Camera request timeout");
            }
            return (int) Math.max(1, nanos / 1_000_000);
        }

        String line() throws IOException {
            final ByteArrayOutputStream line = new ByteArrayOutputStream();
            while (line.size() < 4096) {
                final int next = input.read();
                if (next == '\r') {
                    if (input.read() != '\n') {
                        throw new IOException("Invalid HTTP line");
                    }
                    return new String(line.toByteArray(), StandardCharsets.ISO_8859_1);
                }
                if (next < 0) {
                    throw new EOFException("Incomplete HTTP line");
                }
                if (next < 32 && next != '\t') {
                    throw new IOException("Invalid HTTP line");
                }
                line.write(next);
            }
            throw new IOException("HTTP line too large");
        }

        byte[] body(Integer length) throws IOException {
            final ByteArrayOutputStream body = new ByteArrayOutputStream();
            if (length != null) {
                copy(body, length);
            } else {
                final byte[] buffer = new byte[4096];
                for (int count; (count = input.read(buffer)) != -1;) {
                    if (count > MAX_BODY - body.size()) {
                        throw new IOException("HTTP body too large");
                    }
                    body.write(buffer, 0, count);
                }
            }
            return body.toByteArray();
        }

        byte[] chunkedBody() throws IOException {
            final ByteArrayOutputStream body = new ByteArrayOutputStream();
            for (int index = 0; index < 512; index++) {
                final int bytes = size(line().split(";", 2)[0].trim(), 16);
                if (bytes == 0) {
                    return body.toByteArray();
                }
                if (bytes > MAX_BODY - body.size()) {
                    throw new IOException("HTTP body too large");
                }
                copy(body, bytes);
                if (!line().isEmpty()) {
                    throw new IOException("Invalid chunk boundary");
                }
            }
            throw new IOException("Too many HTTP chunks");
        }

        private void copy(ByteArrayOutputStream body, int length) throws IOException {
            final byte[] buffer = new byte[4096];
            for (int remaining = length; remaining > 0;) {
                final int count = input.read(buffer, 0, Math.min(remaining, buffer.length));
                if (count < 0) {
                    throw new EOFException("Incomplete HTTP body");
                }
                body.write(buffer, 0, count);
                remaining -= count;
            }
        }
    }
}
