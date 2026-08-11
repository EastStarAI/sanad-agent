import 'package:equatable/equatable.dart';

abstract class AuthState extends Equatable {
  const AuthState();

  @override
  List<Object?> get props => [];
}

class AuthInitial extends AuthState {}

class AuthLoading extends AuthState {}

class AuthAuthenticated extends AuthState {
  final String username;
  final String displayName;
  final String email;
  final String userId;
  final String accessToken;
  final double userCredits;
  final double totalCredits;

  const AuthAuthenticated({
    required this.username,
    String? displayName,
    required this.email,
    required this.userId,
    required this.accessToken,
    required this.userCredits,
    required this.totalCredits,
  }) : displayName = displayName ?? username;

  @override
  List<Object?> get props => [
    username,
    displayName,
    email,
    userId,
    accessToken,
    userCredits,
    totalCredits,
  ];

  AuthAuthenticated copyWith({
    String? username,
    String? displayName,
    String? email,
    String? userId,
    String? accessToken,
    double? userCredits,
    double? totalCredits,
  }) {
    return AuthAuthenticated(
      username: username ?? this.username,
      displayName: displayName ?? this.displayName,
      email: email ?? this.email,
      userId: userId ?? this.userId,
      accessToken: accessToken ?? this.accessToken,
      userCredits: userCredits ?? this.userCredits,
      totalCredits: totalCredits ?? this.totalCredits,
    );
  }
}

class AuthUnauthenticated extends AuthState {}

class AuthError extends AuthState {
  final String message;

  const AuthError(this.message);

  @override
  List<Object?> get props => [message];
}
