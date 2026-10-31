# Google Drive Setup — Home Finance 1.0.3 (free)

Google Drive backup is optional and free. Local backups work without it.

## The 4 things that most often break Drive backup

1. **Wrong signing key (most common).** The Android OAuth client in Google Cloud must contain the SHA-1 of the key that
   signed the APK on your phone. `flutter build apk --release` signs with the *debug* key unless you set up a release
   keystore. Register the SHA-1 of whichever key you really use (register both if unsure).
   - Debug key SHA-1 (Windows, Command Prompt):
     `keytool -list -v -keystore "%USERPROFILE%\.android\debug.keystore" -alias androiddebugkey -storepass android -keypass android`
   - Your own keystore: `keytool -list -v -keystore your.jks -alias youralias`
   - Package name must equal `applicationId` in `android/app/build.gradle(.kts)`.
2. **OAuth consent screen left in "Testing".** In Testing mode only listed *Test users* can sign in and Google expires the
   sign-in after about 7 days, so backups work for a week and then stop. Fix: Google Cloud → APIs & Services → OAuth consent
   screen → add your Google account(s) as Test users **and/or** click **Publish app** (the `drive.file` scope is
   non-sensitive, so no Google review is needed for personal use).
3. **Drive API not enabled** in the same Google Cloud project (APIs & Services → Library → Google Drive API → Enable).
4. **Drive permission box unticked** on the Google consent screen. Disconnect, reconnect and tick it.

Do not put client secrets in the code. Mobile OAuth clients don't use one.

## iPhone
Create an **iOS** OAuth client using your final bundle identifier, then add two GitHub (or Codemagic) secrets:
`GOOGLE_IOS_CLIENT_ID` and `GOOGLE_IOS_REVERSED_CLIENT_ID`.

## What changed in 1.0.3
- Errors are no longer swallowed: **More → Backup & Restore** shows "Last Google Drive problem: …" in red.
- "Sync Backup Folder Now" only says "up to date" when it truly was; an expired sign-in now gives a clear message.
- "Connected" is saved only after Drive access is proven (folders created).
- Backups are also checked when you return to the app, not only on a cold start.

## Folders created
Home Finance / Backups / Automatic, Manual, Pre-Restore, Safety.
With the `drive.file` scope the app only sees files it created. If you change the OAuth client/signing key, it won't see old
backups made under the previous one (they remain in your Drive, just invisible to the app).
