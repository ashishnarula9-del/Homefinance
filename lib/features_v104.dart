part of 'main.dart';

// ---------------------------------------------------------------------------
// Home Finance 1.0.4 features. Kept in one file (a "part" of main.dart) so it
// shares the app's helpers. No database schema change: budgets and recurring
// rules are stored as JSON in app_meta, so they travel inside every backup.
// They are NOT part of Wi-Fi Sync (which merges database tables only).
// ---------------------------------------------------------------------------

// ============================== Data layer ==================================

extension AppDbFeatures on AppDb {
  /// Search/filter transactions. [text] matches note, category, member,
  /// account or amount.
  Future<List<Map<String, dynamic>>> searchTransactions({
    String text = '',
    String? purpose,
    String? userId,
    bool includeDeleted = true,
    int limit = 500,
  }) {
    final where = <String>[];
    final args = <Object?>[];
    if (!includeDeleted) where.add('t.is_deleted=0');
    if (purpose != null) {
      where.add('t.purpose=?');
      args.add(purpose);
    }
    if (userId != null) {
      where.add('t.user_id=?');
      args.add(userId);
    }
    final q = text.trim();
    if (q.isNotEmpty) {
      final like = '%$q%';
      where.add(
        "(COALESCE(t.notes,'') LIKE ? OR COALESCE(c.name,'') LIKE ? OR COALESCE(u.name,'') LIKE ? "
        "OR COALESCE(a.name,'') LIKE ? OR CAST(ABS(t.amount) AS TEXT) LIKE ?)",
      );
      args.addAll([like, like, like, like, like]);
    }
    final whereSql = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
    return db.rawQuery('''
      SELECT t.*, a.name account_name, u.name user_name, c.name category_name
      FROM transactions t
      LEFT JOIN accounts a ON a.id=t.account_id
      LEFT JOIN users u ON u.id=t.user_id
      LEFT JOIN categories c ON c.id=t.category_id
      $whereSql
      ORDER BY t.txn_date DESC, t.created_at DESC
      LIMIT ?
    ''', [...args, limit]);
  }

  // ------------------------------ Budgets ----------------------------------

  Future<Map<String, double>> loadBudgets() async {
    try {
      final raw = await meta('budgets_json');
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final result = <String, double>{};
      decoded.forEach((key, value) {
        if (value is num && value > 0) result[key.toString()] = value.toDouble();
      });
      return result;
    } catch (_) {
      return {};
    }
  }

  Future<void> saveBudgets(Map<String, double> budgets) async {
    await setMeta('budgets_json', jsonEncode(budgets));
  }

  /// Expense spent per category id within the month of [month].
  Future<Map<String, double>> monthlyExpenseByCategory(DateTime month) async {
    final from = DateTime(month.year, month.month, 1);
    final to = DateTime(month.year, month.month + 1, 1);
    final rows = await db.rawQuery('''
      SELECT category_id, SUM(amount) total
      FROM transactions
      WHERE is_deleted=0 AND purpose='expense' AND category_id IS NOT NULL
        AND txn_date>=? AND txn_date<?
      GROUP BY category_id
    ''', [from.toIso8601String(), to.toIso8601String()]);
    final result = <String, double>{};
    for (final row in rows) {
      final id = row['category_id']?.toString();
      if (id == null) continue;
      result[id] = ((row['total'] as num?)?.toDouble() ?? 0).abs();
    }
    return result;
  }

  // ------------------------------ Recurring --------------------------------

