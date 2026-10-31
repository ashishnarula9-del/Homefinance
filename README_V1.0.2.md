# Home Finance v1.0.2 — Android + iPhone

Version: **1.0.2+12**  
Database schema: **5** (unchanged from v1.0.1)

This release adds the complete Backup & Restore layer for both Android and iPhone while keeping the existing Income, Expense, Transfer, Reports, Wi-Fi Sync, automatic backup, and edited/deleted transaction history features.

## New in v1.0.2

- Backup & Restore screen under More.
- Automatic local daily backup on app launch when due.
- Retains 14 daily, 8 weekly, 6 monthly, 5 Wi-Fi safety, and 5 pre-restore backups.
- Manual Backup Now.
- SHA-256 manifest next to every new backup.
- Local backup browser with validation and counts for users, accounts, and transactions.
- Restore from a local backup or an external `.db` backup file.
- Automatic pre-restore safety backup before any database replacement.
- Restore rollback if the selected backup cannot be opened after replacement.
- Device ID is preserved during restore so Wi-Fi Sync does not create duplicate device identities.
- Device-local Google Drive settings are preserved during restore rather than copied from another phone.
- Google Drive backup-folder connection, upload, retry of pending local backups, Drive backup browser, and restore from Drive.
- Google Drive folder structure:

      Home Finance/
        Backups/
          Automatic/
          Manual/
          Pre-Restore/
          Safety/

- Google Drive stores backup files only; the live SQLite database is never operated directly from Drive.
- Drive retention mirrors the local rotation for automatic/weekly/monthly/safety/pre-restore backups. Manual backups are retained until the user removes them.
- Same backup format on Android and iPhone, allowing Android → Google Drive → iPhone restore and the reverse.

## Important Google Drive setup

The source includes Google Drive support, but Google requires your own OAuth application registration before Sign in with Google can work in a release build.

Enable **Google Drive API** in a Google Cloud project and configure OAuth clients for the Android package/signing certificate and the iOS bundle identifier. Use the Drive scope:

`https://www.googleapis.com/auth/drive.file`

This scope is intentionally limited to files/folders created or opened by Home Finance.

### Android

Keep the same Android application ID used by your existing Home Finance installation so upgrades preserve the installed app/data. Register that package name and the release signing SHA certificate in Google Cloud. Do not change the Android application ID just for Google Drive.

Run:

    prepare_android_windows.bat

This ensures the Android release manifest has internet access and permits the existing private-LAN HTTP connection used by Wi-Fi Sync.

### iPhone

Register the final iOS bundle identifier in Google Cloud. Before running the iOS preparation script in macOS/Codemagic, provide:

- `GOOGLE_IOS_CLIENT_ID`
- `GOOGLE_IOS_REVERSED_CLIENT_ID`

`tool/prepare_ios.dart` places these values into `Info.plist` and also keeps the Local Network permission needed for Wi-Fi Sync.

## Restore safety sequence

1. User selects a backup.
2. App validates that it is a Home Finance SQLite database.
3. App checks the schema is not newer than the installed app.
4. If a SHA-256 manifest is available, the checksum is verified.
5. App displays backup date, type, users, accounts, transactions, size, schema, and checksum status.
6. User confirms restore twice.
7. App creates a pre-restore safety backup of the current database.
8. Current database is closed and replaced.
9. Database is reopened/migrated if required.
10. Current device identity and device-local backup/Drive settings are restored.
11. If reopen fails, the pre-restore safety backup is automatically put back.

## Android build

Extract over the existing `C:\FamilyFinance` project and run:

    cd /d C:\FamilyFinance
    prepare_android_windows.bat
    flutter clean
    flutter pub get
    flutter analyze
    flutter build apk --release

Install over v1.0.1 without uninstalling.

## iPhone build

On Windows you can prepare/analyze the source, but Apple requires macOS/Xcode for the actual iOS compile/signing. The included `codemagic.yaml` contains an unsigned compile-check workflow and a TestFlight workflow template.

See `README_IOS_BUILD.md` and `GOOGLE_DRIVE_SETUP.md` before enabling Google Drive in TestFlight.
