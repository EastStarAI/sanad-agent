import 'package:test/test.dart';

void main() {
  test('intentional failing test for bounded verification proof', () {
    expect(1 + 1, equals(3), reason: 'intentional failure demonstration');
  });
}
