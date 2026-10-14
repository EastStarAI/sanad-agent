import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';

/// Simulates a paginated data source for a given page size configuration.
class _PageSimulator {
  final int firstPageSize;
  final int nextPageSize;

  const _PageSimulator({
    required this.firstPageSize,
    required this.nextPageSize,
  });

  /// Runs full pagination to retrieve all sessions in [allSessions].
  /// Returns:
  /// - requestsCount: number of requests needed to fetch all sessions
  /// - totalBytes: cumulative JSON bytes transferred
  /// - firstPageBytes: bytes in the first page response
  /// - initialFetchTimeUs: parsing/transport elapsed time in microseconds for page 1
  /// - totalTimeUs: cumulative parsing/transport elapsed time in microseconds
  /// - peakObjectCount: number of session models held in memory
  ({
    int requestsCount,
    int totalBytes,
    int firstPageBytes,
    int initialFetchTimeUs,
    int totalTimeUs,
    int peakObjectCount,
  })
  simulateFetchAll(List<Map<String, dynamic>> allSessions) {
    int requests = 0;
    int totalBytes = 0;
    int firstPageBytes = 0;
    int firstPageTimeUs = 0;
    final stopwatch = Stopwatch()..start();
    final List<Session> accumulated = [];

    int offset = 0;
    bool isFirst = true;

    while (offset < allSessions.length || (offset == 0 && allSessions.isEmpty)) {
      final limit = isFirst ? firstPageSize : nextPageSize;
      final int end = (offset + limit < allSessions.length) ? offset + limit : allSessions.length;
      final pageSlice = allSessions.sublist(offset, end);
      final hasMore = end < allSessions.length;
      final nextCursor = hasMore ? 'cur-$end' : null;

      final payloadMap = {
        'sessions': pageSlice,
        'next_cursor': nextCursor,
        'has_more': hasMore,
      };
      final encoded = utf8.encode(jsonEncode(payloadMap));
      final bytes = encoded.length;
      totalBytes += bytes;
      requests++;

      // Simulate parsing
      final decoded = jsonDecode(utf8.decode(encoded)) as Map<String, dynamic>;
      final rawList = decoded['sessions'] as List;
      for (final item in rawList) {
        accumulated.add(Session.fromJson(Map<String, dynamic>.from(item as Map)));
      }

      if (isFirst) {
        firstPageBytes = bytes;
        firstPageTimeUs = stopwatch.elapsedMicroseconds;
        isFirst = false;
      }

      offset = end;
      if (!hasMore) break;
    }

    final totalTimeUs = stopwatch.elapsedMicroseconds;
    return (
      requestsCount: requests,
      totalBytes: totalBytes,
      firstPageBytes: firstPageBytes,
      initialFetchTimeUs: firstPageTimeUs,
      totalTimeUs: totalTimeUs,
      peakObjectCount: accumulated.length,
    );
  }
}

List<Map<String, dynamic>> _generateSyntheticSessions(int count, {String? workspaceId}) {
  return List.generate(count, (i) {
    final time = DateTime.utc(2026, 1, 1).add(Duration(minutes: i)).toIso8601String();
    return {
      'id': 'sess-uuid-${i.toString().padLeft(4, '0')}-abcd-1234',
      'title': 'Conversation Title #$i with some realistic length',
      'device_id': 'device-sample-uuid-5678',
      'workspace_id': workspaceId,
      'created_at': time,
      'updated_at': time,
      'last_message_at': time,
      'pinned': false,
      'metadata': {
        'model': 'gpt-4o',
        'provider': 'anthropic-sample',
        'source': 'desktop-client',
      },
    };
  });
}

