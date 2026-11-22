import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/responsive/breakpoints.dart';
import '../../core/router/app_router.dart';
import '../../data/api_client.dart';
import '../../data/models/clip_record.dart';
import '../../data/models/coach.dart';
import '../../data/repositories/analysis_repository.dart';
import '../../shared/disclaimers.dart';
import '../../shared/widgets/message_view.dart';
import '../../shared/widgets/page_scaffold.dart';
import '../results/widgets/session_summary.dart';
import '../coach/source_chips.dart';
import '../../core/theme/tokens.dart';

class ChatState {
  const ChatState({this.messages = const [], this.streaming, this.busy = false, this.error});

  final List<ChatMessage> messages;

  /// The answer as it streams in, before the server's checked version replaces it.
  final String? streaming;
  final bool busy;
  final String? error;

  int get questions => messages.where((m) => m.fromUser).length;
}

/// F22: one chat per job, saved in the record on the server.
class ChatController extends AutoDisposeFamilyNotifier<ChatState, String> {
  @override
  ChatState build(String jobId) {
    // Opened straight at /results/chat the record may still be loading: take its history
    // when it arrives (and after it is refreshed), unless a question is in flight.
    ref.listen(recordProvider(jobId), (_, next) {
      final chat = next.valueOrNull?.chat;
      if (chat != null && !state.busy && chat.length >= state.messages.length) {
        state = ChatState(messages: chat, error: state.error);
      }
    });
    final record = ref.read(recordProvider(jobId)).valueOrNull;
    return ChatState(messages: record?.chat ?? const []);
  }

  Future<void> send(String text) async {
    final question = text.trim();
    if (question.isEmpty || state.busy) return;
    // Keep the controller while the answer streams, even if the user leaves the screen, so
    // the answer is still saved here and the record is refreshed.
    final keep = ref.keepAlive();
    final asked = ChatMessage(role: 'user', text: question, at: DateTime.now().toUtc());
    state = ChatState(messages: [...state.messages, asked], streaming: '', busy: true);
    void fail(String message) => state = ChatState(
      messages: state.messages.where((m) => m != asked).toList(),
      error: message,
    );
    var finished = false;
    try {
      await for (final event in ref.read(apiClientProvider).chat(arg, question)) {
        switch (event['type']) {
          case 'delta':
            state = ChatState(
              messages: state.messages,
              streaming: '${state.streaming ?? ''}${event['text']}',
              busy: true,
            );
          case 'done':
            final answer = ChatMessage.fromJson(event['message'] as Map<String, dynamic>);
            // D42: the knowledge the answer cited; not saved in the record, shown this session.
            final sources = CoachSource.listFrom(event['sources']);
            if (sources.isNotEmpty) {
              ref
                  .read(chatSourcesProvider(arg).notifier)
                  .update((m) => {...m, answer.text: sources});
            }
            state = ChatState(messages: [...state.messages, answer]);
            finished = true;
          case 'error':
            fail(event['detail'] as String? ?? 'The coach could not answer');
            finished = true;
        }
      }
      // The server saves a question only with its answer: without `done` nothing was kept.
      if (!finished) fail('The answer was cut off. Try asking again.');
      // The record on the server now holds the chat; refresh it for next time.
      ref.invalidate(recordProvider(arg));
    } on ApiException catch (e) {
      fail(e.message);
    } on Object catch (e) {
      fail('The coach could not answer: $e');
    } finally {
      if (state.busy) state = ChatState(messages: state.messages, error: state.error);
      keep.close();
    }
  }
}

final chatControllerProvider = AutoDisposeNotifierProviderFamily<ChatController, ChatState, String>(
  ChatController.new,
);

/// Knowledge sources of this session's answers, by answer text (D42).
final chatSourcesProvider = StateProvider.family<Map<String, List<CoachSource>>, String>(
  (ref, jobId) => const {},
);

