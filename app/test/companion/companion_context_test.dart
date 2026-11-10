import 'package:dsh_app/companion/companion_context.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a full backlog keeps the newest eight, oldest first', () {
    final now = DateTime.utc(2026, 11, 8, 12);
    final events = [
      for (var i = 0; i < 10; i++)
        CompanionContextEvent(
          id: 'e$i',
          kind: 'pet',
          at: now.subtract(Duration(minutes: 10 - i)),
          detail: 'touch $i',
        ),
    ];
    final kept = companionRecentEvents(events, now: now);
    expect(kept.map((e) => e.id), ['e2', 'e3', 'e4', 'e5', 'e6', 'e7', 'e8', 'e9']);
  });
}
