import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/widgets/coach_reply.dart';
import '../../shared/widgets/smooth_scroll.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/theme/tokens.dart';
import '../../data/api_client.dart';
import '../../data/models/clip_record.dart';
import '../../data/models/coach.dart';
import '../../data/repositories/analysis_repository.dart';
import '../../shared/disclaimers.dart';
import '../../shared/widgets/message_view.dart';
import 'source_chips.dart';
import '../../ui/depth.dart';
import '../../shared/widgets/helper_text.dart';

/// One turn of the general coach conversation, with the knowledge it cited.
class CoachTurn {
  const CoachTurn({required this.message, this.sources = const []});

  final ChatMessage message;
  final List<CoachSource> sources;
}

class CoachChatState {
  const CoachChatState({this.turns = const [], this.streaming, this.busy = false, this.error});

  final List<CoachTurn> turns;
  final String? streaming;
  final bool busy;
  final String? error;
}

/// D42: the general coach (technique, rules, drills, progress across sessions). The
/// conversation lives in the app; the server keeps no copy (POST /coach/chat).
class CoachChatController extends Notifier<CoachChatState> {
  static const historyTurns = 12;

  @override
  CoachChatState build() => const CoachChatState();

  Future<void> send(String text) async {
    final question = text.trim();
    if (question.isEmpty || state.busy) return;
    final earlier = [
      for (final t in state.turns.reversed.take(historyTurns).toList().reversed)
        <String, dynamic>{'role': t.message.role, 'text': t.message.text},
    ];
    final asked = CoachTurn(
      message: ChatMessage(role: 'user', text: question, at: DateTime.now().toUtc()),
    );
    state = CoachChatState(turns: [...state.turns, asked], streaming: '', busy: true);
    void fail(String message) => state = CoachChatState(
      turns: state.turns.where((t) => t != asked).toList(),
      error: message,
    );
    var finished = false;
    try {
      final events = ref.read(apiClientProvider).coachChat(question, history: earlier);
      await for (final event in events) {
        switch (event['type']) {
          case 'delta':
            state = CoachChatState(
              turns: state.turns,
              streaming: '${state.streaming ?? ''}${event['text']}',
              busy: true,
            );
          case 'done':
            final answer = CoachTurn(
              message: ChatMessage.fromJson(event['message'] as Map<String, dynamic>),
              sources: CoachSource.listFrom(event['sources']),
            );
            state = CoachChatState(turns: [...state.turns, answer]);
            finished = true;
          case 'error':
            fail(event['detail'] as String? ?? 'The coach could not answer');
            finished = true;
        }
      }
      if (!finished) fail('The answer was cut off. Try asking again.');
    } on ApiException catch (e) {
      fail(e.message);
    } on Object catch (e) {
      fail('The coach could not answer: $e');
    } finally {
      if (state.busy) state = CoachChatState(turns: state.turns, error: state.error);
    }
  }

  void clear() {
    if (!state.busy) state = const CoachChatState();
  }
}

/// Kept for the app's lifetime, so leaving the screen does not lose the conversation.
final coachChatProvider = NotifierProvider<CoachChatController, CoachChatState>(
  CoachChatController.new,
);

const kCoachSuggestions = [
  'Am I improving across my sessions?',
  'When should I split step?',
  'How does doubles rotation work?',
  'What are the service rules?',
];

class CoachScreen extends ConsumerStatefulWidget {
  const CoachScreen({super.key});

  @override
  ConsumerState<CoachScreen> createState() => _CoachScreenState();
}

