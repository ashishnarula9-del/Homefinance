import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:excel/excel.dart' as xl;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

part 'features_v104.dart';
part 'features_v105.dart';

const appVersion = '1.0.5';
const databaseSchemaVersion = 5;
const uuid = Uuid();
const money = _MoneyFormat();
final dataRevision = ValueNotifier<int>(0);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppDb.instance.init();
  final autoFile = await AppDb.instance.autoBackupIfDue();
  try {
    await AppDb.instance.processRecurringDue();
  } catch (_) {}
  await AppLock.instance.load();
  runApp(const FamilyFinanceApp());
  unawaited(DriveBackupService.instance.syncAfterLaunch(autoFile));
}

class FamilyFinanceApp extends StatelessWidget {
  const FamilyFinanceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Home Finance',
      builder: (context, child) => AppLockGate(child: child ?? const SizedBox.shrink()),
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF168A49)),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF7F9FC),
        cardTheme: const CardThemeData(elevation: 0, margin: EdgeInsets.zero),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
      ),
      home: const Shell(),
    );
  }
}

class AppDb {
  AppDb._();
  static final instance = AppDb._();

  Database? _db;
  String? _dbPath;
  String _deviceId = '';
  String get deviceId => _deviceId;
  Database get db => _db!;
  String get dbPath => _dbPath!;

