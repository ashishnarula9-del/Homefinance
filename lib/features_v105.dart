part of 'main.dart';

// ---------------------------------------------------------------------------
// Home Finance 1.0.5 safety features (part of main.dart).
// ---------------------------------------------------------------------------

// ============================ Money formatting ==============================

/// Shows whole rupees without decimals (₹1,200) and paise only when present
/// (₹1,200.50), so nothing is silently rounded on screen.
class _MoneyFormat {
  const _MoneyFormat();

  static final NumberFormat _whole = NumberFormat.currency(
    locale: 'en_IN',
    symbol: '₹',
    decimalDigits: 0,
  );
  static final NumberFormat _paise = NumberFormat.currency(
    locale: 'en_IN',
    symbol: '₹',
    decimalDigits: 2,
  );

  String format(num value) {
    final rounded = (value.toDouble() * 100).roundToDouble() / 100;
    final isWhole = (rounded - rounded.truncateToDouble()).abs() < 0.005;
    return (isWhole ? _whole : _paise).format(rounded);
  }
}

// ================================ App lock ==================================

/// PIN lock. The PIN is stored (salted + hashed) in a small file that is NOT
/// part of database backups, so restoring a backup on a new phone never brings
/// an old PIN with it. This is a privacy lock against casual access; it does
/// not encrypt the database file.
class AppLock {
  AppLock._();
  static final AppLock instance = AppLock._();

  String? _salt;
  String? _hash;
  int _length = 4;
  int _fails = 0;
  DateTime? _until;

  bool get isEnabled => _hash != null && _hash!.isNotEmpty;
  int get length => _length;

  Duration? get lockRemaining {
    final until = _until;
    if (until == null) return null;
    final now = DateTime.now();
    return now.isBefore(until) ? until.difference(now) : null;
  }

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, 'app_lock.json'));
  }

  Future<void> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final decoded = jsonDecode(await f.readAsString());
      if (decoded is! Map) return;
      _salt = decoded['salt']?.toString();
      _hash = decoded['hash']?.toString();
      _length = (decoded['len'] as num?)?.toInt() ?? 4;
      _fails = (decoded['fails'] as num?)?.toInt() ?? 0;
      _until = DateTime.tryParse(decoded['until']?.toString() ?? '');
    } catch (_) {}
  }

  Future<void> _save() async {
    final f = await _file();
    await f.writeAsString(
      jsonEncode({
        'salt': _salt,
        'hash': _hash,
        'len': _length,
        'fails': _fails,
        'until': _until?.toIso8601String(),
      }),
      flush: true,
    );
  }

  String _digest(String pin, String salt) =>
      sha256.convert(utf8.encode('$salt:$pin:home-finance')).toString();

  bool _sameText(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  bool verify(String pin) {
    if (!isEnabled) return true;
    return _sameText(_digest(pin, _salt ?? ''), _hash ?? '');
  }

  Future<void> setPin(String pin) async {
    _salt = uuid.v4();
    _hash = _digest(pin, _salt!);
    _length = pin.length;
    _fails = 0;
    _until = null;
    await _save();
  }

  Future<void> clear() async {
    _salt = null;
    _hash = null;
    _fails = 0;
    _until = null;
    try {
      final f = await _file();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<void> recordFailure() async {
    _fails++;
    if (_fails >= 5) {
      final seconds = min(30 * (_fails - 4), 900);
      _until = DateTime.now().add(Duration(seconds: seconds));
    }
    try {
      await _save();
    } catch (_) {}
  }

  Future<void> recordSuccess() async {
    if (_fails == 0 && _until == null) return;
    _fails = 0;
    _until = null;
    try {
      await _save();
    } catch (_) {}
  }
}

class PinPad extends StatelessWidget {
  const PinPad({
    super.key,
    required this.length,
    required this.entered,
    required this.onDigit,
    required this.onBackspace,
  });

  final int length;
  final int entered;
  final void Function(String digit) onDigit;
  final VoidCallback onBackspace;

  Widget _key(String d) {
    return SizedBox(
      width: 84,
      height: 64,
      child: TextButton(
        onPressed: () => onDigit(d),
        child: Text(d, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < length; i++)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 7),
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < entered ? primary : Colors.black12,
                ),
              ),
          ],
        ),
        const SizedBox(height: 24),
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
        ])
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [for (final d in row) _key(d)],
          ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(width: 84, height: 64),
            _key('0'),
            SizedBox(
              width: 84,
              height: 64,
              child: IconButton(
                onPressed: onBackspace,
                icon: const Icon(Icons.backspace_outlined),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Wraps the whole app (via MaterialApp.builder). Keeps the app alive underneath
/// and covers it with the lock screen after 60 seconds in the background.
class AppLockGate extends StatefulWidget {
  const AppLockGate({super.key, required this.child});
  final Widget child;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  bool locked = false;
  DateTime? pausedAt;

  @override
  void initState() {
    super.initState();
    locked = AppLock.instance.isEnabled;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      pausedAt ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final at = pausedAt;
      pausedAt = null;
      if (AppLock.instance.isEnabled &&
          at != null &&
          DateTime.now().difference(at) > const Duration(seconds: 60)) {
        setState(() => locked = true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (locked)
          Positioned.fill(
            child: _LockScreen(onUnlocked: () => setState(() => locked = false)),
          ),
      ],
    );
  }
}

class _LockScreen extends StatefulWidget {
  const _LockScreen({required this.onUnlocked});
  final VoidCallback onUnlocked;

  @override
  State<_LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<_LockScreen> {
  String entry = '';
  String? message;

  String _waitText(Duration wait) =>
      'Too many wrong attempts. Try again in ${wait.inSeconds + 1}s.';

  void _digit(String d) {
    final wait = AppLock.instance.lockRemaining;
    if (wait != null) {
      setState(() => message = _waitText(wait));
      return;
    }
    final len = AppLock.instance.length;
    if (entry.length >= len) return;
    setState(() => entry += d);
    if (entry.length < len) return;
    if (AppLock.instance.verify(entry)) {
      unawaited(AppLock.instance.recordSuccess());
      widget.onUnlocked();
      return;
    }
    unawaited(AppLock.instance.recordFailure());
    final newWait = AppLock.instance.lockRemaining;
    setState(() {
      entry = '';
      message = newWait != null ? _waitText(newWait) : 'Wrong PIN. Try again.';
    });
  }

  void _backspace() {
    if (entry.isEmpty) return;
    setState(() => entry = entry.substring(0, entry.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline, size: 48),
                const SizedBox(height: 12),
                const Text('Enter PIN', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                SizedBox(
                  height: 40,
                  child: Text(
                    message ?? '',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.red.shade700),
                  ),
                ),
                PinPad(
                  length: AppLock.instance.length,
                  entered: entry.length,
                  onDigit: _digit,
                  onBackspace: _backspace,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AppLockPage extends StatefulWidget {
  const AppLockPage({super.key});

  @override
  State<AppLockPage> createState() => _AppLockPageState();
}

class _AppLockPageState extends State<AppLockPage> {
  Future<void> _setup() async {
    final ok = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const PinSetupPage()),
    );
    if (ok == true && mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('App lock PIN saved.')));
    }
  }

  Future<void> _turnOff() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Turn off App Lock?'),
        content: const Text('Anyone who opens the app will be able to see your finances.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Turn off')),
        ],
      ),
    );
    if (ok != true) return;
    await AppLock.instance.clear();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final enabled = AppLock.instance.isEnabled;
    return Scaffold(
      appBar: AppBar(title: const Text('App Lock')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            enabled
                ? 'App Lock is ON (${AppLock.instance.length}-digit PIN). The app asks for the PIN when opened, '
                    'and again after being in the background for over a minute.'
                : 'Protect your finances with a PIN.',
            style: const TextStyle(fontSize: 16),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _setup,
            icon: const Icon(Icons.pin_outlined),
            label: Text(enabled ? 'Change PIN' : 'Turn on App Lock'),
          ),
          if (enabled) ...[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _turnOff,
              icon: const Icon(Icons.lock_open),
              label: const Text('Turn off App Lock'),
            ),
          ],
          const SizedBox(height: 20),
          const Text(
            'Good to know:\n'
            '• There is no PIN recovery. If you forget it, uninstall and reinstall the app, then restore a backup '
            '(the PIN is not stored in backups). Keep a recent backup in Files or Google Drive.\n'
            '• This stops casual access. It does not encrypt the database or backup files, so keep backup files private.\n'
            '• After 5 wrong PINs the app makes you wait, and the wait grows with each further mistake.',
          ),
        ],
      ),
    );
  }
}

