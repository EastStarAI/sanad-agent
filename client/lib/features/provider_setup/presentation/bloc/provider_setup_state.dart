import 'package:equatable/equatable.dart';
import 'package:sanad_client/features/provider_setup/data/models/auth_session_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/model_options_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_instance_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_readiness_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_template_dto.dart';

/// High-level step in the provider setup flow.
enum ProviderSetupStatus {
  initial,
  loading,
  picker,
  apiKey,
  customEndpoint,
  deviceCode,
  loopback,
  modelSelection,
  saving,
  ready,
  error,
  instancesList,
  instanceForm,
}

/// Explicit model-discovery lifecycle. A failed live fetch is never presented
/// as a successful fallback list.
enum ModelDiscoveryStatus { idle, loading, loaded, failed, manual }

/// Mutations that keep the current setup surface visible while in flight.
enum ProviderSetupOperation { savingDetails, savingModel }

/// Sentinel used to distinguish "not provided" from "explicitly null" in
/// [copyWith] for nullable fields.
const _unset = Object();

/// State for [ProviderSetupCubit]. Designed to be reusable from onboarding,
/// Settings, and bounded provider-required overlays.
class ProviderSetupState extends Equatable {
  final ProviderSetupStatus status;
  final List<ProviderDto> providers;
  final List<ProviderTemplateDto> templates;
  final List<ProviderInstanceDto> instances;
  final String? activeProvider;
  final String? activeModel;
  final ProviderDto? selectedProvider;
  final ProviderTemplateDto? selectedTemplate;
  final ProviderInstanceDto? selectedInstance;
  final String? provisionalInstanceId;
  final ModelOptionsDto? modelOptions;
  final String? selectedModel;
  final ModelDiscoveryStatus modelDiscoveryStatus;
  final String? modelDiscoveryError;
  final AuthSessionDto? authSession;
  final AuthPollStatus? authPollStatus;
  final ProviderReadinessDto? readiness;
  final Map<String, dynamic>? testResult;
  final String? error;
  final String? loadingMessage;
  final bool polling;
  final ProviderSetupOperation? operation;
  final Map<String, String> instanceOperations;
  final Map<String, String> instanceFeedback;
  final bool verificationLaunchAttempted;
  final bool verificationPageOpened;
  final String? verificationLaunchError;
  final int snapshotGeneration;

  const ProviderSetupState({
    this.status = ProviderSetupStatus.initial,
    this.providers = const [],
    this.templates = const [],
    this.instances = const [],
    this.activeProvider,
    this.activeModel,
    this.selectedProvider,
    this.selectedTemplate,
    this.selectedInstance,
    this.provisionalInstanceId,
    this.modelOptions,
    this.selectedModel,
    this.modelDiscoveryStatus = ModelDiscoveryStatus.idle,
    this.modelDiscoveryError,
    this.authSession,
    this.authPollStatus,
    this.readiness,
    this.testResult,
    this.error,
    this.loadingMessage,
    this.polling = false,
    this.operation,
    this.instanceOperations = const {},
    this.instanceFeedback = const {},
    this.verificationLaunchAttempted = false,
    this.verificationPageOpened = false,
    this.verificationLaunchError,
    this.snapshotGeneration = 0,
  });

  bool get isLoading => status == ProviderSetupStatus.loading || status == ProviderSetupStatus.saving;

  bool get isReady => status == ProviderSetupStatus.ready;

  ProviderSetupState copyWith({
    ProviderSetupStatus? status,
    List<ProviderDto>? providers,
    List<ProviderTemplateDto>? templates,
    List<ProviderInstanceDto>? instances,
    Object? activeProvider = _unset,
    Object? activeModel = _unset,
    Object? selectedProvider = _unset,
    Object? selectedTemplate = _unset,
    Object? selectedInstance = _unset,
    Object? provisionalInstanceId = _unset,
    Object? modelOptions = _unset,
    Object? selectedModel = _unset,
    ModelDiscoveryStatus? modelDiscoveryStatus,
    Object? modelDiscoveryError = _unset,
    Object? authSession = _unset,
    Object? authPollStatus = _unset,
    Object? readiness = _unset,
    Object? testResult = _unset,
    Object? error = _unset,
    Object? loadingMessage = _unset,
    bool? polling,
    Object? operation = _unset,
    Map<String, String>? instanceOperations,
    Map<String, String>? instanceFeedback,
    bool? verificationLaunchAttempted,
    bool? verificationPageOpened,
    Object? verificationLaunchError = _unset,
    int? snapshotGeneration,
  }) {
    return ProviderSetupState(
      status: status ?? this.status,
      providers: providers ?? this.providers,
      templates: templates ?? this.templates,
      instances: instances ?? this.instances,
      activeProvider: activeProvider == _unset ? this.activeProvider : activeProvider as String?,
      activeModel: activeModel == _unset ? this.activeModel : activeModel as String?,
      selectedProvider: selectedProvider == _unset ? this.selectedProvider : selectedProvider as ProviderDto?,
      selectedTemplate: selectedTemplate == _unset ? this.selectedTemplate : selectedTemplate as ProviderTemplateDto?,
      selectedInstance: selectedInstance == _unset ? this.selectedInstance : selectedInstance as ProviderInstanceDto?,
      provisionalInstanceId: provisionalInstanceId == _unset
          ? this.provisionalInstanceId
          : provisionalInstanceId as String?,
      modelOptions: modelOptions == _unset ? this.modelOptions : modelOptions as ModelOptionsDto?,
      selectedModel: selectedModel == _unset ? this.selectedModel : selectedModel as String?,
      modelDiscoveryStatus: modelDiscoveryStatus ?? this.modelDiscoveryStatus,
      modelDiscoveryError: modelDiscoveryError == _unset ? this.modelDiscoveryError : modelDiscoveryError as String?,
      authSession: authSession == _unset ? this.authSession : authSession as AuthSessionDto?,
      authPollStatus: authPollStatus == _unset ? this.authPollStatus : authPollStatus as AuthPollStatus?,
      readiness: readiness == _unset ? this.readiness : readiness as ProviderReadinessDto?,
      testResult: testResult == _unset ? this.testResult : testResult as Map<String, dynamic>?,
      error: error == _unset ? this.error : error as String?,
      loadingMessage: loadingMessage == _unset ? this.loadingMessage : loadingMessage as String?,
      polling: polling ?? this.polling,
      operation: operation == _unset ? this.operation : operation as ProviderSetupOperation?,
      instanceOperations: instanceOperations ?? this.instanceOperations,
      instanceFeedback: instanceFeedback ?? this.instanceFeedback,
      verificationLaunchAttempted: verificationLaunchAttempted ?? this.verificationLaunchAttempted,
      verificationPageOpened: verificationPageOpened ?? this.verificationPageOpened,
      verificationLaunchError: verificationLaunchError == _unset
          ? this.verificationLaunchError
          : verificationLaunchError as String?,
      snapshotGeneration: snapshotGeneration ?? this.snapshotGeneration,
    );
  }

  @override
  List<Object?> get props => [
    status,
    providers,
    templates,
    instances,
    activeProvider,
    activeModel,
    selectedProvider,
    selectedTemplate,
    selectedInstance,
    provisionalInstanceId,
    modelOptions,
    selectedModel,
    modelDiscoveryStatus,
    modelDiscoveryError,
    authSession,
    authPollStatus,
    readiness,
    testResult,
    error,
    loadingMessage,
    polling,
    operation,
    instanceOperations,
    instanceFeedback,
    verificationLaunchAttempted,
    verificationPageOpened,
    verificationLaunchError,
    snapshotGeneration,
  ];
}
