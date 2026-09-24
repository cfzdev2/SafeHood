'use strict';

const {
  intersectionOverUnion,
} = require('./yolox_postprocess');

const supportedTypes =
  new Set([
    'person',
    'vehicle',
  ]);

function isProbability(value) {
  return (
    Number.isFinite(value) &&
    value >= 0 &&
    value <= 1
  );
}

function normalizeDetection(value) {
  if (
    !value ||
    typeof value !== 'object' ||
    !supportedTypes.has(value.type) ||
    !isProbability(value.score)
  ) {
    return null;
  }

  const box = value.box;

  if (
    !box ||
    !Number.isFinite(box.left) ||
    !Number.isFinite(box.top) ||
    !Number.isFinite(box.right) ||
    !Number.isFinite(box.bottom) ||
    box.right <= box.left ||
    box.bottom <= box.top
  ) {
    return null;
  }

  const className =
    typeof value.className === 'string' &&
    value.className.trim()
      ? value.className.trim()
      : value.type;

  return {
    type: value.type,
    classId:
      Number.isInteger(value.classId)
        ? value.classId
        : null,
    className,
    score: value.score,
    box: {
      left: box.left,
      top: box.top,
      right: box.right,
      bottom: box.bottom,
      width: box.right - box.left,
      height: box.bottom - box.top,
    },
  };
}

function validateThreshold(
  value,
  label,
) {
  if (!isProbability(value)) {
    throw new RangeError(
      `${label} musi być liczbą od 0 do 1.`,
    );
  }
}

class ObjectTracker {
  constructor({
    highScoreThreshold = 0.5,
    lowScoreThreshold = 0.15,
    highMatchIouThreshold = 0.3,
    lowMatchIouThreshold = 0.2,
    minimumConfirmedFrames = 3,
    maximumMissedFrames = 6,
  } = {}) {
    validateThreshold(
      highScoreThreshold,
      'highScoreThreshold',
    );

    validateThreshold(
      lowScoreThreshold,
      'lowScoreThreshold',
    );

    validateThreshold(
      highMatchIouThreshold,
      'highMatchIouThreshold',
    );

    validateThreshold(
      lowMatchIouThreshold,
      'lowMatchIouThreshold',
    );

    if (
      lowScoreThreshold >=
      highScoreThreshold
    ) {
      throw new RangeError(
        'lowScoreThreshold musi być mniejszy ' +
        'od highScoreThreshold.',
      );
    }

    if (
      !Number.isInteger(
        minimumConfirmedFrames,
      ) ||
      minimumConfirmedFrames < 1
    ) {
      throw new RangeError(
        'minimumConfirmedFrames musi być ' +
        'dodatnią liczbą całkowitą.',
      );
    }

    if (
      !Number.isInteger(
        maximumMissedFrames,
      ) ||
      maximumMissedFrames < 0
    ) {
      throw new RangeError(
        'maximumMissedFrames musi być ' +
        'nieujemną liczbą całkowitą.',
      );
    }

    this.highScoreThreshold =
      highScoreThreshold;

    this.lowScoreThreshold =
      lowScoreThreshold;

    this.highMatchIouThreshold =
      highMatchIouThreshold;

    this.lowMatchIouThreshold =
      lowMatchIouThreshold;

    this.minimumConfirmedFrames =
      minimumConfirmedFrames;

    this.maximumMissedFrames =
      maximumMissedFrames;

    this._tracks = [];
    this._nextTrackId = 1;
  }

  update(
    detections,
    {
      timestampMillis = Date.now(),
    } = {},
  ) {
    if (!Array.isArray(detections)) {
      throw new TypeError(
        'detections musi być tablicą.',
      );
    }

    if (
      !Number.isFinite(timestampMillis) ||
      timestampMillis < 0
    ) {
      throw new RangeError(
        'timestampMillis jest nieprawidłowy.',
      );
    }

    const normalizedDetections =
      detections
        .map(normalizeDetection)
        .filter(
          (detection) =>
            detection !== null &&
            detection.score >=
              this.lowScoreThreshold,
        );

    const highDetections =
      normalizedDetections.filter(
        (detection) =>
          detection.score >=
          this.highScoreThreshold,
      );

    const lowDetections =
      normalizedDetections.filter(
        (detection) =>
          detection.score <
          this.highScoreThreshold,
      );

    for (const track of this._tracks) {
      track.age += 1;
    }

    const highAssociation =
      this._associate(
        this._tracks,
        highDetections,
        this.highMatchIouThreshold,
      );

    const newlyConfirmedTracks = [];

    for (
      const match
      of highAssociation.matches
    ) {
      if (
        this._updateTrack(
          match.track,
          match.detection,
          timestampMillis,
        )
      ) {
        newlyConfirmedTracks.push(
          match.track,
        );
      }
    }

    const lowAssociation =
      this._associate(
        highAssociation.unmatchedTracks,
        lowDetections,
        this.lowMatchIouThreshold,
      );

    for (
      const match
      of lowAssociation.matches
    ) {
      if (
        this._updateTrack(
          match.track,
          match.detection,
          timestampMillis,
        )
      ) {
        newlyConfirmedTracks.push(
          match.track,
        );
      }
    }

    for (
      const track
      of lowAssociation.unmatchedTracks
    ) {
      track.missedFrames += 1;
      track.consecutiveHits = 0;
    }

    for (
      const detection
      of highAssociation
        .unmatchedDetections
    ) {
      const track =
        this._createTrack(
          detection,
          timestampMillis,
        );

      this._tracks.push(track);

      if (track.confirmed) {
        newlyConfirmedTracks.push(
          track,
        );
      }
    }

    const removedTracks =
      this._tracks.filter(
        (track) =>
          track.missedFrames >
          this.maximumMissedFrames,
      );

    this._tracks =
      this._tracks.filter(
        (track) =>
          track.missedFrames <=
          this.maximumMissedFrames,
      );

    const visibleTracks =
      this._tracks.filter(
        (track) =>
          track.missedFrames === 0,
      );

    return {
      visibleTracks:
        visibleTracks.map(
          (track) =>
            this._publicTrack(track),
        ),

      confirmedTracks:
        visibleTracks
          .filter(
            (track) =>
              track.confirmed,
          )
          .map(
            (track) =>
              this._publicTrack(track),
          ),

      newlyConfirmedTracks:
        newlyConfirmedTracks.map(
          (track) =>
            this._publicTrack(track),
        ),

      lostTracks:
        this._tracks
          .filter(
            (track) =>
              track.missedFrames > 0,
          )
          .map(
            (track) =>
              this._publicTrack(track),
          ),

      removedTrackIds:
        removedTracks.map(
          (track) => track.id,
        ),
    };
  }