const kSuggestedQuestions = [
  'What should I fix first?',
  'Why did my smashes land short?',
  'How did I lose my rallies?',
];

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.jobId});

  final String jobId;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send([String? text]) {
    // A question still being answered: keep what was typed instead of dropping it.
    if (ref.read(chatControllerProvider(widget.jobId)).busy) return;
    final message = text ?? _input.text;
    _input.clear();
    ref.read(chatControllerProvider(widget.jobId).notifier).send(message).then((_) {
      // A question that failed (too many requests, a server or network error) is taken out
      // of the list; put it back in the box so it need not be typed again.
      if (!mounted || text != null) return;
      final state = ref.read(chatControllerProvider(widget.jobId));
      if (state.error != null && _input.text.isEmpty) {
        _input.text = message.trim();
      }
    });
  }

  /// Keep the newest message in view as questions are asked and the answer streams in.
  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  void _seek(Moment m) {
    ref.read(seekRequestProvider(widget.jobId).notifier).state = m;
    context.go(Routes.results(widget.jobId));
  }

  @override
  Widget build(BuildContext context) {
    final health = ref.watch(healthProvider).valueOrNull;
    final available = health?.chatAvailable ?? false;
    final state = ref.watch(chatControllerProvider(widget.jobId));
    final sources = ref.watch(chatSourcesProvider(widget.jobId));
    ref.listen(chatControllerProvider(widget.jobId), (_, _) => _scrollToEnd());
    final limit = health?.chatMaxMessages ?? 0;
    final atLimit = limit > 0 && state.questions >= limit;
    final theme = Theme.of(context);
    final p = AppPalette.of(context);
    final gutter = Breakpoints.gutter(Breakpoints.of(context));

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(gutter, Spacing.lg, gutter, Spacing.sm),
          child: MaxWidth(
            maxWidth: 900,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const PageHeader(title: 'Ask your coach'),
                const SizedBox(height: Spacing.sm),
                Expanded(
                  child: !available
                      ? MessageView(
                          icon: Icons.forum_outlined,
                          message: health == null
                              ? 'Checking the server…'
                              : 'Coach chat is off on this server',
                          detail:
                              'The server owner has not set a Gemini or Claude API key. Session notes in '
                              'the Coach tab still work.\n\n$kChatPrivacy',
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(kChatPrivacy, style: theme.textTheme.bodySmall),
                            Expanded(
                              child: ListView(
                                controller: _scroll,
                                padding: const EdgeInsets.symmetric(vertical: Spacing.lg),
                                children: [
                                  if (state.messages.isEmpty && state.streaming == null) ...[
                                    Text(
                                      'Ask about your strokes, rallies, line calls or what to work on. '
                                      'Answers come only from this session\'s data.',
                                      style: theme.textTheme.bodyMedium,
                                    ),
                                    const SizedBox(height: Spacing.md),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: [
                                        for (final q in kSuggestedQuestions)
                                          ActionChip(label: Text(q), onPressed: () => _send(q)),
                                      ],
                                    ),
                                  ],
                                  for (final m in state.messages)
                                    _Bubble(
                                      message: m,
                                      onSeek: _seek,
                                      sources: sources[m.text] ?? const [],
                                    ),
                                  if (state.streaming != null)
                                    _Bubble(
                                      message: ChatMessage(
                                        role: 'assistant',
                                        text: state.streaming!.isEmpty ? '…' : state.streaming!,
                                      ),
                                      onSeek: _seek,
                                    ),
                                  if (state.error != null)
                                    Padding(
                                      padding: const EdgeInsets.only(top: Spacing.sm),
                                      child: Text(
                                        state.error!,
                                        style: TextStyle(color: theme.colorScheme.error),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            // One rounded bar: the question box and the send button inside it.
                            Container(
                              padding: const EdgeInsets.fromLTRB(
                                Spacing.lg,
                                Spacing.xs,
                                Spacing.xs,
                                Spacing.xs,
                              ),
                              decoration: BoxDecoration(
                                color: p.surface,
                                borderRadius: BorderRadius.circular(Radii.xl),
                                border: Border.all(color: p.hairline ?? p.surface2),
                                boxShadow: p.cardShadow,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: _input,
                                      enabled: !state.busy && !atLimit,
                                      maxLength: 1000,
                                      minLines: 1,
                                      maxLines: 4,
                                      textInputAction: TextInputAction.send,
                                      onSubmitted: (_) => _send(),
                                      decoration: InputDecoration(
                                        hintText: atLimit
                                            ? 'Question limit for this session reached'
                                            : 'Your question',
                                        // The count is shown under the bar instead.
                                        counterText: '',
                                        filled: false,
                                        border: InputBorder.none,
                                        enabledBorder: InputBorder.none,
                                        focusedBorder: InputBorder.none,
                                        disabledBorder: InputBorder.none,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: Spacing.sm),
                                  IconButton.filled(
                                    tooltip: 'Send',
                                    onPressed: state.busy || atLimit ? null : _send,
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
                              padding: const EdgeInsets.fromLTRB(
                                Spacing.lg,
                                Spacing.sm,
                                Spacing.lg,
                                0,
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: Text(
                                      kCoachingDisclaimer,
                                      style: theme.textTheme.bodySmall?.copyWith(
                                        fontStyle: FontStyle.italic,
                                      ),
                                    ),
                                  ),
                                  if (limit > 0) ...[
                                    const SizedBox(width: Spacing.md),
                                    Text(
                                      '${state.questions} of $limit',
                                      style: theme.textTheme.bodySmall,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.onSeek, this.sources = const []});

  final ChatMessage message;
  final ValueChanged<Moment> onSeek;
  final List<CoachSource> sources;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final user = message.fromUser;
    const round = Radius.circular(Radii.lg);
    const tail = Radius.circular(Radii.sm);
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: Spacing.xs),
          decoration: BoxDecoration(
            // Yours in ink on the right, the coach's in lavender on the left; the corner
            // nearest the speaker's side stays tight.
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
                  child: SelectableText(
                    message.text,
                    style: user ? TextStyle(color: p.onInk) : null,
                  ),
                ),
                if (message.citations.isNotEmpty) ...[
                  const SizedBox(height: Spacing.sm),
                  MomentChips(moments: message.citations, onSeek: onSeek),
                ],
                if (sources.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  SourceChips(sources: sources),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
