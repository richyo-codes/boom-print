import 'package:boomprint/log_redaction.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final scheme in ['http', 'https', 'rtsp', 'rtsps', 'ftp', 'ftps']) {
    test('redacts $scheme user information in native log messages', () {
      final url = '$scheme://viewer:p%40ss%3Aword@camera.local:322/live';
      expect(
        redactLogText('[ffmpeg] Opening "$url"'),
        '[ffmpeg] Opening "$scheme://[redacted]@camera.local:322/live"',
      );
    });
  }

  test(
    'redacts multiple URLs, IPv6, and passwords containing raw at signs',
    () {
      expect(
        redactLogText(
          'rtsp://user:p@ss@[::1]:554/live\n'
          'https://other:secret@camera/snapshot',
        ),
        'rtsp://[redacted]@[::1]:554/live\n'
        'https://[redacted]@camera/snapshot',
      );
    },
  );

  test('preserves harmless URLs and useful playback diagnostics', () {
    const text =
        'https://camera.local/live?channel=1 playing=true size=1760x1080';
    expect(redactLogText(text), text);
    expect(redactLogText(''), '');
  });

  test('redacts query credentials while retaining other parameters', () {
    expect(
      redactLogText(
        'http://camera/live?password=secret&channel=1&token=abc#stream',
      ),
      'http://camera/live?password=[redacted]&channel=1&token=[redacted]#stream',
    );
    expect(
      redactLogText('https://camera/?API_KEY=key&access_code=code'),
      'https://camera/?API_KEY=[redacted]&access_code=[redacted]',
    );
  });

  test('redacts HTTP authentication headers', () {
    expect(
      redactLogText(
        'Authorization: Basic dXNlcjpwYXNz\n'
        'Proxy-Authorization: Bearer eyJtoken',
      ),
      'Authorization: Basic [redacted]\n'
      'Proxy-Authorization: Bearer [redacted]',
    );
  });

  test('redacts known secrets outside URLs, including encoded variants', () {
    const password = 'camera pass@word';
    final input = 'password=$password encoded=${Uri.encodeComponent(password)}';
    expect(
      redactLogText(input, secrets: ['', password, 'camera pass']),
      'password=[redacted] encoded=[redacted]',
    );
  });

  test(
    'redacts playlist and exception diagnostics without changing the URL',
    () {
      const url = 'rtsps://viewer:secret@printer.local:322/live';
      final playlist = 'Playlist(medias: [Media($url)])';
      final error = 'Failed to open $url: HTTP 401';
      expect(redactLogText(playlist), isNot(contains('secret')));
      expect(redactLogText(error), contains('HTTP 401'));
      expect(url, contains('viewer:secret@'));
    },
  );
}
