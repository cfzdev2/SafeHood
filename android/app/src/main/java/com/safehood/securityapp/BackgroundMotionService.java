package com.safehood.securityapp;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.net.Network;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.IBinder;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Base64;
import android.util.Log;
import android.view.Surface;
import androidx.media3.common.C;
import androidx.media3.common.MediaItem;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import androidx.media3.common.VideoSize;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.rtsp.RtspMediaSource;
import com.google.firebase.auth.FirebaseAuth;
import com.google.firebase.firestore.FirebaseFirestore;
import com.google.firebase.firestore.ListenerRegistration;
import com.google.firebase.functions.FirebaseFunctions;
import com.google.firebase.functions.HttpsCallableReference;
import io.flutter.plugins.videoplayer.CameraRtspRenderers;
import io.flutter.plugins.videoplayer.CameraStreamRecorder;
import io.flutter.plugins.videoplayer.CameraVideoBuffer;
import java.net.URI;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.TimeZone;
import java.util.concurrent.TimeUnit;

/** Monitors one opted-in local camera, including when there is no Flutter Activity. */
@UnstableApi
public final class BackgroundMotionService extends Service {
  private static final String TAG = "SafeHoodMotion";
  private static final String CHANNEL = "safehood_background_motion";
  private static final String START = "com.safehood.securityapp.MOTION_START";
  private static final String STOP = "com.safehood.securityapp.MOTION_STOP";
  private static final int NOTICE = 29106;
  private static final long[] RETRY_MS = {2000, 4000, 8000, 15000, 30000};

  // Main-thread state only. Camera credentials stay in memory, outside intents and logs.
  record Request(
      String owner,
      String camera,
      List<URI> streams,
      Network network,
      String emulatorHost,
      DvripAlarmReceiver.Credentials nativeCredentials) {}

  private static final Map<Integer, String> previews = new HashMap<>();
  private static Request pending;
  private static BackgroundMotionService current;
  private static Runnable onState;

  static void setObserver(Runnable listener) {
    onState = listener;
  }

  static Map<String, Object> status() {
    Request active = current == null ? pending : current.request;
    var state = new HashMap<String, Object>();
    state.put("phase", active == null ? "off" : current == null ? "starting" : current.phase);
    if (active != null) state.put("cameraId", active.camera());
    return state;
  }

