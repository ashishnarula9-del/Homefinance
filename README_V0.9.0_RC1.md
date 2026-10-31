# Home Finance v0.9.0 RC1 — Pre-release

This is the release-candidate build based on the stable v0.1.4 feature set.

## Release policy
Feature freeze for v1.0. No major new modules are added in RC1. The purpose of this build is final usability, integrity, upgrade, backup and report verification.

## RC1 changes
- Version raised to 0.9.0+9 / display version 0.9.0 RC1.
- Database schema remains version 3; existing v0.1.4 data is retained when installed over the current app.
- Migrated deprecated DropdownButtonFormField `value:` usage to `initialValue:` for current Flutter compatibility.
- Data & App Info now identifies the app as Pre-release / RC1 and states that data is stored locally on the device.
- Existing v0.1.4 report dependent filters, category management, Home layout, member-wise accounts, six recent transactions, transaction editing, soft deletion and Backup Now remain frozen for release validation.

## Build
From C:\FamilyFinance:

flutter clean
flutter pub get
flutter analyze
flutter build apk --release

Expected APK:
build\app\outputs\flutter-apk\app-release.apk

Install over v0.1.4 without uninstalling so upgrade/data-retention behaviour is tested.
