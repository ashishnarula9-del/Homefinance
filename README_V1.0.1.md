# Home Finance v1.0.1

Maintenance/final release update adding transaction change visibility and immutable history.

## Added
- Edited transactions are highlighted in light amber/orange and marked EDITED.
- Deleted transactions remain visible in the full Transactions screen, highlighted in light red and marked DELETED.
- Deleted transactions remain excluded from balances, Home totals, recent active Home transactions, and reports.
- Before every edit or delete, the complete transaction row is copied to `transaction_versions`.
- `View original / history` displays the original transaction and later preserved versions.
- Linked transfers preserve both sides before edit/delete.
- Transaction history is included in same-Wi-Fi synchronization.
- Database schema upgraded from 4 to 5 without replacing the existing database.

## Version
- App: 1.0.1+11
- Database schema: 5
