package com.safehood.securityapp;

// Protocol adapted from cmolson/reolink-provisioning (MIT); see docs/third_party.

import java.io.IOException;
import java.math.BigInteger;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.security.AlgorithmParameters;
import java.security.GeneralSecurityException;
import java.security.KeyFactory;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.MessageDigest;
import java.security.interfaces.ECPublicKey;
import java.security.spec.ECGenParameterSpec;
import java.security.spec.ECParameterSpec;
import java.security.spec.ECPoint;
import java.security.spec.ECPublicKeySpec;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.List;
import javax.crypto.Cipher;
import javax.crypto.KeyAgreement;
import javax.crypto.Mac;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.SecretKeySpec;

final class ReolinkBleWire {
    static final int MAX_FRAME = 2048;
    static final int WIFI = 100001;
    private static final String CURVE = "secp256r1";

    private ReolinkBleWire() { }

    static String advertisedName(String uid) throws GeneralSecurityException {
        if (!uid.matches("[A-Z0-9]{16}")) throw new IllegalArgumentException();
        final byte[] hash = MessageDigest.getInstance("SHA-256").digest(utf8(uid));
        return "Reolink_" + Base64.getEncoder().encodeToString(hash).substring(0, 16);
    }

    static byte[] utf8(String text) {
        return text.getBytes(StandardCharsets.UTF_8);
    }

    static ByteBuffer little(int size) {
        return ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN);
    }

    static byte[] intLe(int value) {
        return little(4).putInt(value).array();
    }

    static byte[] tlv(int type, byte[] value) {
        return little(8 + value.length).putInt(type).putInt(value.length).put(value).array();
    }

    static final class Tlv {
        final int type;
        final byte[] value;

        Tlv(int type, byte[] value) {
            this.type = type;
            this.value = value;
        }
    }

    static List<Tlv> tlvs(byte[] message) throws IOException {
        if (message.length > MAX_FRAME) throw new IOException("BLE message too large");
        final var bytes = ByteBuffer.wrap(message).order(ByteOrder.LITTLE_ENDIAN);
        final var result = new ArrayList<Tlv>();
        while (bytes.hasRemaining()) {
            if (bytes.remaining() < 8 || result.size() >= 16) {
                throw new IOException("Invalid BLE message");
            }
            final int type = bytes.getInt();
            final int count = bytes.getInt();
            if (count < 0 || count > bytes.remaining()) throw new IOException("Invalid TLV size");
            final byte[] value = new byte[count];
            bytes.get(value);
            result.add(new Tlv(type, value));
        }
        return result;
    }

    static byte[] frame(byte[] message) {
        if (message.length < 1 || message.length > MAX_FRAME) {
            throw new IllegalArgumentException("BLE frame size");
        }
        return little(4 + message.length).putInt(message.length).put(message).array();
    }

    static final class Frames {
        private final ByteBuffer length = little(4);
        private ByteBuffer payload;

        List<byte[]> push(byte[] chunk) throws IOException {
            final var result = new ArrayList<byte[]>();
            for (byte value : chunk) {
                if (payload == null) {
                    length.put(value);
                    if (!length.hasRemaining()) {
                        final int size = length.getInt(0);
                        length.clear();
                        if (size < 1 || size > MAX_FRAME) throw new IOException("Invalid BLE frame");
                        payload = ByteBuffer.allocate(size);
                    }
                } else {
                    payload.put(value);
                    if (!payload.hasRemaining()) {
                        result.add(payload.array());
                        payload = null;
                    }
                }
            }
            return result;
        }
    }

    static KeyPair generateKey() throws GeneralSecurityException {
        final var generator = KeyPairGenerator.getInstance("EC");
        generator.initialize(new ECGenParameterSpec(CURVE));
        return generator.generateKeyPair();
    }

    static byte[] publicKey(KeyPair pair) {
        final var key = (ECPublicKey) pair.getPublic();
        final byte[] encoded = new byte[65];
        encoded[0] = 4;
        coordinate(key.getW().getAffineX(), encoded, 1);
        coordinate(key.getW().getAffineY(), encoded, 33);
        return encoded;
    }

    private static void coordinate(BigInteger value, byte[] result, int offset) {
        final byte[] src = value.toByteArray();
        final int count = Math.min(src.length, 32);
        System.arraycopy(src, src.length - count, result, offset + 32 - count, count);
    }

    static byte[] shared(KeyPair pair, byte[] peer) throws GeneralSecurityException {
        if (peer.length != 65 || peer[0] != 4) throw new GeneralSecurityException("BLE key format");
        final var parameters = AlgorithmParameters.getInstance("EC");
        parameters.init(new ECGenParameterSpec(CURVE));
        final var point = new ECPoint(
                new BigInteger(1, Arrays.copyOfRange(peer, 1, 33)),
                new BigInteger(1, Arrays.copyOfRange(peer, 33, 65)));
        final var publicKey = KeyFactory.getInstance("EC").generatePublic(
                new ECPublicKeySpec(point, parameters.getParameterSpec(ECParameterSpec.class)));
        final var agreement = KeyAgreement.getInstance("ECDH");
        agreement.init(pair.getPrivate());
        agreement.doPhase(publicKey, true);
        return agreement.generateSecret();
    }

    /** A single PBKDF2 block: password is binary, salt is the ECDH shared secret. */
    static byte[] derive(byte[] firstRandom, byte[] secondRandom, byte[] secret)
            throws GeneralSecurityException {
        if (firstRandom.length != 64 || secondRandom.length != 64 || secret.length != 32) {
            throw new GeneralSecurityException("BLE key lengths");
        }
        final var hmac = Mac.getInstance("HmacSHA256");
        hmac.init(new SecretKeySpec(join(firstRandom, secondRandom), "HmacSHA256"));
        hmac.update(secret);
        byte[] block = hmac.doFinal(new byte[]{0, 0, 0, 1});
        final byte[] answer = block.clone();
        for (int index = 1; index < 10_000; index++) {
            block = hmac.doFinal(block);
            for (int i = 0; i < 32; i++) answer[i] ^= block[i];
        }
        Arrays.fill(block, (byte) 0);
        return answer;
    }

    static byte[] cfb(int mode, byte[] keys, byte[] data) throws GeneralSecurityException {
        final var cipher = Cipher.getInstance("AES/CFB/NoPadding");
        cipher.init(mode, new SecretKeySpec(keys, 0, 16, "AES"), new IvParameterSpec(keys, 16, 16));
        return cipher.doFinal(data);
    }

    static byte[] join(byte[] first, byte[] second) {
        final byte[] both = Arrays.copyOf(first, first.length + second.length);
        System.arraycopy(second, 0, both, first.length, second.length);
        return both;
    }
}
