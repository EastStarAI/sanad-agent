enum ConversationVisualState {
  newConversation,
  loadingTransition,
  activeSession,
}

extension ConversationVisualStateX on ConversationVisualState {
  bool get isNewConversation => this == ConversationVisualState.newConversation;
  bool get isLoadingTransition => this == ConversationVisualState.loadingTransition;
  bool get isActiveSession => this == ConversationVisualState.activeSession;
  bool get showAppBar => !isNewConversation;
}

