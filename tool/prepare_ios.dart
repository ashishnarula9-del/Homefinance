import 'dart:io';

/// Change the name shown under the app icon here, then run this script again and rebuild.
const appName = 'Home Finance';

void main(List<String> args) {
  final plist = File('ios/Runner/Info.plist');
  if (!plist.existsSync()) {
    stderr.writeln('ERROR: ios/Runner/Info.plist was not found.');
    stderr.writeln('Run: flutter create --platforms=ios .');
    exitCode = 2;
    return;
  }

  var text = plist.readAsStringSync();
  text = _upsertString(text, 'CFBundleDisplayName', appName);
  text = _upsertString(text, 'CFBundleName', appName);
  text = _upsertString(
    text,
    'NSLocalNetworkUsageDescription',
    'Home Finance uses your local Wi-Fi network only when you choose Wi-Fi Sync to exchange family finance data with another device.',
  );
  text = _upsertDictionaryBoolean(
    text,
    'NSAppTransportSecurity',
    'NSAllowsLocalNetworking',
    true,
  );

  final iosClientId = Platform.environment['GOOGLE_IOS_CLIENT_ID'];
  final reversedClientId = Platform.environment['GOOGLE_IOS_REVERSED_CLIENT_ID'];
  if (iosClientId != null && iosClientId.isNotEmpty) {
    text = _upsertString(text, 'GIDClientID', iosClientId);
  }
  if (reversedClientId != null && reversedClientId.isNotEmpty) {
    text = _upsertUrlScheme(text, reversedClientId);
  }

  plist.writeAsStringSync(text);
  stdout.writeln('Configured ios/Runner/Info.plist for Home Finance.');
  if (iosClientId == null ||
      iosClientId.isEmpty ||
      reversedClientId == null ||
      reversedClientId.isEmpty) {
    stdout.writeln('NOTE: Google Drive iOS sign-in credentials were not injected.');
    stdout.writeln('Set GOOGLE_IOS_CLIENT_ID and GOOGLE_IOS_REVERSED_CLIENT_ID before a Drive-enabled iOS release build.');
  }
}

String _upsertString(String plist, String key, String value) {
  final escaped = _xmlEscape(value);
  final pair = RegExp(
    '<key>${RegExp.escape(key)}</key>\\s*<string>.*?</string>',
    dotAll: true,
  );
  if (pair.hasMatch(plist)) {
    return plist.replaceFirst(pair, '<key>$key</key>\n\t<string>$escaped</string>');
  }
  return _insertBeforeFinalDict(plist, '\t<key>$key</key>\n\t<string>$escaped</string>\n');
}

String _upsertDictionaryBoolean(
  String plist,
  String dictKey,
  String boolKey,
  bool value,
) {
  final dictPattern = RegExp(
    '<key>${RegExp.escape(dictKey)}</key>\\s*<dict>(.*?)</dict>',
    dotAll: true,
  );
  final boolTag = value ? '<true/>' : '<false/>';
  final match = dictPattern.firstMatch(plist);
  if (match != null) {
    var body = match.group(1)!;
    final boolPattern = RegExp(
      '<key>${RegExp.escape(boolKey)}</key>\\s*<(?:true|false)/>',
      dotAll: true,
    );
    if (boolPattern.hasMatch(body)) {
      body = body.replaceFirst(boolPattern, '<key>$boolKey</key>\n\t\t$boolTag');
    } else {
      body = '$body\n\t\t<key>$boolKey</key>\n\t\t$boolTag\n\t';
    }
    return plist.replaceRange(
      match.start,
      match.end,
      '<key>$dictKey</key>\n\t<dict>$body</dict>',
    );
  }
  return _insertBeforeFinalDict(
    plist,
    '\t<key>$dictKey</key>\n\t<dict>\n\t\t<key>$boolKey</key>\n\t\t$boolTag\n\t</dict>\n',
  );
}

String _upsertUrlScheme(String plist, String scheme) {
  final escaped = _xmlEscape(scheme);
  if (plist.contains('<string>$escaped</string>')) return plist;
  final fragment =
      '\t<key>CFBundleURLTypes</key>\n'
      '\t<array>\n'
      '\t\t<dict>\n'
      '\t\t\t<key>CFBundleTypeRole</key>\n'
      '\t\t\t<string>Editor</string>\n'
      '\t\t\t<key>CFBundleURLSchemes</key>\n'
      '\t\t\t<array>\n'
      '\t\t\t\t<string>$escaped</string>\n'
      '\t\t\t</array>\n'
      '\t\t</dict>\n'
      '\t</array>\n';
  return _insertBeforeFinalDict(plist, fragment);
}

String _insertBeforeFinalDict(String plist, String fragment) {
  final index = plist.lastIndexOf('</dict>');
  if (index < 0) {
    stderr.writeln('ERROR: Invalid Info.plist: closing </dict> not found.');
    exit(3);
  }
  return plist.substring(0, index) + fragment + plist.substring(index);
}

String _xmlEscape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
