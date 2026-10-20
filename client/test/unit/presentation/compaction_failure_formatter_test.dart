import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/compaction_event_snapshot.dart';
import 'package:sanad_client/features/conversations/presentation/utils/compaction_failure_formatter.dart';
import 'package:sanad_client/l10n/app_localizations.dart';
import 'package:sanad_client/l10n/app_localizations_en.dart';

void main() {
  group('CompactionFailureFormatter', () {
    test('distinguishes thinking validation failures from provider errors', () {
      final thinkingUnsupported = CompactionFailureFormatter.resolve(
        stage: 'preparation',
        cause: 'thinking_capability_unsupported',
        failureReason: 'summarization_failed',
      );
      expect(
        thinkingUnsupported.explanation,
        'Selected thinking mode is not supported by the active model or route.',
      );
      expect(
        thinkingUnsupported.nextAction,
        'Select a supported thinking mode or route and try again.',
      );
      expect(thinkingUnsupported.stage, 'preparation');
      expect(thinkingUnsupported.cause, 'thinking_capability_unsupported');

      final providerTimeout = CompactionFailureFormatter.resolve(
        stage: 'provider',
        cause: 'timeout',
        failureReason: 'summarization_failed',
      );
      expect(
        providerTimeout.explanation,
        'Provider timed out during context summarization.',
      );
      expect(
        providerTimeout.nextAction,
        'Check network connection or try again.',
      );
      expect(providerTimeout.stage, 'provider');
      expect(providerTimeout.cause, 'timeout');
    });

    test('distinguishes tool-result pruning failures and over-budget projection', () {
      final pruningMalformed = CompactionFailureFormatter.resolve(
        stage: 'pruning',
        cause: 'tool_result_malformed',
        failureReason: 'summarization_failed',
      );
      expect(
        pruningMalformed.explanation,
        'Structured tool results could not be pruned for summarization.',
      );
      expect(
        pruningMalformed.nextAction,
        'Send a new message or retry compaction.',
      );
      expect(pruningMalformed.stage, 'pruning');

      final overBudget = CompactionFailureFormatter.resolve(
        stage: 'pruning',
        cause: 'projection_still_over_budget',
        failureReason: 'projection_still_over_budget',
      );
      expect(
        overBudget.explanation,
        'Context history remains over budget after pruning.',
      );
      expect(
        overBudget.nextAction,
        'Shorten earlier messages or start a new session.',
      );
    });

    test('distinguishes validation and persistence failures', () {
      final continuity = CompactionFailureFormatter.resolve(
        stage: 'validation',
        cause: 'continuity_validation_failed',
        failureReason: 'continuity_validation_failed',
      );
      expect(
        continuity.explanation,
        'Summary failed continuity verification.',
      );
      expect(
        continuity.nextAction,
        'Retry compaction to generate a complete summary.',
      );

      final staleRevision = CompactionFailureFormatter.resolve(
        stage: 'persistence',
        cause: 'source_revision_stale',
        failureReason: 'source_revision_stale',
      );
      expect(
        staleRevision.explanation,
        'Conversation history changed during compaction.',
      );
      expect(
        staleRevision.nextAction,
        'Try running compaction again with current history.',
      );

      final interrupted = CompactionFailureFormatter.resolve(
        stage: 'persistence',
        cause: 'interrupted',
        failureReason: 'interrupted',
      );
      expect(
        interrupted.explanation,
        'Compaction was interrupted by daemon restart.',
      );
      expect(
        interrupted.nextAction,
        'Try running compaction again.',
      );
    });

    test('handles claim rejections (session_busy, compaction_in_progress, unavailable)', () {
      final busy = CompactionFailureFormatter.resolve(
        stage: 'preparation',
        cause: 'session_busy',
        outcome: 'session_busy',
      );
      expect(busy.explanation, 'Session is busy.');
      expect(busy.nextAction, 'Try /compact again when idle.');
      expect(busy.toToastMessage(), 'Session is busy. Try /compact again when idle.');

      final inProgress = CompactionFailureFormatter.resolve(
        stage: 'preparation',
        cause: 'compaction_in_progress',
        outcome: 'compaction_in_progress',
      );
      expect(inProgress.explanation, 'Context compaction is already in progress.');
      expect(inProgress.nextAction, 'Wait for the current operation to finish before retrying.');
      expect(
        inProgress.toToastMessage(),
        'Context compaction is already in progress. Wait for the current operation to finish before retrying.',
      );

      final unavailable = CompactionFailureFormatter.resolve(
        stage: 'preparation',
        cause: 'unavailable',
        outcome: 'unavailable',
      );
      expect(unavailable.explanation, 'Failed to prepare context compaction.');
      expect(unavailable.nextAction, 'Check session settings and try again.');
    });

    test('decodes camelCase causes, stages, and failure reasons', () {
      final camelThinking = CompactionFailureFormatter.resolve(
        stage: 'preparation',
        cause: 'thinkingCapabilityUnsupported',
      );
      expect(
        camelThinking.explanation,
        'Selected thinking mode is not supported by the active model or route.',
      );
      expect(camelThinking.cause, 'thinking_capability_unsupported');

      final camelContinuity = CompactionFailureFormatter.resolve(
        failureReason: 'continuityValidationFailed',
      );
      expect(
        camelContinuity.explanation,
        'Summary failed continuity verification.',
      );
      expect(camelContinuity.stage, 'validation');
      expect(camelContinuity.cause, 'continuity_validation_failed');

      final camelBudget = CompactionFailureFormatter.resolve(
        failureReason: 'projectionStillOverBudget',
      );
      expect(
        camelBudget.explanation,
        'Context history remains over budget after pruning.',
      );
      expect(camelBudget.stage, 'pruning');
      expect(camelBudget.cause, 'projection_still_over_budget');
    });

    test('retains useful legacy fallback when only legacy failureReason is provided', () {
      final legacySummarization = CompactionFailureFormatter.resolve(
        failureReason: 'summarization_failed',
      );
      expect(
        legacySummarization.explanation,
        'Provider summarization failed.',
      );
      expect(
        legacySummarization.nextAction,
        'Try running compaction again.',
      );
      expect(legacySummarization.stage, 'provider');

      final legacyPersistence = CompactionFailureFormatter.resolve(
        failureReason: 'persistence_failed',
      );
      expect(
        legacyPersistence.explanation,
        'Failed to persist compaction boundaries to storage.',
      );
      expect(legacyPersistence.stage, 'persistence');

      final unknownLegacy = CompactionFailureFormatter.resolve(
        failureReason: 'unknown_hardware_fault',
      );
      expect(
        unknownLegacy.explanation,
        'Context compaction encountered an unexpected error.',
      );
      expect(
        unknownLegacy.nextAction,
        'Try running compaction again.',
      );
    });

    test('never displays raw exception bodies, secrets, paths, or URLs', () {
      const sensitiveLeak = 'Exception: /var/root/secret_key.pem failed with bearer sk-live-12345';
      final formatted = CompactionFailureFormatter.resolve(
        failureReason: sensitiveLeak,
        cause: 'unexpected_error',
      );
      expect(formatted.explanation, isNot(contains('/var/root')));
      expect(formatted.explanation, isNot(contains('secret_key')));
      expect(formatted.explanation, isNot(contains('sk-live-12345')));
      expect(formatted.nextAction, isNot(contains('sk-live-12345')));
      expect(
        formatted.explanation,
        'Context compaction encountered an unexpected error.',
      );
    });

    test('does not fabricate a provider diagnosis for an unclassified error', () {
      // The Agent's fallback cause defaults the stage to provider when no stage
      // hint exists; the explanation must stay the honest fallback instead of
      // claiming a provider summarization failure.
      final providerStage = CompactionFailureFormatter.resolve(
        stage: 'provider',
        cause: 'unexpected_error',
        failureReason: 'summarization_failed',
      );
      expect(
        providerStage.explanation,
        'Context compaction encountered an unexpected error.',
      );
      expect(providerStage.nextAction, 'Try running compaction again.');

      // A stage the Agent actually asserted keeps its specific explanation.
      final preparationStage = CompactionFailureFormatter.resolve(
        stage: 'preparation',
        cause: 'unexpected_error',
      );
      expect(
        preparationStage.explanation,
        'Failed to prepare context compaction.',
      );
      expect(preparationStage.nextAction, 'Check session settings and try again.');
    });

    test('formats detail lines with Failure: and Next action: prefixes', () {
      final explanation = CompactionFailureFormatter.resolve(
        stage: 'provider',
        cause: 'rate_limited',
      );
      final lines = explanation.toDetailLines();
      expect(lines, [
        'Failure: Provider rate limit reached during summarization.',
        'Next action: Wait a moment before retrying.',
      ]);
      expect(
        explanation.toDetailText(),
        'Failure: Provider rate limit reached during summarization.\n'
        'Next action: Wait a moment before retrying.',
      );
    });

    testWidgets('resolves localized Arabic strings with AppLocalizations', (tester) async {
      late AppLocalizations arabicL10n;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              arabicL10n = AppLocalizations.of(context)!;
              return const SizedBox();
            },
          ),
        ),
      );

      // Every expectation derives from the localization system: the root
      // contract forbids Arabic literals in handwritten Dart, including tests.
      expect(arabicL10n.localeName, 'ar');
      expect(
        arabicL10n.compactionFailureThinkingUnsupported,
        isNot(
          equals(AppLocalizationsEn().compactionFailureThinkingUnsupported),
        ),
      );

      final arThinking = CompactionFailureFormatter.resolve(
        stage: 'preparation',
        cause: 'thinking_capability_unsupported',
        l10n: arabicL10n,
      );
      expect(
        arThinking.explanation,
        arabicL10n.compactionFailureThinkingUnsupported,
      );
      expect(
        arThinking.nextAction,
        arabicL10n.compactionActionThinkingUnsupported,
      );
      expect(arThinking.toDetailLines(l10n: arabicL10n), [
        arabicL10n.compactionFailurePrefix(
          arabicL10n.compactionFailureThinkingUnsupported,
        ),
        arabicL10n.compactionNextActionPrefix(
          arabicL10n.compactionActionThinkingUnsupported,
        ),
      ]);

      final arBusy = CompactionFailureFormatter.resolve(
        cause: 'session_busy',
        l10n: arabicL10n,
      );
      expect(arBusy.explanation, arabicL10n.compactionFailureSessionBusy);
      expect(arBusy.nextAction, arabicL10n.compactionActionSessionBusy);
    });

    test('resolveForSnapshot and resolveForResult resolve models directly', () {
      const snapshot = CompactionEventSnapshot(
        sessionId: 'session-1',
        compactionId: 'cmp-1',
        status: CompactionLifecycleStatus.failed,
        trigger: CompactionTriggerKind.manual,
        failureStage: 'provider',
        failureCause: 'timeout',
      );
      final fromSnapshot = CompactionFailureFormatter.resolveForSnapshot(snapshot);
      expect(fromSnapshot.stage, 'provider');
      expect(fromSnapshot.cause, 'timeout');
      expect(
        fromSnapshot.explanation,
        'Provider timed out during context summarization.',
      );

      const result = SessionCompactResult(
        outcome: 'failed',
        failureStage: 'preparation',
        failureCause: 'thinking_capability_unsupported',
      );
      final fromResult = CompactionFailureFormatter.resolveForResult(result);
      expect(fromResult.stage, 'preparation');
      expect(fromResult.cause, 'thinking_capability_unsupported');
      expect(
        fromResult.explanation,
        'Selected thinking mode is not supported by the active model or route.',
      );
    });
  });
}