class PinSetupPage extends StatefulWidget {
  const PinSetupPage({super.key});

  @override
  State<PinSetupPage> createState() => _PinSetupPageState();
}

class _PinSetupPageState extends State<PinSetupPage> {
  int length = 4;
  String entry = '';
  String first = '';
  bool confirming = false;
  String? message;

  bool get _canChangeLength => !confirming && entry.isEmpty;

  Future<void> _digit(String d) async {
    if (entry.length >= length) return;
    setState(() {
      entry += d;
      message = null;
    });
    if (entry.length < length) return;
    if (!confirming) {
      setState(() {
        first = entry;
        entry = '';
        confirming = true;
        message = 'Enter the same PIN again to confirm.';
      });
      return;
    }
    if (entry == first) {
      await AppLock.instance.setPin(entry);
      if (mounted) Navigator.pop(context, true);
    } else {
      setState(() {
        entry = '';
        first = '';
        confirming = false;
        message = 'The PINs did not match. Start again.';
      });
    }
  }

  void _backspace() {
    if (entry.isEmpty) return;
    setState(() => entry = entry.substring(0, entry.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Set PIN')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ChoiceChip(
                      label: const Text('4 digits'),
                      selected: length == 4,
                      onSelected: _canChangeLength ? (_) => setState(() => length = 4) : null,
                    ),
                    const SizedBox(width: 10),
                    ChoiceChip(
                      label: const Text('6 digits'),
                      selected: length == 6,
                      onSelected: _canChangeLength ? (_) => setState(() => length = 6) : null,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  confirming ? 'Confirm your PIN' : 'Choose a PIN',
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 40,
                  child: Text(message ?? '', textAlign: TextAlign.center),
                ),
                PinPad(
                  length: length,
                  entered: entry.length,
                  onDigit: _digit,
                  onBackspace: _backspace,
                ),
                const SizedBox(height: 16),
                const Text(
                  'There is no PIN recovery. Keep a recent backup saved in Files or Google Drive.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