  reset() {
    this._tracks = [];
    this._nextTrackId = 1;
  }

  _associate(
    tracks,
    detections,
    minimumIou,
  ) {
    const unmatchedTracks = [
      ...tracks,
    ];

    const unmatchedDetections = [
      ...detections,
    ];

    const matches = [];

    while (
      unmatchedTracks.length > 0 &&
      unmatchedDetections.length > 0
    ) {
      let bestMatch = null;

      for (
        let trackIndex = 0;
        trackIndex <
        unmatchedTracks.length;
        trackIndex += 1
      ) {
        const track =
          unmatchedTracks[trackIndex];

        for (
          let detectionIndex = 0;
          detectionIndex <
          unmatchedDetections.length;
          detectionIndex += 1
        ) {
          const detection =
            unmatchedDetections[
              detectionIndex
            ];

          if (
            track.type !==
            detection.type
          ) {
            continue;
          }

          const iou =
            intersectionOverUnion(
                track,
                detection,
            );

            if (
            iou < minimumIou ||
            (
                bestMatch &&
                iou <= bestMatch.iou
            )
            ) {
            continue;
            }

          bestMatch = {
            trackIndex,
            detectionIndex,
            iou,
          };
        }
      }

      if (!bestMatch) {
        break;
      }

      const [track] =
        unmatchedTracks.splice(
          bestMatch.trackIndex,
          1,
        );

      const [detection] =
        unmatchedDetections.splice(
          bestMatch.detectionIndex,
          1,
        );

      matches.push({
        track,
        detection,
        iou: bestMatch.iou,
      });
    }

    return {
      matches,
      unmatchedTracks,
      unmatchedDetections,
    };
  }

  _createTrack(
    detection,
    timestampMillis,
  ) {
    const track = {
      id: this._nextTrackId,
      type: detection.type,
      classId: detection.classId,
      className: detection.className,
      score: detection.score,
      bestScore: detection.score,
      bestClassName:
        detection.className,
      box: {
        ...detection.box,
      },
      age: 1,
      detectionCount: 1,
      consecutiveHits: 1,
      missedFrames: 0,
      confirmed:
        this.minimumConfirmedFrames === 1,
      firstSeenAtMillis:
        timestampMillis,
      lastSeenAtMillis:
        timestampMillis,
    };

    this._nextTrackId += 1;

    return track;
  }

  _updateTrack(
    track,
    detection,
    timestampMillis,
  ) {
    const wasConfirmed =
      track.confirmed;

    track.type = detection.type;
    track.classId = detection.classId;
    track.className =
      detection.className;
    track.score = detection.score;
    track.box = {
      ...detection.box,
    };

    track.detectionCount += 1;
    track.consecutiveHits += 1;
    track.missedFrames = 0;
    track.lastSeenAtMillis =
      timestampMillis;

    if (
      detection.score >
      track.bestScore
    ) {
      track.bestScore =
        detection.score;

      track.bestClassName =
        detection.className;
    }

    if (
      !track.confirmed &&
      track.consecutiveHits >=
        this.minimumConfirmedFrames
    ) {
      track.confirmed = true;
    }

    return (
      !wasConfirmed &&
      track.confirmed
    );
  }

  _publicTrack(track) {
    return {
      id: track.id,
      type: track.type,
      classId: track.classId,
      className: track.className,
      score: track.score,
      bestScore: track.bestScore,
      bestClassName:
        track.bestClassName,
      box: {
        ...track.box,
      },
      age: track.age,
      detectionCount:
        track.detectionCount,
      consecutiveHits:
        track.consecutiveHits,
      missedFrames:
        track.missedFrames,
      confirmed: track.confirmed,
      firstSeenAtMillis:
        track.firstSeenAtMillis,
      lastSeenAtMillis:
        track.lastSeenAtMillis,
    };
  }
}

module.exports = {
  ObjectTracker,
};