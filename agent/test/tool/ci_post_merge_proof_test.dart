// Guards the post-merge proof selector in Public CI.
//
// `classify` in `.github/workflows/ci.yml` reduces the `push` run to the
// complement of the lanes a proof run already proved, and it runs every lane
// otherwise. Two proof sources exist because the merge path is a repository
// setting rather than a property of the workflow:
//
//   A. a successful `merge_group` run for the pushed commit (the merge queue);
//   B. the merged pull request's own final successful `pull_request` run, which
//      is accepted only when `tree(push) == tree(pull-request head)` and
//      `push^1` is an ancestor of that head — the guarantee "require branches to
//      be up to date" provides.
//
// A weakened selector would silently drop coverage from `main`, so the
// invariants are asserted twice:
//
// 1. Structurally here, on the workflow text, so a weakened selector fails even
//    on a host that cannot run the harness.
// 2. Behaviourally in `scripts/ci/test_post_merge_proof.sh`, which extracts the
//    real functions and the real `push` caller from the workflow and runs them
//    against fixtures with a fake `gh`. This suite runs that harness where
//    `bash` and `jq` exist.
//
// `docs/operations/continuous_integration.md` owns the model.

import 'dart:io';

import 'package:test/test.dart';

/// This suite runs with the Agent package as its working directory.
const String _workflowPath = '../.github/workflows/ci.yml';
const String _harnessPath = '../scripts/ci/test_post_merge_proof.sh';

/// Returns the body of a `run:`-block function declared at the workflow's shell
/// indentation, so an assertion cannot accidentally match a different job.
String _function(String workflow, String name) {
  final lines = workflow.split('\n');
  final start = lines.indexWhere((line) => line == '          $name() {');
  if (start < 0) {
    throw StateError('$name() is missing from ci.yml');
  }
  final end = lines.indexWhere((line) => line == '          }', start + 1);
  if (end < 0) {
    throw StateError('$name() has no closing brace');
  }
  return lines.sublist(start, end + 1).join('\n');
}

void main() {
  late String workflow;
  late String queueProof;
  late String pullRequestProof;

  setUpAll(() {
    workflow = File(_workflowPath).readAsStringSync();
    queueProof = _function(workflow, 'prove_from_merge_queue');
    pullRequestProof = _function(workflow, 'prove_from_merged_pull_request');
  });

  group('rollback path', () {
    test('the dormant merge_group trigger is kept', () {
      // A rollback to the queue must not need a workflow change.
      expect(workflow, contains('\n  merge_group:\n'));
    });
  });

  group('proof source A', () {
    test('only a successful queue run for the pushed commit qualifies', () {
      expect(queueProof, contains('event=merge_group'));
      expect(queueProof, contains(r'head_sha=$GITHUB_SHA'));
      expect(queueProof, contains('conclusion == "success"'));
    });
  });

  group('proof source B', () {
    test('the pushed commit resolves to exactly one merged pull request', () {
      expect(pullRequestProof, contains(r'commits/$GITHUB_SHA/pulls'));
      expect(pullRequestProof, contains('merged_at'));
      expect(pullRequestProof, contains('base.ref'));
      // A run is keyed by head SHA only, so a shared head is ambiguous.
      expect(pullRequestProof, contains(r'commits/$head_sha/pulls'));
    });

    test('the tree and the parent relationship are both proved', () {
      expect(pullRequestProof, contains(r'git rev-parse "$GITHUB_SHA^{tree}"'));
      expect(pullRequestProof, contains('.tree.sha'));
      expect(pullRequestProof, contains(r'compare/$parent...$head_sha'));
      expect(pullRequestProof, contains('ahead|identical'));
    });

    test('the run is this pull request and this head', () {
      expect(pullRequestProof, contains('event=pull_request'));
      expect(pullRequestProof, contains(r'head_sha=$head_sha'));
      expect(pullRequestProof, contains(r'head_branch == $ref'));
      expect(pullRequestProof, contains('conclusion == "success"'));
    });
  });

  group('fail-closed ordering', () {
    test('the queue proof is tried first and every other outcome keeps all lanes', () {
      final queueFirst = workflow.indexOf('if prove_from_merge_queue; then');
      final pullRequestSecond =
          workflow.indexOf('elif prove_from_merged_pull_request; then');
      expect(queueFirst, isNonNegative);
      expect(pullRequestSecond, greaterThan(queueFirst));
      // The else branch is the fail-closed default: no proof, no reduction.
      final elseStart = workflow.indexOf('No reusable proof for ');
      final elseEnd = workflow.indexOf('\n          fi', elseStart);
      expect(elseStart, greaterThan(pullRequestSecond));
      expect(elseEnd, greaterThan(elseStart));
      final elseBranch = workflow.substring(elseStart, elseEnd);
      expect(elseBranch, contains('proven=" "'));
      expect(
        elseBranch,
        isNot(contains('complement=true')),
        reason: 'a failed proof must leave every lane enabled',
      );
    });
  });

  group('fixture harness', () {
    final windows = Platform.isWindows;
    final bash = windows
        ? null
        : Process.runSync('bash', ['--version']).exitCode == 0;
    final jq = bash == true
        ? Process.runSync('bash', ['-c', 'command -v jq']).exitCode == 0
        : false;

    test('every source and every mismatch is proved or refused', () {
      if (bash != true || !jq) {
        markTestSkipped(
          'the selector harness needs bash and jq; the structural guards above '
          'still run on this host',
        );
        return;
      }
      final result = Process.runSync('bash', [_harnessPath]);
      expect(
        result.exitCode,
        0,
        reason: '${result.stdout}\n${result.stderr}',
      );
      expect(result.stdout, contains('cases passed'));
      expect(result.stdout, isNot(contains('FAIL')));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