  static void start(Context context, Request config) {
    if (pending != null || (current != null && current.request != null)) {
      throw new IllegalStateException("A camera is already monitored");
    }
    pending = config;
    try {
      Intent intent = new Intent(context, BackgroundMotionService.class).setAction(START);
      if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent);
      else context.startService(intent);
    } catch (RuntimeException error) {
      pending = null;
      throw error;
    }
    changed();
  }

  static void stop(Context context, String camera) {
    Request config = current == null ? pending : current.request;
    if (config == null || !config.camera().equals(camera)) return;
    pending = null;
    context.stopService(new Intent(context, BackgroundMotionService.class));
    changed();
  }

  static void preview(int lease, String camera) {
    String old = camera == null ? previews.remove(lease) : previews.put(lease, camera);
    if (current != null
        && current.request != null
        && (current.request.camera().equals(camera) || current.request.camera().equals(old))) {
      current.sync();
    }
  }

  static void clearPreviews() {
    if (previews.isEmpty()) return;
    previews.clear();
    if (current != null) current.sync();
  }

  private static void changed() {
    if (onState != null) onState.run();
  }

  private final Handler main = new Handler(Looper.getMainLooper());
  private final Runnable reconnect =
      () -> {
        reconnectScheduled = false;
        open();
      };
  private final Runnable watchdog = this::checkFrames;
  private final List<Attempt> attempts = new ArrayList<>();
  private Request request;
  private String phase = "starting";
  private boolean enabled;
  private boolean sending;
  private boolean uploadFailed;
  private boolean stopping;
  private boolean reconnectScheduled;
  private Attempt attempt;
  private ExoPlayer player;
  private BackgroundMotionFrames frames;
  private long openedAt;
  private long lastEventAt;
  private int nextAttempt;
  private int backoff;
  private ListenerRegistration settings;
  private FirebaseAuth.AuthStateListener authListener;
  private HttpsCallableReference ingest;
  private HttpsCallableReference clipUpload;
  private CameraVideoBuffer videoBuffer;
  private HandlerThread recordingThread;
  private BackgroundClipDelivery pendingClip;
  private DvripAlarmReceiver nativeReceiver;
  private boolean nativeAttempted;
  private boolean nativeConfirmed;
  private boolean softwareDecoder;
  private int corruptRestarts;

  private record Attempt(URI uri, boolean tcp) {}

  @Override
  public IBinder onBind(Intent intent) {
    return null;
  }

  @Override
  public int onStartCommand(Intent intent, int flags, int startId) {
    String action = intent == null ? null : intent.getAction();
    if (STOP.equals(action)) {
      finish();
    } else if (START.equals(action) && pending != null && request == null) {
      request = pending;
      pending = null;
      current = this;
      try {
        if (Build.VERSION.SDK_INT >= 29) {
          startForeground(
              NOTICE, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE);
        } else {
          startForeground(NOTICE, notification());
        }
        observeAccount();
      } catch (RuntimeException error) {
        Log.w(TAG, "Could not initialize monitoring: " + error.getClass().getSimpleName());
        finish();
      }
      changed();
    } else if (request == null) {
      finish();
    }
    return START_NOT_STICKY;
  }

  private boolean ownsCamera() {
    var user = FirebaseAuth.getInstance().getCurrentUser();
    return request != null
        && user != null
        && user.isEmailVerified()
        && request.owner().equals(user.getUid());
  }

  private void observeAccount() {
    if (!ownsCamera()) {
      finish();
      return;
    }
    var auth = FirebaseAuth.getInstance();
    authListener =
        ignored -> {
          if (!ownsCamera()) finish();
        };
    auth.addAuthStateListener(authListener);
    var functions = FirebaseFunctions.getInstance("europe-central2");
    if (request.emulatorHost() != null) functions.useEmulator(request.emulatorHost(), 5001);
    ingest = functions.getHttpsCallable("ingestCameraEvent");
    ingest.setTimeout(20, TimeUnit.SECONDS);
    clipUpload = functions.getHttpsCallable("uploadPhoneMotionClip");
    clipUpload.setTimeout(30, TimeUnit.SECONDS);

    for (URI uri : request.streams()) attempts.add(new Attempt(uri, true));
    for (URI uri : request.streams()) attempts.add(new Attempt(uri, false));
    settings =
        FirebaseFirestore.getInstance()
            .collection("users")
            .document(request.owner())
            .collection("cameras")
            .document(request.camera())
            .addSnapshotListener(
                (snapshot, error) -> {
                  if (stopping) return;
                  if (error != null) {
                    Log.w(TAG, "Could not read the camera settings: " + error.getCode());
                    finish();
                    return;
                  }
                  if (snapshot == null
                      || !snapshot.exists()
                      || !Boolean.TRUE.equals(snapshot.get("liveMotionEnabled"))
                      || Boolean.TRUE.equals(snapshot.get("deletionPending"))
                      || !("onvif".equals(snapshot.get("connectionType"))
                          || "rtsp".equals(snapshot.get("connectionType")))) {
                    finish();
                    return;
                  }
                  enabled = true;
                  sync();
                });
  }

  private boolean previewOpen() {
    return previews.containsValue(request.camera());
  }

  private void sync() {
    if (stopping || !enabled) return;
    if (previewOpen()) {
      cancelReconnect();
      closePlayback();
      closeNative();
      phase("preview");
    } else if (frames == null && !reconnectScheduled) {
      // Give the foreground decoder time to release the camera on navigation.
      scheduleReconnect("preview".equals(phase) ? 550 : 0);
    }
  }

  private void cancelReconnect() {
    main.removeCallbacks(reconnect);
    reconnectScheduled = false;
  }

  private void scheduleReconnect(long delay) {
    cancelReconnect();
    reconnectScheduled = true;
    main.postDelayed(reconnect, delay);
  }

  private void open() {
    if (stopping || !enabled || previewOpen() || frames != null) return;
    if (!ownsCamera()) {
      finish();
      return;
    }
    var wifi =
        CameraLocalNetwork.links(this).stream()
            .filter(link -> link.network().equals(request.network()))
            .findFirst()
            .orElse(null);
    if (wifi == null) {
      // Do not try the saved credentials on another Wi-Fi with the same private subnet.
      phase("wifiLost");
      scheduleReconnect(30_000);
      return;
    }
    startNative();
    URI uri = null;
    while (nextAttempt < attempts.size()) {
      attempt = attempts.get(nextAttempt++);
      if (attempt.tcp() || CameraLocalNetwork.isDefault(this, wifi)) {
        uri = attempt.uri();
        break;
      }
    }
    if (uri == null) {
      nextAttempt = 0;
      retry();
      return;
    }
    phase("starting");
    openedAt = SystemClock.elapsedRealtime();
    Attempt selected = attempt;
    var receiver =
        new BackgroundMotionFrames.Listener() {
          @Override
          public void onSurface(Surface surface) {
            if (stopping || attempt != selected || frames == null) return;
            try {
              startPlayback(selected, surface);
            } catch (Exception error) {
              retry();
            }
          }

          @Override
          public void onMotion(long occurredAt, byte[] jpeg) {
            if (!stopping && !nativeConfirmed && attempt == selected && frames != null)
              send(occurredAt, jpeg);
          }

          @Override
          public void onError() {
            if (attempt == selected && frames != null) retry();
          }

          @Override
          public void onCorruptFrame() {
            if (attempt != selected || frames == null || stopping) return;
            softwareDecoder = true;
            // Retry the same stream with a different decoder, retaining TCP.
            int tcpAttempt = attempts.indexOf(new Attempt(selected.uri(), true));
            nextAttempt = tcpAttempt >= 0 ? tcpAttempt : Math.max(0, nextAttempt - 1);
            if (++corruptRestarts > 2) {
              closePlayback();
              cancelReconnect();
              phase("invalidVideo");
              scheduleReconnect(30_000);
            } else retry();
          }
        };
    frames = new BackgroundMotionFrames(receiver);
    frames.start();
    main.postDelayed(watchdog, 1000);
  }

  private void startNative() {
    if (request.nativeCredentials() == null || nativeAttempted || nativeReceiver != null) return;
    nativeAttempted = true;
    var holder = new DvripAlarmReceiver[1];
    var receiver =
        new DvripAlarmReceiver(
            request.network().getSocketFactory(),
            request.nativeCredentials(),
            new DvripAlarmReceiver.Listener() {
              @Override
              public void onMotion(long occurredAt, byte[] jpeg) {
                main.post(
                    () -> {
                      if (stopping || previewOpen() || nativeReceiver != holder[0]) return;
                      // Keep the existing fallback until an actual native alarm proves this path.
                      nativeConfirmed = true;
                      // Keep receiving video for the pre-event buffer, even after native alarms
                      // work.
                      phase("nativeWatching");
                      long firstChange = frames == null ? 0 : frames.lastMotionStartedAt();
                      long eventAt =
                          firstChange > 0
                                  && occurredAt >= firstChange
                                  && occurredAt - firstChange <= 10_000
                              ? firstChange
                              : occurredAt;
                      send(eventAt, jpeg);
                      if (frames == null && !reconnectScheduled) scheduleReconnect(0);
                    });
              }

              @Override
              public void onClosed() {
                main.post(
                    () -> {
                      if (stopping || nativeReceiver != holder[0]) return;
                      nativeReceiver = null;
                      nativeConfirmed = false;
                      if (!previewOpen() && frames == null) retry();
                    });
              }
            });
    holder[0] = receiver;
    nativeReceiver = receiver;
    receiver.start();
  }

  private void closeNative() {
    var receiver = nativeReceiver;
    nativeReceiver = null;
    nativeConfirmed = false;
    nativeAttempted = false;
    if (receiver != null) receiver.close();
  }

  private void startPlayback(Attempt selected, Surface surface) throws Exception {
    URI uri = selected.uri();
    var sockets =
        new LocalCameraPlayerChannel.CameraSockets(
            request.network().getSocketFactory(),
            CameraLocalNetwork.ipv4(uri.getHost()),
            uri.getPort() == -1 ? 554 : uri.getPort());
    videoBuffer = new CameraVideoBuffer();
    var decoder =
        new ExoPlayer.Builder(this, CameraRtspRenderers.create(this, softwareDecoder, videoBuffer))
            .build();
    player = decoder;
    decoder.addListener(
        new Player.Listener() {
          @Override
          public void onPlayerError(PlaybackException error) {
            if (player == decoder) {
              Log.w(TAG, "RTSP playback error: " + error.errorCode);
              main.post(
                  () -> {
                    if (player == decoder) retry();
                  });
            }
          }

          @Override
          public void onVideoSizeChanged(VideoSize size) {
            if (player == decoder && frames != null) frames.setVideoSize(size.width, size.height);
          }
        });
    decoder.setTrackSelectionParameters(
        decoder
            .getTrackSelectionParameters()
            .buildUpon()
            .setTrackTypeDisabled(C.TRACK_TYPE_AUDIO, true)
            .build());
    decoder.setWakeMode(C.WAKE_MODE_NETWORK);
    decoder.setVideoSurface(surface);
    decoder.setMediaSource(
        new RtspMediaSource.Factory()
            .setSocketFactory(sockets)
            .setForceUseRtpTcp(selected.tcp())
            .setDebugLoggingEnabled(false)
            .setTimeoutMs(8000)
            .createMediaSource(MediaItem.fromUri(Uri.parse(uri.toASCIIString()))));
    decoder.prepare();
    decoder.play();
  }

  private void checkFrames() {
    if (stopping || frames == null) return;
    long last = frames.lastSampleAt();
    if (SystemClock.elapsedRealtime() - (last == 0 ? openedAt : last) > 12_000) {
      retry();
      return;
    }
    if (last != 0) {
      if (SystemClock.elapsedRealtime() - openedAt >= 60_000) corruptRestarts = 0;
      backoff = 0;
      phase(uploadFailed ? "uploadFailed" : nativeConfirmed ? "nativeWatching" : "watching");
    }
    main.postDelayed(watchdog, 2000);
  }

  private void retry() {
    closePlayback();
    cancelReconnect();
    if (stopping || !enabled || previewOpen()) return;
    phase("reconnecting");
    scheduleReconnect(RETRY_MS[Math.min(backoff, RETRY_MS.length - 1)]);
    if (backoff < RETRY_MS.length - 1) backoff++;
  }

  private void closePlayback() {
    main.removeCallbacks(watchdog);
    attempt = null;
    var decoder = player;
    player = null;
    if (decoder != null) {
      decoder.clearVideoSurface();
      decoder.release();
    }
    if (frames != null) frames.close();
    frames = null;
    if (videoBuffer != null) videoBuffer.close();
    videoBuffer = null;
  }

  private void send(long occurredAt, byte[] jpeg) {
    long now = SystemClock.elapsedRealtime();
    if (stopping
        || !enabled
        || sending
        || !ownsCamera()
        || (lastEventAt != 0 && now - lastEventAt < 30_000)) return;
    sending = true;
    lastEventAt = now;
    BackgroundClipDelivery evidence = beginClip(occurredAt);
    var format = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.ROOT);
    format.setTimeZone(TimeZone.getTimeZone("UTC"));
    var data = new HashMap<String, Object>();
    data.put("cameraId", request.camera());
    data.put("type", "motion");
    data.put("source", "phone-motion");
    data.put("occurredAt", format.format(new Date(occurredAt)));
    if (jpeg != null) data.put("phoneSnapshot", Base64.encodeToString(jpeg, Base64.NO_WRAP));
    ingest
        .call(data)
        .addOnCompleteListener(
            result -> {
              sending = false;
              if (stopping) {
                if (evidence != null) evidence.cancel();
                return;
              }
              uploadFailed = !result.isSuccessful();
              if (evidence != null) {
                Object response = result.isSuccessful() ? result.getResult().getData() : null;
                Object id = response instanceof Map<?, ?> map ? map.get("id") : null;
                evidence.eventSaved(id instanceof String text ? text : null);
              }
              if (nativeConfirmed) phase(uploadFailed ? "uploadFailed" : "nativeWatching");
              if (uploadFailed) Log.w(TAG, "Could not save background motion event");
              else Log.i(TAG, "Background motion event saved");
            });
  }

  private BackgroundClipDelivery beginClip(long occurredAt) {
    CameraVideoBuffer buffer = videoBuffer;
    if (buffer == null || (pendingClip != null && !pendingClip.isDone())) return null;
    long ageMillis = Math.max(0, System.currentTimeMillis() - occurredAt);
    CameraVideoBuffer.Anchor anchor = buffer.anchorAt(System.nanoTime() - ageMillis * 1_000_000L);
    if (anchor == null) return null;
    final String owner = request.owner();
    final String camera = request.camera();
    BackgroundClipDelivery evidence =
        new BackgroundClipDelivery(
            (eventId, bytes, prebuffer) -> {
              if (stopping
                  || !enabled
                  || !ownsCamera()
                  || !owner.equals(request.owner())
                  || !camera.equals(request.camera())) return;
              var data = new HashMap<String, Object>();
              data.put("cameraId", camera);
              data.put("eventId", eventId);
              data.put("mp4Base64", Base64.encodeToString(bytes, Base64.NO_WRAP));
              data.put("prebufferMillis", prebuffer);
              clipUpload
                  .call(data)
                  .addOnCompleteListener(
                      result -> {
                        if (!result.isSuccessful())
                          Log.w(TAG, "Could not attach background event recording");
                        else Log.i(TAG, "Background event recording attached");
                      });
            });
    pendingClip = evidence;
    if (recordingThread == null) {
      recordingThread = new HandlerThread("SafeHoodBackgroundClip");
      recordingThread.start();
    }
    Handler worker = new Handler(recordingThread.getLooper());
    worker.post(
        () ->
            CameraStreamRecorder.start(
                getCacheDir(),
                buffer,
                anchor,
                worker,
                evidence::isDone,
                clip ->
                    main.post(
                        () -> {
                          if (stopping || !ownsCamera()) {
                            evidence.cancel();
                            return;
                          }
                          Object bytes = clip == null ? null : clip.get("bytes");
                          Object prefix = clip == null ? null : clip.get("prebufferMillis");
                          evidence.clipReady(
                              bytes instanceof byte[] data ? data : null,
                              prefix instanceof Number number ? number.intValue() : -1);
                        })));
    return evidence;
  }

  private void phase(String next) {
    if (stopping || next.equals(phase)) return;
    phase = next;
    getSystemService(NotificationManager.class).notify(NOTICE, notification());
    changed();
  }

  private Notification notification() {
    var manager = getSystemService(NotificationManager.class);
    Notification.Builder builder;
    if (Build.VERSION.SDK_INT >= 26) {
      manager.createNotificationChannel(
          new NotificationChannel(
              CHANNEL, "Wykrywanie ruchu w tle", NotificationManager.IMPORTANCE_LOW));
      builder = new Notification.Builder(this, CHANNEL);
    } else {
      builder = new Notification.Builder(this).setPriority(Notification.PRIORITY_LOW);
    }
    var openApp =
        PendingIntent.getActivity(
            this, 0, new Intent(this, MainActivity.class), PendingIntent.FLAG_IMMUTABLE);
    var stopAction =
        PendingIntent.getService(
            this,
            0,
            new Intent(this, BackgroundMotionService.class).setAction(STOP),
            PendingIntent.FLAG_IMMUTABLE);
    String detail =
        switch (phase) {
          case "nativeWatching" -> "Kamera wykrywa ruch. Telefon odbiera jej alarmy.";
          case "invalidVideo" -> "Nieprawidłowy obraz. Wznawiam połączenie z kamerą.";
          case "watching" -> "Telefon obserwuje obraz z kamery.";
          case "preview" -> "Wykrywanie z otwartego podglądu.";
          case "reconnecting" -> "Wznawiam połączenie z kamerą.";
          case "wifiLost" -> "Utracono Wi-Fi kamery. Włącz monitoring ponownie po powrocie.";
          case "uploadFailed" -> "Nie udało się zapisać ruchu. Sprawdź połączenie z internetem.";
          default -> "Łączenie z kamerą…";
        };
    return builder
        .setSmallIcon(R.mipmap.ic_launcher)
        .setContentTitle("SafeHood · Wykrywanie w tle")
        .setContentText(detail)
        .setVisibility(Notification.VISIBILITY_PRIVATE)
        .setOngoing(true)
        .setOnlyAlertOnce(true)
        .setContentIntent(openApp)
        .addAction(new Notification.Action.Builder(null, "Zatrzymaj", stopAction).build())
        .build();
  }

  private void finish() {
    if (stopping) return;
    stopping = true;
    stopForeground(STOP_FOREGROUND_REMOVE);
    stopSelf();
  }

  @Override
  public void onDestroy() {
    stopping = true;
    main.removeCallbacksAndMessages(null);
    closePlayback();
    closeNative();
    if (pendingClip != null) pendingClip.cancel();
    pendingClip = null;
    if (recordingThread != null) recordingThread.quitSafely();
    recordingThread = null;
    if (settings != null) settings.remove();
    if (authListener != null) FirebaseAuth.getInstance().removeAuthStateListener(authListener);
    request = null;
    if (current == this) current = null;
    changed();
    super.onDestroy();
  }
}
