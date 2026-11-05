import 'package:flutter/material.dart';
import 'package:sanad_client/core/theme/app_typography.dart';

class PlanTaskList extends StatelessWidget {
  final Map<String, dynamic>? plan;

  const PlanTaskList({super.key, required this.plan});

  @override
  Widget build(BuildContext context) {
    final tasks = plan?['tasks'] as List?;
    if (tasks == null || tasks.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: tasks.map((task) => _buildTask(context, task)).toList(),
    );
  }

  Widget _buildTask(BuildContext context, dynamic task) {
    final title = task['title']?.toString() ?? 'Task';
    final status = task['status']?.toString() ?? 'pending';
    final isDone = status == 'done' || status == 'completed';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        children: [
          Icon(
            isDone ? Icons.check_circle_outline : Icons.circle_outlined,
            size: 14,
            color: isDone
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.24),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: AppTypography.text(context,
                color: isDone
                    ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6)
                    : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.38),
                fontSize: 12,
                decoration: isDone ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
