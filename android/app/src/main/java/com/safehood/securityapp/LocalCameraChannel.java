package com.safehood.securityapp;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.AtomicFile;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.net.URI;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.Executors;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import org.json.JSONArray;
import org.json.JSONObject;

/** Device-only catalog; keys live in Keystore and the encrypted file is outside backups. */
public final class LocalCameraChannel implements AutoCloseable {
    private static final String ALIAS = "safehood.local.camera.catalog.v1";
    private static final int LIMIT = 64;
    private static final int FILE_LIMIT = 384 * 1024;
    private final MethodChannel channel;
    private final Context context;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final java.util.concurrent.ExecutorService worker = Executors.newSingleThreadExecutor();

    public LocalCameraChannel(Context context, BinaryMessenger messenger) {
        this.context = context.getApplicationContext();
        channel = new MethodChannel(messenger, "safehood/local_camera_store");
        channel.setMethodCallHandler(this::handle);
    }

    private void handle(MethodCall call, MethodChannel.Result reply) {
        if (!call.method.equals("list") && !call.method.equals("save") && !call.method.equals("delete")) {
            reply.notImplemented();
            return;
        }
        worker.execute(() -> {
            try {
                final String scope = call.argument("scope");
                if (scope == null || !scope.matches("[A-Za-z0-9_-]{1,128}")) {
                    throw new IOException("Invalid scope");
                }
                final Object result = catalog(call, scope);
                main.post(() -> reply.success(result));
            } catch (Exception error) {
                main.post(() -> reply.error("localStorage", null, null));
            }
        });
    }

    private Object catalog(MethodCall call, String scope) throws Exception {
        final var file = new AtomicFile(new File(context.getNoBackupFilesDir(),
                "camera-catalog-" + scope + ".bin"));
        final JSONArray database = read(file, scope);
        if (call.method.equals("list")) {
            final var rows = new ArrayList<Map<String, String>>();
            for (int i = 0; i < database.length(); i++) rows.add(row(database.getJSONObject(i)));
            return rows;
        }
        final String id = call.argument("id");
        if (id != null && !UUID.fromString(id).toString().equals(id)) {
            throw new IOException("Invalid ID");
        }
        int index = -1;
        for (int i = 0; i < database.length(); i++) {
            if (database.getJSONObject(i).getString("id").equals(id)) index = i;
        }
        if (call.method.equals("delete")) {
            if (index < 0) return null;
            database.remove(index);
        } else {
            if (id != null && index < 0) throw new IOException("Unknown camera");
            if (index < 0 && database.length() >= LIMIT) throw new IOException("Camera limit");
            final Map<?, ?> map = call.argument("source");
            final String uri = (String) map.get("uri");
            localUri(uri);
            final String name = (String) map.get("name");
            if (name == null || name.trim().isEmpty() || name.length() > 80) {
                throw new IOException("Invalid name");
            }
            final String uid = (String) map.get("reolinkUid");
            if (uid != null && !uid.matches("[A-Z0-9]{16}")) throw new IOException("Invalid UID");
            final var item = new JSONObject()
                    .put("id", id == null ? UUID.randomUUID().toString() : id)
                    .put("name", name).put("uri", uri).put("reolinkUid", uid);
            if (index >= 0) database.put(index, item);
            else database.put(item);
        }
        write(file, scope, database);
        return null;
    }

    static URI localUri(String input) throws Exception {
        if (input == null || input.length() > 2048) throw new IOException("Invalid RTSP URL");
        final var uri = new URI(input);
        if (!"rtsp".equals(uri.getScheme()) || uri.getRawFragment() != null
                || uri.getPort() == 0 || uri.getPort() > 65535) throw new IOException("Invalid RTSP URL");
        CameraLocalNetwork.ipv4(uri.getHost());
        return uri;
    }

    private static Map<String, String> row(JSONObject object) throws Exception {
        final var item = new HashMap<String, String>();
        for (String key : new String[]{"id", "name", "uri", "reolinkUid"}) {
            if (!object.isNull(key)) item.put(key, object.getString(key));
        }
        return item;
    }

    private static JSONArray read(AtomicFile file, String scope) throws Exception {
        final byte[] bytes;
        try {
            bytes = file.readFully();
        } catch (FileNotFoundException missing) {
            if (file.getBaseFile().exists()) throw missing;
            return new JSONArray();
        }
        if (bytes.length < 30 || bytes.length > FILE_LIMIT || bytes[0] != 1) {
            throw new IOException("Invalid camera catalog");
        }
        final var cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE, key(false), new GCMParameterSpec(128, bytes, 1, 12));
        cipher.updateAAD(aad(scope));
        return new JSONArray(new String(cipher.doFinal(bytes, 13, bytes.length - 13), StandardCharsets.UTF_8));
    }

    private static void write(AtomicFile file, String scope, JSONArray database) throws Exception {
        final var cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, key(true));
        cipher.updateAAD(aad(scope));
        final byte[] iv = cipher.getIV();
        final byte[] data = cipher.doFinal(database.toString().getBytes(StandardCharsets.UTF_8));
        if (iv.length != 12 || data.length + 13 > FILE_LIMIT) {
            throw new IOException("Camera catalog limit");
        }
        final var out = file.startWrite();
        try {
            out.write(ByteBuffer.allocate(13 + data.length).put((byte) 1).put(iv).put(data).array());
            file.finishWrite(out);
        } catch (Exception error) {
            file.failWrite(out);
            throw error;
        }
    }

    private static byte[] aad(String scope) {
        return (ALIAS + ":" + scope).getBytes(StandardCharsets.UTF_8);
    }

    private static SecretKey key(boolean create) throws Exception {
        final var keys = KeyStore.getInstance("AndroidKeyStore");
        keys.load(null);
        final var stored = keys.getKey(ALIAS, null);
        if (stored instanceof SecretKey secret) return secret;
        if (!create) throw new IOException("Missing camera key");
        final var generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
        generator.init(new KeyGenParameterSpec.Builder(ALIAS,
                KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setKeySize(256)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());
        return generator.generateKey();
    }

    @Override public void close() {
        channel.setMethodCallHandler(null);
        worker.shutdown();
    }
}
