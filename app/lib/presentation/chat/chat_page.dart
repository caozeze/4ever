import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/ai/demo_chat_controller.dart';
import '../../application/ai/generation_budget_policy.dart';
import '../../core/providers/model_management_providers.dart';
import '../../domain/ai/model_install_progress.dart';
import '../../domain/ai/model_install_status.dart';
import '../app_navigation_drawer.dart';

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key});

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final TextEditingController _promptController = TextEditingController(
    text: DemoChatController.defaultPrompt,
  );
  final ScrollController _scrollController = ScrollController();
  final List<_ChatMessage> _messages = <_ChatMessage>[];

  ModelInstallStatus _status = ModelInstallStatus.notInstalled;
  var _isPreparing = false;
  var _isGenerating = false;
  String? _statusMessage;
  String? _errorMessage;

  bool get _isReady => _status == ModelInstallStatus.ready;

  @override
  void initState() {
    super.initState();
    _messages.add(
      const _ChatMessage(
        role: _ChatRole.assistant,
        text: 'Ask me a wellbeing question. I will answer with local Gemma 4.',
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_prepareModel());
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _promptController.dispose();
    super.dispose();
  }

  Future<void> _prepareModel() async {
    if (_isPreparing || _isReady) {
      return;
    }

    setState(() {
      _isPreparing = true;
      _statusMessage = 'Preparing local Gemma 4...';
      _errorMessage = null;
    });

    try {
      final controller = await ref.read(demoChatControllerProvider.future);
      await for (final progress in controller.prepareModel()) {
        if (!mounted) {
          return;
        }
        _applyProgress(progress);
      }
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = ModelInstallStatus.failed;
        _errorMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isPreparing = false;
        });
      }
    }
  }

  Future<void> _askGemma() async {
    final prompt = _promptController.text.trim();
    if (prompt.isEmpty || !_isReady || _isGenerating) {
      return;
    }

    setState(() {
      _isGenerating = true;
      _statusMessage = null;
      _errorMessage = null;
      _messages.add(_ChatMessage(role: _ChatRole.user, text: prompt));
      _promptController.clear();
    });
    _scrollToLatestMessage();

    try {
      final controller = await ref.read(demoChatControllerProvider.future);
      final response = await controller.ask(
        prompt: prompt,
        intent: GenerationIntent.chat,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _messages.add(
          _ChatMessage(role: _ChatRole.assistant, text: response.text),
        );
      });
      _scrollToLatestMessage();
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isGenerating = false;
        });
      }
    }
  }

  void _applyProgress(ModelInstallProgress progress) {
    setState(() {
      _status = progress.status;
      if (progress.status == ModelInstallStatus.failed) {
        _errorMessage = progress.message;
        _statusMessage = null;
      } else {
        _statusMessage = progress.message;
        _errorMessage = null;
      }
      if (progress.status == ModelInstallStatus.ready) {
        _statusMessage = null;
      }
    });
  }

  void _scrollToLatestMessage() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) {
        return;
      }
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final canSend = _isReady && !_isGenerating;

    return Scaffold(
      appBar: AppBar(title: const Text('Gemma Health Coach')),
      drawer: const AppNavigationDrawer(currentPath: '/chat'),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: ListView.builder(
                key: const ValueKey<String>('gemma_message_list'),
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                itemCount: _messages.length,
                itemBuilder: (BuildContext context, int index) {
                  return _ChatBubble(message: _messages[index]);
                },
              ),
            ),
            if (_statusMessage != null || _isPreparing || _errorMessage != null)
              _ChatStatusBar(
                statusMessage: _isPreparing
                    ? 'Preparing local Gemma 4...'
                    : _statusMessage,
                errorMessage: _errorMessage,
                onRetry: _status == ModelInstallStatus.failed
                    ? _prepareModel
                    : null,
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      key: const ValueKey<String>('gemma_prompt_input'),
                      controller: _promptController,
                      minLines: 1,
                      maxLines: 5,
                      textInputAction: TextInputAction.newline,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        hintText: 'Ask Gemma 4...',
                      ),
                      onSubmitted: canSend ? (_) => _askGemma() : null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const ValueKey<String>('gemma_ask_button'),
                    onPressed: canSend ? _askGemma : null,
                    child: Text(_isGenerating ? 'Asking...' : 'Ask'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _ChatRole { user, assistant }

class _ChatMessage {
  const _ChatMessage({required this.role, required this.text});

  final _ChatRole role;
  final String text;
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({required this.message});

  final _ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = message.role == _ChatRole.user;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: isUser
                  ? theme.colorScheme.primaryContainer
                  : theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: isUser
                  ? SelectableText(
                      message.text,
                      key: const ValueKey<String>('gemma_user_message'),
                      style: theme.textTheme.bodyLarge,
                    )
                  : MarkdownBody(
                      key: const ValueKey<String>('gemma_answer'),
                      data: message.text,
                      selectable: true,
                      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                        p: theme.textTheme.bodyLarge,
                        strong: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChatStatusBar extends StatelessWidget {
  const _ChatStatusBar({
    required this.statusMessage,
    required this.errorMessage,
    required this.onRetry,
  });

  final String? statusMessage;
  final String? errorMessage;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasError = errorMessage != null;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: hasError
          ? theme.colorScheme.errorContainer
          : theme.colorScheme.surfaceContainerHighest,
      child: Row(
        children: <Widget>[
          if (!hasError)
            const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          if (!hasError) const SizedBox(width: 8),
          Expanded(
            child: Text(
              errorMessage ?? statusMessage ?? '',
              key: hasError
                  ? const ValueKey<String>('gemma_error')
                  : const ValueKey<String>('gemma_status_message'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: hasError
                    ? theme.colorScheme.onErrorContainer
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (onRetry != null)
            TextButton(
              key: const ValueKey<String>('gemma_retry_button'),
              onPressed: onRetry,
              child: const Text('Retry'),
            ),
        ],
      ),
    );
  }
}
