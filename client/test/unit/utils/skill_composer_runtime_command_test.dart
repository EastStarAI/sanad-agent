import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/presentation/utils/skill_composer_utils.dart';

void main() {
  test('runtime slash query is detected only at composer index zero', () {
    const atStart = TextEditingValue(text: '/comp', selection: TextSelection.collapsed(offset: 5));
    expect(SkillComposerUtils.detectRuntimeSlashQuery(atStart)?.query, 'comp');
    expect(SkillComposerUtils.detectSlashQuery(atStart), isNull);

    const midMessage = TextEditingValue(
      text: 'please /compact now',
      selection: TextSelection.collapsed(offset: 14),
    );
    expect(SkillComposerUtils.detectRuntimeSlashQuery(midMessage), isNull);
    expect(SkillComposerUtils.detectSlashQuery(midMessage)?.slashIndex, 7);
  });
}
