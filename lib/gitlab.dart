import 'dart:convert';
import 'dart:io';

class AuthException implements Exception {
  AuthException(this.message);
  final String message;
  @override
  String toString() => message;
}

class TokenInfo {
  TokenInfo(this.scopes, this.expiresAt);
  final List<String> scopes;
  final DateTime? expiresAt;

  bool get canReadApi => scopes.contains('read_api') || scopes.contains('api');
}

enum Bucket { waiting, toReview, ready, changes, drafts }

class MergeRequest {
  MergeRequest({
    required this.title,
    required this.url,
    required this.reference,
    required this.author,
    required this.draft,
    required this.createdAt,
    required this.updatedAt,
    required this.approvals,
    required this.notes,
    this.askedBy = const [],
  });

  factory MergeRequest.fromJson(
    Map<String, dynamic> j, [
    List<String> askedBy = const [],
  ]) => MergeRequest(
    title: j['title'] as String,
    url: j['webUrl'] as String,
    reference: j['reference'] as String,
    author: j['author']['username'] as String,
    draft: j['draft'] as bool,
    createdAt: DateTime.parse(j['createdAt'] as String),
    updatedAt: DateTime.parse(j['updatedAt'] as String),
    approvals: (j['approvedBy']['nodes'] as List).length,
    notes: j['userNotesCount'] as int? ?? 0,
    askedBy: askedBy,
  );

  final String title, url, reference, author;
  final bool draft;
  final DateTime createdAt, updatedAt;
  final int approvals, notes;
  final List<String> askedBy;
}

List<Map<String, dynamic>> _nodes(dynamic conn) =>
    (conn['nodes'] as List).cast<Map<String, dynamic>>();

/// Buckets the user's own open MRs the same way my-mr-status.sh does: a
/// reviewer who reviewed without approving means changes were requested.
/// So does an unresolved thread opened by another human, because people
/// comment without ever being added as reviewers, unless [me] wrote the
/// last reply and the thread is back with them to resolve. [me] defaults to
/// the author, but bot-authored MRs assigned to the user pass it explicitly.
Bucket classifyAuthored(Map<String, dynamic> mr, [String? me]) {
  final approvers = {for (final a in _nodes(mr['approvedBy'])) a['username']};
  final changes = _nodes(mr['reviewers']).any((r) {
    final state = r['mergeRequestInteraction']?['reviewState'];
    return (state == 'REVIEWED' || state == 'REQUESTED_CHANGES') &&
        !approvers.contains(r['username']);
  });
  me ??= mr['author']?['username'];
  final threads = mr['discussions'] == null
      ? <Map<String, dynamic>>[]
      : _nodes(mr['discussions']);
  final open = threads.any((d) {
    final first = _nodes(d['notes']).firstOrNull?['author'];
    return d['resolvable'] == true &&
        d['resolved'] != true &&
        first != null &&
        first['bot'] != true &&
        first['username'] != me &&
        _nodes(d['last'] ?? {'nodes': []})
                .firstOrNull?['author']?['username'] !=
            me;
  });
  if (changes || open) return Bucket.changes;
  if (mr['draft'] == true) return Bucket.drafts;
  if (const ['MERGEABLE', 'NEED_REBASE'].contains(mr['detailedMergeStatus'])) {
    return Bucket.ready;
  }
  return Bucket.waiting;
}

/// MRs where someone actually asked [me] for something, from pending todos.
/// Reviewer slots filled by approval rules or CODEOWNERS only produce
/// review_requested todos, which the query never fetches, so group
/// assignments stay out. Reacting to the note behind a todo acknowledges it.
List<MergeRequest> askedOfMe(List<Map<String, dynamic>> todos, String me) {
  final askers = <String, List<String>>{};
  final targets = <String, Map<String, dynamic>>{};
  for (final t in todos) {
    final mr = t['target'] as Map<String, dynamic>?;
    if (mr == null ||
        mr['state'] != 'opened' ||
        mr['draft'] == true ||
        mr['author']['username'] == me ||
        !canApprove(mr) ||
        _nodes(mr['approvedBy']).any((a) => a['username'] == me) ||
        _nodes(t['note']?['awardEmoji'] ?? {'nodes': []})
            .any((e) => e['user']['username'] == me)) {
      continue;
    }
    final url = mr['webUrl'] as String;
    targets[url] = mr;
    final who = askers.putIfAbsent(url, () => []);
    final asker = t['author']['username'] as String;
    if (!who.contains(asker)) who.add(asker);
  }
  return [
    for (final MapEntry(key: url, value: mr) in targets.entries)
      MergeRequest.fromJson(mr, askers[url]!),
  ];
}

bool canApprove(Map<String, dynamic> mr) =>
    mr['userPermissions']?['canApprove'] != false;

