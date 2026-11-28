package com.safehood.securityapp;

import java.util.concurrent.CompletableFuture;

/** Main-thread handoff of the single camera connection from a recording to a live preview. */
final class BackgroundClipHandoff {
  private CompletableFuture<Void> active;

  boolean collecting() {
    return active != null;
  }

  Runnable begin(Runnable reconcile) {
    if (collecting()) throw new IllegalStateException("Capture already in progress");
    var ticket = new CompletableFuture<Void>();
    active = ticket;
    return () -> {
      if (active != ticket) return; // Late completion/timeout from a previous clip.
      active = null;
      try {
        reconcile.run(); // Close the old receiver before letting another player open it.
      } finally {
        ticket.complete(null);
      }
    };
  }

  void whenAvailable(Runnable ready) {
    if (active == null) ready.run();
    else active.thenRun(ready);
  }

  void close() {
    var ticket = active;
    active = null;
    if (ticket != null) ticket.complete(null);
  }
}
