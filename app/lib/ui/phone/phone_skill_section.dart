import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/phone_state.dart';
import '../common/list_page_row.dart';
import '../theme/app_icons.dart';

/// Only offers local, completed native candidates; opening and saving are separate decisions.
class PhoneSkillSection extends ConsumerStatefulWidget {
  const PhoneSkillSection({super.key, required this.status});
  final PhoneSkillStatus status;

  @override
  ConsumerState<PhoneSkillSection> createState() => _PhoneSkillSectionState();
}

class _PhoneSkillSectionState extends ConsumerState<PhoneSkillSection> {
  bool _presenting = false;
  bool _setting = false;

  @override
  void didUpdateWidget(PhoneSkillSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Existing candidates do not produce a burst of prompts on entering the page
    // or enabling the setting. A new completion can ask while this page is visible.
    if (_presenting || !oldWidget.status.askAfterSuccess || !widget.status.askAfterSuccess) return;
    final previous = {for (final c in oldWidget.status.candidates) (c.taskId, c.generation)};
    for (final candidate in widget.status.candidates) {
      if (previous.contains((candidate.taskId, candidate.generation))) continue;
      _presenting = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (ModalRoute.of(context)?.isCurrent != true) {
          setState(() => _presenting = false);
          return;
        }
        _presenting = false;
        unawaited(_open(candidate));
      });
      break;
    }
  }

  Future<void> _open(PhoneSkillCandidate candidate) async {
    if (_presenting) return;
    setState(() => _presenting = true);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.phoneSkillConfirmGoal),
        content: Text(context.l10n.phoneSkillConfirmGoalBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.l10n.commonCancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(context.l10n.phoneSkillGoalDone)),
        ],
      ),
    );
    if (!mounted) return;
    if (confirmed == true) {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PhoneSkillEditor(channel: ref.read(phoneChannelProvider), candidate: candidate),
      );
      if (!mounted) return;
      unawaited(ref.read(phoneProvider.notifier).refreshStatus());
    }
    setState(() => _presenting = false);
  }

  Future<void> _setPrompt(bool value) async {
    setState(() => _setting = true);
    final ok = await ref.read(phoneProvider.notifier).setSkillSavePrompt(value);
    if (!mounted) return;
    setState(() => _setting = false);
    if (!ok) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.phoneSkillUnavailable)));
  }

  @override
  Widget build(BuildContext context) => ListPageCard(
    title: context.l10n.phoneSkillSectionTitle,
    children: [
      ListPageRow(
        icon: AppIcons.bookmark,
        title: context.l10n.phoneSkillAskAfterSuccess,
        subtitle: context.l10n.phoneSkillAskAfterSuccessHint,
        trailing: Switch(value: widget.status.askAfterSuccess, onChanged: _setting ? null : _setPrompt),
        chevron: false,
      ),
      for (final candidate in widget.status.candidates)
        ListPageRow(
          icon: AppIcons.completed,
          title: context.l10n.phoneSkillTask(candidate.taskId, candidate.steps),
          subtitle: context.l10n.phoneSkillCandidateHint,
          trailing: TextButton(
            onPressed: _presenting ? null : () => _open(candidate),
            child: Text(context.l10n.phoneSkillSaveAction),
          ),
          chevron: false,
        ),
    ],
  );
}

class PhoneSkillEditor extends StatefulWidget {
  const PhoneSkillEditor({super.key, required this.channel, required this.candidate});
  final PhoneChannel channel;
  final PhoneSkillCandidate candidate;

  @override
  State<PhoneSkillEditor> createState() => _PhoneSkillEditorState();
}

