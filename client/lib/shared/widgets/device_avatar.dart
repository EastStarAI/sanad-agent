// ignore_for_file: unused_field, unused_element, prefer_final_fields
import 'package:logging/logging.dart';
import 'dart:async';

import 'package:flutter/material.dart';

// import 'package:sanad_client/infrastructure/livekit/livekit_stubs.dart' as sdk; // Purged LiveKit dependency
// import 'package:rive/rive.dart';

class DeviceAvatar extends StatefulWidget {
  static final _logger = Logger('DeviceAvatar');

  // Commented out LiveKit-specific inputs for future non-LiveKit adaptation
  // final sdk.VideoTrack? videoTrack;
  // final sdk.AudioTrack? audioTrack;
  // final sdk.Participant? participant;
  final double size;

  const DeviceAvatar({
    super.key,
    // this.videoTrack,
    // this.audioTrack,
    // this.participant,
    this.size = 200,
  });

  @override
  State<DeviceAvatar> createState() => _DeviceAvatarState();
}

class _DeviceAvatarState extends State<DeviceAvatar> {
  // Rive Native Controllers
  // File? _riveFile;
  // RiveWidgetController? _controller;

  // Inputs
  // BooleanInput? _isThinking;
  // BooleanInput? _isListening;
  // BooleanInput? _isSpeaking;
  // TriggerInput? _speakTrigger;
  // TriggerInput? _idleTrigger;
  // NumberInput? _audioLevel;

  bool _isRiveInitialized = false;

  // Commented out LiveKit listeners/state
  // sdk.AudioVisualizer? _visualizer;
  // sdk.EventsListener<sdk.AudioVisualizerEvent>? _visualizerListener;
  // sdk.EventsListener<sdk.ParticipantEvent>? _participantListener;
  // sdk.DeviceState _agentState = sdk.DeviceState.initializing;
  // sdk.DeviceState? _lastDeviceState;

  // Local/future agent state enum or mock representation
  String _agentState = 'listening';
  String? _lastDeviceState;
  double _currentAudioLevel = 0.0;

  @override
  void initState() {
    super.initState();
    // unawaited(_initRive());
    unawaited(_attachListeners());
  }

  // Future<void> _initRive() async {
  //   try {
  //     final file = await File.asset(
  //       'assets/agent_character.riv',
  //       riveFactory: Factory.rive,
  //     );
  //
  //     _riveFile = file;
  //     _controller = RiveWidgetController(_riveFile!);
  //
  //     _bindInputs();
  //
  //     setState(() {
  //       _isRiveInitialized = true;
  //     });
  //     _updateRiveState();
  //   } catch (e) {
  //     DeviceAvatar._logger.severe('Error initializing Rive: $e');
  //   }
  // }
  //
  // void _bindInputs() {
  //   if (_controller == null) return;
  //
  //   // -------------------------------------------------------------------------
  //   // DESIGNER SPECIFIED INPUTS
  //   // -------------------------------------------------------------------------
  //
  //   // Booleans for State
  //   // ignore: deprecated_member_use
  //   _isThinking = _controller?.stateMachine.boolean('IsThinking');
  //   // ignore: deprecated_member_use
  //   _isListening = _controller?.stateMachine.boolean('IsListening');
  //   // ignore: deprecated_member_use
  //   _isSpeaking = _controller?.stateMachine.boolean('IsSpeaking');
  //
  //   // Triggers for Transitions
  //   // ignore: deprecated_member_use
  //   _speakTrigger = _controller?.stateMachine.trigger('speak');
  //
  //   // ignore: deprecated_member_use
  //   _idleTrigger = _controller?.stateMachine.trigger('Idle');
  //
  //   // Audio Level for Lip Sync (0-100)
  //   // ignore: deprecated_member_use
  //   _audioLevel = _controller?.stateMachine.number('AudioLevel');
  // }

  @override
  void didUpdateWidget(DeviceAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Commented out LiveKit-specific updates
    // if (oldWidget.audioTrack != widget.audioTrack || oldWidget.participant != widget.participant) {
    //   unawaited(_handleUpdate());
    // }
  }

  // Future<void> _handleUpdate() async {
  //   await _detachListeners();
  //   await _attachListeners();
  // }

  @override
  void dispose() {
    unawaited(_detachListeners());
    // _controller?.dispose();
    // _riveFile?.dispose();
    super.dispose();
  }

  Future<void> _attachListeners() async {
    // TODO: Wire up non-LiveKit stream/audio level listeners here in Phase 2/3
  }

  Future<void> _detachListeners() async {
    // TODO: Clean up non-LiveKit stream/audio level listeners here in Phase 2/3
  }

  void _updateRiveState() {
    // if (!_isRiveInitialized) return;
    //
    // bool thinking = false;
    // bool listening = false;
    // bool speaking = false;
    //
    // switch (_agentState) {
    //   case 'thinking':
    //     thinking = true;
    //     break;
    //   case 'listening':
    //     listening = true;
    //     break;
    //   case 'speaking':
    //     speaking = true;
    //     break;
    //   default:
    //     listening = true;
    //     break;
    // }
    //
    // if (_isThinking != null) _isThinking!.value = thinking;
    // if (_isListening != null) _isListening!.value = listening;
    // if (_isSpeaking != null) _isSpeaking!.value = speaking;
    //
    // // Handle Triggers (Transition logic)
    // if (_speakTrigger != null && speaking && _lastDeviceState != 'speaking') {
    //   _speakTrigger!.fire();
    // }
    //
    // // Fire idle trigger if we were speaking and now we are not
    // if (!speaking && _lastDeviceState == 'speaking') {
    //   // Force audio level to 0 immediatey
    //   _currentAudioLevel = 0;
    //   _updateRiveInputs();
    //
    //   if (_idleTrigger != null) {
    //     _idleTrigger!.fire();
    //   } else {
    //     // FALLBACK: If no idle trigger is found, we assume the animation is stuck loops.
    //     // We will reset the controller to force it back to default state.
    //     _forceResetController();
    //   }
    // }
    //
    // _lastDeviceState = _agentState;
  }

  // void _forceResetController() {
  //   if (_riveFile == null) return;
  //
  //   // Dispose only the controller
  //   _controller?.dispose();
  //
  //   // Re-create controller from the same file
  //   _controller = RiveWidgetController(_riveFile!);
  //
  //   // Re-bind inputs on the new controller
  //   _bindInputs();
  //
  //   // Trigger rebuild
  //   setState(() {});
  // }
  //
  // void _updateRiveInputs() {
  //   if (!_isRiveInitialized) return;
  //   if (_audioLevel != null) {
  //     _audioLevel!.value = _currentAudioLevel;
  //   }
  // }

  @override
  Widget build(BuildContext context) {
    // Rive commented out fallback UI
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Center(
        child: Container(
          width: widget.size * 0.8,
          height: widget.size * 0.8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
            border: Border.all(
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
              width: 2,
            ),
          ),
          child: Icon(
            Icons.smart_toy_outlined,
            size: widget.size * 0.4,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
    );
  }
}