  Future<List<Map<String, dynamic>>> loadRecurring() async {
    try {
      final raw = await meta('recurring_json');
      if (raw == null || raw.isEmpty) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveRecurring(List<Map<String, dynamic>> items) async {
    await setMeta('recurring_json', jsonEncode(items));
  }

  /// Posts every recurring entry that is due (today or earlier). Returns how
  /// many transactions were created. Safe to call often.
  Future<int> processRecurringDue() async {
    final items = await loadRecurring();
    if (items.isEmpty) return 0;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    var created = 0;
    for (final item in items) {
      if (item['active'] != true) continue;
      final parsedDue = DateTime.tryParse(item['next_due']?.toString() ?? '');
      if (parsedDue == null) continue;
      DateTime due = parsedDue;
      final userId = item['user_id']?.toString() ?? '';
      final accountId = item['account_id']?.toString() ?? '';
      final account = await db.query(
        'accounts',
        where: 'id=? AND is_active=1',
        whereArgs: [accountId],
        limit: 1,
      );
      if (userId.isEmpty || account.isEmpty) continue; // wait until account is active again
      var guard = 0;
      while (!due.isAfter(today) && guard < 24) {
        try {
          final note = (item['notes']?.toString() ?? '').trim();
          await addTxn(
            userId: userId,
            accountId: accountId,
            purpose: item['kind']?.toString() == 'income' ? 'income' : 'expense',
            amount: (item['amount'] as num).toDouble(),
            categoryId: item['category_id']?.toString(),
            notes: note.isEmpty ? '(Recurring)' : '(Recurring) $note',
            date: due,
          );
          created++;
        } catch (_) {
          break;
        }
        due = nextRecurringDate(due, item);
        item['next_due'] = due.toIso8601String();
        // Save after every posting so a crash can never post the same entry twice.
        await saveRecurring(items);
        guard++;
      }
    }
    return created;
  }

  // --------------------------- Backup health -------------------------------

  /// Returns a warning message, or null when backups look healthy.
  Future<String?> backupHealthMessage() async {
    final txnCount = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM transactions')) ?? 0;
    if (txnCount == 0) return null;
    final backupError = await meta('last_backup_error');
    if (backupError != null && backupError.isNotEmpty) {
      return 'The automatic backup on this phone failed (possibly low storage). Tap to open Backup & Restore.';
    }
    final driveOn = (await meta('gdrive_backup_enabled')) == '1';
    final err = await meta('gdrive_last_error');
    if (driveOn && err != null && err.isNotEmpty) {
      return 'Google Drive backup has a problem. Tap to see details.';
    }
    DateTime? latest;
    for (final key in const ['last_gdrive_backup', 'last_shared_backup']) {
      final d = DateTime.tryParse((await meta(key)) ?? '');
      if (d != null && (latest == null || d.isAfter(latest))) latest = d;
    }
    if (latest == null) {
      return 'Your data is only backed up on this phone. Tap to connect Google Drive or save a backup to Files.';
    }
    final days = DateTime.now().difference(latest).inDays;
    if (days >= 7) {
      return 'No backup outside this phone for $days days. Tap to back up now.';
    }
    return null;
  }
}

DateTime nextRecurringDate(DateTime from, Map<String, dynamic> item) {
  final frequency = item['frequency']?.toString() ?? 'monthly';
  if (frequency == 'weekly') {
    return DateTime(from.year, from.month, from.day + 7);
  }
  final wantedDay = (item['day'] as num?)?.toInt() ?? from.day;
  final lastDayOfNextMonth = DateTime(from.year, from.month + 2, 0).day;
  final day = wantedDay > lastDayOfNextMonth ? lastDayOfNextMonth : wantedDay;
  return DateTime(from.year, from.month + 1, day);
}

// ============================== CSV export ==================================

class CsvExport {
  static String _cell(Object? value) {
    final s = (value ?? '').toString();
    if (s.contains(',') || s.contains('"') || s.contains('\n') || s.contains('\r')) {
      return '"${s.replaceAll('"', '""')}"';
    }
    return s;
  }

  static Future<void> share(List<Map<String, dynamic>> rows, String label) async {
    final buffer = StringBuffer('\uFEFF'); // BOM so Excel reads rupee/Unicode text correctly
    void line(List<Object?> cells) => buffer.write('${cells.map(_cell).join(',')}\r\n');
    line(['Date', 'Member', 'Account', 'Type', 'Category', 'Amount', 'Notes', 'Status', 'Transaction ID', 'Linked Transfer ID']);
    for (final r in rows) {
      final purpose = r['purpose']?.toString() ?? '';
      final type = purpose == 'transfer'
          ? (r['type'] == 'transfer_in' ? 'Transfer In' : 'Transfer Out')
          : (purpose == 'income' ? 'Income' : 'Expense');
      final dateText = r['txn_date']?.toString() ?? '';
      final deleted = (r['is_deleted'] as num?)?.toInt() == 1;
      final edited = ((r['edit_count'] as num?)?.toInt() ?? 0) > 0;
      line([
        dateText.length >= 10 ? dateText.substring(0, 10) : dateText,
        r['user_name'],
        r['account_name'],
        type,
        r['category_name'],
        ((r['amount'] as num?)?.toDouble() ?? 0).toStringAsFixed(2),
        r['notes'],
        deleted ? 'Deleted' : (edited ? 'Edited' : 'Active'),
        r['id'],
        r['linked_id'],
      ]);
    }
    final dir = await getTemporaryDirectory();
    final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final file = File(p.join(dir.path, 'home_finance_${label}_$stamp.csv'));
    await file.writeAsString(buffer.toString(), flush: true);
    await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path)], text: 'Home Finance CSV export'),
    );
  }
}

