package com.safehood.securityapp;

/** Joins an acknowledged private event with its clip, in either completion order, once only. */
final class BackgroundClipDelivery {
  interface Upload {
    void send(String eventId, byte[] bytes, int prebufferMillis);
  }

  private final Upload upload;
  private String eventId;
  private byte[] bytes;
  private int prebuffer;
  private boolean done;

  BackgroundClipDelivery(Upload upload) {
    this.upload = upload;
  }

  synchronized void eventSaved(String id) {
    if (done) return;
    if (id == null || id.isEmpty()) {
      cancel();
      return;
    }
    if (eventId == null) eventId = id;
    deliver();
  }

  synchronized void clipReady(byte[] data, int prebufferMillis) {
    if (done) return;
    if (data == null
        || data.length < 100
        || data.length > 6 * 1024 * 1024
        || prebufferMillis < 0
        || prebufferMillis > 5000) {
      cancel();
      return;
    }
    if (bytes == null) {
      bytes = data;
      prebuffer = prebufferMillis;
    }
    deliver();
  }

  private void deliver() {
    if (eventId == null || bytes == null) return;
    byte[] clip = bytes;
    bytes = null;
    done = true;
    upload.send(eventId, clip, prebuffer);
  }

  synchronized void cancel() {
    done = true;
    bytes = null;
    eventId = null;
  }

  synchronized boolean isDone() {
    return done;
  }
}
