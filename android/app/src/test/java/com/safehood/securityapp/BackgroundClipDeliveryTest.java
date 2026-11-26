package com.safehood.securityapp;

import static org.junit.Assert.*;

import java.util.ArrayList;
import org.junit.Test;

public final class BackgroundClipDeliveryTest {
  @Test
  public void waitsForAcknowledgedEventAndClipInEitherOrderAndUploadsOnce() {
    for (boolean clipFirst : new boolean[] {true, false}) {
      var sent = new ArrayList<String>();
      var delivery =
          new BackgroundClipDelivery(
              (id, bytes, prefix) -> {
                assertEquals(4000, prefix);
                assertEquals(150, bytes.length);
                sent.add(id);
              });
      if (clipFirst) delivery.clipReady(new byte[150], 4000);
      else delivery.eventSaved("event");
      assertTrue(sent.isEmpty());
      if (clipFirst) delivery.eventSaved("event");
      else delivery.clipReady(new byte[150], 4000);
      delivery.eventSaved("other-event");
      delivery.clipReady(new byte[200], 0);
      assertEquals(java.util.List.of("event"), sent);
      assertTrue(delivery.isDone());
    }
  }

  @Test
  public void failureOrLogoutDiscardsPendingEvidence() {
    for (boolean cancelBeforeEvent : new boolean[] {true, false}) {
      var delivery =
          new BackgroundClipDelivery((id, bytes, prefix) -> fail("Cancelled capture uploaded"));
      if (cancelBeforeEvent) delivery.clipReady(new byte[150], 1000);
      else delivery.eventSaved("event");
      delivery.cancel();
      delivery.eventSaved("event");
      delivery.clipReady(new byte[150], 1000);
      assertTrue(delivery.isDone());
    }
  }

  @Test
  public void missingEventOrRecordingCannotUpload() {
    var delivery =
        new BackgroundClipDelivery((id, bytes, prefix) -> fail("Missing evidence uploaded"));
    delivery.eventSaved(null);
    delivery.clipReady(new byte[150], 0);
    assertTrue(delivery.isDone());
    delivery = new BackgroundClipDelivery((id, bytes, prefix) -> fail("Missing clip uploaded"));
    delivery.eventSaved("event");
    delivery.clipReady(null, 0);
    assertTrue(delivery.isDone());
  }

  @Test
  public void rejectsInvalidClipMetadata() {
    var delivery = new BackgroundClipDelivery((id, bytes, prefix) -> fail("Invalid clip uploaded"));
    delivery.eventSaved("event");
    delivery.clipReady(new byte[150], 5001);
    assertTrue(delivery.isDone());
  }
}
