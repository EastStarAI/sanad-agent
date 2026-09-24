import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sanad_client/core/presentation/widgets/app_progress_indicator.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';

class TerminalToolTile extends StatelessWidget {
  final CanonicalEvent event;

  const TerminalToolTile({
    super.key,
    required this.event,
  });

  @override
  Widget build(BuildContext context) {
    if (event.status == EventStatus.running) {
      return _buildRunningIndicator(context);
    }

    Map<String, dynamic> mapInput = {};
    final input = event.kind == EventKind.toolCall ? event.toolInput : null;
    if (input is Map) {
      mapInput = Map<String, dynamic>.from(input);
    } else if (input is String) {
      try {
        final decoded = jsonDecode(input);
        if (decoded is Map) {
          mapInput = Map<String, dynamic>.from(decoded);
        }
      } catch (_) {}
    }

    final output = event.toolOutput;
    final cmd = mapInput['command'] ?? '';
    final cwd = mapInput['cwd'] ?? '';

    // Parse output response
    bool hasError = event.status == EventStatus.error;
    String consoleText = '';

    if (output is String) {
      try {
        final decoded = jsonDecode(output);
        if (decoded is Map<String, dynamic>) {
          hasError = decoded['isError'] == true;
          consoleText = decoded['output']?.toString() ?? '';
        } else {
          consoleText = output;
        }
      } catch (_) {
        consoleText = output;
      }
    } else if (output is Map<String, dynamic>) {
      hasError = output['isError'] == true;
      consoleText = output['output']?.toString() ?? '';
    } else if (output != null) {
      consoleText = output.toString();
    }

    // Split stdout and stderr if parsed from 'STDERR:\n' separator
    String stdoutText = consoleText;
    String stderrText = '';
    final stderrIndex = consoleText.indexOf('STDERR:\n');
    if (stderrIndex != -1) {
      stdoutText = consoleText.substring(0, stderrIndex).trim();
      stderrText = consoleText.substring(stderrIndex + 'STDERR:\n'.length).trim();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (cwd.toString().isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 6.0),
            child: Text(
              'Directory: $cwd',
              style: GoogleFonts.outfit(
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
                fontSize: 11,
              ),
            ),
          ),
        ],
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF0D0D0D),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: hasError ? Colors.red.shade900 : Colors.grey.shade800,
              width: 1.5,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (cmd.toString().isNotEmpty) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      r'$ ',
                      style: GoogleFonts.firaCode(
                        fontSize: 11,
                        color: Colors.green.shade500,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        cmd.toString(),
                        style: GoogleFonts.firaCode(
                          fontSize: 11,
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Divider(color: Colors.grey.shade800, height: 1),
                const SizedBox(height: 8),
              ],
              if (stdoutText.isNotEmpty)
                Text(
                  stdoutText,
                  style: GoogleFonts.firaCode(
                    fontSize: 11,
                    color: Colors.green.shade400,
                  ),
                ),
              if (stderrText.isNotEmpty) ...[
                if (stdoutText.isNotEmpty) const SizedBox(height: 8),
                Text(
                  'STDERR:',
                  style: GoogleFonts.outfit(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: Colors.red.shade400,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  stderrText,
                  style: GoogleFonts.firaCode(
                    fontSize: 11,
                    color: Colors.red.shade300,
                  ),
                ),
              ],
              if (stdoutText.isEmpty && stderrText.isEmpty)
                Text(
                  'No output returned.',
                  style: GoogleFonts.firaCode(
                    fontSize: 11,
                    color: Colors.grey.shade500,
                    fontStyle: FontStyle.italic,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRunningIndicator(BuildContext context) {
    Map<String, dynamic> mapInput = {};
    final input = event.toolInput;
    if (input is Map) {
      mapInput = Map<String, dynamic>.from(input);
    } else if (input is String) {
      try {
        final decoded = jsonDecode(input);
        if (decoded is Map) {
          mapInput = Map<String, dynamic>.from(decoded);
        }
      } catch (_) {}
    }

    final cmd = mapInput['command'] ?? '';
    final cwd = mapInput['cwd'] ?? '';

    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (cwd.toString().isNotEmpty) ...[
            Text(
              'Directory: $cwd',
              style: GoogleFonts.outfit(
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 6),
          ],
          if (cmd.toString().isNotEmpty) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF0D0D0D),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: Colors.grey.shade800,
                  width: 1.5,
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    r'$ ',
                    style: GoogleFonts.firaCode(
                      fontSize: 11,
                      color: Colors.green.shade500,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      cmd.toString(),
                      style: GoogleFonts.firaCode(
                        fontSize: 11,
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: AppProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Executing terminal command...',
                  style: GoogleFonts.roboto(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
