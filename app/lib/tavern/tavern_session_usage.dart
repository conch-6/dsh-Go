// 舞台 › 本局 › 本局用量 (docs/design/roleplay-optimization.md §2, 费用可见): what
// the replies on a chat's current line took, as the model reported it,
// added up. Alternatives swiped away are not on the line and not counted.

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'tavern_provider.dart';

class TavernSessionUsage {
  const TavernSessionUsage({this.replies = 0, this.prompt = 0, this.cacheHit = 0, this.completion = 0});

  /// Replies that carry reported usage.
  final int replies;
  final int prompt;
  final int cacheHit;
  final int completion;
}

/// [chatId]'s current line, all of it (the engine hands it out a page at a
/// time, newest first), its replies' usage summed.
Future<TavernSessionUsage> tavernSessionUsage(Tavern tavern, String chatId, {int page = 200}) async {
  var replies = 0, prompt = 0, cacheHit = 0, completion = 0;
  String? before;
  while (true) {
    final messages = await tavern.path(chatId, limit: page, beforeNodeId: before);
    for (final m in messages) {
      if (m.role != TavernRole.character) continue;
      if (m.reportedUsage case final usage?) {
        replies++;
        prompt += usage.promptTokens;
        cacheHit += usage.cacheHitTokens;
        completion += usage.completionTokens;
      }
    }
    if (messages.length < page) break;
    before = messages.first.nodeId;
  }
  return TavernSessionUsage(replies: replies, prompt: prompt, cacheHit: cacheHit, completion: completion);
}

/// A token count at a glance: 8,421 as it is; 12,345 as 1.2万 (or 12.3k).
String tavernTokenCount(int tokens, {required bool zh}) {
  if (tokens < 10000) return '$tokens';
  if (zh) {
    final wan = tokens / 10000;
    return '${wan >= 100 ? wan.round() : wan.toStringAsFixed(1)}万';
  }
  final k = tokens / 1000;
  return k >= 1000 ? '${(k / 1000).toStringAsFixed(1)}M' : '${k >= 100 ? k.round() : k.toStringAsFixed(1)}k';
}

/// One chat and what its current line took.
class TavernChatUsage {
  const TavernChatUsage(this.chat, this.usage);

  final TavernChatSummary chat;
  final TavernSessionUsage usage;

  int get total => usage.prompt + usage.completion;
}

/// 用量统计: every chat's current line added up, the ones that took the most
/// first; chats with nothing reported left out. Read afresh each time.
final tavernAllUsageProvider = FutureProvider.autoDispose<List<TavernChatUsage>>((ref) async {
  final tavern = ref.watch(tavernProvider);
  final chats = await tavern.watchChats().first;
  final all = [for (final chat in chats) TavernChatUsage(chat, await tavernSessionUsage(tavern, chat.id))]
    ..removeWhere((c) => c.usage.replies == 0);
  all.sort((a, b) => b.total.compareTo(a.total));
  return all;
}, retry: (_, _) => null);
