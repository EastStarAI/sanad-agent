import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_cubit.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_state.dart';
import 'package:go_router/go_router.dart';
import 'package:sanad_client/core/navigation/app_routes.dart';

class UserProfileTile extends StatelessWidget {
  const UserProfileTile({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AuthCubit, AuthState>(
      builder: (context, authState) {
        final bool isAuthenticated = authState is AuthAuthenticated;
        final String displayName;
        if (isAuthenticated) {
          displayName = authState.displayName;
        } else if (authState is AuthLoading) {
          displayName = 'Signing in...';
        } else {
          displayName = '';
        }

        return InkWell(
          onTap: () {
            unawaited(context.push(AppRoutes.settings));
          },
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: Theme.of(context).colorScheme.outline)),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  child: isAuthenticated
                      ? Text(
                          displayName.substring(0, 1).toUpperCase(),
                          style: TextStyle(color: Theme.of(context).colorScheme.onPrimary, fontSize: 12),
                        )
                      : Icon(
                          Icons.person_outline,
                          size: 16,
                          color: Theme.of(context).colorScheme.onPrimary,
                        ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    displayName,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontWeight: FontWeight.w500,
                      fontSize: 14,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Icon(Icons.settings, size: 16, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5)),
              ],
            ),
          ),
        );
      },
    );
  }
}