// ============================ Transactions page =============================

class TransactionsPage extends StatefulWidget {
  const TransactionsPage({super.key});

  @override
  State<TransactionsPage> createState() => _TransactionsPageState();
}

class _TransactionsPageState extends State<TransactionsPage> {
  final TextEditingController _searchCtl = TextEditingController();
  Timer? _debounce;
  String _text = '';
  String? _purpose;
  String? _userId;
  bool _showDeleted = true;
  List<Map<String, dynamic>> _users = [];

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtl.dispose();
    super.dispose();
  }

  Future<void> _loadUsers() async {
    final list = await AppDb.instance.users(activeOnly: false);
    if (!mounted) return;
    setState(() => _users = list);
  }

  Future<List<Map<String, dynamic>>> _query({int limit = 500}) {
    return AppDb.instance.searchTransactions(
      text: _text,
      purpose: _purpose,
      userId: _userId,
      includeDeleted: _showDeleted,
      limit: limit,
    );
  }

  bool get _filtering => _text.isNotEmpty || _purpose != null || _userId != null;

  Widget _typeChip(String label, String? value) {
    return ChoiceChip(
      label: Text(label),
      selected: _purpose == value,
      onSelected: (_) => setState(() => _purpose = value),
    );
  }

  Future<void> _exportCsv() async {
    try {
      final rows = await _query(limit: 100000);
      if (rows.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Nothing to export.')));
        }
        return;
      }
      await CsvExport.share(rows, 'transactions');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_cleanError(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Transactions'),
        actions: [
          IconButton(
            tooltip: 'Export shown transactions as CSV',
            icon: const Icon(Icons.file_download_outlined),
            onPressed: _exportCsv,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              controller: _searchCtl,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: 'Search note, category, member, account, amount',
                isDense: true,
                suffixIcon: _text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchCtl.clear();
                          setState(() => _text = '');
                        },
                      ),
              ),
              onChanged: (value) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 300), () {
                  if (mounted) setState(() => _text = value.trim());
                });
              },
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                _typeChip('All', null),
                const SizedBox(width: 8),
                _typeChip('Income', 'income'),
                const SizedBox(width: 8),
                _typeChip('Expense', 'expense'),
                const SizedBox(width: 8),
                _typeChip('Transfer', 'transfer'),
                const SizedBox(width: 12),
                DropdownButton<String?>(
                  value: _userId,
                  underline: const SizedBox.shrink(),
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('All members')),
                    for (final u in _users)
                      DropdownMenuItem<String?>(
                        value: u['id'].toString(),
                        child: Text(u['name'].toString()),
                      ),
                  ],
                  onChanged: (value) => setState(() => _userId = value),
                ),
                const SizedBox(width: 12),
                FilterChip(
                  label: const Text('Show deleted'),
                  selected: _showDeleted,
                  onSelected: (value) => setState(() => _showDeleted = value),
                ),
              ],
            ),
          ),
          Expanded(
            child: ValueListenableBuilder<int>(
              valueListenable: dataRevision,
              builder: (context, _, __) {
                return FutureBuilder<List<Map<String, dynamic>>>(
                  future: _query(),
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return Center(child: Text(_cleanError(snapshot.error!)));
                    }
                    if (!snapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final rows = snapshot.data!;
                    if (rows.isEmpty) {
                      return Center(
                        child: Text(_filtering ? 'No matching transactions.' : 'No transactions yet.'),
                      );
                    }
                    return ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
                      itemCount: rows.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final row = rows[index];
                        final deleted = (row['is_deleted'] as num?)?.toInt() == 1;
                        return TransactionTile(
                          row: row,
                          showMenu: true,
                          onEdit: deleted ? null : () => showEditTransactionSheet(context, row),
                          onDelete: deleted ? null : () => _confirmDelete(context, row),
                          onHistory: () => showTransactionHistory(context, row),
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, Map<String, dynamic> row) async {
    final linked = row['linked_id'] != null;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(linked ? 'Delete transfer?' : 'Delete transaction?'),
        content: Text(
          linked
              ? 'Both sides of this linked transfer will be removed from active reports. History is retained internally.'
              : 'This transaction will be soft-deleted. History is retained internally.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) {
      await AppDb.instance.softDeleteTransaction(row['id'] as String);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Deleted.')));
      }
    }
  }
}

// ============================ Home widgets ==================================

class BackupHealthBanner extends StatelessWidget {
  const BackupHealthBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: dataRevision,
      builder: (context, _, __) {
        return FutureBuilder<String?>(
          future: AppDb.instance.backupHealthMessage(),
          builder: (context, snapshot) {
            final message = snapshot.data;
            if (message == null) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Material(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const DataInfoPage()),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Icon(Icons.warning_amber_rounded, color: Colors.orange.shade800),
                        const SizedBox(width: 10),
                        Expanded(child: Text(message, style: const TextStyle(fontSize: 13))),
                        const Icon(Icons.chevron_right),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _BudgetLine {
  const _BudgetLine(this.name, this.limit, this.spent);
  final String name;
  final double limit;
  final double spent;
  double get ratio => limit > 0 ? spent / limit : 0;
}

class HomeBudgetCard extends StatelessWidget {
  const HomeBudgetCard({super.key});

  Future<List<_BudgetLine>> _loadLines() async {
    final budgets = await AppDb.instance.loadBudgets();
    if (budgets.isEmpty) return const <_BudgetLine>[];
    final spent = await AppDb.instance.monthlyExpenseByCategory(DateTime.now());
    final cats = await AppDb.instance.categories('expense', activeOnly: false);
    final names = <String, String>{
      for (final c in cats) c['id'].toString(): c['name'].toString(),
    };
    final lines = <_BudgetLine>[];
    budgets.forEach((id, limit) {
      lines.add(_BudgetLine(names[id] ?? 'Category', limit, spent[id] ?? 0));
    });
    lines.sort((a, b) => b.ratio.compareTo(a.ratio));
    return lines;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: dataRevision,
      builder: (context, _, __) {
        return FutureBuilder<List<_BudgetLine>>(
          future: _loadLines(),
          builder: (context, snapshot) {
            final lines = snapshot.data ?? const <_BudgetLine>[];
            if (lines.isEmpty) return const SizedBox.shrink();
            final shown = lines.take(4).toList();
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Card(
                color: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: const BorderSide(color: Colors.black12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Budgets this month',
                              style: TextStyle(fontWeight: FontWeight.w800),
                            ),
                          ),
                          TextButton(
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => const BudgetsPage()),
                            ),
                            child: const Text('Manage'),
                          ),
                        ],
                      ),
                      for (final line in shown) ...[
                        Row(
                          children: [
                            Expanded(child: Text(line.name)),
                            Text(
                              '${money.format(line.spent)} / ${money.format(line.limit)}',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: line.ratio >= 1 ? Colors.red.shade700 : Colors.black87,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        LinearProgressIndicator(
                          value: line.ratio.clamp(0.0, 1.0).toDouble(),
                          minHeight: 7,
                          borderRadius: BorderRadius.circular(6),
                          color: line.ratio >= 1
                              ? Colors.red
                              : (line.ratio >= 0.8 ? Colors.orange : const Color(0xFF168A49)),
                          backgroundColor: Colors.black12,
                        ),
                        const SizedBox(height: 10),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// ============================== Budgets page ================================

class BudgetsPage extends StatefulWidget {
  const BudgetsPage({super.key});

  @override
  State<BudgetsPage> createState() => _BudgetsPageState();
}

class _BudgetsPageState extends State<BudgetsPage> {
  List<Map<String, dynamic>> categories = [];
  Map<String, double> budgets = {};
  Map<String, double> spent = {};
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cats = await AppDb.instance.categories('expense');
    final b = await AppDb.instance.loadBudgets();
    final s = await AppDb.instance.monthlyExpenseByCategory(DateTime.now());
    if (!mounted) return;
    setState(() {
      categories = cats;
      budgets = b;
      spent = s;
      loading = false;
    });
  }

  Future<void> _edit(Map<String, dynamic> category) async {
    final id = category['id'].toString();
    final current = budgets[id];
    final controller = TextEditingController(
      text: current == null ? '' : current.toStringAsFixed(current % 1 == 0 ? 0 : 2),
    );
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Monthly budget: ${category['name']}'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Amount per month', prefixText: '₹ '),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, 'cancel'), child: const Text('Cancel')),
          if (current != null)
            TextButton(onPressed: () => Navigator.pop(dialogContext, 'remove'), child: const Text('Remove')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, 'save'), child: const Text('Save')),
        ],
      ),
    );
    final text = controller.text.trim().replaceAll(',', '');
    if (action == 'remove') {
      budgets.remove(id);
    } else if (action == 'save') {
      final value = double.tryParse(text);
      if (value == null || value <= 0) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Enter an amount greater than zero.')),
          );
        }
        return;
      }
      budgets[id] = value;
    } else {
      return;
    }
    await AppDb.instance.saveBudgets(budgets);
    dataRevision.value++;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Monthly Budgets')),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : categories.isEmpty
              ? const Center(child: Text('Add expense categories first.'))
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
                  itemCount: categories.length + 1,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return const Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: Text(
                          'Tap a category to set a monthly limit. Budgets reset each calendar month. '
                          'They are saved on this phone and inside its backups (not sent by Wi-Fi Sync).',
                        ),
                      );
                    }
                    final cat = categories[index - 1];
                    final id = cat['id'].toString();
                    final limit = budgets[id];
                    final used = spent[id] ?? 0;
                    return ListTile(
                      title: Text(cat['name'].toString()),
                      subtitle: Text(
                        limit == null
                            ? 'No budget'
                            : '${money.format(used)} of ${money.format(limit)} this month',
                      ),
                      trailing: const Icon(Icons.edit_outlined),
                      onTap: () => _edit(cat),
                    );
                  },
                ),
    );
  }
}