class _PhoneSkillEditorState extends State<PhoneSkillEditor> {
  final _goal = TextEditingController();
  final _prerequisites = TextEditingController();
  final _checks = <int, TextEditingController>{};
  PhoneSkillDraftView? _draft;
  List<int> _order = [];
  bool _busy = true;
  bool _dirty = false;
  bool _confirmed = false;
  bool _pendingWrite = false;
  bool _closing = false;
  bool _allowPop = false;
  bool _saved = false;
  String? _savedPath;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    final reply = await widget.channel.openSkillDraft(widget.candidate, confirmed: true);
    if (!mounted) {
      // open can finish after this dialog was removed. Cancel only its returned
      // identity; native open always creates a new id, even for the same task.
      if (reply.draft case final draft?) unawaited(widget.channel.discardSkillDraft(draft));
      return;
    }
    _accept(reply);
  }

  void _accept(PhoneSkillReply reply) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = null;
      switch (reply.kind) {
        case PhoneSkillReplyKind.shown:
          final view = reply.draft!;
          final previous = _draft;
          if (view.taskId != widget.candidate.taskId || view.generation != widget.candidate.generation ||
              previous != null && (view.draftId != previous.draftId || view.revision < previous.revision)) {
            _error = 'stale';
            return;
          }
          _draft = view;
          _order = [...view.stepOrder];
          for (final index in _order) { _checks.putIfAbsent(index, TextEditingController.new); }
          _dirty = false;
          _confirmed = false;
          _pendingWrite = view.phase == 'staging' || view.phase == 'committing';
        case PhoneSkillReplyKind.saved:
          _saved = true;
          _pendingWrite = false;
          _savedPath = reply.relativePath;
          _goal.clear();
          _prerequisites.clear();
          for (final controller in _checks.values) { controller.clear(); }
        case PhoneSkillReplyKind.saving:
          _pendingWrite = true;
          _confirmed = false;
        case PhoneSkillReplyKind.rejected:
          _error = reply.code;
          _confirmed = false;
        case PhoneSkillReplyKind.discarded:
          _error = 'stale';
      }
    });
  }

  void _changed() => setState(() { _dirty = true; _confirmed = false; });

  Future<void> _applyEdits() async {
    final draft = _draft!;
    setState(() { _busy = true; _confirmed = false; });
    final reply = await widget.channel.editSkillDraft(draft, goal: _goal.text,
      prerequisites: _prerequisites.text, checkpoints: [for (final index in _order) _checks[index]!.text],
      stepOrder: [..._order]);
    _accept(reply);
  }

  Future<void> _save() async {
    final draft = _draft!;
    setState(() { _busy = true; _confirmed = false; });
    _accept(await widget.channel.saveSkillDraft(draft, confirmed: true));
  }

  Future<void> _checkWrite() async {
    setState(() => _busy = true);
    _accept(await widget.channel.viewSkillDraft(_draft!));
  }

  Future<void> _close() async {
    if (_closing) return;
    setState(() => _closing = true);
    final draft = _draft;
    if (!_saved && draft != null) {
      final reply = await widget.channel.discardSkillDraft(draft);
      if (!mounted) return;
      if (reply.code == 'cannot_cancel' || reply.code == 'unavailable') {
        final leave = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
          title: Text(context.l10n.phoneSkillWriting),
          content: Text(context.l10n.phoneSkillCannotCancel),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.l10n.phoneSkillKeepWaiting)),
            TextButton(onPressed: () => Navigator.pop(context, true), child: Text(context.l10n.commonClose)),
          ],
        ));
        if (!mounted) return;
        if (leave != true) { setState(() => _closing = false); return; }
      } else if (reply.kind == PhoneSkillReplyKind.saved) {
        _accept(reply);
        setState(() => _closing = false);
        return;
      }
    }
    if (!mounted) return;
    setState(() => _allowPop = true);
    Navigator.pop(context);
  }

  @override
  void dispose() {
    final draft = _draft;
    if (!_saved && !_allowPop && draft != null) unawaited(widget.channel.discardSkillDraft(draft));
    _goal.dispose();
    _prerequisites.dispose();
    for (final controller in _checks.values) { controller.dispose(); }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final draft = _draft;
    final editable = !_busy && !_pendingWrite && !_saved && !_closing;
    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) { if (!didPop) unawaited(_close()); },
      child: AlertDialog(
        title: Text(_saved ? l10n.commonSaved : l10n.phoneSkillSaveAction),
        content: SizedBox(
          width: 640,
          child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_busy) const LinearProgressIndicator(),
              if (_error != null) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(_skillError(context, _error!))),
              if (_saved) ...[
                Text(l10n.phoneSkillSavedBody),
                SelectableText(_savedPath!),
              ] else if (draft != null) ...[
                Text(l10n.phoneSkillPrivacyHint),
                const SizedBox(height: 12),
                TextField(controller: _goal, enabled: editable, maxLength: 2000, onChanged: (_) => _changed(),
                  decoration: InputDecoration(labelText: l10n.phoneSkillGoal)),
                TextField(controller: _prerequisites, enabled: editable, maxLength: 2000, onChanged: (_) => _changed(),
                  decoration: InputDecoration(labelText: l10n.phoneSkillPrerequisites)),
                for (var position = 0; position < _order.length; position++) ...[
                  Row(children: [
                    Expanded(child: Text(l10n.phoneSkillStep(_order[position] + 1))),
                    IconButton(tooltip: l10n.phoneSkillMoveUp, icon: const Icon(AppIcons.collapse),
                      onPressed: editable && position > 0 ? () => setState(() {
                        final index = _order.removeAt(position); _order.insert(position - 1, index); _dirty = true; _confirmed = false;
                      }) : null),
                    IconButton(tooltip: l10n.phoneSkillMoveDown, icon: const Icon(AppIcons.expand),
                      onPressed: editable && position + 1 < _order.length ? () => setState(() {
                        final index = _order.removeAt(position); _order.insert(position + 1, index); _dirty = true; _confirmed = false;
                      }) : null),
                    IconButton(tooltip: l10n.commonDelete, icon: const Icon(AppIcons.delete),
                      onPressed: editable && _order.length > 1 ? () => setState(() {
                        _order.removeAt(position); _dirty = true; _confirmed = false;
                      }) : null),
                  ]),
                  TextField(controller: _checks[_order[position]], enabled: editable, maxLength: 2000,
                    onChanged: (_) => _changed(), decoration: InputDecoration(labelText: l10n.phoneSkillCheckpoint)),
                ],
                TextButton(onPressed: editable && _dirty ? _applyEdits : null, child: Text(l10n.phoneSkillUpdatePreview)),
                const Divider(),
                Text(l10n.phoneSkillPreviewTitle, style: Theme.of(context).textTheme.titleSmall),
                if (draft.parameterizedFields.isNotEmpty) Text(l10n.phoneSkillParameterizedHint),
                SelectableText(draft.markdown),
                CheckboxListTile(contentPadding: EdgeInsets.zero, value: _confirmed,
                  onChanged: editable && !_dirty ? (value) => setState(() => _confirmed = value == true) : null,
                  title: Text(l10n.phoneSkillFinalConfirmation)),
                if (_pendingWrite) Text(l10n.phoneSkillWriting),
              ],
            ],
          )),
        ),
        actions: [
          TextButton(onPressed: _closing ? null : _close, child: Text(l10n.commonClose)),
          if (_pendingWrite) TextButton(onPressed: _busy ? null : _checkWrite, child: Text(l10n.phoneSkillCheckWrite)),
          if (!_saved && !_pendingWrite) FilledButton(
            onPressed: editable && draft != null && !_dirty && _confirmed ? _save : null,
            child: Text(l10n.commonSave),
          ),
        ],
      ),
    );
  }
}

String _skillError(BuildContext context, String code) => switch (code) {
  'stale' => context.l10n.phoneSkillStale,
  'busy' || 'cannot_cancel' => context.l10n.phoneSkillCannotCancel,
  'confirmation_required' => context.l10n.phoneSkillFinalConfirmation,
  'sensitive' => context.l10n.phoneSkillSensitive,
  'invalid' || 'too_large' => context.l10n.phoneSkillInvalid,
  'no_home' || 'conflict' || 'io' => context.l10n.phoneSkillWriteFailed,
  _ => context.l10n.phoneSkillUnavailable,
};
