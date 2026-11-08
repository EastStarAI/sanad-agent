import 'dart:async';
import 'dart:math' as math;
import 'package:sanad_client/core/theme/app_typography.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/voice/presentation/bloc/voice_stream_cubit.dart';
import 'package:sanad_client/features/voice/presentation/bloc/voice_stream_state.dart';
import 'package:sanad_client/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class VoiceStreamPanel extends StatefulWidget {
  final VoiceStreamState voiceState;
  final DeviceConfig agent;
  final Color borderColor;
  final Color inputBgColor;

  const VoiceStreamPanel({
    super.key,
    required this.voiceState,
    required this.agent,
    required this.borderColor,
    required this.inputBgColor,
  });

  @override
  State<VoiceStreamPanel> createState() => _VoiceStreamPanelState();
}

class _VoiceStreamPanelState extends State<VoiceStreamPanel> with SingleTickerProviderStateMixin {
  late AnimationController _animationController;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    unawaited(_animationController.repeat());
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final isConnecting = widget.voiceState.status == VoiceSessionStatus.connecting;
    final isSpeaking = widget.voiceState.status == VoiceSessionStatus.speaking;
    final isListening = widget.voiceState.status == VoiceSessionStatus.listening;
    final isBlocked =
        widget.voiceState.status == VoiceSessionStatus.updateRequired ||
        widget.voiceState.status == VoiceSessionStatus.error;
    final l10n = AppLocalizations.of(context)!;

    String statusText = 'Connecting...';
    if (isListening) {
      statusText = widget.voiceState.isMuted ? 'Microphone muted' : 'Listening to you...';
    }
    if (isSpeaking) statusText = '${widget.agent.name} is speaking...';
    if (widget.voiceState.status == VoiceSessionStatus.updateRequired) {
      // No degraded fallback exists for an outdated relay peer, so the panel
      // states the required action instead of pretending the call is running.
      statusText = l10n.voiceUpdateRequired;
    } else if (widget.voiceState.status == VoiceSessionStatus.error) {
      statusText = l10n.voiceUnavailable;
    }

    // Wave color palettes - Premium Gradients
    final List<Color> userWaveColors = [
      const Color(0xFF00F2FE),
      const Color(0xFF4FACFE),
    ];
    final List<Color> agentWaveColors = [
      const Color(0xFFF9D423),
      const Color(0xFFFF4E50),
    ];

    return Container(
      decoration: BoxDecoration(
        color: widget.inputBgColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: widget.borderColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              // Glowing Agent Avatar
              Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: (isSpeaking ? agentWaveColors[1] : userWaveColors[1]).withValues(alpha: 0.3),
                      blurRadius: 12,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: CircleAvatar(
                  radius: 20,
                  backgroundColor: colorScheme.surfaceContainerHighest,
                  child: Text(
                    widget.agent.name.isNotEmpty ? widget.agent.name[0].toUpperCase() : 'A',
                    style: AppTypography.text(context,
                      color: colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.agent.name,
                      style: AppTypography.text(context,
                        color: colorScheme.onSurface,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 2),
                  Text(
                    statusText,
                    key: const Key('voice_status_text'),
                    style: AppTypography.text(context,
                      color: isBlocked
                          ? colorScheme.error
                          : isConnecting
                          ? Colors.orangeAccent
                          : isSpeaking
                          ? agentWaveColors[1]
                          : colorScheme.onSurfaceVariant,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  ],
                ),
              ),
              // Mute/Unmute microphone button
              IconButton(
                tooltip: widget.voiceState.isMuted ? 'Unmute Microphone' : 'Mute Microphone',
                icon: Icon(
                  widget.voiceState.isMuted ? Icons.mic_off : Icons.mic,
                  size: 20,
                ),
                color: widget.voiceState.isMuted ? Colors.redAccent : colorScheme.onSurfaceVariant,
                onPressed: () {
                  context.read<VoiceStreamCubit>().toggleMute();
                },
              ),
              // Mute/Mute State indicator or Mute Mic
              const SizedBox(width: 10),
              // Exit/Hang-up Button
              GestureDetector(
                onTap: () async {
                  await context.read<VoiceStreamCubit>().stopVoiceSession();
                },
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: const BoxDecoration(
                    color: Color(0xFFFF3B30),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.call_end,
                    color: Colors.white,
                    size: 18,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          // Waveforms
          Container(
            height: 60,
            width: double.infinity,
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(12),
            ),
            child: AnimatedBuilder(
              animation: _animationController,
              builder: (context, child) {
                return CustomPaint(
                  painter: FluidWavePainter(
                    animationValue: _animationController.value,
                    userAmplitude: widget.voiceState.isMuted ? 0.0 : (isListening ? 0.6 : (isConnecting ? 0.2 : 0.05)),
                    agentAmplitude: isSpeaking ? 0.7 : 0.05,
                    userColors: userWaveColors,
                    agentColors: agentWaveColors,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class FluidWavePainter extends CustomPainter {
  final double animationValue;
  final double userAmplitude;
  final double agentAmplitude;
  final List<Color> userColors;
  final List<Color> agentColors;

  FluidWavePainter({
    required this.animationValue,
    required this.userAmplitude,
    required this.agentAmplitude,
    required this.userColors,
    required this.agentColors,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final yCenter = size.height / 2;

    // 1. Draw User Wave (fluid siri-like movement)
    if (userAmplitude > 0) {
      _drawFluidWave(
        canvas,
        size,
        yCenter,
        userAmplitude,
        userColors,
        phaseShift: animationValue * 2 * math.pi,
        frequency: 2.0,
      );
      _drawFluidWave(
        canvas,
        size,
        yCenter,
        userAmplitude * 0.6,
        [userColors[0].withValues(alpha: 0.4), userColors[1].withValues(alpha: 0.4)],
        phaseShift: -animationValue * 2 * math.pi + 1.0,
        frequency: 2.8,
      );
    }

    // 2. Draw Agent Wave
    if (agentAmplitude > 0) {
      _drawFluidWave(
        canvas,
        size,
        yCenter,
        agentAmplitude,
        agentColors,
        phaseShift: animationValue * 2 * math.pi + math.pi / 2,
        frequency: 1.6,
      );
      _drawFluidWave(
        canvas,
        size,
        yCenter,
        agentAmplitude * 0.5,
        [agentColors[0].withValues(alpha: 0.4), agentColors[1].withValues(alpha: 0.4)],
        phaseShift: -animationValue * 2 * math.pi + math.pi / 3,
        frequency: 2.2,
      );
    }
  }

  void _drawFluidWave(
    Canvas canvas,
    Size size,
    double yCenter,
    double amplitude,
    List<Color> colors, {
    required double phaseShift,
    required double frequency,
  }) {
    final paint = Paint()
      ..shader = LinearGradient(colors: colors).createShader(Offset.zero & size)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;

    final path = Path();
    path.moveTo(0, yCenter);

    for (double x = 0; x <= size.width; x += 2) {
      final normalizedX = x / size.width;
      // Window function to taper the ends of the wave beautifully
      final envelope = math.sin(normalizedX * math.pi);

      final y =
          yCenter +
          amplitude * yCenter * 0.8 * envelope * math.sin((normalizedX * frequency * 2 * math.pi) + phaseShift);
      path.lineTo(x, y);
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant FluidWavePainter oldDelegate) {
    return oldDelegate.animationValue != animationValue ||
        oldDelegate.userAmplitude != userAmplitude ||
        oldDelegate.agentAmplitude != agentAmplitude;
  }
}
