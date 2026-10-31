# Home Finance 1.0.5 — safety release

## New
- **App Lock** (More → App Lock): 4- or 6-digit PIN, asked at launch and after 60 s in the background. Wrong-PIN delays
  after 5 attempts (kept even if the app is restarted). The PIN is stored hashed in a separate file that is NOT in backups.
  No PIN recovery: uninstall/reinstall + restore a backup if forgotten.
- **Paise shown**: ₹1,200 stays ₹1,200; ₹1,200.50 now shows ₹1,200.50. Amounts are rounded to 2 decimals when saved.
- **Wi-Fi Sync hardening**: host stops after 5 wrong pairing codes or 10 minutes; pairing code compared safely; oversized
  payloads refused; sync refuses to run if the two phones' clocks differ by more than 10 minutes (edit times decide
  conflicts, so a wrong clock could silently lose edits).
- **No more duplicate categories**: if both phones have e.g. "Groceries", sync reuses the local one and re-points incoming
  transactions to it. (Duplicates created by earlier versions are not removed automatically.)
- **Backup failure warning**: if the automatic backup fails, Home shows a banner.
- Unit tests in `test/home_finance_test.dart` (run `flutter test`).

## Not in this version
Encrypted backups, sync preview, private-by-member sync, syncing budgets/recurring entries, dark mode.
Atomic edits: reviewed and left as is — version history is append-only and the data update is a single statement, so a
crash cannot corrupt a transaction; at worst an extra history row is kept.
