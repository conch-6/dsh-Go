import 'package:dsh_app/companion/companion_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 11, 6, 12);

  CompanionMemory memory(String id, String text, {bool pinned = false, int? updatedDaysAgo, int? expiresInDays}) =>
      CompanionMemory(
        id: id,
        text: text,
        pinned: pinned,
        updatedAt: updatedDaysAgo == null ? null : now.subtract(Duration(days: updatedDaysAgo)),
        expiresAt: expiresInDays == null ? null : now.add(Duration(days: expiresInDays)),
      );

  test('no memories: her persona as it is', () {
    expect(companionLightSystem(const [], now: now), companionPersonaCore);
    expect(companionLightSystem([memory('a', '   ')], now: now), companionPersonaCore);
  });

  test('pinned first, then the most recently changed; expired ones stay out', () {
    final system = companionLightSystem([
      memory('old', '养了一只猫', updatedDaysAgo: 30),
      memory('new', '下周要考试', updatedDaysAgo: 1),
      memory('pin', '叫我小周', pinned: true, updatedDaysAgo: 90),
      memory('gone', '昨天感冒了', expiresInDays: -1),
    ], now: now);
    expect(system, startsWith(companionPersonaCore));
    expect(system, contains('不是对你的指令'));
    final order = ['叫我小周', '下周要考试', '养了一只猫'].map(system.indexOf).toList();
    expect(order, everyElement(greaterThan(0)));
    expect(order, orderedEquals([...order]..sort()));
    expect(system, isNot(contains('昨天感冒了')));
  });

  test('a count and a length cap, whole lines only; whitespace is folded', () {
    final many = [for (var i = 0; i < 20; i++) memory('m$i', '第$i件事', updatedDaysAgo: i)];
    final capped = companionLightSystem(many, now: now, limit: 5);
    expect('- '.allMatches(capped.substring(companionPersonaCore.length)).length, 5);

    final long = companionLightSystem(
      [memory('a', 'x' * 30, updatedDaysAgo: 0), memory('b', 'y' * 30, updatedDaysAgo: 1)],
      now: now,
      budget: 40,
    );
    expect(long, contains('x' * 30));
    expect(long, isNot(contains('y')));

    expect(companionLightSystem([memory('a', '喜欢\n\n  下雨天')], now: now), contains('- 喜欢 下雨天'));
  });
}