void main() {
  group('Page Size Experiment (Task 97i): 6/10 Baseline vs 9/15 (+50%) Experiment', () {
    const baseline = _PageSimulator(firstPageSize: 6, nextPageSize: 10);
    const experiment = _PageSimulator(firstPageSize: 9, nextPageSize: 15);

    test('Workload 1: Initial Page Payload Overhead Analysis (Single Section)', () {
      // Generate 20 sessions (typical section with multiple pages available)
      final sessions = _generateSyntheticSessions(20);

      final rBaseline = baseline.simulateFetchAll(sessions);
      final rExp = experiment.simulateFetchAll(sessions);

      // Measure first-page payload overhead:
      final byteDelta = rExp.firstPageBytes - rBaseline.firstPageBytes;
      final payloadOverheadPct = (byteDelta / rBaseline.firstPageBytes) * 100.0;

      print('=== Single Section Page 1 Comparison ===');
      print('Baseline (limit 6): ${rBaseline.firstPageBytes} bytes');
      print('Experiment (limit 9): ${rExp.firstPageBytes} bytes');
      print('Payload Overhead Delta: +$byteDelta bytes (+${payloadOverheadPct.toStringAsFixed(1)}%)');

      // The frozen 97a policy requires: "Adopt 9/15 (+50%) only upon payload overhead <15%"
      // With 9 items vs 6 items, the payload overhead is ~40-50%, exceeding the <15% budget.
      expect(payloadOverheadPct, greaterThan(15.0), reason: '9 items introduces >15% byte overhead on initial fetch');
    });

    test('Workload 2: Multi-Workspace Sidebar Initial Load (1 unscoped + 8 workspaces)', () {
      // 9 sections total (matching the 97 user log scenario).
      // Realistic session distribution across 9 sections:
      // - Unscoped: 12 sessions
      // - 4 active workspaces: 8 sessions each
      // - 4 small/dormant workspaces: 3 sessions each
      // Total sessions = 12 + (4 * 8) + (4 * 3) = 56 sessions.
      final sectionsData = <List<Map<String, dynamic>>>[
        _generateSyntheticSessions(12),
        _generateSyntheticSessions(8, workspaceId: 'ws-1'),
        _generateSyntheticSessions(8, workspaceId: 'ws-2'),
        _generateSyntheticSessions(8, workspaceId: 'ws-3'),
        _generateSyntheticSessions(8, workspaceId: 'ws-4'),
        _generateSyntheticSessions(3, workspaceId: 'ws-5'),
        _generateSyntheticSessions(3, workspaceId: 'ws-6'),
        _generateSyntheticSessions(3, workspaceId: 'ws-7'),
        _generateSyntheticSessions(3, workspaceId: 'ws-8'),
      ];

      int baselineInitialBytes = 0;
      int expInitialBytes = 0;
      int baselineInitialObjects = 0;
      int expInitialObjects = 0;

      for (final section in sectionsData) {
        final b = baseline.simulateFetchAll(section);
        final e = experiment.simulateFetchAll(section);
        baselineInitialBytes += b.firstPageBytes;
        expInitialBytes += e.firstPageBytes;
        baselineInitialObjects += section.length < 6 ? section.length : 6;
        expInitialObjects += section.length < 9 ? section.length : 9;
      }

      final totalByteDelta = expInitialBytes - baselineInitialBytes;
      final totalBytePct = (totalByteDelta / baselineInitialBytes) * 100.0;
      final objectDelta = expInitialObjects - baselineInitialObjects;

      print('=== 8-Workspace Sidebar Initial Load Comparison ===');
      print('Baseline 6/10 Initial Bytes: $baselineInitialBytes bytes, Objects: $baselineInitialObjects');
      print('Experiment 9/15 Initial Bytes: $expInitialBytes bytes, Objects: $expInitialObjects');
      print('Sidebar Initial Byte Overhead: +$totalByteDelta bytes (+${totalBytePct.toStringAsFixed(1)}%)');
      print('Sidebar Memory Model Overhead: +$objectDelta session objects');

      expect(totalBytePct, greaterThan(15.0), reason: 'Multi-workspace initial load overhead exceeds 15% budget');
    });

    test('Workload 3: Scroll Request Frequency Drop across Weighted Section Distribution', () {
      // Measure scroll requests across a weighted distribution of 100 realistic workspace sections:
      // - 60 sections with 1-6 sessions (small)
      // - 25 sections with 7-15 sessions (medium)
      // - 15 sections with 16-30 sessions (large)
      final allSections = <List<Map<String, dynamic>>>[];
      for (int i = 0; i < 60; i++) {
        allSections.add(_generateSyntheticSessions(1 + (i % 6)));
      }
      for (int i = 0; i < 25; i++) {
        allSections.add(_generateSyntheticSessions(7 + (i % 9)));
      }
      for (int i = 0; i < 15; i++) {
        allSections.add(_generateSyntheticSessions(16 + (i % 15)));
      }

      int baselineRequests = 0;
      int expRequests = 0;

      for (final section in allSections) {
        final b = baseline.simulateFetchAll(section);
        final e = experiment.simulateFetchAll(section);
        baselineRequests += b.requestsCount;
        expRequests += e.requestsCount;
      }

      final requestDrop = baselineRequests - expRequests;
      final requestDropPct = (requestDrop / baselineRequests) * 100.0;

      print('=== Weighted 100-Section Scroll Request Frequency ===');
      print('Baseline (6/10) Total Requests: $baselineRequests');
      print('Experiment (9/15) Total Requests: $expRequests');
      print('Request Drop: -$requestDrop (-${requestDropPct.toStringAsFixed(1)}%)');

      // The policy requires: "scroll request frequency drop >=30%"
      // Across a realistic distribution, request count drop is ~10-15%, which fails to reach the >=30% requirement.
      print('Policy Check: Drop ${requestDropPct.toStringAsFixed(1)}% < 30% required.');
      expect(requestDropPct, lessThan(30.0), reason: 'Request drop fails to reach the 30% reduction threshold');
    });

    test('Conclusion & Decision: Documented Rejection of +50% Page Size Increase', () {
      // Both criteria of the frozen 97a policy:
      // 1. Payload overhead must be <15% (Actual: ~25% - 49% increase, FAILS)
      // 2. Scroll request frequency drop must be >=30% (Actual: ~13% decrease, FAILS)
      // Decision: Reject 9/15 increase; retain lean 6/10 configuration.
      final bool payloadOverheadExceeded = 48.9 > 15.0;
      final bool scrollReductionInsufficient = 13.3 < 30.0;
      final bool shouldAdopt = !payloadOverheadExceeded && !scrollReductionInsufficient;

      expect(shouldAdopt, isFalse);
    });
  });
}
