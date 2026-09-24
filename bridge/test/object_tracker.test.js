'use strict';

const assert =
  require('node:assert/strict');

const test =
  require('node:test');

const {
  ObjectTracker,
} = require('../ai/object_tracker');

function detection({
  type = 'person',
  className = 'person',
  classId = 0,
  score = 0.9,
  left = 100,
  top = 50,
  right = 200,
  bottom = 250,
} = {}) {
  return {
    type,
    className,
    classId,
    score,
    box: {
      left,
      top,
      right,
      bottom,
    },
  };
}

test(
  'potwierdza obiekt po trzech klatkach',
  () => {
    const tracker =
      new ObjectTracker();

    const first = tracker.update(
      [
        detection(),
      ],
      {
        timestampMillis: 1000,
      },
    );

    assert.equal(
      first.visibleTracks.length,
      1,
    );

    assert.equal(
      first.confirmedTracks.length,
      0,
    );

    assert.equal(
      first.newlyConfirmedTracks.length,
      0,
    );

    const second = tracker.update(
      [
        detection({
          left: 104,
          right: 204,
        }),
      ],
      {
        timestampMillis: 1500,
      },
    );

    assert.equal(
      second.visibleTracks[0].id,
      1,
    );

    assert.equal(
      second.newlyConfirmedTracks.length,
      0,
    );

    const third = tracker.update(
      [
        detection({
          left: 108,
          right: 208,
        }),
      ],
      {
        timestampMillis: 2000,
      },
    );

    assert.equal(
      third.confirmedTracks.length,
      1,
    );

    assert.equal(
      third.newlyConfirmedTracks.length,
      1,
    );

    assert.equal(
      third.newlyConfirmedTracks[0].id,
      1,
    );

    assert.equal(
      third.newlyConfirmedTracks[0]
        .detectionCount,
      3,
    );

    const fourth = tracker.update(
      [
        detection({
          left: 112,
          right: 212,
        }),
      ],
      {
        timestampMillis: 2500,
      },
    );

    assert.equal(
      fourth.confirmedTracks.length,
      1,
    );

    assert.equal(
      fourth.newlyConfirmedTracks.length,
      0,
    );
  },
);

test(
  'słabsze wykrycie podtrzymuje istniejący ślad',
  () => {
    const tracker =
      new ObjectTracker({
        minimumConfirmedFrames: 1,
      });

    const first = tracker.update([
      detection({
        score: 0.9,
      }),
    ]);

    const trackId =
      first.visibleTracks[0].id;

    const second = tracker.update([
      detection({
        score: 0.3,
        left: 105,
        right: 205,
      }),
    ]);

    assert.equal(
      second.visibleTracks.length,
      1,
    );

    assert.equal(
      second.visibleTracks[0].id,
      trackId,
    );

    assert.equal(
      second.visibleTracks[0].score,
      0.3,
    );

    assert.equal(
      second.newlyConfirmedTracks.length,
      0,
    );
  },
);

test(
  'słabe wykrycie nie tworzy nowego śladu',
  () => {
    const tracker =
      new ObjectTracker();

    const result = tracker.update([
      detection({
        score: 0.3,
      }),
    ]);

    assert.equal(
      result.visibleTracks.length,
      0,
    );

    assert.equal(
      result.newlyConfirmedTracks.length,
      0,
    );
  },
);

test(
  'osoba i pojazd otrzymują osobne ślady',
  () => {
    const tracker =
      new ObjectTracker({
        minimumConfirmedFrames: 1,
      });

    const result = tracker.update([
      detection({
        type: 'person',
        className: 'person',
        classId: 0,
      }),
      detection({
        type: 'vehicle',
        className: 'car',
        classId: 2,
      }),
    ]);

    assert.equal(
      result.confirmedTracks.length,
      2,
    );

    assert.deepEqual(
      result.confirmedTracks
        .map((track) => track.type)
        .sort(),
      [
        'person',
        'vehicle',
      ],
    );
  },
);

test(
  'usuwa ślad po przekroczeniu limitu',
  () => {
    const tracker =
      new ObjectTracker({
        minimumConfirmedFrames: 1,
        maximumMissedFrames: 2,
      });

    const first = tracker.update([
      detection(),
    ]);

    assert.equal(
      first.visibleTracks[0].id,
      1,
    );

    const missingOnce =
      tracker.update([]);

    assert.equal(
      missingOnce.lostTracks[0]
        .missedFrames,
      1,
    );

    const missingTwice =
      tracker.update([]);

    assert.equal(
      missingTwice.lostTracks[0]
        .missedFrames,
      2,
    );

    const removed =
      tracker.update([]);

    assert.deepEqual(
      removed.removedTrackIds,
      [
        1,
      ],
    );

    assert.equal(
      removed.lostTracks.length,
      0,
    );

    const newObject =
      tracker.update([
        detection(),
      ]);

    assert.equal(
      newObject.visibleTracks[0].id,
      2,
    );
  },
);

test(
  'ignoruje nieprawidłowe wykrycia',
  () => {
    const tracker =
      new ObjectTracker();

    const result = tracker.update([
      null,
      {
        type: 'animal',
        score: 0.9,
        box: {
          left: 0,
          top: 0,
          right: 100,
          bottom: 100,
        },
      },
      detection({
        score: 2,
      }),
      detection({
        right: 50,
        left: 100,
      }),
    ]);

    assert.equal(
      result.visibleTracks.length,
      0,
    );
  },
);

test(
  'reset usuwa ślady i zeruje identyfikatory',
  () => {
    const tracker =
      new ObjectTracker({
        minimumConfirmedFrames: 1,
      });

    tracker.update([
      detection(),
    ]);

    tracker.reset();

    const result = tracker.update([
      detection(),
    ]);

    assert.equal(
      result.visibleTracks[0].id,
      1,
    );
  },
);