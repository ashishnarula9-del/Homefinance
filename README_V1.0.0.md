# Home Finance v1.0.0 Final

Final release source based on the stable v0.9.0 RC1 ledger.

## Added in v1.0.0

### Wi-Fi Sync
- Two-way sync between two phones on the same Wi-Fi network.
- One phone starts **Host Sync** and displays its local IP plus a temporary 6-digit pairing code.
- The other phone enters that IP/code and taps **Sync Now**.
- Uses UUID record IDs and latest-edit timestamps to merge users, accounts, categories and transactions.
- Soft-deleted transactions synchronize.
- Tombstones synchronize deletions of unused users/accounts/categories.
- A new/pristine installation discards its seed Primary User/Cash/default-category data before its first sync so it can receive the existing household history cleanly.
- A local safety backup is made before sync.
- Wi-Fi sync does not require a cloud account and does not perform broker/order functions.

### Automatic backup
- Enabled by default.
- Runs when the app opens if the previous automatic backup is at least 20 hours old.
- Keeps the latest 14 automatic local backups.
- Keeps the latest 5 pre-sync safety backups.
- Manual **Backup Now** remains available and opens the Android share sheet.
- Automatic backup can be disabled/re-enabled from **More > Data & App Info**.

## Database
- App version: 1.0.0+10
- Database schema: 4
- Existing v0.1.x / v0.9.0 data is migrated in place.
- Database filename is intentionally unchanged: `family_finance_v01_rebuild.db`.

## Android build
Copy/extract this package over the existing `C:\FamilyFinance` Flutter project. The included AndroidManifest adds the permissions needed for same-Wi-Fi synchronization.

Run:

    cd /d C:\FamilyFinance
    flutter clean
    flutter pub get
    flutter analyze
    flutter build apk --release

APK output:

    C:\FamilyFinance\build\app\outputs\flutter-apk\app-release.apk

Install it over the previous Home Finance build. Do not uninstall first if you want to preserve the existing database.

## Wi-Fi sync use
1. Install v1.0.0 on both phones.
2. Connect both phones to the same Wi-Fi.
3. On the phone containing the main/current data: More > Wi-Fi Sync > Start Host Sync.
4. Note the Host IP and 6-digit pairing code.
5. On the other phone: enter Host IP and pairing code > Sync Now.
6. Wait for “Sync complete”.
7. Stop Host when finished.

For the first production sync, keep a manual backup from the main phone before starting.
