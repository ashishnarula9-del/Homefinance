# Home Finance 1.0.2 — iPhone / iOS build

The iPhone app uses the same Flutter/Dart application, SQLite schema 5, backup format, Wi-Fi Sync model, reports, and transaction history as Android 1.0.2.

## Prepare on Windows

Extract the source over the Home Finance project and run:

    cd /d C:\FamilyFinance
    prepare_ios_windows.bat
    flutter analyze

Windows cannot compile or sign the final iPhone application. Use Codemagic or another macOS/Xcode environment for the compile/sign step.

## iOS permissions/configuration included

`tool/prepare_ios.dart` configures:

- App display name: Home Finance
- Local Network privacy description for Wi-Fi Sync
- `NSAllowsLocalNetworking` for the direct private-LAN HTTP sync connection
- Optional Google Sign-In client ID and reversed-client-ID URL scheme when supplied through environment variables

For Google Drive, set these environment variables in Codemagic/macOS:

    GOOGLE_IOS_CLIENT_ID
    GOOGLE_IOS_REVERSED_CLIENT_ID

They come from the iOS OAuth client configured in Google Cloud.

## Codemagic

The included `codemagic.yaml` has:

- `ios_unsigned_check` — compile/analyze without signing.
- `ios_testflight` — signed TestFlight template.

Before TestFlight, replace the placeholder bundle identifier `com.example.familyfinance` with the real identifier and configure the App Store Connect integration/signing profiles.

## Backup & Restore on iPhone

The iPhone build supports:

- Local automatic/manual backups
- Local backup browser
- Restore from a backup chosen with the iOS document picker
- Pre-restore safety backup
- Google Drive backup-folder upload and restore
- Android-created backup restore, provided its schema is supported by the installed iPhone app

## Wi-Fi Sync

The existing Host IP + six-digit pairing-code workflow is unchanged. The first local-network access on iPhone should trigger Apple's Local Network permission prompt; choose Allow.

## Version

- App: 1.0.2
- Flutter build: 1.0.2+12
- Database schema: 5
