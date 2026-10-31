# Build Home Finance on a Windows PC (Android APK)

See the chat instructions; short version:

1. Install Android Studio (SDK + Command-line Tools) and Flutter (C:\flutter). Run `flutter doctor --android-licenses`, then `flutter doctor`.
2. Unzip this project to C:\FamilyFinance (delete old android, android_old, build, .dart_tool folders first).
3. Check pubspec.yaml has `file_picker: ^8.1.7`.
4. Run `prepare_android_windows.bat`
5. Run `flutter analyze`, `flutter test`, `flutter build apk --release`
6. APK: build\app\outputs\flutter-apk\app-release.apk

Name shown under the icon: edit `appName` in tool\prepare_android.dart, run it again, rebuild.
