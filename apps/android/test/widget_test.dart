import 'package:flutter_test/flutter_test.dart';
import 'package:rsk_downloader/core/resolver.dart';

void main() {
  test('extracts YouTube ids from shared links', () {
    expect(youTubeId('https://youtube.com/shorts/dQw4w9WgXcQ?si=abc'), 'dQw4w9WgXcQ');
    expect(youTubeId('https://youtu.be/dQw4w9WgXcQ'), 'dQw4w9WgXcQ');
    expect(extractUrl('look https://example.com/a.mp4.'), 'https://example.com/a.mp4');
  });
}
