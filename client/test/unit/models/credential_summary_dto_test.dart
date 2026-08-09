import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/provider_setup/data/models/credential_summary_dto.dart';

void main() {
  group('CredentialSummaryDto', () {
    test('parses the canonical API-key summary returned by the daemon', () {
      final summary = CredentialSummaryDto.fromJson(const {
        'instance_id': 'api-instance',
        'configured': true,
        'auth_method': 'api_key',
        'status': 'authenticated',
        'masked_key_hint': 'sk-p••••9X2A',
        'relogin_required': false,
      });

      expect(summary.hasSecret, isTrue);
      expect(summary.maskedSecret, 'sk-p••••9X2A');
      expect(summary.status, 'authenticated');
      expect(summary.toJson(), containsPair('configured', true));
      expect(
        summary.toJson(),
        containsPair('masked_key_hint', 'sk-p••••9X2A'),
      );
    });

    test('parses a configured OAuth account without exposing a token', () {
      final summary = CredentialSummaryDto.fromJson(const {
        'instance_id': 'oauth-instance',
        'configured': true,
        'auth_method': 'device_code',
        'status': 'authenticated',
        'account_label': 'user@example.com',
        'account_name': 'User Name',
        'relogin_required': false,
      });

      expect(summary.hasSecret, isTrue);
      expect(summary.maskedSecret, isNull);
      expect(summary.accountLabel, 'user@example.com');
      expect(summary.accountName, 'User Name');
      expect(summary.status, 'authenticated');
      expect(summary.toJson(), containsPair('account_name', 'User Name'));
    });

    test('accepts legacy client aliases during protocol migration', () {
      final summary = CredentialSummaryDto.fromJson(const {
        'has_secret': true,
        'masked_secret': 'legacy••••key',
        'auth_method': 'api_key',
        'status': 'authenticated',
      });

      expect(summary.hasSecret, isTrue);
      expect(summary.maskedSecret, 'legacy••••key');
    });
  });
}