class _CoachScreenState extends ConsumerState<CoachScreen> {
  final _input = TextEditingController();
  final _scroll = SmoothScrollController();

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send([String? text]) {
    if (ref.read(coachChatProvider).busy) return;
    final message = text ?? _input.text;
    _input.clear();
    ref.read(coachChatProvider.notifier).send(message).then((_) {
      if (!mounted || text != null) return;
      if (ref.read(coachChatProvider).error != null && _input.text.isEmpty) {
        _input.text = message.trim();
      }
    });
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final health = ref.watch(healthProvider).valueOrNull;
    final available = health?.chatAvailable ?? false;
    final state = ref.watch(coachChatProvider);
    ref.listen(coachChatProvider, (_, _) => _scrollToEnd());
    final theme = Theme.of(context);
    final gutter = Breakpoints.gutter(Breakpoints.of(context));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Coach'),
        actions: [
          if (state.turns.isNotEmpty)
            IconButton(
              tooltip: 'New conversation',
              onPressed: state.busy ? null : ref.read(coachChatProvider.notifier).clear,
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: SafeArea(
        child: !available
            ? MessageView(
                icon: Icons.forum_outlined,
                message: health == null
                    ? 'Checking the server…'
                    : 'The coach is off on this server',
                detail:
                    'The server owner has not set a Gemini (or Claude) API key.\n\n$kCoachPrivacy',
              )
            : MaxWidth(
                maxWidth: 800,
                child: Column(
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(gutter, Spacing.sm, gutter, 0),
                      child: Text(kCoachPrivacy, style: theme.textTheme.bodySmall),
                    ),
                    Expanded(
                      child: ListView(
                        controller: _scroll,
                        padding: EdgeInsets.all(gutter),
                        children: [
                          if (state.turns.isEmpty && state.streaming == null) ...[
                            Text(
                              'Ask about technique, tactics, drills, the rules, or how you are '
                              'progressing across your recorded sessions.',
                              style: theme.textTheme.bodyMedium,
                            ),
                            const SizedBox(height: Spacing.md),
                            Wrap(
                              spacing: Spacing.sm,
                              runSpacing: Spacing.sm,
                              children: [
                                for (final q in kCoachSuggestions)
                                  ActionChip(label: Text(q), onPressed: () => _send(q)),
                              ],
                            ),
                          ],
                          for (final t in state.turns) CoachBubble(turn: t),
                          if (state.streaming != null)
                            CoachBubble(
                              turn: CoachTurn(
                                message: ChatMessage(
                                  role: 'assistant',
                                  text: state.streaming!.isEmpty ? '…' : state.streaming!,
                                ),
                              ),
                            ),
                          if (state.error != null)
                            Padding(
                              padding: const EdgeInsets.only(top: Spacing.sm),
                              child: HelperText(state.error!, error: true),
                            ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(gutter, 0, gutter, Spacing.sm),
                      child: Row(
                        children: [
                          Expanded(
                            child: InsetBox(
                              radius: Radii.md,
                              child: TextField(
                                controller: _input,
                                enabled: !state.busy,
                                maxLength: 1000,
                                minLines: 1,
                                maxLines: 4,
                                textInputAction: TextInputAction.send,
                                onSubmitted: (_) => _send(),
                                decoration: const InputDecoration(
                                  labelText: 'Your question',
                                  counterText: '',
                                  filled: false,
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: Spacing.sm),
                          IconButton.filled(
                            tooltip: 'Send',
                            onPressed: state.busy ? null : _send,
                            icon: state.busy
                                ? const SizedBox.square(
                                    dimension: 20,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.send),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(gutter, 0, gutter, Spacing.sm),
                      child: Text(
                        kCoachingDisclaimer,
                        style: theme.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// One message of a coach conversation, in the same bubble style as the results chat: yours
/// in ink on the right, the coach's in lavender on the left, the corner nearest the speaker
/// kept tight. [footer] goes under the text (moment links).
class CoachBubble extends StatelessWidget {
  const CoachBubble({super.key, required this.turn, this.footer});

  final CoachTurn turn;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final user = turn.message.fromUser;
    const round = Radius.circular(Radii.lg);
    const tail = Radius.circular(Radii.sm);
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: Spacing.xs),
          decoration: BoxDecoration(
            color: user ? p.ink : p.lavender,
            borderRadius: BorderRadius.only(
              topLeft: round,
              topRight: round,
              bottomLeft: user ? round : tail,
              bottomRight: user ? tail : round,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.lg, vertical: Spacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  label: user ? 'You asked' : 'Coach answered',
                  child: user
                      ? SelectableText(turn.message.text, style: TextStyle(color: p.onInk))
                      : CoachReply(turn.message.text),
                ),
                if (footer != null) ...[const SizedBox(height: Spacing.sm), footer!],
                if (turn.sources.isNotEmpty) ...[
                  const SizedBox(height: Spacing.sm),
                  SourceChips(sources: turn.sources),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