class Stats {
  Stats({
    required this.mergedWeek,
    required this.mergedMonth,
    required this.medianToMerge,
    required this.fastestMerge,
    required this.additions,
    required this.deletions,
    required this.topApprover,
    required this.busiestWeekday,
    required this.streak,
    required this.oldestOpen,
  });

  factory Stats.from({
    required List<Map<String, dynamic>> merged,
    required int mergedWeek,
    required int mergedMonth,
    required List<MergeRequest> open,
    required DateTime now,
  }) {
    final durations = <Duration>[];
    final approvers = <String, int>{};
    final weekdays = <int, int>{};
    final days = <DateTime>{};
    var add = 0, del = 0;
    for (final m in merged) {
      final created = DateTime.parse(m['createdAt'] as String);
      final mergedAt = DateTime.parse(m['mergedAt'] as String).toLocal();
      durations.add(mergedAt.difference(created));
      weekdays.update(mergedAt.weekday, (v) => v + 1, ifAbsent: () => 1);
      days.add(DateTime(mergedAt.year, mergedAt.month, mergedAt.day));
      add += (m['diffStatsSummary']?['additions'] as int?) ?? 0;
      del += (m['diffStatsSummary']?['deletions'] as int?) ?? 0;
      for (final a in _nodes(m['approvedBy'])) {
        approvers.update(a['name'] as String, (v) => v + 1, ifAbsent: () => 1);
      }
    }
    durations.sort();
    String? top(Map<String, int> m) => m.isEmpty
        ? null
        : m.entries.reduce((a, b) => b.value > a.value ? b : a).key;
    final busiest = weekdays.isEmpty
        ? null
        : weekdays.entries.reduce((a, b) => b.value > a.value ? b : a).key;
    final oldest = open.isEmpty
        ? null
        : open
              .map((m) => now.difference(m.createdAt))
              .reduce((a, b) => a > b ? a : b);

    return Stats(
      mergedWeek: mergedWeek,
      mergedMonth: mergedMonth,
      medianToMerge: durations.isEmpty
          ? null
          : durations[durations.length ~/ 2],
      fastestMerge: durations.isEmpty ? null : durations.first,
      additions: add,
      deletions: del,
      topApprover: top(approvers),
      busiestWeekday: busiest,
      streak: workdayStreak(days, now),
      oldestOpen: oldest,
    );
  }

  final int mergedWeek, mergedMonth, additions, deletions, streak;
  final Duration? medianToMerge, fastestMerge, oldestOpen;
  final String? topApprover;
  final int? busiestWeekday;
}

/// Consecutive workdays with at least one merge, ending today (or yesterday,
/// so the streak does not reset before you had a chance to merge today).
int workdayStreak(Set<DateTime> days, DateTime now) {
  var d = DateTime(now.year, now.month, now.day);
  bool workday(DateTime d) => d.weekday <= DateTime.friday;
  DateTime prev(DateTime d) => DateTime(d.year, d.month, d.day - 1);
  if (!days.contains(d)) d = prev(d);
  var n = 0;
  while (true) {
    if (!workday(d)) {
      d = prev(d);
      continue;
    }
    if (!days.contains(d)) return n;
    n++;
    d = prev(d);
  }
}

class Dashboard {
  Dashboard({
    required this.username,
    required this.name,
    required this.avatarUrl,
    required this.buckets,
    required this.stats,
    required this.token,
  });

  final String username, name;
  final String? avatarUrl;
  final Map<Bucket, List<MergeRequest>> buckets;
  final Stats stats;
  final TokenInfo token;
}

const _query = r'''
query($month: Time!, $week: Time!) {
  currentUser {
    username name avatarUrl
    authored: authoredMergeRequests(state: opened, first: 100) { nodes { ...Mr } }
    todos(state: pending, type: [MERGEREQUEST], action: [directly_addressed, mentioned, assigned, marked], first: 100) {
      nodes { author { username } note { awardEmoji { nodes { user { username } } } } target { ... on MergeRequest { ...Mr state } } }
    }
    merged: authoredMergeRequests(state: merged, mergedAfter: $month) { count }
    week: authoredMergeRequests(state: merged, mergedAfter: $week) { count }
  }
}
fragment Mr on MergeRequest {
  title webUrl reference(full: true) draft createdAt updatedAt userNotesCount
  author { username }
  approvedBy { nodes { username } }
  reviewers { nodes { username mergeRequestInteraction { reviewState } } }
  detailedMergeStatus userPermissions { canApprove }
  discussions(first: 100) { nodes { resolvable resolved notes(first: 1) { nodes { author { username bot } } } last: notes(last: 1) { nodes { author { username } } } } }
}
''';

const _mergedQuery = r'''
query($month: Time!, $after: String) {
  currentUser {
    merged: authoredMergeRequests(state: merged, mergedAfter: $month, first: 100, after: $after) {
      pageInfo { hasNextPage endCursor }
      nodes { createdAt mergedAt diffStatsSummary { additions deletions } approvedBy { nodes { name } } }
    }
  }
}
''';