  Future<void> init() async {
    _dbPath = p.join(await getDatabasesPath(), 'family_finance_v01_rebuild.db');
    _db = await openDatabase(
      _dbPath!,
      version: databaseSchemaVersion,
      onConfigure: (d) async => d.execute('PRAGMA foreign_keys = ON'),
      onCreate: _createSchema,
      onUpgrade: _upgradeSchema,
      onOpen: (d) async {
        await d.execute(
          'CREATE TABLE IF NOT EXISTS app_meta(key TEXT PRIMARY KEY,value TEXT)',
        );
        await d.insert(
          'app_meta',
          {'key': 'schema_version', 'value': '$databaseSchemaVersion'},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      },
    );
    final existingDevice = await db.query('app_meta', where: 'key=?', whereArgs: ['device_id']);
    if (existingDevice.isEmpty || (existingDevice.first['value']?.toString().isEmpty ?? true)) {
      _deviceId = uuid.v4();
      await db.insert('app_meta', {'key': 'device_id', 'value': _deviceId}, conflictAlgorithm: ConflictAlgorithm.replace);
    } else {
      _deviceId = existingDevice.first['value'].toString();
    }
  }

  Future<void> _createSchema(Database d, int version) async {
    await d.execute('''
      CREATE TABLE users(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        is_active INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await d.execute('''
      CREATE TABLE accounts(
        id TEXT PRIMARY KEY,
        user_id TEXT,
        name TEXT NOT NULL,
        type TEXT NOT NULL,
        opening_balance REAL NOT NULL DEFAULT 0,
        opening_date TEXT NOT NULL,
        is_shared INTEGER NOT NULL DEFAULT 0,
        is_active INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY(user_id) REFERENCES users(id)
      )
    ''');
    await d.execute('''
      CREATE TABLE categories(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        kind TEXT NOT NULL,
        parent_id TEXT,
        is_active INTEGER NOT NULL DEFAULT 1,
        updated_at TEXT NOT NULL
      )
    ''');
    await d.execute('''
      CREATE TABLE transactions(
        id TEXT PRIMARY KEY,
        linked_id TEXT,
        user_id TEXT,
        account_id TEXT,
        type TEXT NOT NULL,
        purpose TEXT NOT NULL,
        amount REAL NOT NULL,
        category_id TEXT,
        expense_for_user_id TEXT,
        notes TEXT,
        txn_date TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        edit_count INTEGER NOT NULL DEFAULT 0,
        deleted_at TEXT,
        sync_status TEXT NOT NULL DEFAULT 'local',
        device_id TEXT NOT NULL DEFAULT 'local'
      )
    ''');
    await d.execute('''
      CREATE TABLE audit_log(
        id TEXT PRIMARY KEY,
        entity_type TEXT,
        entity_id TEXT,
        action TEXT,
        at TEXT,
        details TEXT
      )
    ''');
    await d.execute('''
      CREATE TABLE transaction_versions(
        id TEXT PRIMARY KEY,
        transaction_id TEXT NOT NULL,
        linked_id TEXT,
        action TEXT NOT NULL,
        snapshot_json TEXT NOT NULL,
        saved_at TEXT NOT NULL,
        device_id TEXT NOT NULL DEFAULT 'local'
      )
    ''');
    await d.execute(
      'CREATE INDEX idx_transaction_versions_txn ON transaction_versions(transaction_id, saved_at)',
    );
    await d.execute('''
      CREATE TABLE sync_tombstones(
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        deleted_at TEXT NOT NULL,
        PRIMARY KEY(entity_type, entity_id)
      )
    ''');
    await d.execute(
      'CREATE TABLE app_meta(key TEXT PRIMARY KEY,value TEXT)',
    );
    await d.execute(
      'CREATE INDEX idx_transactions_account_date ON transactions(account_id, txn_date)',
    );
    await d.execute(
      'CREATE INDEX idx_transactions_linked ON transactions(linked_id)',
    );
    await d.execute(
      'CREATE INDEX idx_transactions_report ON transactions(txn_date, purpose, user_id, account_id, category_id)',
    );

    final now = DateTime.now().toIso8601String();
    final userId = uuid.v4();
    final accountId = uuid.v4();
    await d.insert('users', {
      'id': userId,
      'name': 'Primary User',
      'created_at': now,
      'updated_at': now,
    });
    await d.insert('accounts', {
      'id': accountId,
      'user_id': userId,
      'name': 'Cash',
      'type': 'Cash',
      'opening_balance': 0.0,
      'opening_date': DateTime.now().toIso8601String(),
      'created_at': now,
      'updated_at': now,
    });

    const defaults = [
      ['Salary', 'income'],
      ['Interest', 'income'],
      ['Rent', 'income'],
      ['Other Income', 'income'],
      ['Groceries', 'expense'],
      ['Utilities', 'expense'],
      ['Travel', 'expense'],
      ['Medical', 'expense'],
      ['Household', 'expense'],
      ['Miscellaneous', 'expense'],
    ];
    for (final c in defaults) {
      await d.insert('categories', {
        'id': uuid.v4(),
        'name': c[0],
        'kind': c[1],
        'updated_at': now,
      });
    }
    await d.insert('app_meta', {
      'key': 'schema_version',
      'value': '$databaseSchemaVersion',
    });
  }

  Future<void> _upgradeSchema(Database d, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await d.execute(
        'CREATE TABLE IF NOT EXISTS app_meta(key TEXT PRIMARY KEY,value TEXT)',
      );
      await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_transactions_account_date ON transactions(account_id, txn_date)',
      );
      await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_transactions_linked ON transactions(linked_id)',
      );
    }
    if (oldVersion < 3) {
      await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_transactions_report ON transactions(txn_date, purpose, user_id, account_id, category_id)',
      );
    }
    if (oldVersion < 4) {
      final now = DateTime.now().toIso8601String();
      await d.execute('ALTER TABLE users ADD COLUMN updated_at TEXT');
      await d.execute('ALTER TABLE accounts ADD COLUMN updated_at TEXT');
      await d.execute('ALTER TABLE categories ADD COLUMN updated_at TEXT');
      await d.execute("UPDATE users SET updated_at=COALESCE(created_at, '$now') WHERE updated_at IS NULL OR updated_at=''");
      await d.execute("UPDATE accounts SET updated_at=COALESCE(created_at, '$now') WHERE updated_at IS NULL OR updated_at=''");
      await d.execute("UPDATE categories SET updated_at='$now' WHERE updated_at IS NULL OR updated_at=''");
      await d.execute('''
        CREATE TABLE IF NOT EXISTS sync_tombstones(
          entity_type TEXT NOT NULL,
          entity_id TEXT NOT NULL,
          deleted_at TEXT NOT NULL,
          PRIMARY KEY(entity_type, entity_id)
        )
      ''');
    }
    if (oldVersion < 5) {
      await d.execute('ALTER TABLE transactions ADD COLUMN edit_count INTEGER NOT NULL DEFAULT 0');
      await d.execute('ALTER TABLE transactions ADD COLUMN deleted_at TEXT');
      await d.execute('''
        CREATE TABLE IF NOT EXISTS transaction_versions(
          id TEXT PRIMARY KEY,
          transaction_id TEXT NOT NULL,
          linked_id TEXT,
          action TEXT NOT NULL,
          snapshot_json TEXT NOT NULL,
          saved_at TEXT NOT NULL,
          device_id TEXT NOT NULL DEFAULT 'local'
        )
      ''');
      await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_transaction_versions_txn ON transaction_versions(transaction_id, saved_at)',
      );
    }
    await d.insert(
      'app_meta',
      {'key': 'schema_version', 'value': '$newVersion'},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  void _touch() => dataRevision.value++;

  Future<void> _audit(
    String entityType,
    String entityId,
    String action,
    String details,
  ) async {
    await db.insert('audit_log', {
      'id': uuid.v4(),
      'entity_type': entityType,
      'entity_id': entityId,
      'action': action,
      'at': DateTime.now().toIso8601String(),
      'details': details,
    });
  }

  String _now() => DateTime.now().toUtc().toIso8601String();

  Future<void> _recordTombstone(String entityType, String entityId) async {
    await db.insert(
      'sync_tombstones',
      {'entity_type': entityType, 'entity_id': entityId, 'deleted_at': _now()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String?> meta(String key) async {
    final rows = await db.query('app_meta', where: 'key=?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value']?.toString();
  }

  Future<void> setMeta(String key, String value) async {
    await db.insert('app_meta', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> users({bool activeOnly = true}) {
    return db.query(
      'users',
      where: activeOnly ? 'is_active=1' : null,
      orderBy: 'is_active DESC, name COLLATE NOCASE',
    );
  }

  Future<List<Map<String, dynamic>>> accounts({bool activeOnly = true}) {
    final where = activeOnly ? 'WHERE a.is_active=1 AND u.is_active=1' : '';
    return db.rawQuery('''
      SELECT a.*, u.name user_name, u.is_active user_is_active
      FROM accounts a
      JOIN users u ON u.id=a.user_id
      $where
      ORDER BY a.is_active DESC, u.name COLLATE NOCASE, a.name COLLATE NOCASE
    ''');
  }

  Future<List<Map<String, dynamic>>> accountBalances({bool activeOnly = true}) {
    final where = activeOnly ? 'WHERE a.is_active=1 AND u.is_active=1' : '';
    return db.rawQuery('''
      SELECT
        a.*,
        u.name user_name,
        u.is_active user_is_active,
        a.opening_balance + COALESCE(SUM(CASE WHEN t.is_deleted=0 THEN t.amount ELSE 0 END),0) current_balance
      FROM accounts a
      JOIN users u ON u.id=a.user_id
      LEFT JOIN transactions t ON t.account_id=a.id
      $where
      GROUP BY a.id
      ORDER BY a.is_active DESC, u.name COLLATE NOCASE, a.name COLLATE NOCASE
    ''');
  }

  Future<List<Map<String, dynamic>>> categories(String kind, {bool activeOnly = true}) {
    return db.query(
      'categories',
      where: activeOnly ? 'kind=? AND is_active=1' : 'kind=?',
      whereArgs: [kind],
      orderBy: 'is_active DESC, name COLLATE NOCASE',
    );
  }

  Future<void> addCategory(String kind, String name) async {
    final clean = name.trim();
    if (clean.isEmpty) throw Exception('Category name cannot be blank.');
    final duplicate = Sqflite.firstIntValue(await db.rawQuery(
          'SELECT COUNT(*) FROM categories WHERE kind=? AND lower(name)=lower(?)',
          [kind, clean],
        )) ??
        0;
    if (duplicate > 0) throw Exception('This category already exists.');
    final id = uuid.v4();
    await db.insert('categories', {
      'id': id,
      'name': clean,
      'kind': kind,
      'is_active': 1,
      'updated_at': _now(),
    });
    await _audit('category', id, 'created', '$kind: $clean');
    _touch();
  }

  Future<void> renameCategory(String id, String kind, String name) async {
    final clean = name.trim();
    if (clean.isEmpty) throw Exception('Category name cannot be blank.');
    final duplicate = Sqflite.firstIntValue(await db.rawQuery(
          'SELECT COUNT(*) FROM categories WHERE kind=? AND lower(name)=lower(?) AND id<>?',
          [kind, clean, id],
        )) ??
        0;
    if (duplicate > 0) throw Exception('This category already exists.');
    await db.update('categories', {'name': clean, 'updated_at': _now()}, where: 'id=?', whereArgs: [id]);
    await _audit('category', id, 'edited', 'Renamed to $clean');
    _touch();
  }

  Future<String> removeCategorySafely(String id) async {
    final count = Sqflite.firstIntValue(await db.rawQuery(
          'SELECT COUNT(*) FROM transactions WHERE category_id=?',
          [id],
        )) ??
        0;
    if (count == 0) {
      await _recordTombstone('category', id);
      await db.delete('categories', where: 'id=?', whereArgs: [id]);
      await _audit('category', id, 'deleted', 'Unused category deleted');
      _touch();
      return 'Category deleted.';
    }
    await db.update('categories', {'is_active': 0, 'updated_at': _now()}, where: 'id=?', whereArgs: [id]);
    await _audit('category', id, 'deactivated', 'History retained');
    _touch();
    return 'Category has history, so it was deactivated instead of deleted.';
  }

  Future<void> reactivateCategory(String id) async {
    await db.update('categories', {'is_active': 1, 'updated_at': _now()}, where: 'id=?', whereArgs: [id]);
    await _audit('category', id, 'reactivated', 'Category reactivated');
    _touch();
  }

  Future<List<Map<String, dynamic>>> reportRows({
    required DateTime from,
    required DateTime toExclusive,
    String? userId,
    String? accountId,
    String? categoryId,
    String? purpose,
  }) async {
    final where = <String>['t.is_deleted=0', 't.txn_date>=?', 't.txn_date<?'];
    final args = <Object?>[from.toIso8601String(), toExclusive.toIso8601String()];
    if (userId != null) { where.add('t.user_id=?'); args.add(userId); }
    if (accountId != null) { where.add('t.account_id=?'); args.add(accountId); }
    if (categoryId != null) { where.add('t.category_id=?'); args.add(categoryId); }
    if (purpose != null) { where.add('t.purpose=?'); args.add(purpose); }
    return db.rawQuery('''
      SELECT t.*, u.name user_name, a.name account_name, c.name category_name
      FROM transactions t
      LEFT JOIN users u ON u.id=t.user_id
      LEFT JOIN accounts a ON a.id=t.account_id
      LEFT JOIN categories c ON c.id=t.category_id
      WHERE ${where.join(' AND ')}
      ORDER BY t.txn_date DESC, t.created_at DESC
    ''', args);
  }

  Future<List<Map<String, dynamic>>> recent({int limit = 100, bool includeDeleted = false}) {
    return db.rawQuery('''
      SELECT
        t.*,
        a.name account_name,
        u.name user_name,
        c.name category_name
      FROM transactions t
      LEFT JOIN accounts a ON a.id=t.account_id
      LEFT JOIN users u ON u.id=t.user_id
      LEFT JOIN categories c ON c.id=t.category_id
      WHERE ${includeDeleted ? '1=1' : 't.is_deleted=0'}
      ORDER BY t.txn_date DESC, t.created_at DESC
      LIMIT ?
    ''', [limit]);
  }

  Future<void> _preserveTransactionVersion(Map<String, dynamic> row, String action) async {
    await db.insert('transaction_versions', {
      'id': uuid.v4(),
      'transaction_id': row['id']?.toString() ?? '',
      'linked_id': row['linked_id']?.toString(),
      'action': action,
      'snapshot_json': jsonEncode(row),
      'saved_at': _now(),
      'device_id': _deviceId,
    });
  }

  Future<List<Map<String, dynamic>>> transactionHistory(String transactionId) async {
    final rows = await db.query(
      'transaction_versions',
      where: 'transaction_id=?',
      whereArgs: [transactionId],
      orderBy: 'saved_at ASC',
    );
    return rows.map((r) {
      final decoded = jsonDecode(r['snapshot_json']?.toString() ?? '{}');
      final snapshot = decoded is Map ? Map<String, dynamic>.from(decoded) : <String, dynamic>{};
      return {
        ...r,
        'snapshot': snapshot,
      };
    }).toList();
  }

  Future<Map<String, dynamic>?> transactionById(String id) async {
    final rows = await db.rawQuery('''
      SELECT t.*, a.name account_name, u.name user_name, c.name category_name
      FROM transactions t
      LEFT JOIN accounts a ON a.id=t.account_id
      LEFT JOIN users u ON u.id=t.user_id
      LEFT JOIN categories c ON c.id=t.category_id
      WHERE t.id=?
    ''', [id]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, dynamic>>> linkedTransfer(String linkedId) {
    return db.query(
      'transactions',
      where: 'linked_id=? AND is_deleted=0',
      whereArgs: [linkedId],
      orderBy: 'amount ASC',
    );
  }

  Future<Map<String, double>> totals(DateTime from, DateTime to) async {
    final rows = await db.rawQuery('''
      SELECT purpose, SUM(amount) total
      FROM transactions
      WHERE is_deleted=0
        AND txn_date>=?
        AND txn_date<?
        AND purpose IN ('income','expense')
      GROUP BY purpose
    ''', [from.toIso8601String(), to.toIso8601String()]);

    double income = 0;
    double expenseSigned = 0;
    for (final row in rows) {
      if (row['purpose'] == 'income') {
        income = (row['total'] as num?)?.toDouble() ?? 0;
      } else if (row['purpose'] == 'expense') {
        expenseSigned = (row['total'] as num?)?.toDouble() ?? 0;
      }
    }
    final expense = expenseSigned.abs();
    return {
      'income': income,
      'expense': expense,
      'net': income - expense,
    };
  }

  Future<void> addUser(String name) async {
    final clean = name.trim();
    if (clean.isEmpty) throw Exception('User name cannot be blank.');
    final duplicate = Sqflite.firstIntValue(await db.rawQuery(
          'SELECT COUNT(*) FROM users WHERE lower(name)=lower(?)',
          [clean],
        )) ??
        0;
    if (duplicate > 0) throw Exception('A user with this name already exists.');
    final id = uuid.v4();
    await db.insert('users', {
      'id': id,
      'name': clean,
      'is_active': 1,
      'created_at': _now(),
      'updated_at': _now(),
    });
    await _audit('user', id, 'created', clean);
    _touch();
  }

  Future<void> renameUser(String id, String name) async {
    final clean = name.trim();
    if (clean.isEmpty) throw Exception('User name cannot be blank.');
    final duplicate = Sqflite.firstIntValue(await db.rawQuery(
          'SELECT COUNT(*) FROM users WHERE lower(name)=lower(?) AND id<>?',
          [clean, id],
        )) ??
        0;
    if (duplicate > 0) throw Exception('A user with this name already exists.');
    await db.update('users', {'name': clean, 'updated_at': _now()}, where: 'id=?', whereArgs: [id]);
    await _audit('user', id, 'edited', 'Renamed to $clean');
    _touch();
  }

  Future<void> reactivateUser(String id) async {
    await db.update('users', {'is_active': 1, 'updated_at': _now()}, where: 'id=?', whereArgs: [id]);
    await _audit('user', id, 'reactivated', 'User reactivated');
    _touch();
  }

  Future<String> removeUserSafely(String id) async {
    final activeCount = Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM users WHERE is_active=1'),
        ) ??
        0;
    final userRows = await db.query('users', where: 'id=?', whereArgs: [id]);
    if (userRows.isEmpty) throw Exception('User not found.');
    final isActive = (userRows.first['is_active'] as num?)?.toInt() == 1;
    if (isActive && activeCount <= 1) {
      throw Exception('Add another active user before removing this user.');
    }

    final historyCount = Sqflite.firstIntValue(await db.rawQuery('''
      SELECT COUNT(*)
      FROM transactions t
      WHERE t.user_id=?
         OR t.expense_for_user_id=?
         OR t.account_id IN (SELECT id FROM accounts WHERE user_id=?)
    ''', [id, id, id])) ?? 0;

    if (historyCount == 0) {
      final childAccounts = await db.query('accounts', columns: ['id'], where: 'user_id=?', whereArgs: [id]);
      for (final a in childAccounts) {
        await _recordTombstone('account', a['id'].toString());
      }
      await _recordTombstone('user', id);
      await db.transaction((txn) async {
        await txn.delete('accounts', where: 'user_id=?', whereArgs: [id]);
        await txn.delete('users', where: 'id=?', whereArgs: [id]);
      });
      await _audit('user', id, 'deleted', 'User and unused accounts deleted');
      _touch();
      return 'User deleted.';
    }

    await db.transaction((txn) async {
      await txn.update(
        'users',
        {'is_active': 0, 'updated_at': _now()},
        where: 'id=?',
        whereArgs: [id],
      );
      await txn.update(
        'accounts',
        {'is_active': 0, 'updated_at': _now()},
        where: 'user_id=?',
        whereArgs: [id],
      );
    });
    await _audit('user', id, 'deactivated', 'History retained');
    _touch();
    return 'User has history, so it was deactivated instead of deleted.';
  }

  Future<void> addAccount({
    required String userId,
    required String name,
    required String type,
    required double openingBalance,
    required DateTime openingDate,
    required bool isShared,
  }) async {
    final clean = name.trim();
    if (clean.isEmpty) throw Exception('Account name cannot be blank.');
    final id = uuid.v4();
    await db.insert('accounts', {
      'id': id,
      'user_id': userId,
      'name': clean,
      'type': type,
      'opening_balance': openingBalance,
      'opening_date': openingDate.toIso8601String(),
      'is_shared': isShared ? 1 : 0,
      'is_active': 1,
      'created_at': _now(),
      'updated_at': _now(),
    });
    await _audit('account', id, 'created', '$clean ($type)');
    _touch();
  }

  Future<void> updateAccount({
    required String id,
    required String name,
    required String type,
    required double openingBalance,
    required DateTime openingDate,
    required bool isShared,
  }) async {
    final clean = name.trim();
    if (clean.isEmpty) throw Exception('Account name cannot be blank.');
    await db.update(
      'accounts',
      {
        'name': clean,
        'type': type,
        'opening_balance': openingBalance,
        'opening_date': openingDate.toIso8601String(),
        'is_shared': isShared ? 1 : 0,
        'updated_at': _now(),
      },
      where: 'id=?',
      whereArgs: [id],
    );
    await _audit('account', id, 'edited', '$clean ($type)');
    _touch();
  }

  Future<void> reactivateAccount(String id) async {
    final rows = await db.rawQuery('''
      SELECT u.is_active user_active
      FROM accounts a JOIN users u ON u.id=a.user_id
      WHERE a.id=?
    ''', [id]);
    if (rows.isEmpty) throw Exception('Account not found.');
    if ((rows.first['user_active'] as num?)?.toInt() != 1) {
      throw Exception('Reactivate the account owner first.');
    }
    await db.update('accounts', {'is_active': 1, 'updated_at': _now()}, where: 'id=?', whereArgs: [id]);
    await _audit('account', id, 'reactivated', 'Account reactivated');
    _touch();
  }

  Future<String> removeAccountSafely(String id) async {
    final count = Sqflite.firstIntValue(await db.rawQuery(
          'SELECT COUNT(*) FROM transactions WHERE account_id=?',
          [id],
        )) ??
        0;
    if (count == 0) {
      await _recordTombstone('account', id);
      await db.delete('accounts', where: 'id=?', whereArgs: [id]);
      await _audit('account', id, 'deleted', 'Unused account deleted');
      _touch();
      return 'Account deleted.';
    }
    await db.update('accounts', {'is_active': 0, 'updated_at': _now()}, where: 'id=?', whereArgs: [id]);
    await _audit('account', id, 'deactivated', 'History retained');
    _touch();
    return 'Account has history, so it was deactivated instead of deleted.';
  }

  Future<void> addTxn({
    required String userId,
    required String accountId,
    required String purpose,
    required double amount,
    String? categoryId,
    String? notes,
    DateTime? date,
  }) async {
    amount = double.parse(amount.toStringAsFixed(2));
    if (amount <= 0) throw Exception('Amount must be greater than zero.');
    final id = uuid.v4();
    final now = DateTime.now().toIso8601String();
    final signedAmount = purpose == 'expense' ? -amount.abs() : amount.abs();
    await db.insert('transactions', {
      'id': id,
      'user_id': userId,
      'account_id': accountId,
      'type': purpose,
      'purpose': purpose,
      'amount': signedAmount,
      'category_id': categoryId,
      'notes': notes?.trim(),
      'txn_date': (date ?? DateTime.now()).toIso8601String(),
      'created_at': now,
      'updated_at': now,
      'is_deleted': 0,
      'sync_status': 'local',
      'device_id': _deviceId,
    });
    await _audit('transaction', id, 'created', '$purpose $signedAmount');
    _touch();
  }

  Future<void> updateTxn({
    required String id,
    required String userId,
    required String accountId,
    required String purpose,
    required double amount,
    String? categoryId,
    String? notes,
    required DateTime date,
  }) async {
    amount = double.parse(amount.toStringAsFixed(2));
    if (amount <= 0) throw Exception('Amount must be greater than zero.');
    final signedAmount = purpose == 'expense' ? -amount.abs() : amount.abs();
    final before = await transactionById(id);
    if (before != null) await _preserveTransactionVersion(before, 'before_edit');
    await db.update(
      'transactions',
      {
        'user_id': userId,
        'account_id': accountId,
        'type': purpose,
        'purpose': purpose,
        'amount': signedAmount,
        'category_id': categoryId,
        'notes': notes?.trim(),
        'txn_date': date.toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
        'sync_status': 'local',
        'edit_count': ((before?['edit_count'] as num?)?.toInt() ?? 0) + 1,
      },
      where: 'id=?',
      whereArgs: [id],
    );
    await _audit('transaction', id, 'edited', '$purpose $signedAmount');
    _touch();
  }

  Future<void> transfer({
    required String fromUser,
    required String fromAccount,
    required String toUser,
    required String toAccount,
    required double amount,
    String? notes,
    DateTime? date,
  }) async {
    amount = double.parse(amount.toStringAsFixed(2));
    if (amount <= 0) throw Exception('Amount must be greater than zero.');
    if (fromAccount == toAccount) {
      throw Exception('From and To accounts must be different.');
    }
    final link = uuid.v4();
    final now = DateTime.now().toIso8601String();
    final txnDate = (date ?? DateTime.now()).toIso8601String();
    await db.transaction((b) async {
      await b.insert('transactions', {
        'id': uuid.v4(),
        'linked_id': link,
        'user_id': fromUser,
        'account_id': fromAccount,
        'type': 'transfer_out',
        'purpose': 'transfer',
        'amount': -amount.abs(),
        'notes': notes?.trim(),
        'txn_date': txnDate,
        'created_at': now,
        'updated_at': now,
        'sync_status': 'local',
        'device_id': _deviceId,
        'is_deleted': 0,
      });
      await b.insert('transactions', {
        'id': uuid.v4(),
        'linked_id': link,
        'user_id': toUser,
        'account_id': toAccount,
        'type': 'transfer_in',
        'purpose': 'transfer',
        'amount': amount.abs(),
        'notes': notes?.trim(),
        'txn_date': txnDate,
        'created_at': now,
        'updated_at': now,
        'sync_status': 'local',
        'device_id': _deviceId,
        'is_deleted': 0,
      });
    });
    await _audit('transfer', link, 'created', 'Transfer $amount');
    _touch();
  }

  Future<void> updateTransfer({
    required String linkedId,
    required double amount,
    String? notes,
    required DateTime date,
  }) async {
    amount = double.parse(amount.toStringAsFixed(2));
    if (amount <= 0) throw Exception('Amount must be greater than zero.');
    final rows = await linkedTransfer(linkedId);
    if (rows.length != 2) throw Exception('Linked transfer is incomplete.');
    final now = DateTime.now().toIso8601String();
    for (final row in rows) {
      await _preserveTransactionVersion(Map<String, dynamic>.from(row), 'before_edit');
    }
    await db.transaction((b) async {
      for (final row in rows) {
        final isOut = (row['amount'] as num).toDouble() < 0;
        await b.update(
          'transactions',
          {
            'amount': isOut ? -amount.abs() : amount.abs(),
            'notes': notes?.trim(),
            'txn_date': date.toIso8601String(),
            'updated_at': now,
            'sync_status': 'local',
            'edit_count': ((row['edit_count'] as num?)?.toInt() ?? 0) + 1,
          },
          where: 'id=?',
          whereArgs: [row['id']],
        );
      }
    });
    await _audit('transfer', linkedId, 'edited', 'Transfer $amount');
    _touch();
  }

  Future<void> softDeleteTransaction(String id) async {
    final row = await transactionById(id);
    if (row == null) return;
    final linkedId = row['linked_id'] as String?;
    final now = DateTime.now().toIso8601String();
    if (linkedId != null && linkedId.isNotEmpty) {
      final linkedRows = await linkedTransfer(linkedId);
      for (final linkedRow in linkedRows) {
        await _preserveTransactionVersion(Map<String, dynamic>.from(linkedRow), 'before_delete');
      }
      await db.update(
        'transactions',
        {'is_deleted': 1, 'deleted_at': now, 'updated_at': now, 'sync_status': 'local'},
        where: 'linked_id=?',
        whereArgs: [linkedId],
      );
      await _audit('transfer', linkedId, 'deleted', 'Linked transfer soft deleted');
    } else {
      await _preserveTransactionVersion(row, 'before_delete');
      await db.update(
        'transactions',
        {'is_deleted': 1, 'deleted_at': now, 'updated_at': now, 'sync_status': 'local'},
        where: 'id=?',
        whereArgs: [id],
      );
      await _audit('transaction', id, 'deleted', 'Transaction soft deleted');
    }
    _touch();
  }

  Future<String> _sha256File(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  Future<Directory> backupDirectory() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'FamilyFinanceBackups'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> _writeBackupManifest(File file, String type) async {
    final stat = await file.stat();
    final manifest = <String, dynamic>{
      'format': 'family-finance-sqlite-backup',
      'formatVersion': 1,
      'appVersion': appVersion,
      'schemaVersion': databaseSchemaVersion,
      'createdAt': DateTime.now().toIso8601String(),
      'deviceId': _deviceId,
      'type': type,
      'fileName': p.basename(file.path),
      'size': stat.size,
      'sha256': await _sha256File(file),
    };
    await File('${file.path}.json').writeAsString(jsonEncode(manifest), flush: true);
  }

  Future<File> _writeBackup(String prefix, {String? type}) async {
    try {
      await db.rawQuery('PRAGMA wal_checkpoint(FULL)');
    } catch (_) {
      // Some SQLite configurations do not use WAL; copying still works.
    }
    final dir = await backupDirectory();
    final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final file = await File(dbPath).copy(p.join(dir.path, '${prefix}_$stamp.db'));
    await _writeBackupManifest(file, type ?? prefix);
    return file;
  }

  Future<File> createBackup() async {
    final file = await _writeBackup('family_finance_manual', type: 'manual');
    await _audit('backup', file.path, 'created', 'Manual backup');
    unawaited(DriveBackupService.instance.uploadInBackground(file));
    return file;
  }

  Future<bool> autoBackupEnabled() async => (await meta('auto_backup_enabled')) != '0';

  Future<void> setAutoBackupEnabled(bool enabled) async {
    await setMeta('auto_backup_enabled', enabled ? '1' : '0');
  }

  Future<File?> autoBackupIfDue({bool force = false}) async {
    if (!await autoBackupEnabled()) return null;
    final lastText = await meta('last_auto_backup');
    final last = lastText == null ? null : DateTime.tryParse(lastText);
    if (!force && last != null && DateTime.now().difference(last).inHours < 20) return null;
    try {
      final now = DateTime.now();
      final file = await _writeBackup('family_finance_auto', type: 'automatic');
      await setMeta('last_auto_backup', now.toIso8601String());
      await _pruneBackups('family_finance_auto_', keep: 14);

      final lastWeekly = DateTime.tryParse(await meta('last_weekly_backup') ?? '');
      if (force || lastWeekly == null || now.difference(lastWeekly).inDays >= 7) {
        await _writeBackup('family_finance_weekly', type: 'weekly');
        await setMeta('last_weekly_backup', now.toIso8601String());
        await _pruneBackups('family_finance_weekly_', keep: 8);
      }
      final lastMonthly = DateTime.tryParse(await meta('last_monthly_backup') ?? '');
      if (force || lastMonthly == null || now.difference(lastMonthly).inDays >= 28) {
        await _writeBackup('family_finance_monthly', type: 'monthly');
        await setMeta('last_monthly_backup', now.toIso8601String());
        await _pruneBackups('family_finance_monthly_', keep: 6);
      }
      await _audit('backup', file.path, 'created', 'Automatic backup');
      await setMeta('last_backup_error', '');
      return file;
    } catch (e) {
      try {
        await setMeta('last_backup_error', '${DateTime.now().toIso8601String()}|$e');
      } catch (_) {}
      return null;
    }
  }

  Future<File> createSafetyBackup(String reason) async {
    final prefix = reason.toLowerCase().contains('restore')
        ? 'family_finance_prerestore'
        : 'family_finance_safety';
    final file = await _writeBackup(prefix, type: prefix.contains('prerestore') ? 'pre-restore' : 'safety');
    await _pruneBackups('${prefix}_', keep: 5);
    await _audit('backup', file.path, 'created', reason);
    unawaited(DriveBackupService.instance.uploadInBackground(file));
    return file;
  }

  Future<void> _pruneBackups(String prefix, {required int keep}) async {
    final dir = await backupDirectory();
    final files = await dir
        .list()
        .where((e) => e is File && p.basename(e.path).startsWith(prefix) && e.path.endsWith('.db'))
        .cast<File>()
        .toList();
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    for (final f in files.skip(keep)) {
      try {
        await f.delete();
        final manifest = File('${f.path}.json');
        if (await manifest.exists()) await manifest.delete();
      } catch (_) {}
    }
  }

  Future<List<BackupInfo>> localBackups() async {
    final dir = await backupDirectory();
    final files = await dir
        .list()
        .where((e) => e is File && e.path.toLowerCase().endsWith('.db'))
        .cast<File>()
        .toList();
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    final result = <BackupInfo>[];
    for (final file in files) {
      try {
        result.add(await inspectBackup(file));
      } catch (_) {
        final stat = await file.stat();
        result.add(BackupInfo(
          file: file,
          createdAt: stat.modified,
          type: 'unknown',
          schemaVersion: 0,
          users: 0,
          accounts: 0,
          transactions: 0,
          size: stat.size,
          checksumOk: false,
          valid: false,
        ));
      }
    }
    return result;
  }

  Future<BackupInfo> inspectBackup(File file) async {
    if (!await file.exists()) throw Exception('Backup file was not found.');
    final stat = await file.stat();
    bool checksumOk = true;
    String type = 'backup';
    final manifestFile = File('${file.path}.json');
    if (await manifestFile.exists()) {
      try {
        final manifest = jsonDecode(await manifestFile.readAsString());
        if (manifest is Map) {
          type = manifest['type']?.toString() ?? type;
          final expected = manifest['sha256']?.toString();
          if (expected != null && expected.isNotEmpty) {
            checksumOk = expected == await _sha256File(file);
          }
        }
      } catch (_) {
        checksumOk = false;
      }
    }

    Database? probe;
    try {
      probe = await openReadOnlyDatabase(file.path);
      final tableRows = await probe.rawQuery("SELECT name FROM sqlite_master WHERE type='table'");
      final names = tableRows.map((e) => e['name']?.toString()).whereType<String>().toSet();
      const required = {'users', 'accounts', 'categories', 'transactions', 'app_meta'};
      if (!required.every(names.contains)) throw Exception('This is not a Home Finance backup.');
      final uv = Sqflite.firstIntValue(await probe.rawQuery('PRAGMA user_version')) ?? 0;
      final users = Sqflite.firstIntValue(await probe.rawQuery('SELECT COUNT(*) FROM users')) ?? 0;
      final accounts = Sqflite.firstIntValue(await probe.rawQuery('SELECT COUNT(*) FROM accounts')) ?? 0;
      final txns = Sqflite.firstIntValue(await probe.rawQuery('SELECT COUNT(*) FROM transactions')) ?? 0;
      final valid = checksumOk && uv > 0 && uv <= databaseSchemaVersion;
      return BackupInfo(
        file: file,
        createdAt: stat.modified,
        type: type,
        schemaVersion: uv,
        users: users,
        accounts: accounts,
        transactions: txns,
        size: stat.size,
        checksumOk: checksumOk,
        valid: valid,
      );
    } finally {
      if (probe != null) await probe.close();
    }
  }

  Future<File?> pickExternalBackup() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['db'],
      allowMultiple: false,
    );
    final path = result?.files.single.path;
    return path == null ? null : File(path);
  }

  Future<void> restoreBackup(File selected) async {
    final info = await inspectBackup(selected);
    if (!info.valid) {
      if (!info.checksumOk) throw Exception('Backup checksum failed. The file may be damaged.');
      if (info.schemaVersion > databaseSchemaVersion) {
        throw Exception('This backup was created by a newer Home Finance version. Update the app first.');
      }
      throw Exception('The selected backup is not valid.');
    }

    final originalDeviceId = _deviceId;
    final localAutoBackup = await meta('auto_backup_enabled');
    final localDriveEnabled = await meta('gdrive_backup_enabled');
    final localDriveEmail = await meta('gdrive_email');
    final localLastDrive = await meta('last_gdrive_backup');
    final safety = await createSafetyBackup('Before restore');
    final target = File(dbPath);
    final temp = File('$dbPath.restore_tmp');
    try {
      if (await temp.exists()) await temp.delete();
      await selected.copy(temp.path);
      await _db?.close();
      _db = null;
      for (final sidecar in [File('$dbPath-wal'), File('$dbPath-shm'), File('$dbPath-journal')]) {
        if (await sidecar.exists()) { try { await sidecar.delete(); } catch (_) {} }
      }
      if (await target.exists()) await target.delete();
      await temp.rename(target.path);
      await init();
      _deviceId = originalDeviceId;
      await setMeta('device_id', originalDeviceId);
      await setMeta('auto_backup_enabled', localAutoBackup ?? '1');
      await setMeta('gdrive_backup_enabled', localDriveEnabled ?? '0');
      await setMeta('gdrive_email', localDriveEmail ?? '');
      await setMeta('last_gdrive_backup', localLastDrive ?? '');
      await setMeta('last_restore_at', DateTime.now().toIso8601String());
      await _audit('backup', selected.path, 'restored', 'Database restored from backup');
      _touch();
    } catch (e) {
      try {
        await _db?.close();
        _db = null;
        for (final sidecar in [File('$dbPath-wal'), File('$dbPath-shm'), File('$dbPath-journal')]) {
          if (await sidecar.exists()) { try { await sidecar.delete(); } catch (_) {} }
        }
        if (await target.exists()) await target.delete();
        await safety.copy(target.path);
        await init();
        _deviceId = originalDeviceId;
        await setMeta('device_id', originalDeviceId);
        await setMeta('auto_backup_enabled', localAutoBackup ?? '1');
        await setMeta('gdrive_backup_enabled', localDriveEnabled ?? '0');
        await setMeta('gdrive_email', localDriveEmail ?? '');
        await setMeta('last_gdrive_backup', localLastDrive ?? '');
      } catch (_) {}
      rethrow;
    } finally {
      if (await temp.exists()) {
        try { await temp.delete(); } catch (_) {}
      }
    }
  }

  Future<Map<String, dynamic>> exportSyncSnapshot() async {
    return {
      'schemaVersion': databaseSchemaVersion,
      'generatedAt': _now(),
      'deviceId': _deviceId,
      'users': await db.query('users'),
      'accounts': await db.query('accounts'),
      'categories': await db.query('categories'),
      'transactions': await db.query('transactions'),
      'transactionVersions': await db.query('transaction_versions'),
      'tombstones': await db.query('sync_tombstones'),
      'auditLog': await db.query('audit_log'),
    };
  }

  DateTime _parseStamp(Object? value) =>
      DateTime.tryParse(value?.toString() ?? '')?.toUtc() ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  Future<bool> isPristineInstall() async {
    final txnCount = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM transactions')) ?? 0;
    if (txnCount != 0) return false;
    final usersCount = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM users')) ?? 0;
    final accountsCount = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM accounts')) ?? 0;
    if (usersCount != 1 || accountsCount != 1) return false;
    final user = await db.query('users', columns: ['name'], limit: 1);
    final account = await db.query('accounts', columns: ['name', 'type'], limit: 1);
    return user.isNotEmpty &&
        user.first['name'] == 'Primary User' &&
        account.isNotEmpty &&
        account.first['name'] == 'Cash' &&
        account.first['type'] == 'Cash';
  }

  Future<void> _clearSeedForInitialSync() async {
    await db.transaction((txn) async {
      await txn.delete('accounts');
      await txn.delete('categories');
      await txn.delete('users');
      await txn.delete('sync_tombstones');
      await txn.delete('transaction_versions');
    });
  }

  Future<Map<String, int>> applySyncSnapshot(Map<String, dynamic> snapshot) async {
    final remoteSchema = (snapshot['schemaVersion'] as num?)?.toInt() ?? 0;
    if (remoteSchema != databaseSchemaVersion) {
      throw Exception('Both devices must use a compatible Home Finance database schema ($databaseSchemaVersion).');
    }
    final remoteTime = DateTime.tryParse(snapshot['generatedAt']?.toString() ?? '');
    if (remoteTime != null) {
      final skew = DateTime.now().toUtc().difference(remoteTime.toUtc()).abs();
      if (skew > const Duration(minutes: 10)) {
        throw Exception(
          'The clocks on the two phones differ by ${skew.inMinutes} minutes. '
          'Set Date & Time (and time zone) to automatic on both phones, then sync again.',
        );
      }
    }
    if (await isPristineInstall()) {
      await _clearSeedForInitialSync();
    }
    final categoryRemap = <String, String>{};

    int inserted = 0;
    int updated = 0;
    int deleted = 0;

    List<Map<String, dynamic>> maps(String key) {
      final value = snapshot[key];
      if (value is! List) return const [];
      return value.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }

    await db.transaction((txn) async {
      Future<void> mergeTable(String table, List<Map<String, dynamic>> rows) async {
        for (final incoming in rows) {
          final id = incoming['id']?.toString();
          if (id == null || id.isEmpty) continue;
          if (table == 'transactions') {
            final cid = incoming['category_id']?.toString();
            if (cid != null && categoryRemap.containsKey(cid)) incoming['category_id'] = categoryRemap[cid];
          }
          final local = await txn.query(table, where: 'id=?', whereArgs: [id], limit: 1);
          final tomb = await txn.query(
            'sync_tombstones',
            where: 'entity_type=? AND entity_id=?',
            whereArgs: [table == 'categories' ? 'category' : table.substring(0, table.length - 1), id],
            limit: 1,
          );
          final incomingStamp = _parseStamp(incoming['updated_at']);
          if (tomb.isNotEmpty && _parseStamp(tomb.first['deleted_at']).isAfter(incomingStamp)) continue;
          if (local.isEmpty) {
            if (table == 'categories') {
              // Same name + kind already exists here (e.g. both phones created "Groceries"):
              // reuse the local one instead of creating a duplicate.
              final twin = await txn.query(
                'categories',
                where: 'LOWER(name)=LOWER(?) AND kind=?',
                whereArgs: [incoming['name']?.toString() ?? '', incoming['kind']?.toString() ?? ''],
                limit: 1,
              );
              if (twin.isNotEmpty) {
                categoryRemap[id] = twin.first['id'].toString();
                continue;
              }
            }
            if (table == 'transactions') incoming['sync_status'] = 'synced';
            await txn.insert(table, incoming, conflictAlgorithm: ConflictAlgorithm.replace);
            inserted++;
          } else if (incomingStamp.isAfter(_parseStamp(local.first['updated_at']))) {
            if (table == 'transactions') incoming['sync_status'] = 'synced';
            await txn.update(table, incoming, where: 'id=?', whereArgs: [id]);
            updated++;
          }
        }
      }

      await mergeTable('users', maps('users'));
      await mergeTable('categories', maps('categories'));
      await mergeTable('accounts', maps('accounts'));
      await mergeTable('transactions', maps('transactions'));

      for (final row in maps('transactionVersions')) {
        if (row['id'] != null) {
          await txn.insert('transaction_versions', row, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      }

      final incomingTombstones = maps('tombstones')..sort((a, b) {
        const order = {'category': 0, 'account': 1, 'user': 2};
        return (order[a['entity_type']] ?? 9).compareTo(order[b['entity_type']] ?? 9);
      });
      for (final tomb in incomingTombstones) {
        final type = tomb['entity_type']?.toString() ?? '';
        final id = tomb['entity_id']?.toString() ?? '';
        if (id.isEmpty || !const {'user', 'account', 'category'}.contains(type)) continue;
        final table = type == 'category' ? 'categories' : '${type}s';
        final localRows = await txn.query(table, where: 'id=?', whereArgs: [id], limit: 1);
        final incomingDeleted = _parseStamp(tomb['deleted_at']);
        if (localRows.isNotEmpty && _parseStamp(localRows.first['updated_at']).isAfter(incomingDeleted)) {
          continue;
        }
        if (localRows.isNotEmpty) {
          if (type == 'user') {
            final accountCount = Sqflite.firstIntValue(await txn.rawQuery('SELECT COUNT(*) FROM accounts WHERE user_id=?', [id])) ?? 0;
            if (accountCount > 0) {
              await txn.update('users', {'is_active': 0, 'updated_at': tomb['deleted_at']}, where: 'id=?', whereArgs: [id]);
            } else {
              await txn.delete(table, where: 'id=?', whereArgs: [id]);
            }
          } else {
            await txn.delete(table, where: 'id=?', whereArgs: [id]);
          }
          deleted++;
        }
        await txn.insert('sync_tombstones', tomb, conflictAlgorithm: ConflictAlgorithm.replace);
      }

      for (final row in maps('auditLog')) {
        if (row['id'] != null) {
          await txn.insert('audit_log', row, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      }
      await txn.update('transactions', {'sync_status': 'synced'}, where: "sync_status<>'synced'");
    });

    await setMeta('last_sync_at', DateTime.now().toIso8601String());
    await _audit('sync', snapshot['deviceId']?.toString() ?? 'peer', 'synced', 'Merged $inserted new, $updated updated, $deleted deleted');
    _touch();
    return {'inserted': inserted, 'updated': updated, 'deleted': deleted};
  }

}


class BackupInfo {
  const BackupInfo({
    required this.file,
    required this.createdAt,
    required this.type,
    required this.schemaVersion,
    required this.users,
    required this.accounts,
    required this.transactions,
    required this.size,
    required this.checksumOk,
    required this.valid,
  });

  final File file;
  final DateTime createdAt;
  final String type;
  final int schemaVersion;
  final int users;
  final int accounts;
  final int transactions;
  final int size;
  final bool checksumOk;
  final bool valid;
}

class DriveBackupInfo {
  const DriveBackupInfo({
    required this.id,
    required this.name,
    required this.modifiedAt,
    required this.size,
    required this.parentId,
    required this.type,
  });

  final String id;
  final String name;
  final DateTime modifiedAt;
  final int size;
  final String parentId;
  final String type;
}

class DriveBackupService {
  DriveBackupService._();
  static final instance = DriveBackupService._();

  static const _driveScope = 'https://www.googleapis.com/auth/drive.file';
  final GoogleSignIn _signIn = GoogleSignIn(scopes: const [_driveScope]);

  Future<bool> enabled() async => (await AppDb.instance.meta('gdrive_backup_enabled')) == '1';

  Future<String?> connectedEmail() async {
    final stored = await AppDb.instance.meta('gdrive_email');
    return stored == null || stored.isEmpty ? null : stored;
  }

  Future<GoogleSignInAccount?> _silentAccount() async {
    try {
      return _signIn.currentUser ?? await _signIn.signInSilently();
    } catch (_) {
      return null;
    }
  }

  /// Returns a signed-in account with a fresh access token, or throws a clear
  /// message. Previously a missing account made every Drive step silently do
  /// nothing, which looked like "backup not syncing" with no explanation.
  Future<GoogleSignInAccount> _requireAccount() async {
    final account = await _silentAccount();
    if (account == null) {
      throw Exception(
        'Google sign-in has expired or was revoked. Tap Disconnect Google Drive, then Connect Google Drive again.',
      );
    }
    try {
      await account.clearAuthCache();
    } catch (_) {}
    return account;
  }

  Future<void> _recordError(Object error) async {
    try {
      final text = error.toString();
      await AppDb.instance.setMeta(
        'gdrive_last_error',
        '${DateTime.now().toIso8601String()}|${text.startsWith('Exception: ') ? text.substring(11) : text}',
      );
    } catch (_) {}
  }

  Future<void> _clearError() async {
    try {
      await AppDb.instance.setMeta('gdrive_last_error', '');
    } catch (_) {}
  }

  Exception _driveError(String what, http.Response response) {
    final code = response.statusCode;
    String hint;
    if (code == 401) {
      hint = 'Sign-in expired. Disconnect and connect Google Drive again.';
    } else if (code == 403) {
      hint = 'Google refused access. Check that the Google Drive API is enabled in Google Cloud and that the Drive permission box was ticked when signing in.';
    } else if (code == 404) {
      hint = 'The Drive item was not found (it may have been deleted).';
    } else if (code == 429 || code >= 500) {
      hint = 'Google is busy. Try again later.';
    } else {
      hint = 'Try again later.';
    }
    var detail = '';
    try {
      final decoded = jsonDecode(response.body);
      final message = decoded is Map && decoded['error'] is Map ? (decoded['error'] as Map)['message'] : null;
      if (message != null) detail = ' [$message]';
    } catch (_) {}
    return Exception('$what (HTTP $code). $hint$detail');
  }

  String _signInHint(PlatformException e) {
    final text = '${e.code} ${e.message ?? ''}';
    if (RegExp(r'\b10\b').hasMatch(text) || text.toLowerCase().contains('developer')) {
      return 'Google sign-in setup mismatch (error 10). The app package name or signing SHA-1 does not match the Android OAuth client in Google Cloud. See GOOGLE_DRIVE_SETUP.md.';
    }
    if (text.contains('12500') || text.contains('sign_in_failed')) {
      return 'Google sign-in failed (12500). Check the OAuth consent screen is configured and your Google account is a test user (or publish the app). See GOOGLE_DRIVE_SETUP.md.';
    }
    if (e.code == 'network_error') {
      return 'No internet connection for Google sign-in.';
    }
    return 'Google sign-in failed: ${e.message ?? e.code}';
  }

  Future<String> connect() async {
    GoogleSignInAccount? account;
    try {
      account = await _signIn.signIn();
    } on PlatformException catch (e) {
      throw Exception(_signInHint(e));
    }
    if (account == null) throw Exception('Google Drive sign-in was cancelled.');
    // Prove Drive access works BEFORE saving "connected", so a wrong OAuth or
    // disabled Drive API shows an error instead of a fake connected state.
    try {
      await account.clearAuthCache();
    } catch (_) {}
    try {
      await _ensureBackupFolders(account);
    } catch (e) {
      try { await _signIn.signOut(); } catch (_) {}
      rethrow;
    }
    await AppDb.instance.setMeta('gdrive_backup_enabled', '1');
    await AppDb.instance.setMeta('gdrive_email', account.email);
    await _clearError();
    unawaited(syncPendingBackups().catchError((Object e) async { await _recordError(e); }));
    return account.email;
  }

  Future<void> disconnect() async {
    await AppDb.instance.setMeta('gdrive_backup_enabled', '0');
    await AppDb.instance.setMeta('gdrive_email', '');
    try { await _signIn.disconnect(); } catch (_) {
      try { await _signIn.signOut(); } catch (_) {}
    }
  }

  Future<Map<String, String>> _headers(GoogleSignInAccount account) async {
    final auth = await account.authentication;
    final token = auth.accessToken;
    if (token == null || token.isEmpty) throw Exception('Google Drive authorization expired. Sign in again.');
    return {'Authorization': 'Bearer $token'};
  }

  String _q(String value) => value.replaceAll("'", "\\'");

  Future<String?> _findFolder(GoogleSignInAccount account, String name, {String? parentId}) async {
    final headers = await _headers(account);
    final clauses = <String>[
      "name='${_q(name)}'",
      "mimeType='application/vnd.google-apps.folder'",
      'trashed=false',
      if (parentId != null) "'$parentId' in parents",
    ];
    final uri = Uri.https('www.googleapis.com', '/drive/v3/files', {
      'q': clauses.join(' and '),
      'spaces': 'drive',
      'fields': 'files(id,name)',
      'pageSize': '10',
    });
    final response = await http.get(uri, headers: headers);
    if (response.statusCode != 200) throw _driveError('Google Drive folder lookup failed', response);
    final decoded = jsonDecode(response.body);
    final files = decoded is Map ? decoded['files'] : null;
    if (files is List && files.isNotEmpty && files.first is Map) return (files.first as Map)['id']?.toString();
    return null;
  }

  Future<String> _createFolder(GoogleSignInAccount account, String name, {String? parentId}) async {
    final headers = await _headers(account);
    final body = <String, dynamic>{
      'name': name,
      'mimeType': 'application/vnd.google-apps.folder',
      if (parentId != null) 'parents': [parentId],
    };
    final response = await http.post(
      Uri.parse('https://www.googleapis.com/drive/v3/files?fields=id,name'),
      headers: {...headers, 'Content-Type': 'application/json; charset=UTF-8'},
      body: jsonEncode(body),
    );
    if (response.statusCode != 200) throw _driveError('Could not create Google Drive backup folder', response);
    final decoded = jsonDecode(response.body);
    final id = decoded is Map ? decoded['id']?.toString() : null;
    if (id == null || id.isEmpty) throw Exception('Google Drive did not return a folder ID.');
    return id;
  }

  Future<String> _folder(GoogleSignInAccount account, String name, {String? parentId}) async {
    return await _findFolder(account, name, parentId: parentId) ?? await _createFolder(account, name, parentId: parentId);
  }

  Future<Map<String, String>> _ensureBackupFolders(GoogleSignInAccount account) async {
    final root = await _folder(account, 'Home Finance');
    final backups = await _folder(account, 'Backups', parentId: root);
    return {
      'backups': backups,
      'Automatic': await _folder(account, 'Automatic', parentId: backups),
      'Manual': await _folder(account, 'Manual', parentId: backups),
      'Pre-Restore': await _folder(account, 'Pre-Restore', parentId: backups),
      'Safety': await _folder(account, 'Safety', parentId: backups),
    };
  }

  String _folderNameForFile(String fileName) {
    if (fileName.contains('_manual_')) return 'Manual';
    if (fileName.contains('_prerestore_')) return 'Pre-Restore';
    if (fileName.contains('_safety_')) return 'Safety';
    return 'Automatic';
  }

  Future<String?> _findFileId(GoogleSignInAccount account, String parentId, String name) async {
    final headers = await _headers(account);
    final uri = Uri.https('www.googleapis.com', '/drive/v3/files', {
      'q': "name='${_q(name)}' and '$parentId' in parents and trashed=false",
      'spaces': 'drive',
      'fields': 'files(id,name)',
      'pageSize': '10',
    });
    final response = await http.get(uri, headers: headers);
    if (response.statusCode != 200) throw _driveError('Google Drive file lookup failed', response);
    final decoded = jsonDecode(response.body);
    final files = decoded is Map ? decoded['files'] : null;
    if (files is List && files.isNotEmpty && files.first is Map) return (files.first as Map)['id']?.toString();
    return null;
  }

  Future<void> _uploadFile(GoogleSignInAccount account, File file, String parentId) async {
    final headers = await _headers(account);
    final name = p.basename(file.path);
    final existing = await _findFileId(account, parentId, name);
    final boundary = 'familyfinance_${DateTime.now().microsecondsSinceEpoch}';
    final metadata = jsonEncode({
      'name': name,
      if (existing == null) 'parents': [parentId],
    });
    final bytes = await file.readAsBytes();
    final builder = BytesBuilder();
    builder.add(utf8.encode('--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n$metadata\r\n'));
    builder.add(utf8.encode('--$boundary\r\nContent-Type: application/octet-stream\r\n\r\n'));
    builder.add(bytes);
    builder.add(utf8.encode('\r\n--$boundary--\r\n'));
    final uri = existing == null
        ? Uri.parse('https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,name')
        : Uri.parse('https://www.googleapis.com/upload/drive/v3/files/$existing?uploadType=multipart&fields=id,name');
    final request = http.Request(existing == null ? 'POST' : 'PATCH', uri)
      ..headers.addAll(headers)
      ..headers['Content-Type'] = 'multipart/related; boundary=$boundary'
      ..bodyBytes = builder.takeBytes();
    final response = await http.Response.fromStream(await request.send());
    if (response.statusCode != 200) throw _driveError('Google Drive upload failed', response);
  }

  Future<List<Map<String, dynamic>>> _filesInFolder(GoogleSignInAccount account, String parentId) async {
    final headers = await _headers(account);
    final uri = Uri.https('www.googleapis.com', '/drive/v3/files', {
      'q': "'$parentId' in parents and trashed=false and mimeType!='application/vnd.google-apps.folder'",
      'spaces': 'drive',
      'fields': 'files(id,name,modifiedTime,size)',
      'pageSize': '1000',
      'orderBy': 'modifiedTime desc',
    });
    final response = await http.get(uri, headers: headers);
    if (response.statusCode != 200) throw _driveError('Could not read Google Drive backup folder', response);
    final decoded = jsonDecode(response.body);
    final files = decoded is Map ? decoded['files'] : null;
    if (files is! List) return [];
    return files.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  Future<void> _deleteDriveFile(GoogleSignInAccount account, String id) async {
    final headers = await _headers(account);
    final response = await http.delete(Uri.parse('https://www.googleapis.com/drive/v3/files/$id'), headers: headers);
    if (response.statusCode != 204 && response.statusCode != 200 && response.statusCode != 404) {
      throw _driveError('Could not prune an old Google Drive backup', response);
    }
  }

  Future<void> _pruneRemotePrefix(
    GoogleSignInAccount account,
    String parentId,
    String prefix,
    int keep,
  ) async {
    final all = await _filesInFolder(account, parentId);
    final dbs = all.where((e) {
      final name = e['name']?.toString() ?? '';
      return name.startsWith(prefix) && name.endsWith('.db');
    }).toList();
    dbs.sort((a, b) {
      final ad = DateTime.tryParse(a['modifiedTime']?.toString() ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bd = DateTime.tryParse(b['modifiedTime']?.toString() ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bd.compareTo(ad);
    });
    for (final old in dbs.skip(keep)) {
      final id = old['id']?.toString();
      final name = old['name']?.toString() ?? '';
      if (id != null && id.isNotEmpty) await _deleteDriveFile(account, id);
      Map<String, dynamic>? manifest;
      for (final candidate in all) {
        if (candidate['name']?.toString() == '$name.json') { manifest = candidate; break; }
      }
      final manifestId = manifest?['id']?.toString();
      if (manifestId != null && manifestId.isNotEmpty) await _deleteDriveFile(account, manifestId);
    }
  }

  Future<void> _pruneRemoteBackups(GoogleSignInAccount account, Map<String, String> folders) async {
    await _pruneRemotePrefix(account, folders['Automatic']!, 'family_finance_auto_', 14);
    await _pruneRemotePrefix(account, folders['Automatic']!, 'family_finance_weekly_', 8);
    await _pruneRemotePrefix(account, folders['Automatic']!, 'family_finance_monthly_', 6);
    await _pruneRemotePrefix(account, folders['Pre-Restore']!, 'family_finance_prerestore_', 5);
    await _pruneRemotePrefix(account, folders['Safety']!, 'family_finance_safety_', 5);
  }

  Future<void> uploadBackupIfEnabled(File file) async {
    if (!await enabled()) return;
    final account = await _requireAccount();
    final folders = await _ensureBackupFolders(account);
    final folderName = _folderNameForFile(p.basename(file.path));
    final parentId = folders[folderName]!;
    await _uploadFile(account, file, parentId);
    final manifest = File('${file.path}.json');
    if (await manifest.exists()) await _uploadFile(account, manifest, parentId);
    await AppDb.instance.setMeta('last_gdrive_backup', DateTime.now().toIso8601String());
    await AppDb.instance.setMeta('gdrive_email', account.email);
    try { await _pruneRemoteBackups(account, folders); } catch (_) {}
    await _clearError();
  }

  /// Fire-and-forget upload used after manual/safety backups. Never throws,
  /// but remembers the failure so the Backup screen can show it.
  Future<void> uploadInBackground(File file) async {
    try {
      await uploadBackupIfEnabled(file);
    } catch (e) {
      await _recordError(e);
    }
  }

  Future<void> syncPendingBackups() async {
    if (!await enabled()) return;
    final account = await _requireAccount();
    final folders = await _ensureBackupFolders(account);
    final dir = await AppDb.instance.backupDirectory();
    final localFiles = await dir
        .list()
        .where((e) => e is File && e.path.toLowerCase().endsWith('.db'))
        .cast<File>()
        .toList();
    for (final file in localFiles) {
      final folderName = _folderNameForFile(p.basename(file.path));
      final parentId = folders[folderName]!;
      final existing = await _findFileId(account, parentId, p.basename(file.path));
      if (existing != null) continue;
      await _uploadFile(account, file, parentId);
      final manifest = File('${file.path}.json');
      if (await manifest.exists()) await _uploadFile(account, manifest, parentId);
    }
    try { await _pruneRemoteBackups(account, folders); } catch (_) {}
    await AppDb.instance.setMeta('last_gdrive_backup', DateTime.now().toIso8601String());
    await AppDb.instance.setMeta('gdrive_email', account.email);
    await _clearError();
  }

  Future<void> syncAfterLaunch(File? newlyCreated) async {
    try {
      if (!await enabled()) return;
      if (newlyCreated != null) {
        await uploadBackupIfEnabled(newlyCreated);
      }
      await syncPendingBackups();
    } catch (e) {
      // Local backup remains authoritative; remember why Drive failed so it is
      // visible under More > Backup & Restore, then retry on a later launch.
      await _recordError(e);
    }
  }

  Future<List<DriveBackupInfo>> listDriveBackups() async {
    final account = await _requireAccount();
    final headers = await _headers(account);
    final folders = await _ensureBackupFolders(account);
    final result = <DriveBackupInfo>[];
    for (final type in ['Automatic', 'Manual', 'Pre-Restore', 'Safety']) {
      final parentId = folders[type]!;
      final uri = Uri.https('www.googleapis.com', '/drive/v3/files', {
        'q': "'$parentId' in parents and trashed=false and mimeType!='application/vnd.google-apps.folder'",
        'spaces': 'drive',
        'fields': 'files(id,name,modifiedTime,size,parents)',
        'pageSize': '1000',
        'orderBy': 'modifiedTime desc',
      });
      final response = await http.get(uri, headers: headers);
      if (response.statusCode != 200) throw _driveError('Could not read Google Drive backups', response);
      final decoded = jsonDecode(response.body);
      final files = decoded is Map ? decoded['files'] : null;
      if (files is! List) continue;
      for (final item in files.whereType<Map>()) {
        final name = item['name']?.toString() ?? '';
        if (!name.toLowerCase().endsWith('.db')) continue;
        result.add(DriveBackupInfo(
          id: item['id']?.toString() ?? '',
          name: name,
          modifiedAt: DateTime.tryParse(item['modifiedTime']?.toString() ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
          size: int.tryParse(item['size']?.toString() ?? '') ?? 0,
          parentId: parentId,
          type: type,
        ));
      }
    }
    result.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return result;
  }

  Future<File> downloadBackup(DriveBackupInfo backup) async {
    final account = await _requireAccount();
    final headers = await _headers(account);
    final response = await http.get(
      Uri.parse('https://www.googleapis.com/drive/v3/files/${backup.id}?alt=media'),
      headers: headers,
    );
    if (response.statusCode != 200) throw _driveError('Google Drive download failed', response);
    final temp = await getTemporaryDirectory();
    final file = File(p.join(temp.path, 'restore_${DateTime.now().millisecondsSinceEpoch}_${backup.name}'));
    await file.writeAsBytes(response.bodyBytes, flush: true);

    // Download the matching manifest when it exists so checksum validation remains cross-platform.
    try {
      final manifestId = await _findFileId(account, backup.parentId, '${backup.name}.json');
      if (manifestId != null) {
        final manifestRes = await http.get(
          Uri.parse('https://www.googleapis.com/drive/v3/files/$manifestId?alt=media'),
          headers: headers,
        );
        if (manifestRes.statusCode == 200) {
          await File('${file.path}.json').writeAsBytes(manifestRes.bodyBytes, flush: true);
        }
      }
    } catch (_) {}
    return file;
  }
}


class SyncService {
  SyncService._();
  static final instance = SyncService._();

  static const int port = 8787;
  static const int maxFailedAttempts = 5;
  static const int hostMinutes = 10;
  HttpServer? _server;
  Timer? _expiryTimer;
  int _failedAttempts = 0;
  String? stopReason;
  String? pairCode;
  String? localAddress;
  bool get isHosting => _server != null;

  Future<String?> findLocalIpv4() async {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    String? fallback;
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        fallback ??= address.address;
        final a = address.address;
        if (a.startsWith('192.168.') || a.startsWith('10.') || a.startsWith('172.')) return a;
      }
    }
    return fallback;
  }

  Future<void> startHosting() async {
    if (_server != null) return;
    localAddress = await findLocalIpv4();
    if (localAddress == null) throw Exception('Connect this phone to Wi-Fi before starting Host Sync.');
    pairCode = (100000 + Random.secure().nextInt(900000)).toString();
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port, shared: true);
    _server!.listen(_handleRequest, onError: (_) {});
    _failedAttempts = 0;
    stopReason = null;
    _expiryTimer?.cancel();
    _expiryTimer = Timer(const Duration(minutes: hostMinutes), () {
      stopReason = 'Host stopped automatically after $hostMinutes minutes. Start it again when needed.';
      unawaited(stopHosting());
    });
  }

  Future<void> stopHosting() async {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    final server = _server;
    _server = null;
    pairCode = null;
    if (server != null) await server.close(force: true);
  }

  bool _authorized(HttpRequest request) {
    final code = pairCode;
    final given = request.headers.value('x-family-finance-code');
    if (code == null || given == null || given.length != code.length) return false;
    var diff = 0;
    for (var i = 0; i < code.length; i++) {
      diff |= code.codeUnitAt(i) ^ given.codeUnitAt(i);
    }
    return diff == 0;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    request.response.headers.contentType = ContentType.json;
    try {
      if (!_authorized(request)) {
        _failedAttempts++;
        request.response.statusCode = HttpStatus.unauthorized;
        request.response.write(jsonEncode({'error': 'Invalid pairing code'}));
        await request.response.close();
        if (_failedAttempts >= maxFailedAttempts) {
          stopReason = 'Host stopped after $maxFailedAttempts wrong pairing codes. Start it again to get a new code.';
          await stopHosting();
        }
        return;
      }
      if (request.method == 'GET' && request.uri.path == '/snapshot') {
        request.response.write(jsonEncode(await AppDb.instance.exportSyncSnapshot()));
      } else if (request.method == 'POST' && request.uri.path == '/merge') {
        if (request.contentLength > 50 * 1024 * 1024) throw Exception('Sync payload is too large.');
        final body = await utf8.decoder.bind(request).join();
        final decoded = jsonDecode(body);
        if (decoded is! Map) throw Exception('Invalid sync payload.');
        await AppDb.instance.createSafetyBackup('Before incoming Wi-Fi sync');
        final stats = await AppDb.instance.applySyncSnapshot(Map<String, dynamic>.from(decoded));
        request.response.write(jsonEncode({
          'stats': stats,
          'snapshot': await AppDb.instance.exportSyncSnapshot(),
        }));
      } else {
        request.response.statusCode = HttpStatus.notFound;
        request.response.write(jsonEncode({'error': 'Not found'}));
      }
    } catch (e) {
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write(jsonEncode({'error': e.toString()}));
    }
    await request.response.close();
  }

  Future<Map<String, dynamic>> syncWithHost({
    required String host,
    required String code,
  }) async {
    final cleanHost = host.trim().replaceAll(RegExp(r'^https?://'), '').replaceAll(RegExp(r':\d+$'), '');
    if (cleanHost.isEmpty) throw Exception('Enter the host device IP address.');
    if (!RegExp(r'^\d{6}$').hasMatch(code.trim())) throw Exception('Enter the 6-digit pairing code.');

    await AppDb.instance.createSafetyBackup('Before outgoing Wi-Fi sync');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final base = Uri.parse('http://$cleanHost:$port');
      final getReq = await client.getUrl(base.replace(path: '/snapshot'));
      getReq.headers.set('x-family-finance-code', code.trim());
      final getRes = await getReq.close();
      final getBody = await utf8.decoder.bind(getRes).join();
      if (getRes.statusCode != HttpStatus.ok) {
        throw Exception(_errorFromBody(getBody, 'Could not read host data.'));
      }
      final remote = jsonDecode(getBody);
      if (remote is! Map) throw Exception('Host returned invalid data.');
      final firstStats = await AppDb.instance.applySyncSnapshot(Map<String, dynamic>.from(remote));

      final postReq = await client.postUrl(base.replace(path: '/merge'));
      postReq.headers.contentType = ContentType.json;
      postReq.headers.set('x-family-finance-code', code.trim());
      postReq.write(jsonEncode(await AppDb.instance.exportSyncSnapshot()));
      final postRes = await postReq.close();
      final postBody = await utf8.decoder.bind(postRes).join();
      if (postRes.statusCode != HttpStatus.ok) {
        throw Exception(_errorFromBody(postBody, 'Host could not merge data.'));
      }
      final postDecoded = jsonDecode(postBody);
      if (postDecoded is! Map || postDecoded['snapshot'] is! Map) {
        throw Exception('Host returned an incomplete sync response.');
      }
      final finalStats = await AppDb.instance.applySyncSnapshot(
        Map<String, dynamic>.from(postDecoded['snapshot'] as Map),
      );
      await AppDb.instance.setMeta('last_sync_host', cleanHost);
      return {
        'receivedNew': firstStats['inserted'],
        'receivedUpdated': firstStats['updated'],
        'finalNew': finalStats['inserted'],
        'finalUpdated': finalStats['updated'],
      };
    } on SocketException {
      throw Exception('Could not connect. Keep both phones on the same Wi-Fi and keep Host Sync open on the other phone.');
    } finally {
      client.close(force: true);
    }
  }

  String _errorFromBody(String body, String fallback) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['error'] != null) return decoded['error'].toString();
    } catch (_) {}
    return fallback;
  }
}

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> with WidgetsBindingObserver {
  int index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Apps are rarely fully restarted, so also check backups when returning to the app.
    if (state == AppLifecycleState.resumed) {
      unawaited(() async {
        try {
          final file = await AppDb.instance.autoBackupIfDue();
          await AppDb.instance.processRecurringDue();
          await DriveBackupService.instance.syncAfterLaunch(file);
        } catch (_) {}
      }());
    }
  }

  final pages = const [
    HomePage(),
    TransactionsPage(),
    ReportsPage(),
    MorePage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(child: pages[index]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async => showEntrySheet(context),
        icon: const Icon(Icons.add),
        label: const Text('Add'),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (value) => setState(() => index = value),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            label: 'Transactions',
          ),
          NavigationDestination(
            icon: Icon(Icons.bar_chart_outlined),
            label: 'Reports',
          ),
          NavigationDestination(
            icon: Icon(Icons.more_horiz),
            label: 'More',
          ),
        ],
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String period = 'month';

  DateTimeRange get homeRange {
    final now = DateTime.now();
    switch (period) {
      case 'today':
        final d = DateTime(now.year, now.month, now.day);
        return DateTimeRange(start: d, end: d);
      case 'week':
        final start = DateTime(now.year, now.month, now.day)
            .subtract(Duration(days: now.weekday - 1));
        return DateTimeRange(start: start, end: start.add(const Duration(days: 6)));
      case 'year':
        return DateTimeRange(
          start: DateTime(now.year, 1, 1),
          end: DateTime(now.year, 12, 31),
        );
      default:
        return DateTimeRange(
          start: DateTime(now.year, now.month, 1),
          end: DateTime(now.year, now.month + 1, 1).subtract(const Duration(days: 1)),
        );
    }
  }

  DateTime get from => homeRange.start;
  DateTime get toExclusive => DateTime(
        homeRange.end.year,
        homeRange.end.month,
        homeRange.end.day,
      ).add(const Duration(days: 1));

  String get periodLabel {
    final range = homeRange;
    switch (period) {
      case 'today':
        return DateFormat('dd MMM yyyy').format(range.start);
      case 'week':
        return '${DateFormat('dd MMM').format(range.start)} – ${DateFormat('dd MMM yyyy').format(range.end)}';
      case 'year':
        return 'Calendar Year ${range.start.year}';
      default:
        return DateFormat('MMMM yyyy').format(range.start);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: dataRevision,
      builder: (context, _, __) {
        return FutureBuilder<List<dynamic>>(
          future: Future.wait([
            AppDb.instance.totals(from, toExclusive),
            AppDb.instance.accountBalances(),
            AppDb.instance.recent(limit: 6),
          ]),
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final totals = snapshot.data![0] as Map<String, double>;
            final accounts = snapshot.data![1] as List<Map<String, dynamic>>;
            final transactions = snapshot.data![2] as List<Map<String, dynamic>>;
            final income = totals['income'] ?? 0;
            final expense = totals['expense'] ?? 0;
            final net = income - expense;
            final totalBalance = accounts.fold<double>(
              0,
              (sum, a) => sum + ((a['current_balance'] as num?)?.toDouble() ?? 0),
            );

            final personalAccounts = accounts
                .where((a) => (a['is_shared'] as num?)?.toInt() != 1)
                .toList();
            final cashAccounts = personalAccounts
                .where((a) => (a['type']?.toString().toLowerCase() ?? '') == 'cash')
                .toList();
            final sharedAccounts = accounts
                .where((a) => (a['is_shared'] as num?)?.toInt() == 1)
                .toList();
            final grouped = <String, List<Map<String, dynamic>>>{};
            for (final account in personalAccounts) {
              final owner = account['user_name']?.toString() ?? 'Member';
              grouped.putIfAbsent(owner, () => []).add(account);
            }

            return RefreshIndicator(
              onRefresh: () async => dataRevision.value++,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 90),
                children: [
                  Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.asset('assets/app_icon.png', width: 46, height: 46),
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Home Finance',
                          style: TextStyle(fontSize: 25, fontWeight: FontWeight.w800),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Refresh',
                        onPressed: () => dataRevision.value++,
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _periodChip('today', 'Today'),
                        const SizedBox(width: 8),
                        _periodChip('week', 'Week'),
                        const SizedBox(width: 8),
                        _periodChip('month', 'Month'),
                        const SizedBox(width: 8),
                        _periodChip('year', 'Year'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF159447), Color(0xFF087C69)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Total Balance', style: TextStyle(color: Colors.white70, fontSize: 14)),
                        const SizedBox(height: 6),
                        Text(
                          money.format(totalBalance),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 30,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(periodLabel, style: const TextStyle(color: Colors.white70)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  const BackupHealthBanner(),
                  const HomeBudgetCard(),
                  Row(
                    children: [
                      Expanded(child: _summaryCard('Income', income, const Color(0xFF168A49), Icons.south_west)),
                      const SizedBox(width: 8),
                      Expanded(child: _summaryCard('Expense', expense, const Color(0xFFD93025), Icons.north_east)),
                      const SizedBox(width: 8),
                      Expanded(child: _summaryCard('Net', net, const Color(0xFF1769E0), Icons.savings_outlined)),
                    ],
                  ),
                  const SizedBox(height: 18),
                  _section('Quick Actions'),
                  Row(
                    children: [
                      Expanded(child: _quick(context, 'Income', Icons.account_balance_wallet_outlined, 'income')),
                      const SizedBox(width: 8),
                      Expanded(child: _quick(context, 'Expense', Icons.shopping_bag_outlined, 'expense')),
                      const SizedBox(width: 8),
                      Expanded(child: _quick(context, 'Transfer', Icons.swap_horiz, 'transfer')),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(child: _section('Member Cash Accounts')),
                      TextButton(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const SetupPage()),
                        ),
                        child: const Text('View All'),
                      ),
                    ],
                  ),
                  if (cashAccounts.isEmpty)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(14),
                        child: Text('No member Cash accounts yet.'),
                      ),
                    )
                  else
                    SizedBox(
                      height: 102,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: cashAccounts.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (_, index) => _cashCard(cashAccounts[index]),
                      ),
                    ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(child: _section('Recent Transactions')),
                      TextButton(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const TransactionsPage()),
                        ),
                        child: const Text('View All'),
                      ),
                    ],
                  ),
                  if (transactions.isEmpty)
                    const Card(
                      child: ListTile(
                        leading: Icon(Icons.receipt_long_outlined),
                        title: Text('No transactions yet'),
                      ),
                    )
                  else
                    Card(
                      child: Column(
                        children: transactions
                            .map(
                              (x) => TransactionTile(
                                row: x,
                                onEdit: () => showEditTransactionSheet(context, x),
                              ),
                            )
                            .toList(),
                      ),
                    ),
                  const SizedBox(height: 18),
                  _section('Accounts'),
                  if (accounts.isEmpty)
                    const ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.info_outline),
                      title: Text('No active accounts'),
                      subtitle: Text('Go to More > Users & Accounts to add one.'),
                    ),
                  for (final entry in grouped.entries) ...[
                    _accountOwnerHeading(entry.key),
                    Card(child: Column(children: entry.value.map(_accountTile).toList())),
                    const SizedBox(height: 8),
                  ],
                  if (sharedAccounts.isNotEmpty) ...[
                    _accountOwnerHeading('Shared Accounts'),
                    Card(child: Column(children: sharedAccounts.map(_accountTile).toList())),
                  ],
                  const SizedBox(height: 14),
                  Card(
                    child: ListTile(
                      leading: const CircleAvatar(child: Icon(Icons.shield_outlined)),
                      title: const Text('Backup & Sync protection'),
                      subtitle: const Text('Automatic local/Google Drive backup and Wi-Fi Sync are available under More.'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const DataInfoPage()),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _periodChip(String value, String label) {
    return ChoiceChip(
      label: Text(label),
      selected: period == value,
      onSelected: (_) => setState(() => period = value),
    );
  }

  Widget _summaryCard(String label, double value, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 6),
          Text(label, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(money.format(value), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }

  Widget _cashCard(Map<String, dynamic> account) {
    final balance = (account['current_balance'] as num?)?.toDouble() ?? 0;
    final owner = account['user_name']?.toString() ?? 'Member';
    final initial = owner.trim().isEmpty ? 'M' : owner.trim()[0].toUpperCase();
    return Container(
      width: 128,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF168A49).withValues(alpha: 0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(radius: 16, child: Text(initial)),
          const SizedBox(height: 7),
          Text(owner, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(money.format(balance), style: const TextStyle(color: Color(0xFF168A49), fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }

  Widget _accountOwnerHeading(String owner) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 6),
      child: Text(
        owner,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.black54),
      ),
    );
  }

  Widget _accountTile(Map<String, dynamic> account) {
    final balance = (account['current_balance'] as num?)?.toDouble() ?? 0;
    final type = account['type']?.toString() ?? 'Account';
    final owner = account['user_name']?.toString() ?? '';
    final shared = (account['is_shared'] as num?)?.toInt() == 1;
    return ListTile(
      dense: true,
      leading: CircleAvatar(
        child: Icon(type.toLowerCase() == 'cash' ? Icons.payments_outlined : Icons.account_balance_wallet_outlined),
      ),
      title: Text(account['name']?.toString() ?? type),
      subtitle: Text(shared ? '$owner · $type · Shared' : type),
      trailing: Text(money.format(balance), style: const TextStyle(fontWeight: FontWeight.w700)),
    );
  }

  Widget _quick(BuildContext context, String label, IconData icon, String kind) {
    return FilledButton.tonal(
      onPressed: () => showEntrySheet(context, initial: kind),
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      child: Column(children: [Icon(icon), const SizedBox(height: 4), Text(label)]),
    );
  }

  Widget _section(String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
    );
  }
}

class TransactionTile extends StatelessWidget {
  const TransactionTile({
    super.key,
    required this.row,
    this.showMenu = false,
    this.onEdit,
    this.onDelete,
    this.onHistory,
  });

  final Map<String, dynamic> row;
  final bool showMenu;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onHistory;

  @override
  Widget build(BuildContext context) {
    final amount = (row['amount'] as num?)?.toDouble() ?? 0;
    final purpose = row['purpose']?.toString() ?? '';
    final isTransfer = purpose == 'transfer';
    final title = isTransfer
        ? ((row['type'] == 'transfer_out') ? 'Transfer out' : 'Transfer in')
        : (row['category_name']?.toString().trim().isNotEmpty == true
            ? row['category_name'].toString()
            : _titleCase(purpose));
    final date = DateTime.tryParse(row['txn_date']?.toString() ?? '') ?? DateTime.now();
    final deleted = (row['is_deleted'] as num?)?.toInt() == 1;
    final edited = ((row['edit_count'] as num?)?.toInt() ?? 0) > 0;
    final status = deleted ? 'DELETED' : (edited ? 'EDITED' : null);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      tileColor: deleted ? Colors.red.shade50 : (edited ? Colors.orange.shade50 : null),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      onTap: deleted ? onHistory : onEdit,
      leading: CircleAvatar(
        child: Icon(
          isTransfer
              ? Icons.swap_horiz
              : (amount >= 0 ? Icons.south_west : Icons.north_east),
        ),
      ),
      title: Row(
        children: [
          Expanded(child: Text(title)),
          if (status != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: deleted ? Colors.red.shade100 : Colors.orange.shade100,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(status, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800)),
            ),
        ],
      ),
      subtitle: Text(
        '${row['user_name'] ?? ''} | ${row['account_name'] ?? ''} | ${DateFormat('dd MMM yyyy').format(date)}',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            money.format(amount),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          if (showMenu)
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'edit') onEdit?.call();
                if (value == 'delete') onDelete?.call();
                if (value == 'history') onHistory?.call();
              },
              itemBuilder: (_) => [
                if (onEdit != null) const PopupMenuItem(value: 'edit', child: Text('Edit')),
                if (onDelete != null) const PopupMenuItem(value: 'delete', child: Text('Delete')),
                const PopupMenuItem(value: 'history', child: Text('View original / history')),
              ],
            ),
        ],
      ),
    );
  }

  static String _titleCase(String value) {
    if (value.isEmpty) return 'Transaction';
    return value[0].toUpperCase() + value.substring(1);
  }
}


Future<void> showTransactionHistory(BuildContext context, Map<String, dynamic> current) async {
  final history = await AppDb.instance.transactionHistory(current['id']?.toString() ?? '');
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) {
      final versions = <Map<String, dynamic>>[
        ...history,
        {
          'action': ((current['is_deleted'] as num?)?.toInt() == 1) ? 'current_deleted' : 'current',
          'saved_at': current['updated_at'],
          'snapshot': current,
        },
      ];
      return SafeArea(
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.72,
          minChildSize: 0.45,
          maxChildSize: 0.95,
          builder: (_, controller) => ListView.separated(
            controller: controller,
            padding: const EdgeInsets.all(20),
            itemCount: versions.length + 1,
            separatorBuilder: (_, __) => const Divider(height: 24),
            itemBuilder: (_, index) {
              if (index == 0) {
                return const Text('Transaction History', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800));
              }
              final v = versions[index - 1];
              final snap = Map<String, dynamic>.from(v['snapshot'] as Map);
              final amount = (snap['amount'] as num?)?.toDouble() ?? 0;
              final date = DateTime.tryParse(snap['txn_date']?.toString() ?? '');
              final action = v['action']?.toString() ?? '';
              final label = index == 1 ? 'ORIGINAL' : (index == versions.length ? 'CURRENT' : 'PREVIOUS VERSION');
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 6),
                      Text('Type: ${snap['purpose'] ?? snap['type'] ?? ''}'),
                      Text('Amount: ${money.format(amount)}'),
                      if (date != null) Text('Date: ${DateFormat('dd MMM yyyy').format(date)}'),
                      Text('Notes: ${snap['notes']?.toString().trim().isNotEmpty == true ? snap['notes'] : '-'}'),
                      const SizedBox(height: 6),
                      Text('Saved as: $action', style: const TextStyle(fontSize: 12, color: Colors.black54)),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      );
    },
  );
}

class ReportsPage extends StatefulWidget {
  const ReportsPage({super.key});

  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  String preset = 'month';
  DateTime from = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime to = DateTime(DateTime.now().year, DateTime.now().month + 1, 1)
      .subtract(const Duration(days: 1));
  String? userId;
  String? accountId;
  String? categoryId;
  String? purpose;

  void applyPreset(String value) {
    final now = DateTime.now();
    late DateTime f;
    late DateTime t;
    switch (value) {
      case 'today':
        f = DateTime(now.year, now.month, now.day);
        t = f;
        break;
      case 'week':
        f = DateTime(now.year, now.month, now.day)
            .subtract(Duration(days: now.weekday - 1));
        t = f.add(const Duration(days: 6));
        break;
      case 'year':
        f = DateTime(now.year, 1, 1);
        t = DateTime(now.year, 12, 31);
        break;
      case 'fy':
        final y = now.month >= 4 ? now.year : now.year - 1;
        f = DateTime(y, 4, 1);
        t = DateTime(y + 1, 3, 31);
        break;
      default:
        f = DateTime(now.year, now.month, 1);
        t = DateTime(now.year, now.month + 1, 1)
            .subtract(const Duration(days: 1));
    }
    setState(() {
      preset = value;
      from = f;
      to = t;
    });
  }

  Future<void> pickCustom() async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      initialDateRange: DateTimeRange(start: from, end: to),
    );
    if (range != null) {
      setState(() {
        preset = 'custom';
        from = range.start;
        to = range.end;
      });
    }
  }

  void clearFilters() {
    setState(() {
      userId = null;
      accountId = null;
      categoryId = null;
      purpose = null;
    });
  }

  String _nameFor(List<Map<String, dynamic>> rows, String? id) {
    if (id == null) return '';
    for (final row in rows) {
      if (row['id'] == id) return row['name']?.toString() ?? '';
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: dataRevision,
      builder: (_, __, ___) => FutureBuilder(
        future: Future.wait([
          AppDb.instance.users(activeOnly: false),
          AppDb.instance.accounts(activeOnly: false),
          AppDb.instance.categories('income', activeOnly: false),
          AppDb.instance.categories('expense', activeOnly: false),
        ]),
        builder: (
          context,
          AsyncSnapshot<List<List<Map<String, dynamic>>>> meta,
        ) {
          if (!meta.hasData) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }

          final users = meta.data![0];
          final allAccounts = meta.data![1];
          final incomeCats = meta.data![2];
          final expenseCats = meta.data![3];

          // When a user is selected, only accounts assigned to that user are
          // available in the Account filter. "All Users" shows all accounts.
          final visibleAccounts = userId == null
              ? allAccounts
              : allAccounts.where((a) => a['user_id'] == userId).toList();

          List<Map<String, dynamic>> visibleCategories;
          if (purpose == 'income') {
            visibleCategories = incomeCats;
          } else if (purpose == 'expense') {
            visibleCategories = expenseCats;
          } else if (purpose == 'transfer') {
            visibleCategories = const <Map<String, dynamic>>[];
          } else {
            visibleCategories = [...incomeCats, ...expenseCats];
          }

          final toExclusive = DateTime(to.year, to.month, to.day)
              .add(const Duration(days: 1));

          final filterParts = <String>[];
          if (userId != null) {
            filterParts.add(_nameFor(users, userId));
          }
          if (accountId != null) {
            filterParts.add(_nameFor(allAccounts, accountId));
          }
          if (purpose != null) {
            filterParts.add(
              purpose == 'income'
                  ? 'Income'
                  : purpose == 'expense'
                      ? 'Expenses'
                      : 'Transfers',
            );
          }
          if (categoryId != null) {
            filterParts.add(
              _nameFor([...incomeCats, ...expenseCats], categoryId),
            );
          }

          return Scaffold(
            appBar: AppBar(title: const Text('Detailed Reports')),
            body: FutureBuilder<List<Map<String, dynamic>>>(
              future: AppDb.instance.reportRows(
                from: from,
                toExclusive: toExclusive,
                userId: userId,
                accountId: accountId,
                categoryId: categoryId,
                purpose: purpose,
              ),
              builder: (context, snap) {
                final rows = snap.data ?? const <Map<String, dynamic>>[];
                double income = 0;
                double expense = 0;
                double tin = 0;
                double tout = 0;
                final expenseByCategory = <String, double>{};
                for (final r in rows) {
                  final a = (r['amount'] as num).toDouble();
                  if (r['purpose'] == 'income') income += a;
                  if (r['purpose'] == 'expense') {
                    expense += a.abs();
                    final name = (r['category_name']?.toString().trim().isNotEmpty ?? false)
                        ? r['category_name'].toString()
                        : 'Uncategorised';
                    expenseByCategory[name] = (expenseByCategory[name] ?? 0) + a.abs();
                  }
                  if (r['type'] == 'transfer_in') tin += a.abs();
                  if (r['type'] == 'transfer_out') tout += a.abs();
                }
                final categoryEntries = expenseByCategory.entries.toList()
                  ..sort((a, b) => b.value.compareTo(a.value));

                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final e in const [
                          ('today', 'Today'),
                          ('week', 'This Week'),
                          ('month', 'This Month'),
                          ('year', 'Calendar Year'),
                          ('fy', 'Financial Year'),
                        ])
                          ChoiceChip(
                            label: Text(e.$2),
                            selected: preset == e.$1,
                            onSelected: (_) => applyPreset(e.$1),
                          ),
                        ChoiceChip(
                          label: const Text('Custom'),
                          selected: preset == 'custom',
                          onSelected: (_) => pickCustom(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '${DateFormat('dd MMM yyyy').format(from)}  –  ${DateFormat('dd MMM yyyy').format(to)}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        SizedBox(
                          width: 180,
                          child: DropdownButtonFormField<String?>(
                            key: ValueKey('report-user-$userId'),
                            initialValue: userId,
                            decoration: const InputDecoration(labelText: 'User'),
                            items: [
                              const DropdownMenuItem(
                                value: null,
                                child: Text('All Users'),
                              ),
                              ...users.map(
                                (u) => DropdownMenuItem(
                                  value: u['id'] as String,
                                  child: Text(u['name'].toString()),
                                ),
                              ),
                            ],
                            onChanged: (v) {
                              setState(() {
                                userId = v;
                                // An account from another user must never remain
                                // selected after changing the User filter.
                                accountId = null;
                              });
                            },
                          ),
                        ),
                        SizedBox(
                          width: 180,
                          child: DropdownButtonFormField<String?>(
                            key: ValueKey('report-account-$userId-$accountId'),
                            initialValue: accountId,
                            decoration:
                                const InputDecoration(labelText: 'Account'),
                            items: [
                              const DropdownMenuItem(
                                value: null,
                                child: Text('All Accounts'),
                              ),
                              ...visibleAccounts.map(
                                (a) => DropdownMenuItem(
                                  value: a['id'] as String,
                                  child: Text(a['name'].toString()),
                                ),
                              ),
                            ],
                            onChanged: (v) => setState(() => accountId = v),
                          ),
                        ),
                        SizedBox(
                          width: 180,
                          child: DropdownButtonFormField<String?>(
                            key: ValueKey('report-type-$purpose'),
                            initialValue: purpose,
                            decoration: const InputDecoration(labelText: 'Type'),
                            items: const [
                              DropdownMenuItem(
                                value: null,
                                child: Text('All Types'),
                              ),
                              DropdownMenuItem(
                                value: 'income',
                                child: Text('Income'),
                              ),
                              DropdownMenuItem(
                                value: 'expense',
                                child: Text('Expense'),
                              ),
                              DropdownMenuItem(
                                value: 'transfer',
                                child: Text('Transfer'),
                              ),
                            ],
                            onChanged: (v) {
                              setState(() {
                                purpose = v;
                                // Category options depend on transaction type.
                                // Reset it so an incompatible old selection is
                                // never silently applied.
                                categoryId = null;
                              });
                            },
                          ),
                        ),
                        SizedBox(
                          width: 180,
                          child: DropdownButtonFormField<String?>(
                            key: ValueKey(
                              'report-category-$purpose-$categoryId',
                            ),
                            initialValue:
                                purpose == 'transfer' ? null : categoryId,
                            decoration: InputDecoration(
                              labelText: purpose == 'transfer'
                                  ? 'Category (not used)'
                                  : 'Category',
                            ),
                            items: purpose == 'transfer'
                                ? const [
                                    DropdownMenuItem<String?>(
                                      value: null,
                                      child: Text('Not applicable'),
                                    ),
                                  ]
                                : [
                                    const DropdownMenuItem(
                                      value: null,
                                      child: Text('All Categories'),
                                    ),
                                    ...visibleCategories.map(
                                      (c) => DropdownMenuItem(
                                        value: c['id'] as String,
                                        child: Text(
                                          purpose == null
                                              ? '${c['name']} (${c['kind']})'
                                              : c['name'].toString(),
                                        ),
                                      ),
                                    ),
                                  ],
                            onChanged: purpose == 'transfer'
                                ? null
                                : (v) => setState(() => categoryId = v),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            filterParts.isEmpty
                                ? 'Filters: All Users · All Accounts · All Types'
                                : 'Filters: ${filterParts.join(' · ')}',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: filterParts.isEmpty ? null : clearFilters,
                          icon: const Icon(Icons.filter_alt_off_outlined),
                          label: const Text('Clear Filters'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        _reportCard('Income', income),
                        _reportCard('Expenses', expense),
                        _reportCard('Surplus', income - expense),
                        _reportCard('Transfers In', tin),
                        _reportCard('Transfers Out', tout),
                      ],
                    ),
                    const SizedBox(height: 16),
                    if (categoryEntries.isNotEmpty) ...[
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Expense by Category',
                                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                              ),
                              const SizedBox(height: 12),
                              for (final e in categoryEntries.take(5)) ...[
                                Row(
                                  children: [
                                    Expanded(child: Text(e.key, maxLines: 1, overflow: TextOverflow.ellipsis)),
                                    Text(
                                      expense <= 0 ? '0%' : '${((e.value / expense) * 100).round()}%',
                                      style: const TextStyle(fontWeight: FontWeight.w700),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 5),
                                LinearProgressIndicator(
                                  value: expense <= 0 ? 0.0 : (e.value / expense).clamp(0.0, 1.0).toDouble(),
                                  minHeight: 8,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                const SizedBox(height: 10),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: rows.isEmpty
                                ? null
                                : () => _runExport(
                                      context,
                                      () => ReportService.exportXlsx(
                                        rows,
                                        from,
                                        to,
                                      ),
                                    ),
                            icon: const Icon(Icons.table_chart),
                            label: const Text('XLSX'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton.tonalIcon(
                            onPressed: rows.isEmpty
                                ? null
                                : () => _runExport(
                                      context,
                                      () => ReportService.exportPdf(
                                        rows,
                                        from,
                                        to,
                                      ),
                                    ),
                            icon: const Icon(Icons.picture_as_pdf),
                            label: const Text('PDF'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: rows.isEmpty
                                ? null
                                : () => _runExport(
                                      context,
                                      () => CsvExport.share(rows, 'report'),
                                    ),
                            icon: const Icon(Icons.description_outlined),
                            label: const Text('CSV'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Text(
                      '${rows.length} entries',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    if (snap.connectionState == ConnectionState.waiting)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: CircularProgressIndicator(),
                        ),
                      )
                    else if (rows.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(
                          child: Text('No transactions for this selection.'),
                        ),
                      )
                    else
                      ...rows.map((r) {
                        final amount = (r['amount'] as num).toDouble();
                        final label = r['purpose'] == 'transfer'
                            ? (r['type'] == 'transfer_in'
                                ? 'Transfer In'
                                : 'Transfer Out')
                            : (r['purpose'] == 'income'
                                ? 'Income'
                                : 'Expense');
                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            title: Text(
                              r['category_name']?.toString() ?? label,
                            ),
                            subtitle: Text(
                              '${DateFormat('dd MMM yyyy').format(DateTime.parse(r['txn_date']))} • ${r['user_name'] ?? ''} • ${r['account_name'] ?? ''}\n$label${(r['notes'] ?? '').toString().isEmpty ? '' : ' • ${r['notes']}'}',
                            ),
                            isThreeLine: true,
                            trailing: Text(
                              money.format(amount.abs()),
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700),
                            ),
                          ),
                        );
                      }),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }

  Widget _reportCard(String label, double value) => SizedBox(
        width: 150,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label),
                const SizedBox(height: 5),
                Text(
                  money.format(value),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  Future<void> _runExport(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_cleanError(e))),
        );
      }
    }
  }
}

class MorePage extends StatelessWidget {
  const MorePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('More')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 100),
        children: [
          ListTile(
            leading: const Icon(Icons.people_alt_outlined),
            title: const Text('Users & Accounts'),
            subtitle: const Text('Add, edit, deactivate, or reactivate'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SetupPage()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.category_outlined),
            title: const Text('Income & Expense Categories'),
            subtitle: const Text('Add, edit, deactivate, or reactivate categories'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CategoryManagerPage()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: const Text('App Lock'),
            subtitle: const Text('Protect the app with a PIN'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AppLockPage()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.savings_outlined),
            title: const Text('Monthly Budgets'),
            subtitle: const Text('Set category limits and track them on Home'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const BudgetsPage()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.event_repeat),
            title: const Text('Recurring Entries'),
            subtitle: const Text('Rent, salary, EMIs and subscriptions'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const RecurringPage()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.file_download_outlined),
            title: const Text('Export All Transactions (CSV)'),
            subtitle: const Text('Opens in Excel or Google Sheets'),
            onTap: () async {
              try {
                final rows = await AppDb.instance.searchTransactions(limit: 1000000);
                if (rows.isEmpty) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('No transactions to export.')),
                    );
                  }
                  return;
                }
                await CsvExport.share(rows, 'all_transactions');
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_cleanError(e))));
                }
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.storage_outlined),
            title: const Text('Backup & Restore'),
            subtitle: const Text('Local backups, restore, Google Drive, and app info'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const DataInfoPage()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.wifi),
            title: const Text('Wi-Fi Sync'),
            subtitle: const Text('Sync with another phone on the same Wi-Fi'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const WifiSyncPage()),
            ),
          ),
        ],
      ),
    );
  }
}

class CategoryManagerPage extends StatefulWidget {
  const CategoryManagerPage({super.key});
  @override
  State<CategoryManagerPage> createState()=>_CategoryManagerPageState();
}

class _CategoryManagerPageState extends State<CategoryManagerPage> {
  String kind = 'expense';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Categories')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editCategory(),
        icon: const Icon(Icons.add),
        label: const Text('Add Category'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'expense', label: Text('Expense')),
                ButtonSegment(value: 'income', label: Text('Income')),
              ],
              selected: {kind},
              onSelectionChanged: (value) {
                setState(() => kind = value.first);
              },
            ),
          ),
          Expanded(
            child: ValueListenableBuilder<int>(
              valueListenable: dataRevision,
              builder: (_, __, ___) => FutureBuilder<List<Map<String, dynamic>>>(
                future: AppDb.instance.categories(kind, activeOnly: false),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final rows = snapshot.data!;
                  if (rows.isEmpty) {
                    return const Center(child: Text('No categories yet.'));
                  }

                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                    itemCount: rows.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, index) {
                      final category = rows[index];
                      final active = (category['is_active'] as num).toInt() == 1;

                      return Card(
                        child: ListTile(
                          leading: Icon(
                            kind == 'income'
                                ? Icons.arrow_downward
                                : Icons.arrow_upward,
                          ),
                          title: Text(category['name'].toString()),
                          subtitle: Text(active ? 'Active' : 'Inactive'),
                          trailing: PopupMenuButton<String>(
                            onSelected: (value) async {
                              if (value == 'edit') {
                                await _editCategory(existing: category);
                              } else if (value == 'remove') {
                                final message = await AppDb.instance
                                    .removeCategorySafely(category['id'] as String);
                                if (!mounted) return;
                                ScaffoldMessenger.of(this.context).showSnackBar(
                                  SnackBar(content: Text(message)),
                                );
                                setState(() {});
                              } else if (value == 'reactivate') {
                                await AppDb.instance.reactivateCategory(
                                  category['id'] as String,
                                );
                                if (!mounted) return;
                                setState(() {});
                              }
                            },
                            itemBuilder: (_) => [
                              if (active)
                                const PopupMenuItem(
                                  value: 'edit',
                                  child: Text('Edit'),
                                ),
                              if (active)
                                const PopupMenuItem(
                                  value: 'remove',
                                  child: Text('Delete / Deactivate'),
                                ),
                              if (!active)
                                const PopupMenuItem(
                                  value: 'reactivate',
                                  child: Text('Reactivate'),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _editCategory({Map<String, dynamic>? existing}) async {
    final ctl = TextEditingController(
      text: existing == null ? '' : (existing['name']?.toString() ?? ''),
    );

    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          existing == null
              ? 'Add ${kind == 'income' ? 'Income' : 'Expense'} Category'
              : 'Edit Category',
        ),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Category name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (ok != true) {
      ctl.dispose();
      return;
    }

    try {
      if (existing == null) {
        await AppDb.instance.addCategory(kind, ctl.text);
      } else {
        await AppDb.instance.renameCategory(
          existing['id'] as String,
          kind,
          ctl.text,
        );
      }
      if (!mounted) return;
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_cleanError(e))),
      );
    } finally {
      ctl.dispose();
    }
  }
}

class SetupPage extends StatelessWidget {
  const SetupPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Users & Accounts')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _setupCard(
            icon: Icons.people_alt_outlined,
            title: 'Users',
            subtitle: 'Add, rename, deactivate, or reactivate family members.',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const UsersPage()),
            ),
          ),
          const SizedBox(height: 12),
          _setupCard(
            icon: Icons.account_balance_wallet_outlined,
            title: 'Accounts',
            subtitle: 'Bank, cash, card, UPI/wallet, shared, and other accounts.',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AccountsPage()),
            ),
          ),
        ],
      ),
    );
  }

  Widget _setupCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        leading: CircleAvatar(child: Icon(icon)),
        title: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(subtitle),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

class UsersPage extends StatelessWidget {
  const UsersPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Users')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showUserDialog(context),
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('Add User'),
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: dataRevision,
        builder: (context, _, __) {
          return FutureBuilder<List<Map<String, dynamic>>>(
            future: AppDb.instance.users(activeOnly: false),
            builder: (context, snapshot) {
              if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
              final users = snapshot.data!;
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                itemCount: users.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final user = users[index];
                  final active = (user['is_active'] as num?)?.toInt() == 1;
                  return ListTile(
                    leading: CircleAvatar(
                      child: Icon(active ? Icons.person : Icons.person_off_outlined),
                    ),
                    title: Text(user['name'].toString()),
                    subtitle: Text(active ? 'Active' : 'Inactive'),
                    trailing: PopupMenuButton<String>(
                      onSelected: (value) async {
                        if (value == 'rename') {
                          await _showUserDialog(context, user: user);
                        } else if (value == 'remove') {
                          await _removeUser(context, user);
                        } else if (value == 'reactivate') {
                          await _runAction(
                            context,
                            () => AppDb.instance.reactivateUser(user['id'] as String),
                            success: 'User reactivated.',
                          );
                        }
                      },
                      itemBuilder: (_) => [
                        if (active) const PopupMenuItem(value: 'rename', child: Text('Rename')),
                        if (active) const PopupMenuItem(value: 'remove', child: Text('Remove / Deactivate')),
                        if (!active) const PopupMenuItem(value: 'reactivate', child: Text('Reactivate')),
                      ],
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _showUserDialog(BuildContext context, {Map<String, dynamic>? user}) async {
    final controller = TextEditingController(text: user?['name']?.toString() ?? '');
    final editing = user != null;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(editing ? 'Rename User' : 'Add User'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'User name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              try {
                if (editing) {
                  await AppDb.instance.renameUser(user['id'] as String, controller.text);
                } else {
                  await AppDb.instance.addUser(controller.text);
                }
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              } catch (e) {
                if (dialogContext.mounted) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    SnackBar(content: Text(_cleanError(e))),
                  );
                }
              }
            },
            child: Text(editing ? 'Save' : 'Add'),
          ),
        ],
      ),
    );
  }

  Future<void> _removeUser(BuildContext context, Map<String, dynamic> user) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Remove ${user['name']}?'),
        content: const Text(
          'If this user has no transaction history, the user and unused accounts will be deleted. If history exists, the user and accounts will be deactivated so old records remain valid.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Continue')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final result = await AppDb.instance.removeUserSafely(user['id'] as String);
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result)));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_cleanError(e))));
      }
    }
  }
}

class AccountsPage extends StatelessWidget {
  const AccountsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Accounts')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAccountDialog(context),
        icon: const Icon(Icons.add_card),
        label: const Text('Add Account'),
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: dataRevision,
        builder: (context, _, __) {
          return FutureBuilder<List<Map<String, dynamic>>>(
            future: AppDb.instance.accountBalances(activeOnly: false),
            builder: (context, snapshot) {
              if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
              final accounts = snapshot.data!;
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                itemCount: accounts.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final account = accounts[index];
                  final active = (account['is_active'] as num?)?.toInt() == 1;
                  final balance = (account['current_balance'] as num?)?.toDouble() ?? 0;
                  return ListTile(
                    leading: CircleAvatar(
                      child: Icon(active ? Icons.account_balance_wallet : Icons.credit_card_off_outlined),
                    ),
                    title: Text(account['name'].toString()),
                    subtitle: Text(
                      '${account['user_name']} | ${account['type']} | ${active ? 'Active' : 'Inactive'}${(account['is_shared'] as num?)?.toInt() == 1 ? ' | Shared' : ''}',
                    ),
                    isThreeLine: true,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(money.format(balance), style: const TextStyle(fontWeight: FontWeight.w700)),
                        PopupMenuButton<String>(
                          onSelected: (value) async {
                            if (value == 'edit') {
                              await _showAccountDialog(context, account: account);
                            } else if (value == 'remove') {
                              await _removeAccount(context, account);
                            } else if (value == 'reactivate') {
                              await _runAction(
                                context,
                                () => AppDb.instance.reactivateAccount(account['id'] as String),
                                success: 'Account reactivated.',
                              );
                            }
                          },
                          itemBuilder: (_) => [
                            if (active) const PopupMenuItem(value: 'edit', child: Text('Edit')),
                            if (active) const PopupMenuItem(value: 'remove', child: Text('Remove / Deactivate')),
                            if (!active) const PopupMenuItem(value: 'reactivate', child: Text('Reactivate')),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _showAccountDialog(
    BuildContext context, {
    Map<String, dynamic>? account,
  }) async {
    final users = await AppDb.instance.users();
    if (!context.mounted) return;
    if (users.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add an active user before adding an account.')),
      );
      return;
    }

    final editing = account != null;
    String? userId = editing ? account['user_id'] as String? : users.first['id'] as String;
    final name = TextEditingController(text: editing ? account['name'].toString() : '');
    final opening = TextEditingController(
      text: editing ? ((account['opening_balance'] as num?)?.toDouble() ?? 0).toString() : '0',
    );
    String type = editing ? account['type'].toString() : 'Bank';
    bool shared = editing && (account['is_shared'] as num?)?.toInt() == 1;
    DateTime openingDate = editing
        ? (DateTime.tryParse(account['opening_date']?.toString() ?? '') ?? DateTime.now())
        : DateTime.now();

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) => AlertDialog(
          title: Text(editing ? 'Edit Account' : 'Add Account'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: userId,
                  decoration: const InputDecoration(labelText: 'Owner'),
                  items: users
                      .map((u) => DropdownMenuItem<String>(
                            value: u['id'] as String,
                            child: Text(u['name'].toString()),
                          ))
                      .toList(),
                  onChanged: editing ? null : (value) => setState(() => userId = value),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: name,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Account name'),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: type,
                  decoration: const InputDecoration(labelText: 'Account type'),
                  items: const [
                    DropdownMenuItem(value: 'Bank', child: Text('Bank')),
                    DropdownMenuItem(value: 'Cash', child: Text('Cash')),
                    DropdownMenuItem(value: 'Credit Card', child: Text('Credit Card')),
                    DropdownMenuItem(value: 'UPI / Wallet', child: Text('UPI / Wallet')),
                    DropdownMenuItem(value: 'Other', child: Text('Other')),
                  ],
                  onChanged: (value) => setState(() => type = value ?? type),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: opening,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                  decoration: const InputDecoration(labelText: 'Opening balance', prefixText: '₹ '),
                ),
                const SizedBox(height: 10),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Opening date'),
                  subtitle: Text(DateFormat('dd MMM yyyy').format(openingDate)),
                  trailing: const Icon(Icons.calendar_month),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: dialogContext,
                      initialDate: openingDate,
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                    );
                    if (picked != null) setState(() => openingDate = picked);
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Shared household account'),
                  value: shared,
                  onChanged: (value) => setState(() => shared = value),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                final openingValue = double.tryParse(opening.text.trim());
                if (openingValue == null) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    const SnackBar(content: Text('Enter a valid opening balance.')),
                  );
                  return;
                }
                try {
                  if (editing) {
                    await AppDb.instance.updateAccount(
                      id: account['id'] as String,
                      name: name.text,
                      type: type,
                      openingBalance: openingValue,
                      openingDate: openingDate,
                      isShared: shared,
                    );
                  } else {
                    await AppDb.instance.addAccount(
                      userId: userId!,
                      name: name.text,
                      type: type,
                      openingBalance: openingValue,
                      openingDate: openingDate,
                      isShared: shared,
                    );
                  }
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                } catch (e) {
                  if (dialogContext.mounted) {
                    ScaffoldMessenger.of(dialogContext).showSnackBar(
                      SnackBar(content: Text(_cleanError(e))),
                    );
                  }
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _removeAccount(BuildContext context, Map<String, dynamic> account) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Remove ${account['name']}?'),
        content: const Text(
          'An unused account will be deleted. An account with history will be deactivated so existing records remain valid.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Continue')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final result = await AppDb.instance.removeAccountSafely(account['id'] as String);
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result)));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_cleanError(e))));
      }
    }
  }
}

class DataInfoPage extends StatefulWidget {
  const DataInfoPage({super.key});

  @override
  State<DataInfoPage> createState() => _DataInfoPageState();
}

class _DataInfoPageState extends State<DataInfoPage> {
  bool? autoEnabled;
  bool driveEnabled = false;
  bool driveBusy = false;
  String? driveEmail;
  String? lastAuto;
  String? lastDrive;
  String? driveError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await AppDb.instance.autoBackupEnabled();
    final driveOn = await DriveBackupService.instance.enabled();
    final email = await DriveBackupService.instance.connectedEmail();
    final last = await AppDb.instance.meta('last_auto_backup');
    final gLast = await AppDb.instance.meta('last_gdrive_backup');
    final gErr = await AppDb.instance.meta('gdrive_last_error');
    if (!mounted) return;
    setState(() {
      driveError = (gErr == null || gErr.isEmpty) ? null : gErr;
      autoEnabled = enabled;
      driveEnabled = driveOn;
      driveEmail = email;
      lastAuto = last;
      lastDrive = gLast;
    });
  }

  String _dateText(String? value, String empty) {
    final parsed = DateTime.tryParse(value ?? '');
    if (parsed == null) return empty;
    return DateFormat('dd MMM yyyy, hh:mm a').format(parsed.toLocal());
  }

  Future<void> _connectDrive() async {
    setState(() => driveBusy = true);
    try {
      final email = await DriveBackupService.instance.connect();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Google Drive connected: $email')));
      }
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_cleanError(e))));
    } finally {
      if (mounted) setState(() => driveBusy = false);
    }
  }

  Future<void> _disconnectDrive() async {
    setState(() => driveBusy = true);
    try {
      await DriveBackupService.instance.disconnect();
      await _load();
    } finally {
      if (mounted) setState(() => driveBusy = false);
    }
  }

  Future<void> _syncDriveNow() async {
    setState(() => driveBusy = true);
    try {
      await DriveBackupService.instance.syncPendingBackups();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Google Drive backup folder is up to date.')));
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_cleanError(e))));
    } finally {
      if (mounted) setState(() => driveBusy = false);
    }
  }

  Future<void> _restoreExternal() async {
    try {
      final file = await AppDb.instance.pickExternalBackup();
      if (file == null || !mounted) return;
      final info = await AppDb.instance.inspectBackup(file);
      if (!mounted) return;
      await showRestoreConfirmation(context, info);
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_cleanError(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Backup & Restore')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text('Home Finance', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                  SizedBox(height: 8),
                  Text('App version: $appVersion'),
                  Text('Database schema: $databaseSchemaVersion'),
                  SizedBox(height: 8),
                  Text('Android + iPhone compatible backup format'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text('LOCAL BACKUP', style: TextStyle(fontWeight: FontWeight.w800)),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Automatic backup'),
            subtitle: Text(
              'Last: ${_dateText(lastAuto, 'No automatic backup yet')}\n'
              'Daily backups are created on app launch when due. Weekly and monthly recovery copies are also retained.',
            ),
            value: autoEnabled ?? true,
            onChanged: autoEnabled == null ? null : (value) async {
              await AppDb.instance.setAutoBackupEnabled(value);
              if (value) await AppDb.instance.autoBackupIfDue(force: true);
              await _load();
            },
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            icon: const Icon(Icons.backup_outlined),
            label: const Text('Backup Now'),
            onPressed: () async {
              try {
                final file = await AppDb.instance.createBackup();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Backup created successfully.')));
                }
                final shareFiles = <XFile>[XFile(file.path)];
                final manifest = File('${file.path}.json');
                if (await manifest.exists()) shareFiles.add(XFile(manifest.path));
                final shareResult = await SharePlus.instance.share(
                  ShareParams(files: shareFiles, text: 'Home Finance backup - v$appVersion'),
                );
                if (shareResult.status != ShareResultStatus.dismissed) {
                  await AppDb.instance.setMeta('last_shared_backup', DateTime.now().toIso8601String());
                  dataRevision.value++;
                }
                await _load();
              } catch (e) {
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_cleanError(e))));
              }
            },
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.history),
            label: const Text('View Local Backups'),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LocalBackupsPage())),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.file_open_outlined),
            label: const Text('Restore from Backup File'),
            onPressed: _restoreExternal,
          ),
          const SizedBox(height: 20),
          const Divider(),
          const SizedBox(height: 12),
          const Text('GOOGLE DRIVE BACKUP', style: TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(
            driveEnabled
                ? 'Connected: ${driveEmail ?? 'Google account'}\nLast upload: ${_dateText(lastDrive, 'Not uploaded yet')}'
                : 'Optional. Google Drive stores backup files only; it does not sync the live database.',
          ),
          if (driveEnabled && driveError != null) ...[
            const SizedBox(height: 8),
            Text(
              'Last Google Drive problem: ${driveError!.contains('|') ? driveError!.substring(driveError!.indexOf('|') + 1) : driveError!}',
              style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w600),
            ),
          ],
          const SizedBox(height: 12),
          if (!driveEnabled)
            FilledButton.icon(
              icon: const Icon(Icons.cloud_outlined),
              label: const Text('Connect Google Drive'),
              onPressed: driveBusy ? null : _connectDrive,
            )
          else ...[
            FilledButton.icon(
              icon: const Icon(Icons.cloud_sync_outlined),
              label: const Text('Sync Backup Folder Now'),
              onPressed: driveBusy ? null : _syncDriveNow,
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.cloud_download_outlined),
              label: const Text('Restore from Google Drive'),
              onPressed: driveBusy ? null : () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DriveBackupsPage())),
            ),
            TextButton(onPressed: driveBusy ? null : _disconnectDrive, child: const Text('Disconnect Google Drive')),
          ],
          if (driveBusy) const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: LinearProgressIndicator()),
          const SizedBox(height: 16),
          const Text(
            'Restore always validates the selected database and creates a fresh pre-restore safety backup before replacing current data. The current phone keeps its own device identity after restore, which prevents duplicate-device IDs during Wi-Fi sync.',
          ),
        ],
      ),
    );
  }
}

class LocalBackupsPage extends StatefulWidget {
  const LocalBackupsPage({super.key});
  @override
  State<LocalBackupsPage> createState() => _LocalBackupsPageState();
}

class _LocalBackupsPageState extends State<LocalBackupsPage> {
  late Future<List<BackupInfo>> future;

  @override
  void initState() {
    super.initState();
    future = AppDb.instance.localBackups();
  }

  void _refresh() => setState(() => future = AppDb.instance.localBackups());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Local Backups')),
      body: FutureBuilder<List<BackupInfo>>(
        future: future,
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final rows = snapshot.data!;
          if (rows.isEmpty) return const Center(child: Text('No local backups found.'));
          return RefreshIndicator(
            onRefresh: () async { _refresh(); await future; },
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: rows.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (_, index) {
                final item = rows[index];
                return Card(
                  child: ListTile(
                    leading: Icon(item.valid ? Icons.verified_outlined : Icons.warning_amber_rounded),
                    title: Text(DateFormat('dd MMM yyyy, hh:mm a').format(item.createdAt.toLocal())),
                    subtitle: Text('${item.type} • ${_formatBytes(item.size)} • ${item.transactions} transactions'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      await showRestoreConfirmation(context, item);
                      if (mounted) _refresh();
                    },
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class DriveBackupsPage extends StatefulWidget {
  const DriveBackupsPage({super.key});
  @override
  State<DriveBackupsPage> createState() => _DriveBackupsPageState();
}

class _DriveBackupsPageState extends State<DriveBackupsPage> {
  late Future<List<DriveBackupInfo>> future;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    future = DriveBackupService.instance.listDriveBackups();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Google Drive Backups')),
      body: Stack(
        children: [
          FutureBuilder<List<DriveBackupInfo>>(
            future: future,
            builder: (context, snapshot) {
              if (snapshot.hasError) return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_cleanError(snapshot.error!))));
              if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
              final rows = snapshot.data!;
              if (rows.isEmpty) return const Center(child: Text('No Google Drive backups found.'));
              return ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: rows.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, index) {
                  final item = rows[index];
                  return Card(
                    child: ListTile(
                      leading: const Icon(Icons.cloud_done_outlined),
                      title: Text(DateFormat('dd MMM yyyy, hh:mm a').format(item.modifiedAt.toLocal())),
                      subtitle: Text('${item.type} • ${_formatBytes(item.size)}'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: busy ? null : () async {
                        setState(() => busy = true);
                        try {
                          final file = await DriveBackupService.instance.downloadBackup(item);
                          final info = await AppDb.instance.inspectBackup(file);
                          if (context.mounted) await showRestoreConfirmation(context, info);
                        } catch (e) {
                          if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_cleanError(e))));
                        } finally {
                          if (mounted) setState(() => busy = false);
                        }
                      },
                    ),
                  );
                },
              );
            },
          ),
          if (busy) const Align(alignment: Alignment.topCenter, child: LinearProgressIndicator()),
        ],
      ),
    );
  }
}

String _formatBytes(int value) {
  if (value >= 1024 * 1024) return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
  if (value >= 1024) return '${(value / 1024).toStringAsFixed(0)} KB';
  return '$value B';
}

Future<void> showRestoreConfirmation(BuildContext context, BackupInfo info) async {
  final proceed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Restore this backup?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Created: ${DateFormat('dd MMM yyyy, hh:mm a').format(info.createdAt.toLocal())}'),
          Text('Type: ${info.type}'),
          Text('Schema: ${info.schemaVersion}'),
          Text('Users: ${info.users}'),
          Text('Accounts: ${info.accounts}'),
          Text('Transactions: ${info.transactions}'),
          Text('Size: ${_formatBytes(info.size)}'),
          Text('Checksum: ${info.checksumOk ? 'OK' : 'FAILED'}'),
          const SizedBox(height: 12),
          Text(info.valid
              ? 'A pre-restore safety backup of your current data will be created first.'
              : 'This backup cannot be restored because validation failed.'),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
        FilledButton(onPressed: info.valid ? () => Navigator.pop(dialogContext, true) : null, child: const Text('Restore')),
      ],
    ),
  );
  if (proceed != true || !context.mounted) return;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Confirm full restore'),
      content: const Text('Current users, accounts, categories and transactions will be replaced by this backup. The current database will first be saved as a pre-restore backup.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Restore Now')),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const AlertDialog(content: Row(children: [CircularProgressIndicator(), SizedBox(width: 16), Expanded(child: Text('Restoring backup…'))])),
  );
  try {
    await AppDb.instance.restoreBackup(info.file);
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    if (context.mounted) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Restore complete'),
          content: const Text('Home Finance data has been restored successfully.'),
          actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('OK'))],
        ),
      );
    }
  } catch (e) {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_cleanError(e))));
  }
}


class WifiSyncPage extends StatefulWidget {
  const WifiSyncPage({super.key});

  @override
  State<WifiSyncPage> createState() => _WifiSyncPageState();
}

class _WifiSyncPageState extends State<WifiSyncPage> {
  final hostController = TextEditingController();
  final codeController = TextEditingController();
  bool busy = false;
  String? lastSync;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _load();
    // Refresh so the screen notices when the host stops itself (timeout / wrong codes).
    _ticker = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _load() async {
    final lastHost = await AppDb.instance.meta('last_sync_host');
    final syncAt = await AppDb.instance.meta('last_sync_at');
    if (!mounted) return;
    if (hostController.text.isEmpty && lastHost != null) hostController.text = lastHost;
    setState(() => lastSync = syncAt);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    hostController.dispose();
    codeController.dispose();
    super.dispose();
  }

  String get lastSyncText {
    final d = DateTime.tryParse(lastSync ?? '');
    return d == null ? 'Never synced' : 'Last sync: ${DateFormat('dd MMM yyyy, hh:mm a').format(d)}';
  }

  Future<void> _startHost() async {
    setState(() => busy = true);
    try {
      await SyncService.instance.startHosting();
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_cleanError(e))));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _stopHost() async {
    await SyncService.instance.stopHosting();
    if (mounted) setState(() {});
  }

  Future<void> _syncNow() async {
    setState(() => busy = true);
    try {
      final result = await SyncService.instance.syncWithHost(
        host: hostController.text,
        code: codeController.text,
      );
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sync complete. New: ${result['receivedNew'] ?? 0}, updated: ${result['receivedUpdated'] ?? 0}.')),
        );
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_cleanError(e))));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = SyncService.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Wi-Fi Sync')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Use one phone as Host. On the other phone, enter the Host IP address and the 6-digit pairing code, then tap Sync Now. Both phones must be on the same Wi-Fi network.',
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('This phone as Host', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 10),
                  if (service.isHosting) ...[
                    SelectableText('Host IP: ${service.localAddress ?? 'Unavailable'}'),
                    SelectableText('Port: ${SyncService.port}'),
                    SelectableText('Pairing code: ${service.pairCode ?? ''}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: busy ? null : _stopHost,
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: const Text('Stop Host'),
                    ),
                  ] else ...[
                    if (service.stopReason != null) ...[
                      Text(service.stopReason!, style: TextStyle(color: Colors.orange.shade900)),
                      const SizedBox(height: 8),
                    ],
                    FilledButton.icon(
                      onPressed: busy ? null : _startHost,
                      icon: const Icon(Icons.wifi_tethering),
                      label: const Text('Start Host Sync'),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Sync this phone with Host', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 12),
                  TextField(
                    controller: hostController,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(labelText: 'Host IP address', hintText: 'Example: 192.168.1.25'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: codeController,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    decoration: const InputDecoration(labelText: '6-digit pairing code'),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: busy ? null : _syncNow,
                    icon: const Icon(Icons.sync),
                    label: Text(busy ? 'Syncing…' : 'Sync Now'),
                  ),
                  const SizedBox(height: 8),
                  Text(lastSyncText),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Sync is two-way and uses record IDs plus the latest edit time to merge changes. A safety backup is made before synchronization. Host Sync stops by itself after 10 minutes or 5 wrong codes. Keep it running until the other phone reports Sync complete.',
          ),
        ],
      ),
    );
  }
}

Future<void> showEntrySheet(
  BuildContext context, {
  String initial = 'income',
}) async {
  final users = await AppDb.instance.users();
  final accounts = await AppDb.instance.accounts();
  if (!context.mounted) return;

  if (users.isEmpty || accounts.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Add at least one active user and account first.')),
    );
    return;
  }

  String kind = const {'income', 'expense', 'transfer'}.contains(initial) ? initial : 'income';
  String? userId = users.first['id'] as String;
  String? accountId = _firstAccountId(accounts, userId);
  String? categoryId;
  DateTime date = DateTime.now();
  final amount = TextEditingController();
  final notes = TextEditingController();

  String? toUserId = users.first['id'] as String;
  String? toAccountId = _firstAccountId(accounts, toUserId);
  if (toAccountId == accountId && accounts.length > 1) {
    final alternative = accounts.firstWhere((a) => a['id'] != accountId);
    toUserId = alternative['user_id'] as String;
    toAccountId = alternative['id'] as String;
  }

  Future<List<Map<String, dynamic>>> loadCategories() => AppDb.instance.categories(kind);
  List<Map<String, dynamic>> categories = await loadCategories();
  categoryId = categories.isEmpty ? null : categories.first['id'] as String;
  if (!context.mounted) return;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, setSheetState) {
        final fromAccounts = accounts.where((a) => a['user_id'] == userId).toList();
        final toAccounts = accounts.where((a) => a['user_id'] == toUserId).toList();

        return Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            20,
            20,
            MediaQuery.of(sheetContext).viewInsets.bottom + 20,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  kind == 'transfer' ? 'Transfer Money' : 'Add Transaction',
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 12),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'income', label: Text('Income')),
                    ButtonSegment(value: 'expense', label: Text('Expense')),
                    ButtonSegment(value: 'transfer', label: Text('Transfer')),
                  ],
                  selected: {kind},
                  onSelectionChanged: (selection) async {
                    kind = selection.first;
                    if (kind != 'transfer') {
                      categories = await AppDb.instance.categories(kind);
                      categoryId = categories.isEmpty ? null : categories.first['id'] as String;
                    }
                    setSheetState(() {});
                  },
                ),
                const SizedBox(height: 12),
                if (kind != 'transfer') ...[
                  DropdownButtonFormField<String>(
                    initialValue: userId,
                    decoration: const InputDecoration(labelText: 'User'),
                    items: users
                        .map((u) => DropdownMenuItem<String>(
                              value: u['id'] as String,
                              child: Text(u['name'].toString()),
                            ))
                        .toList(),
                    onChanged: (value) => setSheetState(() {
                      userId = value;
                      accountId = _firstAccountId(accounts, userId);
                    }),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: accountId,
                    decoration: const InputDecoration(labelText: 'Account'),
                    items: fromAccounts
                        .map((a) => DropdownMenuItem<String>(
                              value: a['id'] as String,
                              child: Text(a['name'].toString()),
                            ))
                        .toList(),
                    onChanged: (value) => setSheetState(() => accountId = value),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: categoryId,
                    decoration: const InputDecoration(labelText: 'Category'),
                    items: categories
                        .map((c) => DropdownMenuItem<String>(
                              value: c['id'] as String,
                              child: Text(c['name'].toString()),
                            ))
                        .toList(),
                    onChanged: (value) => setSheetState(() => categoryId = value),
                  ),
                ] else ...[
                  const Text('From', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: userId,
                    decoration: const InputDecoration(labelText: 'From user'),
                    items: users
                        .map((u) => DropdownMenuItem<String>(
                              value: u['id'] as String,
                              child: Text(u['name'].toString()),
                            ))
                        .toList(),
                    onChanged: (value) => setSheetState(() {
                      userId = value;
                      accountId = _firstAccountId(accounts, userId);
                    }),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: accountId,
                    decoration: const InputDecoration(labelText: 'From account'),
                    items: fromAccounts
                        .map((a) => DropdownMenuItem<String>(
                              value: a['id'] as String,
                              child: Text(a['name'].toString()),
                            ))
                        .toList(),
                    onChanged: (value) => setSheetState(() => accountId = value),
                  ),
                  const SizedBox(height: 14),
                  const Text('To', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: toUserId,
                    decoration: const InputDecoration(labelText: 'To user'),
                    items: users
                        .map((u) => DropdownMenuItem<String>(
                              value: u['id'] as String,
                              child: Text(u['name'].toString()),
                            ))
                        .toList(),
                    onChanged: (value) => setSheetState(() {
                      toUserId = value;
                      toAccountId = _firstAccountId(accounts, toUserId);
                    }),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: toAccountId,
                    decoration: const InputDecoration(labelText: 'To account'),
                    items: toAccounts
                        .map((a) => DropdownMenuItem<String>(
                              value: a['id'] as String,
                              child: Text(a['name'].toString()),
                            ))
                        .toList(),
                    onChanged: (value) => setSheetState(() => toAccountId = value),
                  ),
                ],
                const SizedBox(height: 10),
                TextField(
                  controller: amount,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(prefixText: '₹ ', labelText: 'Amount'),
                ),
                const SizedBox(height: 10),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Date'),
                  subtitle: Text(DateFormat('dd MMM yyyy').format(date)),
                  trailing: const Icon(Icons.calendar_month),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: sheetContext,
                      initialDate: date,
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                    );
                    if (picked != null) setSheetState(() => date = picked);
                  },
                ),
                const SizedBox(height: 4),
                TextField(
                  controller: notes,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: 'Notes (optional)'),
                ),
                const SizedBox(height: 14),
                FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  onPressed: () async {
                    final value = double.tryParse(amount.text.trim());
                    if (value == null || value <= 0) {
                      ScaffoldMessenger.of(sheetContext).showSnackBar(
                        const SnackBar(content: Text('Enter a valid amount greater than zero.')),
                      );
                      return;
                    }
                    try {
                      if (kind == 'transfer') {
                        if (userId == null || accountId == null || toUserId == null || toAccountId == null) {
                          throw Exception('Select both From and To accounts.');
                        }
                        await AppDb.instance.transfer(
                          fromUser: userId!,
                          fromAccount: accountId!,
                          toUser: toUserId!,
                          toAccount: toAccountId!,
                          amount: value,
                          notes: notes.text,
                          date: date,
                        );
                      } else {
                        if (userId == null || accountId == null) {
                          throw Exception('Select a user and account.');
                        }
                        await AppDb.instance.addTxn(
                          userId: userId!,
                          accountId: accountId!,
                          purpose: kind,
                          amount: value,
                          categoryId: categoryId,
                          notes: notes.text,
                          date: date,
                        );
                      }
                      if (sheetContext.mounted) Navigator.pop(sheetContext);
                    } catch (e) {
                      if (sheetContext.mounted) {
                        ScaffoldMessenger.of(sheetContext).showSnackBar(
                          SnackBar(content: Text(_cleanError(e))),
                        );
                      }
                    }
                  },
                  child: Text(kind == 'transfer' ? 'Save Transfer' : 'Save'),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

Future<void> showEditTransactionSheet(
  BuildContext context,
  Map<String, dynamic> row,
) async {
  final linkedId = row['linked_id'] as String?;
  if (linkedId != null && linkedId.isNotEmpty) {
    await _showEditTransferSheet(context, row, linkedId);
    return;
  }

  final users = await AppDb.instance.users();
  final accounts = await AppDb.instance.accounts();
  final purpose = row['purpose']?.toString() ?? 'expense';
  final categories = await AppDb.instance.categories(purpose);
  if (!context.mounted) return;

  String? userId = row['user_id'] as String?;
  String? accountId = row['account_id'] as String?;
  String? categoryId = row['category_id'] as String?;
  if (!users.any((u) => u['id'] == userId)) userId = users.isEmpty ? null : users.first['id'] as String;
  if (!accounts.any((a) => a['id'] == accountId)) accountId = _firstAccountId(accounts, userId);
  if (!categories.any((c) => c['id'] == categoryId)) {
    categoryId = categories.isEmpty ? null : categories.first['id'] as String;
  }

  DateTime date = DateTime.tryParse(row['txn_date']?.toString() ?? '') ?? DateTime.now();
  final amount = TextEditingController(text: ((row['amount'] as num).toDouble().abs()).toString());
  final notes = TextEditingController(text: row['notes']?.toString() ?? '');

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, setSheetState) {
        final filteredAccounts = accounts.where((a) => a['user_id'] == userId).toList();
        return Padding(
          padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(sheetContext).viewInsets.bottom + 20),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Edit ${purpose == 'income' ? 'Income' : 'Expense'}',
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: userId,
                  decoration: const InputDecoration(labelText: 'User'),
                  items: users
                      .map((u) => DropdownMenuItem<String>(
                            value: u['id'] as String,
                            child: Text(u['name'].toString()),
                          ))
                      .toList(),
                  onChanged: (value) => setSheetState(() {
                    userId = value;
                    accountId = _firstAccountId(accounts, userId);
                  }),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: accountId,
                  decoration: const InputDecoration(labelText: 'Account'),
                  items: filteredAccounts
                      .map((a) => DropdownMenuItem<String>(
                            value: a['id'] as String,
                            child: Text(a['name'].toString()),
                          ))
                      .toList(),
                  onChanged: (value) => setSheetState(() => accountId = value),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: categoryId,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: categories
                      .map((c) => DropdownMenuItem<String>(
                            value: c['id'] as String,
                            child: Text(c['name'].toString()),
                          ))
                      .toList(),
                  onChanged: (value) => setSheetState(() => categoryId = value),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: amount,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(prefixText: '₹ ', labelText: 'Amount'),
                ),
                const SizedBox(height: 10),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Date'),
                  subtitle: Text(DateFormat('dd MMM yyyy').format(date)),
                  trailing: const Icon(Icons.calendar_month),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: sheetContext,
                      initialDate: date,
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                    );
                    if (picked != null) setSheetState(() => date = picked);
                  },
                ),
                TextField(
                  controller: notes,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: 'Notes (optional)'),
                ),
                const SizedBox(height: 14),
                FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  onPressed: () async {
                    final value = double.tryParse(amount.text.trim());
                    if (value == null || value <= 0 || userId == null || accountId == null) {
                      ScaffoldMessenger.of(sheetContext).showSnackBar(
                        const SnackBar(content: Text('Check user, account, and amount.')),
                      );
                      return;
                    }
                    try {
                      await AppDb.instance.updateTxn(
                        id: row['id'] as String,
                        userId: userId!,
                        accountId: accountId!,
                        purpose: purpose,
                        amount: value,
                        categoryId: categoryId,
                        notes: notes.text,
                        date: date,
                      );
                      if (sheetContext.mounted) Navigator.pop(sheetContext);
                    } catch (e) {
                      if (sheetContext.mounted) {
                        ScaffoldMessenger.of(sheetContext).showSnackBar(
                          SnackBar(content: Text(_cleanError(e))),
                        );
                      }
                    }
                  },
                  child: const Text('Save Changes'),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

Future<void> _showEditTransferSheet(
  BuildContext context,
  Map<String, dynamic> row,
  String linkedId,
) async {
  final linkedRows = await AppDb.instance.linkedTransfer(linkedId);
  if (!context.mounted) return;
  if (linkedRows.length != 2) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('This linked transfer is incomplete and cannot be edited.')),
    );
    return;
  }
  final positive = linkedRows.firstWhere((r) => (r['amount'] as num).toDouble() > 0);
  DateTime date = DateTime.tryParse(row['txn_date']?.toString() ?? '') ?? DateTime.now();
  final amount = TextEditingController(text: (positive['amount'] as num).toDouble().abs().toString());
  final notes = TextEditingController(text: row['notes']?.toString() ?? '');

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, setSheetState) => Padding(
        padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(sheetContext).viewInsets.bottom + 20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Edit Transfer', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              const Text('Account endpoints are fixed in this build. You can change amount, date, and notes.'),
              const SizedBox(height: 12),
              TextField(
                controller: amount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(prefixText: '₹ ', labelText: 'Amount'),
              ),
              const SizedBox(height: 10),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Date'),
                subtitle: Text(DateFormat('dd MMM yyyy').format(date)),
                trailing: const Icon(Icons.calendar_month),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: sheetContext,
                    initialDate: date,
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                  );
                  if (picked != null) setSheetState(() => date = picked);
                },
              ),
              TextField(
                controller: notes,
                maxLines: 2,
                decoration: const InputDecoration(labelText: 'Notes (optional)'),
              ),
              const SizedBox(height: 14),
              FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                onPressed: () async {
                  final value = double.tryParse(amount.text.trim());
                  if (value == null || value <= 0) {
                    ScaffoldMessenger.of(sheetContext).showSnackBar(
                      const SnackBar(content: Text('Enter a valid amount greater than zero.')),
                    );
                    return;
                  }
                  try {
                    await AppDb.instance.updateTransfer(
                      linkedId: linkedId,
                      amount: value,
                      notes: notes.text,
                      date: date,
                    );
                    if (sheetContext.mounted) Navigator.pop(sheetContext);
                  } catch (e) {
                    if (sheetContext.mounted) {
                      ScaffoldMessenger.of(sheetContext).showSnackBar(
                        SnackBar(content: Text(_cleanError(e))),
                      );
                    }
                  }
                },
                child: const Text('Save Changes'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class ReportService {
  static Future<void> exportXlsx(List<Map<String,dynamic>> rows, DateTime from, DateTime to) async {
    final book=xl.Excel.createExcel(); final sheet=book['Detailed Report'];
    sheet.appendRow(['From',DateFormat('dd MMM yyyy').format(from),'To',DateFormat('dd MMM yyyy').format(to)].map(xl.TextCellValue.new).toList());
    sheet.appendRow(['Date','User','Account','Type','Category','Amount','Notes','Linked Transfer ID'].map(xl.TextCellValue.new).toList());
    for(final r in rows){
      final type=r['purpose']=='transfer'?(r['type']=='transfer_in'?'Transfer In':'Transfer Out'):(r['purpose']=='income'?'Income':'Expense');
      sheet.appendRow([r['txn_date'].toString().substring(0,10),r['user_name']??'',r['account_name']??'',type,r['category_name']??'',(r['amount'] as num).toDouble().abs(),r['notes']??'',r['linked_id']??''].map((x)=>xl.TextCellValue(x.toString())).toList());
    }
    final dir=await getTemporaryDirectory(); final file=File(p.join(dir.path,'family_finance_${DateFormat('yyyyMMdd').format(from)}_${DateFormat('yyyyMMdd').format(to)}.xlsx')); await file.writeAsBytes(book.encode()!); await SharePlus.instance.share(ShareParams(files:[XFile(file.path)],text:'Home Finance detailed report'));
  }

  static Future<void> exportPdf(List<Map<String,dynamic>> rows, DateTime from, DateTime to) async {
    final doc=pw.Document(); double income=0,expense=0,tin=0,tout=0;
    for(final r in rows){final a=(r['amount'] as num).toDouble();if(r['purpose']=='income')income+=a;if(r['purpose']=='expense')expense+=a.abs();if(r['type']=='transfer_in')tin+=a.abs();if(r['type']=='transfer_out')tout+=a.abs();}
    doc.addPage(pw.MultiPage(build:(_)=>[pw.Text('Home Finance Detailed Report',style:pw.TextStyle(fontSize:20,fontWeight:pw.FontWeight.bold)),pw.Text('${DateFormat('dd MMM yyyy').format(from)} to ${DateFormat('dd MMM yyyy').format(to)}'),pw.SizedBox(height:10),pw.Text('Income: ${money.format(income)}   Expenses: ${money.format(expense)}   Surplus: ${money.format(income-expense)}'),pw.Text('Transfers In: ${money.format(tin)}   Transfers Out: ${money.format(tout)}'),pw.SizedBox(height:12),pw.TableHelper.fromTextArray(headers:['Date','User','Account','Type','Category','Amount'],data:rows.map((r){final type=r['purpose']=='transfer'?(r['type']=='transfer_in'?'Transfer In':'Transfer Out'):(r['purpose']=='income'?'Income':'Expense');return [r['txn_date'].toString().substring(0,10),r['user_name']??'',r['account_name']??'',type,r['category_name']??'',money.format((r['amount'] as num).toDouble().abs())];}).toList())]));
    final dir=await getTemporaryDirectory(); final file=File(p.join(dir.path,'family_finance_${DateFormat('yyyyMMdd').format(from)}_${DateFormat('yyyyMMdd').format(to)}.pdf')); await file.writeAsBytes(await doc.save()); await SharePlus.instance.share(ShareParams(files:[XFile(file.path)],text:'Home Finance detailed report'));
  }
}

String? _firstAccountId(List<Map<String, dynamic>> accounts, String? userId) {
  final owned = accounts.where((a) => a['user_id'] == userId).toList();
  return owned.isEmpty ? null : owned.first['id'] as String;
}

String _cleanError(Object error) {
  final value = error.toString();
  return value.startsWith('Exception: ') ? value.substring(11) : value;
}

Future<void> _runAction(
  BuildContext context,
  Future<void> Function() action, {
  required String success,
}) async {
  try {
    await action();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(success)));
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_cleanError(e))));
    }
  }
}
