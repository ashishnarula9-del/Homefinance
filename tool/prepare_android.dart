import 'dart:io';

/// Change the name shown under the app icon here, then run this script again and rebuild.
const appName = 'Home Finance';

void main() {
  final manifest = File('android/app/src/main/AndroidManifest.xml');
  if (!manifest.existsSync()) {
    stderr.writeln('ERROR: android/app/src/main/AndroidManifest.xml was not found.');
    stderr.writeln('Run: flutter create --platforms=android .');
    exitCode = 2;
    return;
  }

  var text = manifest.readAsStringSync();
  if (!text.contains('android.permission.INTERNET')) {
    final manifestStart = text.indexOf('<manifest');
    if (manifestStart < 0) {
      stderr.writeln('ERROR: <manifest> element not found.');
      exitCode = 3;
      return;
    }
    final close = text.indexOf('>', manifestStart);
    text = '${text.substring(0, close + 1)}\n    <uses-permission android:name="android.permission.INTERNET" />${text.substring(close + 1)}';
  }

  final appTag = RegExp(r'<application\b[^>]*>', dotAll: true);
  final match = appTag.firstMatch(text);
  if (match == null) {
    stderr.writeln('ERROR: <application> element not found.');
    exitCode = 3;
    return;
  }
  var tag = match.group(0)!;
  final labelPattern = RegExp(r'android:label="[^"]*"');
  if (labelPattern.hasMatch(tag)) {
    tag = tag.replaceFirst(labelPattern, 'android:label="$appName"');
  } else {
    tag = tag.substring(0, tag.length - 1) + '\n        android:label="$appName">';
  }
  if (!tag.contains('android:usesCleartextTraffic=')) {
    tag = tag.substring(0, tag.length - 1) + '\n        android:usesCleartextTraffic="true">';
  }
  text = text.replaceRange(match.start, match.end, tag);

  manifest.writeAsStringSync(text);
  stdout.writeln('Configured Home Finance Android name, networking, Wi-Fi Sync and Google Drive backup.');
}
