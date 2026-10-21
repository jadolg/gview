import 'package:flutter_test/flutter_test.dart';
import 'package:gview/gitlab.dart';

Map<String, dynamic> mr({
  bool draft = false,
  String status = 'NOT_APPROVED',
  List<String> approvers = const [],
  Map<String, String> reviewers = const {},
  List<Map<String, dynamic>> threads = const [],
}) => {
  'author': {'username': 'me'},
  'discussions': {'nodes': threads},
  'draft': draft,
  'detailedMergeStatus': status,
  'approvedBy': {
    'nodes': [
      for (final a in approvers) {'username': a},
    ],
  },
  'reviewers': {
    'nodes': [
      for (final MapEntry(:key, :value) in reviewers.entries)
        {
          'username': key,
          'mergeRequestInteraction': {'reviewState': value},
        },
    ],
  },
};

void main() {
  test('classifyAuthored', () {
    expect(classifyAuthored(mr()), Bucket.waiting);
    expect(classifyAuthored(mr(status: 'MERGEABLE')), Bucket.ready);
    expect(classifyAuthored(mr(status: 'NEED_REBASE')), Bucket.ready);
    expect(
      classifyAuthored(mr(draft: true, status: 'MERGEABLE')),
      Bucket.drafts,
    );
    expect(
      classifyAuthored(mr(reviewers: {'a': 'REQUESTED_CHANGES'})),
      Bucket.changes,
    );
    expect(classifyAuthored(mr(reviewers: {'a': 'REVIEWED'})), Bucket.changes);
    expect(
      classifyAuthored(
        mr(status: 'MERGEABLE', approvers: ['a'], reviewers: {'a': 'REVIEWED'}),
      ),
      Bucket.ready,
    );

    Map<String, dynamic> thread(
      String by, {
      bool bot = false,
      bool resolvable = true,
      bool resolved = false,
      String? reply,
    }) => {
      'resolvable': resolvable,
      'resolved': resolved,
      'last': {
        'nodes': [
          {
            'author': {'username': reply ?? by},
          },
        ],
      },
      'notes': {
        'nodes': [
          {
            'author': {'username': by, 'bot': bot},
          },
        ],
      },
    };
    expect(classifyAuthored(mr(threads: [thread('a')])), Bucket.changes);
    for (final t in [
      thread('a', resolved: true),
      thread('a', resolvable: false),
      thread('ai', bot: true),
      thread('me'),
      thread('a', reply: 'me'),
    ]) {
      expect(classifyAuthored(mr(threads: [t])), Bucket.waiting);
    }
    expect(
      classifyAuthored({
        ...mr(threads: [thread('me')]),
        'author': {'username': 'bot'},
      }, 'me'),
      Bucket.waiting,
    );
  });

  test('askedOfMe dedupes MRs and drops what is not really mine', () {
    Map<String, dynamic> target(
      String url, {
      String state = 'opened',
      bool draft = false,
      String author = 'x',
      List<String> approvers = const [],
      bool canApprove = true,
    }) => {
      ...mr(draft: draft, approvers: approvers),
      'userPermissions': {'canApprove': canApprove},
      'title': url,
      'webUrl': url,
      'reference': url,
      'state': state,
      'author': {'username': author},
      'createdAt': '2026-09-01T00:00:00Z',
      'updatedAt': '2026-09-01T00:00:00Z',
    };
    Map<String, dynamic> todo(
      String by,
      Map<String, dynamic>? t, {
      List<String> reacted = const [],
    }) => {
      'author': {'username': by},
      'note': {
        'awardEmoji': {
          'nodes': [
            for (final u in reacted)
              {
                'user': {'username': u},
              },
          ],
        },
      },
      'target': t,
    };

    final got = askedOfMe([
      todo('a', target('keep')),
      todo('b', target('keep')),
      todo('a', target('keep')),
      todo('a', target('merged', state: 'merged')),
      todo('a', target('draft', draft: true)),
      todo('a', target('mine', author: 'me')),
      todo('a', target('approved', approvers: ['me'])),
      todo('a', null),
      todo('a', target('acked'), reacted: ['me']),
      todo('a', target('bot-pushed', canApprove: false)),
      todo('a', target('keep'), reacted: ['b']),
    ], 'me');
    expect(got.map((m) => m.url), ['keep']);
    expect(got.single.askedBy, ['a', 'b']);
  });

  test('workdayStreak skips weekends and tolerates no merge yet today', () {
    final monday = DateTime(2026, 9, 21);
    final days = {
      DateTime(2026, 9, 17),
      DateTime(2026, 9, 18),
      DateTime(2026, 9, 21),
    };
    expect(workdayStreak(days, monday), 3);
    expect(workdayStreak(days, DateTime(2026, 9, 22, 9)), 3);
    expect(workdayStreak(days, DateTime(2026, 9, 23)), 0);
    expect(workdayStreak({}, monday), 0);
  });

  test('normalizeHost', () {
    expect(
      GitLab.normalizeHost(' https://gitlab.example.com/ '),
      'gitlab.example.com',
    );
    expect(
      GitLab.tokenPage('gitlab.com').toString(),
      'https://gitlab.com/-/user_settings/personal_access_tokens?name=gview&scopes=read_api',
    );
  });

  test('arrivals only reports MRs new to a watched bucket', () {
    MergeRequest m(String url) => MergeRequest(
      title: url,
      url: url,
      reference: url,
      author: 'x',
      draft: false,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      approvals: 0,
      notes: 0,
    );
    Dashboard dash(Map<Bucket, List<String>> b) => Dashboard(
      username: 'me',
      name: 'Me',
      avatarUrl: null,
      buckets: {
        for (final k in Bucket.values) k: [for (final u in b[k] ?? []) m(u)],
      },
      token: TokenInfo(['read_api'], null),
      stats: Stats.from(
        merged: [],
        mergedWeek: 0,
        mergedMonth: 0,
        open: [],
        now: DateTime(2026),
      ),
    );

    final before = dash({
      Bucket.waiting: ['a'],
      Bucket.ready: ['b'],
    });
    final after = dash({
      Bucket.ready: ['a', 'b'],
      Bucket.waiting: ['c'],
      Bucket.toReview: ['d'],
    });
    expect(arrivals(null, after), isEmpty);
    expect(
      [for (final (b, mr) in arrivals(before, after)) '${b.name}:${mr.url}'],
      ['toReview:d', 'ready:a'],
    );
  });
}