class GitLab {
  GitLab(String host, this.token) : host = normalizeHost(host);

  final String host, token;
  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 10);

  static String normalizeHost(String h) => h
      .trim()
      .replaceFirst(RegExp(r'^https?://'), '')
      .replaceFirst(RegExp(r'/+$'), '');

  static Uri tokenPage(String host) => Uri.https(
    normalizeHost(host),
    '/-/user_settings/personal_access_tokens',
    {'name': 'gview', 'scopes': 'read_api'},
  );

  Future<dynamic> _send(String method, String path, [Object? body]) async {
    final req = await _http.openUrl(method, Uri.https(host, path));
    req.headers.set('Authorization', 'Bearer $token');
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close().timeout(const Duration(seconds: 30));
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw AuthException(
        'GitLab rejected the token (HTTP ${res.statusCode}).',
      );
    }
    if (res.statusCode >= 400) {
      throw HttpException('HTTP ${res.statusCode} from $host$path');
    }
    return jsonDecode(text);
  }

  Future<TokenInfo> tokenInfo() async {
    final j = await _send(
      'GET',
      '/api/v4/personal_access_tokens/self',
    ) as Map<String, dynamic>;
    final exp = j['expires_at'] as String?;
    return TokenInfo(
      (j['scopes'] as List).cast<String>(),
      exp == null ? null : DateTime.parse(exp),
    );
  }

  Future<Map<String, dynamic>> _graphql(
    String query,
    Map<String, dynamic> variables,
  ) async {
    final j = await _send('POST', '/api/graphql', {
      'query': query,
      'variables': variables,
    }) as Map<String, dynamic>;
    if (j['errors'] != null) throw Exception(j['errors'][0]['message']);
    return j['data']['currentUser'] as Map<String, dynamic>;
  }

  // ponytail: stops at 1000 merges per 30 days; raise the page cap if that's not enough.
  Future<List<Map<String, dynamic>>> _merged(String month) async {
    final all = <Map<String, dynamic>>[];
    String? after;
    for (var page = 0; page < 10; page++) {
      final conn = (await _graphql(_mergedQuery, {
        'month': month,
        'after': after,
      }))['merged'];
      all.addAll(_nodes(conn));
      if (conn['pageInfo']['hasNextPage'] != true) break;
      after = conn['pageInfo']['endCursor'] as String;
    }
    return all;
  }

  Future<Dashboard> load() async {
    final now = DateTime.now();
    final monday = DateTime(now.year, now.month, now.day - (now.weekday - 1));
    final month = now
        .subtract(const Duration(days: 30))
        .toUtc()
        .toIso8601String();
    final results = await Future.wait([
      _graphql(_query, {
        'month': month,
        'week': monday.toUtc().toIso8601String(),
      }),
      tokenInfo(),
      _merged(month),
    ]);
    final u = results[0] as Map<String, dynamic>;
    final me = u['username'] as String;

    final buckets = {for (final b in Bucket.values) b: <MergeRequest>[]};
    final authored = _nodes(u['authored']);
    for (final m in authored) {
      buckets[classifyAuthored(m)]!.add(MergeRequest.fromJson(m));
    }
    final todos = _nodes(u['todos']);
    final owned = {
      for (final t in todos)
        if (t['target'] case final Map<String, dynamic> m
            when m['state'] == 'opened' &&
                !canApprove(m) &&
                !authored.any((a) => a['webUrl'] == m['webUrl']))
          m['webUrl']: m,
    };
    for (final m in owned.values) {
      buckets[classifyAuthored(m, me)]!.add(MergeRequest.fromJson(m));
    }
    buckets[Bucket.toReview] = askedOfMe(todos, me);
    for (final l in buckets.values) {
      l.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    }

    var avatar = u['avatarUrl'] as String?;
    if (avatar != null && avatar.startsWith('/')) {
      avatar = 'https://$host$avatar';
    }

    return Dashboard(
      username: me,
      name: u['name'] as String,
      avatarUrl: avatar,
      buckets: buckets,
      token: results[1] as TokenInfo,
      stats: Stats.from(
        merged: results[2] as List<Map<String, dynamic>>,
        mergedMonth: u['merged']['count'] as int,
        mergedWeek: u['week']['count'] as int,
        open: authored.map(MergeRequest.fromJson).toList(),
        now: now,
      ),
    );
  }
}

const notifyBuckets = [Bucket.toReview, Bucket.ready, Bucket.changes];

/// MRs that entered a bucket worth a notification since [before].
List<(Bucket, MergeRequest)> arrivals(Dashboard? before, Dashboard after) {
  if (before == null) return [];
  return [
    for (final b in notifyBuckets)
      for (final mr in after.buckets[b]!)
        if (!before.buckets[b]!.any((o) => o.url == mr.url)) (b, mr),
  ];
}
