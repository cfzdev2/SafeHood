import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:safehood/features/cameras/data/focus72_direct_probe.dart';

final _red = base64Decode(
  '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBUODAsLDBkSEw8VHhsgHx4'
  'bHR0hJTApISMtJB0dKjkqLTEzNjY2ICg7Pzo0PjA1NjP/2wBDAQkJCQwLDBgODhgzIh0iMzMzM'
  'zMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzP/wAARCAA'
  'MABADASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAb/xAAUEAEAAAAAAAAAAAAAAAAAA'
  'AAA/8QAFQEBAQAAAAAAAAAAAAAAAAAABAf/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIR'
  'AxEAPwCOADUp/9k=',
);
final _blue = base64Decode(
  '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBUODAsLDBkSEw8VHhsgHx4'
  'bHR0hJTApISMtJB0dKjkqLTEzNjY2ICg7Pzo0PjA1NjP/2wBDAQkJCQwLDBgODhgzIh0iMzMzM'
  'zMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzP/wAARCAA'
  'MABADASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAT/xAAUEAEAAAAAAAAAAAAAAAAAA'
  'AAA/8QAFAEBAAAAAAAAAAAAAAAAAAAABv/EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAMAwEAAhE'
  'DEQA/AJQCMDf/2Q==',
);

Stream<List<int>> _parts(List<Uint8List> images) async* {
  final bytes = Uint8List.fromList([
    for (final jpeg in images) ...[
      ...ascii.encode('--video\r\nContent-Type: image/jpeg\r\n\r\n'),
      ...jpeg,
      ...ascii.encode('\r\n'),
    ],
    ...ascii.encode('--video--\r\n'),
  ]);
  for (var start = 0; start < bytes.length; start += 19) {
    final end = start + 19 < bytes.length ? start + 19 : bytes.length;
    yield Uint8List.sublistView(bytes, start, end);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('checks only the selected private IPv4 and rejects local relays', () {
    for (final address in [
      '127.0.0.1',
      'localhost',
      '8.8.8.8',
      'http://192.168.1.21',
      '192.168.1.21:18554',
    ]) {
      expect(focus72DirectCandidates(address), isEmpty, reason: address);
    }
    final urls = focus72DirectCandidates(' 192.168.1.21 ');
    expect(urls.map((url) => url.host).toSet(), {'192.168.1.21'});
    expect(urls.map((url) => url.port).toSet(), {80, 8080});
    expect(
      urls.every((url) => url.userInfo.isEmpty && url.scheme == 'http'),
      isTrue,
    );
    expect(urls.map((url) => url.path).toSet(), {
      '/axis-cgi/mjpg/video.cgi',
      '/image.cgi',
    });
  });

  test('a still JPEG is a photo and an HTML page is no image', () async {
    final photo = await inspectFocus72Image(
      Stream.value(_red),
      ContentType('image', 'jpeg'),
    );
    expect(photo.status, Focus72DirectStatus.photo);
    expect(photo.image, _red);

    final page = await inspectFocus72Image(
      Stream.value(utf8.encode('<html>Sign in</html>')),
      ContentType.html,
    );
    expect(page.status, Focus72DirectStatus.unavailable);
    expect(page.image, isNull);
  });

  test('JPEG metadata differences alone do not confirm video', () async {
    final withComment = Uint8List.fromList([
      ..._red.take(2),
      0xff,
      0xfe,
      0x00,
      0x03,
      0x61,
      ..._red.skip(2),
    ]);
    final result = await inspectFocus72Image(
      _parts([_red, withComment]),
      ContentType.parse('multipart/x-mixed-replace; boundary="video"'),
    );
    expect(result.status, Focus72DirectStatus.sameFrames);
  });

  test('different decoded frames confirm a multipart camera feed', () async {
    final result = await inspectFocus72Image(
      _parts([_red, _blue]),
      ContentType.parse('multipart/x-mixed-replace; boundary="video"'),
    );
    expect(result.status, Focus72DirectStatus.video);
    expect(result.image, _blue);
  });
}
