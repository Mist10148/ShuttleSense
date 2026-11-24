import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../shared/widgets/notice.dart';
import '../../data/api_client.dart';
import '../../data/models/clip_record.dart';
import '../../data/models/coach.dart';
import '../../data/models/json.dart';
import '../coach/coach_screen.dart' show CoachBubble, CoachTurn;
import '../results/widgets/session_summary.dart' show MomentChips;

typedef PracticeQuestion =
    Stream<Json> Function(String question, String version, List<Json> history, CancelToken cancel);

class PracticeFollowup extends StatefulWidget {
  const PracticeFollowup({
    super.key,
    required this.version,
    required this.enabled,
    required this.suggestions,
    required this.onAsk,
    required this.onSeek,
    required this.onReload,
  });

  final String version;
  final bool enabled;
  final List<String> suggestions;
  final PracticeQuestion onAsk;
  final ValueChanged<double> onSeek;
  final VoidCallback onReload;

  @override
  State<PracticeFollowup> createState() => _PracticeFollowupState();
}

class _PracticeFollowupState extends State<PracticeFollowup> {
  final input = TextEditingController();
  final turns = <CoachTurn>[];
  CancelToken? pending;
  String? streaming, error;
  bool needsReload = false;

  @override
  void dispose() {
    pending?.cancel();
    input.dispose();
    super.dispose();
  }

  Future<void> send() async {
    final question = input.text.trim();
    if (!widget.enabled || needsReload || pending != null || question.isEmpty) return;
    final cancel = CancelToken();
    final history = [
      for (final turn in turns.reversed.take(12).toList().reversed)
        <String, dynamic>{'role': turn.message.role, 'text': turn.message.text},
    ];
    setState(() {
      pending = cancel;
      streaming = '';
      error = null;
    });
    try {
      await for (final event in widget.onAsk(question, widget.version, history, cancel)) {
        if (!mounted || cancel.isCancelled) return;
        switch (event['type']) {
          case 'delta':
            setState(() => streaming = '${streaming ?? ''}${event['text']}');
          case 'done':
            final answer = CoachTurn(
              message: ChatMessage.fromJson(event['message'] as Json),
              sources: CoachSource.listFrom(event['sources']),
            );
            setState(() {
              turns.addAll([
                CoachTurn(
                  message: ChatMessage(role: 'user', text: question, at: DateTime.now().toUtc()),
                ),
                answer,
              ]);
              input.clear();
            });
            return;
          case 'error':
            throw ApiException(
              event['detail'] as String? ?? 'The coach could not answer.',
              statusCode: event['status'] as int?,
            );
        }
      }
      throw const FormatException('The answer was interrupted. Try sending again.');
    } on ApiException catch (e) {
      if (mounted && !cancel.isCancelled) {
        setState(() {
          error = e.message;
          needsReload = e.statusCode == 409 && e.message.contains('Reload the guide');
        });
      }
    } on Object catch (e) {
      if (mounted && !cancel.isCancelled) {
        setState(() => error = e is FormatException ? e.message : 'The coach could not answer.');
      }
    } finally {
      if (mounted && !cancel.isCancelled) {
        setState(() {
          pending = null;
          streaming = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final canSend = widget.enabled && !needsReload && pending == null;
    final p = AppPalette.of(context);
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: Spacing.sm,
      children: [
        if (widget.enabled)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.shield_outlined, size: 16, color: p.text3),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  'The AI provider receives your questions and text from this report. Video and images stay on the server.',
                  style: text.bodySmall?.copyWith(color: p.text3),
                ),
              ),
            ],
          ),
        if (turns.isEmpty && canSend) ...[
          Text(
            'TRY ASKING',
            style: text.labelSmall?.copyWith(
              color: p.text3,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
          Wrap(
            spacing: Spacing.xs + 2,
            runSpacing: Spacing.xs + 2,
            children: [
              for (final suggestion in widget.suggestions)
                // A long coach-written title wraps to two lines instead of running out.
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 320),
                  child: ActionChip(
                    avatar: const Icon(Icons.chat_bubble_outline_rounded, size: 16),
                    label: Text(suggestion, maxLines: 2, overflow: TextOverflow.ellipsis),
                    onPressed: () => input.value = TextEditingValue(
                      text: suggestion,
                      selection: TextSelection.collapsed(offset: suggestion.length),
                    ),
                  ),
                ),
            ],
          ),
        ],
        for (final turn in turns)
          CoachBubble(
            turn: turn.message.fromUser
                ? turn
                : CoachTurn(
                    message: ChatMessage(
                      role: 'assistant',
                      text: _withoutMarkers(turn.message.text),
                      at: turn.message.at,
                    ),
                    sources: turn.sources,
                  ),
            footer: turn.message.citations.isEmpty
                ? null
                : MomentChips(
                    moments: turn.message.citations,
                    onSeek: (m) => widget.onSeek(m.timeS),
                  ),
          ),
        if (streaming case final String partial)
          CoachBubble(
            turn: CoachTurn(
              message: ChatMessage(
                role: 'assistant',
                text: partial.isEmpty ? 'Preparing an answer…' : _withoutMarkers(partial),
                at: DateTime.now().toUtc(),
              ),
            ),
          ),
        if (error != null)
          NoticeBanner(
            tone: NoticeTone.error,
            message: error!,
            actionLabel: needsReload ? 'Reload coaching guide' : null,
            onAction: needsReload && widget.enabled ? widget.onReload : null,
          ),
        if (needsReload && error == null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed: widget.enabled ? widget.onReload : null,
              child: const Text('Reload coaching guide'),
            ),
          ),
        // The question box and its send key, side by side when there is room.
        LayoutBuilder(
          builder: (context, box) {
            final field = TextField(
              controller: input,
              enabled: canSend,
              maxLength: 1000,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Ask about this video'),
            );
            final button = ValueListenableBuilder(
              valueListenable: input,
              builder: (context, value, _) => FilledButton.icon(
                onPressed: canSend && value.text.trim().isNotEmpty ? send : null,
                icon: const Icon(Icons.send_rounded, size: 18),
                label: const Text('Send question'),
              ),
            );
            if (box.maxWidth < 420) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: Spacing.sm,
                children: [field, button],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: field),
                const SizedBox(width: Spacing.sm),
                Padding(padding: const EdgeInsets.only(top: 4), child: button),
              ],
            );
          },
        ),
      ],
    );
  }
}

String _withoutMarkers(String text) =>
    text.replaceAll(RegExp(r'\[(?:t=|kb:|session:|history:)[^\]\n]*(?:\]|$)'), '').trim();
