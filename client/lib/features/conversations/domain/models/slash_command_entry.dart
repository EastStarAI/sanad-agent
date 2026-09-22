import 'package:flutter/widgets.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';

enum SlashCommandType {
  skill('skill'),
  runtimeAction('runtime_action');

  final String type;
  const SlashCommandType(this.type);
}

enum SlashCommandPlacement { messageStart, anywhere }

enum SlashCommandSelectionAction { insertToken, executeImmediately }

extension SlashCommandTypeX on SlashCommandType {
  SlashCommandPlacement get placement {
    return switch (this) {
      SlashCommandType.skill => SlashCommandPlacement.anywhere,
      SlashCommandType.runtimeAction => SlashCommandPlacement.messageStart,
    };
  }

  SlashCommandSelectionAction get selectionAction {
    return switch (this) {
      SlashCommandType.skill => SlashCommandSelectionAction.insertToken,
      SlashCommandType.runtimeAction => SlashCommandSelectionAction.executeImmediately,
    };
  }

  IconData get icon {
    switch (this) {
      case SlashCommandType.skill:
        return Symbols.contract;
      case SlashCommandType.runtimeAction:
        return Symbols.terminal;
    }
  }
}

class SlashCommandEntry {
  final String sourceId;
  final String command;
  final String insertText;
  final String? description;
  final SlashCommandType type;

  const SlashCommandEntry({
    required this.sourceId,
    required this.command,
    required this.insertText,
    this.description,
    this.type = SlashCommandType.skill,
  });

  String get invocationText {
    final normalizedCommand = command.trim().replaceFirst(RegExp(r'^/+'), '');
    return switch (type) {
      SlashCommandType.skill => insertText,
      SlashCommandType.runtimeAction => '/$normalizedCommand',
    };
  }
}