// ============================ Recurring page ================================

class RecurringPage extends StatefulWidget {
  const RecurringPage({super.key});

  @override
  State<RecurringPage> createState() => _RecurringPageState();
}

class _RecurringPageState extends State<RecurringPage> {
  List<Map<String, dynamic>> items = [];
  Map<String, String> categoryNames = {};
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await AppDb.instance.loadRecurring();
    final names = <String, String>{};
    for (final kind in const ['income', 'expense']) {
      for (final c in await AppDb.instance.categories(kind, activeOnly: false)) {
        names[c['id'].toString()] = c['name'].toString();
      }
    }
    if (!mounted) return;
    setState(() {
      items = list;
      categoryNames = names;
      loading = false;
    });
  }

  Future<void> _save() => AppDb.instance.saveRecurring(items);

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _add() async {
    final users = await AppDb.instance.users();
    final accounts = await AppDb.instance.accounts();
    if (users.isEmpty || accounts.isEmpty) {
      _snack('Add a member and an account first.');
      return;
    }
    final cats = <String, List<Map<String, dynamic>>>{
      'expense': await AppDb.instance.categories('expense'),
      'income': await AppDb.instance.categories('income'),
    };
    if (!mounted) return;

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    var kind = 'expense';
    var userId = users.first['id'].toString();
    String? accountId;
    String? categoryId;
    var frequency = 'monthly';
    var start = today;
    String? error;
    final amountCtl = TextEditingController();
    final notesCtl = TextEditingController();

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final userAccounts = accounts.where((a) => a['user_id'].toString() == userId).toList();
          if (accountId == null || !userAccounts.any((a) => a['id'].toString() == accountId)) {
            accountId = userAccounts.isEmpty ? null : userAccounts.first['id'].toString();
          }
          final catList = cats[kind] ?? const <Map<String, dynamic>>[];
          if (categoryId != null && !catList.any((c) => c['id'].toString() == categoryId)) {
            categoryId = null;
          }
          return AlertDialog(
            title: const Text('New recurring entry'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: kind,
                    decoration: const InputDecoration(labelText: 'Type'),
                    items: const [
                      DropdownMenuItem(value: 'expense', child: Text('Expense')),
                      DropdownMenuItem(value: 'income', child: Text('Income')),
                    ],
                    onChanged: (v) {
                      if (v != null) setLocal(() => kind = v);
                    },
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: amountCtl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(labelText: 'Amount', prefixText: '₹ ', errorText: error),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: userId,
                    decoration: const InputDecoration(labelText: 'Member'),
                    items: [
                      for (final u in users)
                        DropdownMenuItem(value: u['id'].toString(), child: Text(u['name'].toString())),
                    ],
                    onChanged: (v) {
                      if (v != null) setLocal(() => userId = v);
                    },
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    key: ValueKey('account-$userId'),
                    initialValue: accountId,
                    decoration: const InputDecoration(labelText: 'Account'),
                    items: [
                      for (final a in userAccounts)
                        DropdownMenuItem(value: a['id'].toString(), child: Text(a['name'].toString())),
                    ],
                    onChanged: (v) => setLocal(() => accountId = v),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    key: ValueKey('category-$kind'),
                    initialValue: categoryId,
                    decoration: const InputDecoration(labelText: 'Category (optional)'),
                    items: [
                      for (final c in catList)
                        DropdownMenuItem(value: c['id'].toString(), child: Text(c['name'].toString())),
                    ],
                    onChanged: (v) => setLocal(() => categoryId = v),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: frequency,
                    decoration: const InputDecoration(labelText: 'Repeats'),
                    items: const [
                      DropdownMenuItem(value: 'monthly', child: Text('Every month')),
                      DropdownMenuItem(value: 'weekly', child: Text('Every week')),
                    ],
                    onChanged: (v) {
                      if (v != null) setLocal(() => frequency = v);
                    },
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.event),
                    label: Text('First date: ${DateFormat('dd MMM yyyy').format(start)}'),
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: ctx,
                        initialDate: start,
                        firstDate: today,
                        lastDate: today.add(const Duration(days: 365 * 3)),
                      );
                      if (picked != null) setLocal(() => start = picked);
                    },
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: notesCtl,
                    decoration: const InputDecoration(labelText: 'Note (optional)'),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
              FilledButton(
                onPressed: () {
                  final amount = double.tryParse(amountCtl.text.trim().replaceAll(',', ''));
                  if (amount == null || amount <= 0) {
                    setLocal(() => error = 'Enter an amount greater than zero');
                    return;
                  }
                  if (accountId == null) {
                    setLocal(() => error = 'This member has no active account');
                    return;
                  }
                  Navigator.pop(dialogContext, <String, dynamic>{
                    'id': uuid.v4(),
                    'kind': kind,
                    'amount': amount,
                    'user_id': userId,
                    'account_id': accountId,
                    'category_id': categoryId,
                    'notes': notesCtl.text.trim(),
                    'frequency': frequency,
                    'day': start.day,
                    'next_due': DateTime(start.year, start.month, start.day).toIso8601String(),
                    'active': true,
                  });
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
    if (result == null) return;
    items.add(result);
    await _save();
    final created = await AppDb.instance.processRecurringDue();
    if (created > 0) _snack('Posted $created entry now.');
    await _load();
  }

  Future<void> _delete(int index) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete recurring entry?'),
        content: const Text('Entries already posted stay in your transactions. Only future postings stop.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    items.removeAt(index);
    await _save();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Recurring Entries')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('Add'),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
              children: [
                const Text(
                  'Entries post automatically when you open the app on or after the due date. '
                  'Use this on ONE phone only, otherwise Wi-Fi Sync would show duplicates.',
                ),
                const SizedBox(height: 8),
                if (items.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 40),
                    child: Center(child: Text('No recurring entries yet.')),
                  ),
                for (var i = 0; i < items.length; i++) _tile(i),
              ],
            ),
    );
  }

  Widget _tile(int index) {
    final item = items[index];
    final isIncome = item['kind'] == 'income';
    final amount = (item['amount'] as num?)?.toDouble() ?? 0;
    final category = categoryNames[item['category_id']?.toString() ?? ''];
    final due = DateTime.tryParse(item['next_due']?.toString() ?? '');
    final note = (item['notes']?.toString() ?? '').trim();
    final title = [isIncome ? 'Income' : 'Expense', if (category != null) category, if (note.isNotEmpty) note].join(' • ');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text('${money.format(amount)}  $title'),
      subtitle: Text(
        '${item['frequency'] == 'weekly' ? 'Weekly' : 'Monthly'} • next ${due == null ? '-' : DateFormat('dd MMM yyyy').format(due)}',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            value: item['active'] == true,
            onChanged: (v) async {
              item['active'] = v;
              await _save();
              if (v) await AppDb.instance.processRecurringDue();
              await _load();
            },
          ),
          IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _delete(index)),
        ],
      ),
    );
  }
}
