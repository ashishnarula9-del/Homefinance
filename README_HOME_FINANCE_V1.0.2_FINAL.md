# Home Finance v1.0.2 Final — Android + iPhone

This is the frozen cross-platform Home Finance release source. It uses the existing database filename and schema version 5 so upgrades preserve data from earlier Family Finance/Home Finance builds.

## Frozen branding
- Visible app name: **Home Finance**
- Approved app icon: Option 4 — green circular house, rupee symbol, family silhouettes
- Android/iOS launcher icons are generated from `assets/app_icon.png`.
- Internal package/bundle identity is intentionally not renamed by this package.

## Frozen home design
- Home Finance header and approved logo
- Period selector: Today / Week / Month / Year
- Total Balance overview
- Income, Expense and Net summary cards
- Quick actions: Income / Expense / Transfer
- Member-wise Cash account cards
- Recent Transactions limited to six with View All
- Member-wise Accounts and Shared Accounts
- Backup & Sync protection entry

## Reports
Existing detailed filters, PDF/XLSX export and date presets are retained. A compact **Expense by Category** insight has been added to match the approved visual direction.

## Data safety and sync
- Edited/deleted transaction history preserved
- Local automatic/manual backup and restore
- Pre-restore safety backup and validation
- Google Drive backup-folder sync
- Same-Wi-Fi live data sync
- Google Drive is backup transport only, not live database sync

## Android preparation on Windows
```bat
cd /d C:\FamilyFinance
prepare_android_windows.bat
flutter analyze
flutter build apk --release
```

`prepare_android_windows.bat` preserves the Android application identity, sets the display name to Home Finance, applies network settings and generates the approved launcher icon.

## iPhone preparation
Run `prepare_ios_windows.bat` to create/configure iOS project files. A signed iPhone/TestFlight build still requires macOS/Xcode or the included Codemagic workflow. Google iOS client credentials must be supplied for Google Drive sign-in.
