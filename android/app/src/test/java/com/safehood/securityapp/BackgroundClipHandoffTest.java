package com.safehood.securityapp;

import static org.junit.Assert.*;

import java.util.ArrayList;
import java.util.List;
import org.junit.Test;

public final class BackgroundClipHandoffTest {
  @Test
  public void tappingAPushBeforeMuxFinishesOpensLiveOnlyAfterReleasingReceiver() {
    var log = new ArrayList<String>();
    var gate = new BackgroundClipHandoff();
    var delivery = new BackgroundClipDelivery((id, bytes, prefix) -> log.add("upload " + id));
    var captured = gate.begin(() -> log.add("close receiver"));
    gate.whenAvailable(() -> log.add("open live"));
    assertTrue(log.isEmpty());
    delivery.clipReady(new byte[250], 4000);
    captured.run();
    assertEquals(List.of("close receiver", "open live"), log);
    // Slow event acknowledgement/upload does not keep the user out of live view.
    delivery.eventSaved("event");
    assertEquals(List.of("close receiver", "open live", "upload event"), log);
  }

  @Test
  public void timeoutShutdownAndLateCallbacksCannotTrapOrReleaseAnotherPreview() {
    var log = new ArrayList<String>();
    var gate = new BackgroundClipHandoff();
    var deadline = gate.begin(() -> log.add("release one"));
    gate.whenAvailable(() -> log.add("preview one"));
    deadline.run();
    var later = gate.begin(() -> log.add("release two"));
    gate.whenAvailable(() -> log.add("preview two"));
    deadline.run(); // Delayed callback from first clip.
    assertTrue(gate.collecting());
    assertEquals(List.of("release one", "preview one"), log);
    gate.close();
    later.run();
    assertFalse(gate.collecting());
    gate.whenAvailable(() -> log.add("immediate"));
    assertEquals(List.of("release one", "preview one", "preview two", "immediate"), log);
  }
}
