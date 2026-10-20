import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:url_launcher/url_launcher.dart';

import 'gitlab.dart';

// The data protection keychain needs a provisioned Keychain Sharing
// entitlement, which a locally signed app does not have.
const _storage = FlutterSecureStorage(
  mOptions: MacOsOptions(usesDataProtectionKeychain: false),
);

const _window = MethodChannel('gview/window');

void main() => runApp(const GviewApp());

class GviewApp extends StatelessWidget {
  const GviewApp({super.key});

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) =>
        ThemeData(colorSchemeSeed: const Color(0xFFFC6D26), brightness: b);
    return MaterialApp(
      title: 'gview',
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      home: const Root(),
    );
  }
}

class Root extends StatefulWidget {
  const Root({super.key});

  @override
  State<Root> createState() => _RootState();
}

class _RootState extends State<Root> {
  GitLab? _client;
  bool _loaded = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    () async {
      final host = await _storage.read(key: 'host');
      final token = await _storage.read(key: 'token');
      setState(() {
        if (host != null && token != null) _client = GitLab(host, token);
        _loaded = true;
      });
    }();
  }

  Future<void> _signOut([String? message]) async {
    await _storage.delete(key: 'token');
    setState(() {
      _client = null;
      _message = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const Scaffold();
    final client = _client;
    if (client == null) {
      return SetupPage(
        message: _message,
        onConnected: (c) => setState(() => _client = c),
      );
    }
    return DashboardPage(client: client, onSignOut: _signOut);
  }
}

class SetupPage extends StatefulWidget {
  const SetupPage({super.key, required this.onConnected, this.message});

  final ValueChanged<GitLab> onConnected;
  final String? message;

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  final _host = TextEditingController(text: 'gitlab.com');
  final _token = TextEditingController();
  late String? _error = widget.message;
  bool _busy = false;

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final client = GitLab(_host.text, _token.text.trim());
    try {
      final info = await client.tokenInfo();
      if (!info.canReadApi) {
        throw AuthException(
          'This token has scopes ${info.scopes.join(', ')}. gview needs read_api.',
        );
      }
      await _storage.write(key: 'host', value: client.host);
      await _storage.write(key: 'token', value: client.token);
      widget.onConnected(client);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(32),
            children: [
              Text('Connect gview to GitLab', style: t.headlineMedium),
              const SizedBox(height: 8),
              Text(
                'gview only reads data. It needs a personal access token with '
                'the read_api scope, stored in your macOS keychain.',
                style: t.bodyMedium,
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _host,
                decoration: const InputDecoration(
                  labelText: 'GitLab host',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 24),
              _Step(
                n: 1,
                title: 'Create a token',
                body:
                    'GitLab opens with the name "gview" and the read_api '
                    'scope already selected. Pick an expiry date, click '
                    '"Create token" and copy it.',
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open GitLab token page'),
                  onPressed: () => launchUrl(GitLab.tokenPage(_host.text)),
                ),
              ),
              _Step(
                n: 2,
                title: 'Paste it here',
                body: 'gview checks the scope before saving it.',
                child: TextField(
                  controller: _token,
                  obscureText: true,
                  onSubmitted: (_) => _connect(),
                  decoration: const InputDecoration(
                    labelText: 'glpat-...',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              FilledButton(
                onPressed: _busy ? null : _connect,
                child: _busy
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Connect'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.n,
    required this.title,
    required this.body,
    required this.child,
  });

  final int n;
  final String title, body;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(radius: 14, child: Text('$n')),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(body),
                const SizedBox(height: 12),
                child,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

const _buckets = {
  Bucket.waiting: ('Waiting for review', Icons.hourglass_top, Colors.blue),
  Bucket.toReview: ('Waiting on me', Icons.rate_review, Colors.purple),
  Bucket.ready: ('Ready to merge', Icons.merge, Colors.green),
  Bucket.changes: ('Changes requested', Icons.edit_note, Colors.deepOrange),
  Bucket.drafts: ('Drafts', Icons.draw, Colors.blueGrey),
};

class DashboardPage extends StatefulWidget {
  const DashboardPage({
    super.key,
    required this.client,
    required this.onSignOut,
  });

  final GitLab client;
  final Future<void> Function([String? message]) onSignOut;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  Dashboard? _data;
  Object? _error;
  bool _loading = false;
  DateTime? _updated;
  Bucket? _selected = Bucket.toReview;
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(minutes: 5), (_) => _refresh());
    _window.setMethodCallHandler((call) async {
      if (call.method == 'refresh') await _refresh();
    });
  }

  void _announce(Dashboard? before, Dashboard after) {
    final n = notifyBuckets.fold(0, (n, b) => n + after.buckets[b]!.length);
    _window.invokeMethod('status', n == 0 ? '' : '$n');

    final news = arrivals(before, after);
    if (news.length > 5) {
      _window.invokeMethod('notify', {
        'title': '${news.length} MRs changed',
        'body': 'Open gview to see them.',
      });
      return;
    }
    for (final (b, mr) in news) {
      _window.invokeMethod('notify', {
        'title': _buckets[b]!.$1,
        'body': b == Bucket.toReview
            ? '${mr.title}\nasked by ${mr.askedBy.map((u) => '@$u').join(', ')}'
            : mr.title,
        'url': mr.url,
      });
    }
  }

  @override
  void dispose() {
    _window.setMethodCallHandler(null);
    _timer.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final d = await widget.client.load();
      if (!mounted) return;
      _announce(_data, d);
      setState(() {
        _data = d;
        _error = null;
        _updated = DateTime.now();
      });
    } on AuthException catch (e) {
      _window.invokeMethod('status', '!');
      _window.invokeMethod('notify', {
        'title': 'gview needs a new token',
        'body': '$e',
      });
      await widget.onSignOut('$e Create a new token.');
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onPanStart: (_) => _window.invokeMethod('drag'),
          child: AppBar(
            title: Row(
              children: [
                if (d?.avatarUrl != null) ...[
                  CircleAvatar(
                    radius: 14,
                    backgroundImage: NetworkImage(d!.avatarUrl!),
                  ),
                  const SizedBox(width: 12),
                ],
                Flexible(
                  child: Text(
                    d == null ? 'gview' : d.name,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            actions: [
              if (_updated != null)
                Text(
                  'Updated ${_clock(_updated!)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              IconButton(
                tooltip: 'Refresh',
                onPressed: _loading ? null : _refresh,
                icon: _loading
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
              ),
              IconButton(
                tooltip: 'Forget token',
                onPressed: () => widget.onSignOut(),
                icon: const Icon(Icons.logout),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
      body: d == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Text('Could not load: $_error'),
            )
          : _body(d),
    );
  }

  Widget _body(Dashboard d) {
    final t = Theme.of(context).textTheme;
    final expires = d.token.expiresAt;
    final daysLeft = expires?.difference(DateTime.now()).inDays;
    final sel = _selected;
    final list = [
      for (final b in sel == null ? Bucket.values : [sel])
        for (final mr in d.buckets[b]!) (b, mr),
    ];
    final (label, _, color) = sel == null
        ? ('All open MRs', null, null)
        : _buckets[sel]!;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        if (_error != null) _Banner('Last refresh failed: $_error'),
        if (daysLeft != null && daysLeft < 14)
          _Banner(
            'Your token expires in $daysLeft days. '
            'Forget it and create a new one before it stops working.',
          ),
        _Grid(
          minTileWidth: 150,
          children: [
            for (final MapEntry(key: b, value: (label, icon, color))
                in _buckets.entries)
              _CountCard(
                label: label,
                icon: icon,
                color: color,
                count: d.buckets[b]!.length,
                selected: b == _selected,
                onTap: () =>
                    setState(() => _selected = b == _selected ? null : b),
              ),
          ],
        ),
        const SizedBox(height: 24),
        Text(label, style: t.titleLarge?.copyWith(color: color)),
        const SizedBox(height: 8),
        if (list.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('Nothing here. Enjoy it.'),
            ),
          )
        else
          for (final (b, mr) in list) _MrTile(bucket: b, mr: mr),
        const SizedBox(height: 32),
        Text('Your last 30 days', style: t.titleLarge),
        const SizedBox(height: 8),
        _stats(d.stats),
      ],
    );
  }

  Widget _stats(Stats s) {
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    String? dur(Duration? d) => d == null ? null : _ago(d);
    final tiles = <(String, String?, IconData, Color)>[
      ('Merged this week', '${s.mergedWeek}', Icons.celebration, Colors.pink),
      ('Merged in 30 days', '${s.mergedMonth}', Icons.done_all, Colors.green),
      (
        'Merge streak',
        '${s.streak} workdays',
        Icons.local_fire_department,
        Colors.deepOrange,
      ),
      ('Median time to merge', dur(s.medianToMerge), Icons.timer, Colors.blue),
      ('Fastest merge', dur(s.fastestMerge), Icons.bolt, Colors.amber),
      (
        'Lines changed',
        '+${s.additions}  −${s.deletions}',
        Icons.difference,
        Colors.teal,
      ),
      ('Your biggest fan', s.topApprover, Icons.favorite, Colors.red),
      (
        'Favourite merge day',
        s.busiestWeekday == null ? null : weekdays[s.busiestWeekday! - 1],
        Icons.calendar_today,
        Colors.indigo,
      ),
      ('Oldest open MR', dur(s.oldestOpen), Icons.elderly, Colors.brown),
    ];
    return _Grid(
      minTileWidth: 200,
      children: [
        for (final (label, value, icon, color) in tiles)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 20, color: color),
                  const SizedBox(height: 8),
                  Text(
                    value ?? '–',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  Text(label, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _CountCard extends StatelessWidget {
  const _CountCard({
    required this.label,
    required this.icon,
    required this.color,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: selected ? color : Colors.transparent,
          width: 2,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: color),
              const SizedBox(height: 8),
              Text(
                '$count',
                style: Theme.of(context).textTheme.displaySmall
                    ?.copyWith(color: color),
              ),
              FittedBox(fit: BoxFit.scaleDown, child: Text(label, maxLines: 1)),
            ],
          ),
        ),
      ),
    );
  }
}

class _MrTile extends StatelessWidget {
  const _MrTile({required this.bucket, required this.mr});

  final Bucket bucket;
  final MergeRequest mr;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final (_, icon, color) = _buckets[bucket]!;
    final age = DateTime.now().difference(mr.createdAt);
    final ageColor = age.inDays >= 14
        ? Colors.red
        : age.inDays >= 7
        ? Colors.orange
        : cs.outline;
    final bang = mr.reference.lastIndexOf('!');
    final path = mr.reference.substring(0, bang);
    final slash = path.lastIndexOf('/');
    final repo = path.substring(slash + 1);
    final group = slash < 0 ? '' : path.substring(0, slash);

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: () => launchUrl(Uri.parse(mr.url)),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 5, color: color),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 14, 8, 14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CircleAvatar(
                        radius: 18,
                        backgroundColor: color.withValues(alpha: 0.15),
                        child: Icon(icon, color: color, size: 20),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              mr.title,
                              style: t.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text.rich(
                              TextSpan(
                                children: [
                                  if (group.isNotEmpty)
                                    TextSpan(
                                      text: '$group/',
                                      style: TextStyle(color: cs.outline),
                                    ),
                                  TextSpan(
                                    text: repo,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  TextSpan(
                                    text: ' ${mr.reference.substring(bang)}',
                                    style: TextStyle(
                                      color: color,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                              style: t.bodySmall,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                if (bucket == Bucket.toReview &&
                                    mr.askedBy.isNotEmpty)
                                  _Pill(
                                    Icons.person,
                                    'asked by ${mr.askedBy.map((u) => '@$u').join(', ')}',
                                    color,
                                  ),
                                _Pill(
                                  Icons.schedule,
                                  'opened ${_ago(age)} ago',
                                  ageColor,
                                ),
                                if (mr.approvals > 0)
                                  _Pill(
                                    Icons.thumb_up_alt,
                                    '${mr.approvals} approvals',
                                    Colors.green,
                                  ),
                                if (mr.notes > 0)
                                  _Pill(
                                    Icons.chat_bubble,
                                    '${mr.notes} comments',
                                    Colors.blue,
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.open_in_new, size: 18, color: cs.outline),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.icon, this.text, this.color);

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(
            text,
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// Wrap whose tiles stretch so every row spans the full width.
class _Grid extends StatelessWidget {
  const _Grid({required this.minTileWidth, required this.children});

  final double minTileWidth;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    const gap = 16.0;
    return LayoutBuilder(
      builder: (context, c) {
        final cols = ((c.maxWidth + gap) ~/ (minTileWidth + gap)).clamp(1, 99);
        // Without the slack, float rounding can push the last tile to a new row.
        final w = (c.maxWidth - gap * (cols - 1)) / cols - 0.01;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final child in children) SizedBox(width: w, child: child),
          ],
        );
      },
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Card(
      color: c.errorContainer,
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(text, style: TextStyle(color: c.onErrorContainer)),
      ),
    );
  }
}

String _ago(Duration d) {
  if (d.inDays > 0) return '${d.inDays}d';
  if (d.inHours > 0) return '${d.inHours}h';
  if (d.inMinutes > 0) return '${d.inMinutes}m';
  return '${d.inSeconds}s';
}

String _clock(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
