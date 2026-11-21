import 'dart:typed_data';

/// Detects sustained local changes, while ignoring a brightness shift affecting
/// the whole picture. Only the downscaled luminance samples are retained here.
class LiveMotionDetector {
  static const width = 64;
  static const height = 36;
  static const pixels = width * height;

  Uint8List? _previous;
  int _changesInARow = 0;
  int _quietFrames = 0;
  bool _episode = false;

  void reset() {
    _previous = null;
    _changesInARow = 0;
    _quietFrames = 0;
    _episode = false;
  }

  bool add(Uint8List frame) {
    if (frame.length != pixels) return false;
    var low = 255;
    var high = 0;
    for (final value in frame) {
      if (value < low) low = value;
      if (value > high) high = value;
    }
    if ((high < 6 || low > 249) && high - low <= 3) {
      // Some decoders briefly show an empty frame when reconnecting.
      reset();
      return false;
    }

    final previous = _previous;
    if (previous == null) {
      _previous = frame;
      return false;
    }
    var totalDelta = 0;
    for (var i = 0; i < pixels; i++) {
      totalDelta += frame[i] - previous[i];
    }
    final exposureShift = totalDelta ~/ pixels;
    var changed = 0;
    for (var i = 0; i < pixels; i++) {
      if ((frame[i] - previous[i] - exposureShift).abs() >= 24) changed++;
    }
    final moving = changed * 100 >= pixels * 7;

    if (_episode) {
      _previous = frame;
      _quietFrames = moving ? 0 : _quietFrames + 1;
      if (_quietFrames >= 3) {
        _quietFrames = 0;
        _episode = false;
      }
      return false;
    }
    if (!moving) {
      _previous = frame;
      _changesInARow = 0;
      return false;
    }
    // Keep the baseline for another sample so a single damaged frame doesn't
    // both trigger detection and change the reference for the next sample.
    if (++_changesInARow < 2) return false;
    _previous = frame;
    _changesInARow = 0;
    _episode = true;
    return true;
  }
}
