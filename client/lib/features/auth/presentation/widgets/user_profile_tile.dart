import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:sanad_client/core/navigation/app_routes.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_cubit.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_state.dart';

class UserProfileTile extends StatelessWidget {
  const UserProfileTile({super.key});

  void _openSettings(BuildContext context, String section) {
    unawaited(context.push('${AppRoutes.settings}?section=$section'));
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AuthCubit, AuthState>(
      builder: (context, authState) {
        final isAuthenticated = authState is AuthAuthenticated;
        final String displayName;
        if (isAuthenticated) {
          displayName = authState.displayName;
        } else if (authState is AuthLoading) {
          displayName = 'Signing in...';
        } else {
          displayName = '';
        }

        final theme = Theme.of(context);
        return Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: theme.colorScheme.outline)),
          ),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  key: const Key('sidebar_profile_destination'),
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => _openSettings(context, 'profile'),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 14,
                          backgroundColor: theme.colorScheme.primary,
                          child: isAuthenticated
                              ? Text(
                                  displayName.substring(0, 1).toUpperCase(),
                                  style: TextStyle(color: theme.colorScheme.onPrimary, fontSize: 12),
                                )
                              : Icon(
                                  Icons.person_outline,
                                  size: 16,
                                  color: theme.colorScheme.onPrimary,
                                ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            displayName,
                            style: TextStyle(
                              color: theme.colorScheme.onSurface,
                              fontWeight: FontWeight.w500,
                              fontSize: 14,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              IconButton(
                key: const Key('sidebar_general_settings_destination'),
                tooltip: 'General settings',
                onPressed: () => _openSettings(context, 'general'),
                icon: Icon(
                  Icons.settings,
                  size: 16,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
