import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The smallest text the app sets, in logical pixels. Below it text is hard to
/// read at the normal setting (the device's large-text setting scales whatever
/// is set here, up to twice, see `maxTextScale`).
const _smallest = 12.0;

/// No text in the app is set smaller than [_smallest]: a caption, a badge or a
/// chart label is 12 too, or larger.
void main() {
  test('no text is set smaller than 12 px', () {
    final size = RegExp(r'fontSize:\s*(\d+(?:\.\d+)?)');
    final tooSmall = <String>[];
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        for (final match in size.allMatches(lines[i])) {
          if (double.parse(match.group(1)!) < _smallest) {
            tooSmall.add('${file.path}:${i + 1}: ${match.group(0)}');
          }
        }
      }
    }
    expect(tooSmall, isEmpty, reason: 'raise these to $_smallest or more');
  });
}
