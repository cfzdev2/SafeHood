import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:safehood/features/cameras/data/live_motion_detector.dart';

Uint8List _frame({int light = 0, bool movement = false}) {
  return Uint8List.fromList(
    List.generate(LiveMotionDetector.pixels, (i) {
      final x = i % LiveMotionDetector.width;
      final y = i ~/ LiveMotionDetector.width;
      final background = 45 + x + light;
      return movement && x >= 18 && x < 42 && y >= 9 && y < 28
          ? background + 75
          : background;
    }),
  );
}

void main() {
  test(
    'rebases a whole-frame discontinuity without raising a motion alarm',
    () {
      final detector = LiveMotionDetector();
      final first = Uint8List.fromList(
        List.generate(LiveMotionDetector.pixels, (i) => i.isEven ? 35 : 200),
      );
      final second = Uint8List.fromList(
        first.map((value) => 235 - value).toList(),
      );
      expect(detector.add(first), isFalse);
      expect(detector.add(second), isFalse);
      expect(detector.add(second), isFalse);
      expect(detector.add(first), isFalse);
      expect(detector.add(first), isFalse);
    },
  );

  test('ignores global brightness and a single damaged frame', () {
    final detector = LiveMotionDetector();
    expect(detector.add(_frame()), isFalse);
    expect(detector.add(_frame(light: 36)), isFalse);
    expect(detector.add(_frame(light: 36, movement: true)), isFalse);
    expect(detector.add(_frame(light: 36)), isFalse);
    expect(detector.add(Uint8List(LiveMotionDetector.pixels)), isFalse);
    expect(detector.add(_frame(light: 36, movement: true)), isFalse);
    expect(detector.add(_frame(light: 36, movement: true)), isFalse);
  });

  test('reports once per episode and again after the scene has settled', () {
    final detector = LiveMotionDetector();
    expect(detector.add(_frame()), isFalse);
    expect(detector.add(_frame(movement: true)), isFalse);
    expect(detector.add(_frame(movement: true)), isTrue);
    for (var i = 0; i < 5; i++) {
      expect(detector.add(_frame(movement: i.isEven)), isFalse);
    }
    for (var i = 0; i < 3; i++) {
      expect(detector.add(_frame(movement: true)), isFalse);
    }
    expect(detector.add(_frame()), isFalse);
    expect(detector.add(_frame()), isTrue);
  });
}
