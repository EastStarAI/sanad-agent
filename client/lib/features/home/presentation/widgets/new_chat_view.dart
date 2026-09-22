import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_state.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_header_actions.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input_panel.dart';
import 'package:sanad_client/features/conversations/domain/models/message_delivery_intent.dart';
import 'package:sanad_client/utils/app_platform.dart';

class NewChatView extends StatefulWidget {
  final void Function(String, {MessageDeliveryIntent intent}) onSendMessage;
  final VoidCallback? onStop;

  const NewChatView({
    super.key,
    required this.onSendMessage,
    this.onStop,
  });

  @override
  State<NewChatView> createState() => _NewChatViewState();
}

class _NewChatViewState extends State<NewChatView> {
  static const List<String> _helpMessages = [
    'Automate tasks, analyze data, and write code — just ask.',
    'I can search the web, manage files, and run terminal commands.',
    'Start a conversation or pick a workspace to work with local files.',
    'Ask me to research, summarize, or draft content for you.',
    'Need help debugging? Share your error logs or code to fix it together.',
    'I can design system architectures, database schemas, and workflows.',
    'Create structured implementation plans and execute tasks step-by-step.',
    'Let me generate test suites, run checks, and keep documentation updated.',
  ];

  late final String _helpMessage;

  @override
  void initState() {
    super.initState();
    _helpMessage = _helpMessages[Random().nextInt(_helpMessages.length)];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasDrawer = Scaffold.maybeOf(context)?.hasDrawer ?? false;

    final mainContent = Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 40),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(height: 24),
              // Experimental: horizontal wordmark replaces the 54pt "Sanad Agent"
              // hero title. SVG aspect is 808:106.4 (~7.6:1). Dark variant is
              // selected by brightness for legibility on dark surfaces.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: SizedBox(
                  width: 461,
                  height: 60,
                  child: SvgPicture.asset(
                    Theme.of(context).brightness == Brightness.dark
                        ? 'assets/brand/sanad-wordmark-horizontal-dark.svg'
                        : 'assets/brand/sanad-wordmark-horizontal.svg',
                  ),
                ),
              ),
              const SizedBox(height: 28),
              BlocBuilder<ConversationInputCubit, ConversationInputState>(
                builder: (context, inputState) {
                  final workspaceName = inputState.selectedWorkspace?.name;
                  final titleText = workspaceName != null ? 'Start a new task in $workspaceName' : 'Start a new task';
                  return Text(
                    titleText,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Georgia',
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.9),
                      fontSize: 28,
                      fontWeight: FontWeight.w400,
                      letterSpacing: -0.3,
                    ),
                  );
                },
              ),
              const SizedBox(height: 8),
              Text(
                _helpMessage,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 32),
              ConversationInputPanel(
                onSendMessage: widget.onSendMessage,
                onStop: widget.onStop,
                sessionId: null,
                showBlur: true,
                maxLines: 20,
              ),
              const SizedBox(height: 96),
            ],
          ),
        ),
      ),
    );

    if (hasDrawer) {
      return Stack(
        children: [
          mainContent,
          Positioned(
            top: AppPlatform.isMacOS ? 12 : MediaQuery.paddingOf(context).top + 8,
            left: 0,
            child: ConversationHeaderActions(
              onMenuPressed: () => Scaffold.of(context).openDrawer(),
            ),
          ),
        ],
      );
    }

    return mainContent;
  }
}
