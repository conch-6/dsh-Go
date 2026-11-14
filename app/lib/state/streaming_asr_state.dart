import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../voice/streaming_asr.dart';

final streamingAsrProvider = Provider<StreamingAsr>((ref) {
  final asr = StreamingAsr();
  ref.onDispose(() => unawaited(asr.dispose()));
  return asr;
});
