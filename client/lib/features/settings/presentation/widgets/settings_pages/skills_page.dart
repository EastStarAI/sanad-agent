import 'package:flutter/material.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/settings/data/device_skills_client.dart';

import '../settings_widgets.dart';

class SkillsPage extends StatelessWidget {
  const SkillsPage({super.key, required this.device, this.workspace});
  final DeviceConfig device;
  final DeviceWorkspace? workspace;

  @override
  Widget build(BuildContext context) => FutureBuilder<List<DeviceSkillEntry>>(
    future: getIt<DeviceSkillsClient>().list(
      device,
      workspaceId: workspace?.id,
    ),
    builder: (context, snapshot) {
      final title = workspace == null ? 'Skills' : '${workspace!.name} Skills';
      final subtitle = workspace == null
          ? 'User-level skills available on ${device.name}.'
          : 'Workspace and inherited device skills. Workspace skills take precedence when names match.';
      return PageFrame(
        title: title,
        subtitle: subtitle,
        child: snapshot.connectionState != ConnectionState.done
            ? const LinearProgressIndicator()
            : snapshot.hasError
            ? SettingsCard(child: Text(snapshot.error.toString()))
            : SkillList(
                skills: snapshot.data ?? const [],
                workspaceScoped: workspace != null,
              ),
      );
    },
  );
}

class SkillList extends StatelessWidget {
  const SkillList({
    super.key,
    required this.skills,
    required this.workspaceScoped,
  });
  final List<DeviceSkillEntry> skills;
  final bool workspaceScoped;

  @override
  Widget build(BuildContext context) {
    if (skills.isEmpty) {
      return const SettingsCard(child: Text('No skills found.'));
    }
    return Column(
      children: [
        for (final skill in skills) ...[
          SettingsCard(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                skill.active ? Icons.auto_awesome : Icons.visibility_off_outlined,
              ),
              title: Text(skill.name),
              subtitle: Text(
                skill.description ?? (skill.shadowedBy == null ? 'No description' : 'Shadowed by ${skill.shadowedBy}'),
              ),
              trailing: Chip(
                label: Text(_originLabel(skill.origin, workspaceScoped)),
              ),
            ),
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  String _originLabel(String origin, bool workspaceScoped) {
    final normalized = origin.toLowerCase();
    if (workspaceScoped && normalized.contains('workspace')) return 'Workspace';
    return 'Device';
  }
}
