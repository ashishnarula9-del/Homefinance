# Free iPhone build (no paid service for building)

Home Finance is already a Flutter app, so the iPhone app is the *same code*. Windows can't build iOS, so a free macOS
machine on GitHub does it for you.

## Steps
1. Create a free GitHub account and a **new repository** (public repos get free macOS build minutes; private repos get a
   limited free allowance). Upload this whole folder (including `.github`).
2. Edit `BUNDLE_ORG` at the top of `.github/workflows/ios_unsigned_ipa.yml` to something unique (e.g. `com.yourname`).
3. Repository → **Actions → Build unsigned iPhone IPA → Run workflow**. After ~10–20 min download `HomeFinance_unsigned_ipa`.
4. On Windows install **iTunes and iCloud from apple.com** (not the Store versions) and **Sideloadly** (free).
   Plug in the iPhone, drag in the `.ipa`, sign in with your free Apple ID, press Start.
5. iPhone: Settings → General → VPN & Device Management → trust your Apple ID. Enable Developer Mode if asked.

## Limits you can't avoid without paying Apple
- Free Apple ID apps **expire after 7 days**; re-run Sideloadly to refresh (your data stays). Max 3 sideloaded apps.
- TestFlight / App Store need the paid Apple Developer Program (US$99/year). That is the only paid piece, and it's optional.
- Google Drive sign-in on iPhone needs the iOS OAuth client to match the *final* bundle ID. Sideloadly may append a suffix
  to the bundle ID for free accounts; if Drive sign-in fails, register the ID shown in Sideloadly, or just use the
  zero-setup route: **Backup Now → Share → Save to Files** (iCloud Drive / On My iPhone).
- I could not compile iOS here, so the first run may need small fixes; send me the Actions log if it fails.
