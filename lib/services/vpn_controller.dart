import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/config_source.dart';
import '../models/split_tunnel.dart';
import '../models/vpn_profile.dart';
import 'android_incoming_link_bridge.dart';
import 'app_state_store.dart';
import 'core_runtime_service.dart';
import 'profile_catalog_service.dart';
import 'share_link_parser.dart';
import 'windows_app_catalog_service.dart';

enum AddSourceSuccessTarget { add, paste, qr, json }

class VpnController extends ChangeNotifier {
  static const Duration _transientErrorDuration = Duration(seconds: 3);

  VpnController({
    ShareLinkParser? parser,
    ProfileCatalogService? profileCatalogService,
    CoreRuntimeService? runtimeService,
    AppStateStore? appStateStore,
    WindowsAppCatalogService? appCatalogService,
  }) : _profileCatalogService =
           profileCatalogService ?? ProfileCatalogService(parser: parser),
       _runtimeService = runtimeService ?? CoreRuntimeService(),
       _appStateStore = appStateStore ?? AppStateStore(),
       _appCatalogService = appCatalogService ?? WindowsAppCatalogService() {
    _language = detectAppLanguage(Platform.localeName);
    _runtimeService.onProcessExit = _handleUnexpectedExit;
    _runtimeService.onLogUpdated = _handleRuntimeLogUpdated;
    _autoUpdateTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(refreshDueSubscriptions()),
    );
    _hydration = _restoreState();
    unawaited(_syncAndroidRuntimeAfterRestore());
    _listenForAndroidIncomingLinks();
  }

  final ProfileCatalogService _profileCatalogService;
  final CoreRuntimeService _runtimeService;
  final AppStateStore _appStateStore;
  final WindowsAppCatalogService _appCatalogService;
  final AndroidIncomingLinkBridge? _incomingLinkBridge = Platform.isAndroid
      ? AndroidIncomingLinkBridge()
      : null;

  final List<ConfigSource> _sources = <ConfigSource>[];
  final Map<String, DateTime> _lastAutoUpdateAttemptAt = <String, DateTime>{};

  late final Future<void> _hydration;
  late AppLanguage _language;
  TrafficMode _trafficMode = Platform.isAndroid
      ? TrafficMode.tun
      : TrafficMode.systemProxy;
  TunIpMode _tunIpMode = TunIpMode.ipv4;
  SplitTunnelSettings _splitTunnelSettings = const SplitTunnelSettings();
  ConnectionPhase _phase = ConnectionPhase.disconnected;
  String _rawInput = '';
  String? _selectedSourceId;
  String? _activeSourceId;
  ParsedVpnProfile? _activeProfile;
  DateTime? _connectedAt;
  String? _inputError;
  String? _runtimeError;
  Timer? _inputErrorTimer;
  Timer? _runtimeErrorTimer;
  int _inputErrorToken = 0;
  int _runtimeErrorToken = 0;
  bool _isAddingSource = false;
  AddSourceSuccessTarget? _addingSourceTarget;
  bool _didAddSourceRecently = false;
  AddSourceSuccessTarget? _recentAddSuccessTarget;
  Timer? _autoUpdateTimer;
  Timer? _recentAddSuccessTimer;
  StreamSubscription<String>? _incomingLinkSubscription;
  Future<void> _incomingLinkImportQueue = Future<void>.value();

  AppLanguage get language => _language;
  TrafficMode get trafficMode => _trafficMode;
  TunIpMode get tunIpMode => _tunIpMode;
  SplitTunnelSettings get splitTunnelSettings =>
      _splitTunnelSettings.normalized;
  SplitTunnelMode get splitTunnelMode => _splitTunnelSettings.mode;
  List<SplitTunnelApp> get splitTunnelApps =>
      List<SplitTunnelApp>.unmodifiable(_splitTunnelSettings.normalized.apps);
  ConnectionPhase get phase => _phase;
  String get rawInput => _rawInput;
  List<ConfigSource> get sources => List<ConfigSource>.unmodifiable(_sources);
  DateTime? get connectedAt => _connectedAt;
  ConfigSource? get selectedSource => _resolveSelectedSource();
  ParsedVpnProfile? get previewProfile => selectedSource?.selectedProfile;
  bool get isAddingSource => _isAddingSource;
  AddSourceSuccessTarget? get addingSourceTarget => _addingSourceTarget;
  bool get didAddSourceRecently => _didAddSourceRecently;
  AddSourceSuccessTarget? get recentAddSuccessTarget => _recentAddSuccessTarget;
  String? get previewError => _inputError;
  String? get runtimeError => _runtimeError;
  List<String> get runtimeLogs => _runtimeService.recentLogs;
  String get runtimeLogsText => runtimeLogs.join('\n');
  bool get isBusy =>
      _phase == ConnectionPhase.connecting ||
      _phase == ConnectionPhase.disconnecting;
  bool get isConnected => _phase == ConnectionPhase.connected;
  bool get hasSources => _sources.isNotEmpty;
  bool get hasMultipleProfiles => (selectedSource?.hasMultipleProfiles).isTrue;
  bool get canBrowseSources => !isBusy && !_isAddingSource;
  bool get canAddSource => !isBusy && !_isAddingSource;
  bool get canEditSources => !isBusy && !isConnected && !_isAddingSource;
  bool get canRemoveSources => !isBusy && !_isAddingSource;
  bool get supportsTrafficModeSelection => !Platform.isAndroid;
  bool get canChangeTrafficMode =>
      supportsTrafficModeSelection && !isBusy && !isConnected;
  bool get supportsTunIpModeSelection => true;
  bool get canChangeTunIpMode =>
      supportsTunIpModeSelection && !isBusy && !isConnected;
  bool get supportsSplitTunneling => Platform.isWindows || Platform.isAndroid;
  bool get canChangeSplitTunnel =>
      supportsSplitTunneling && !isBusy && !isConnected;

  CoreFlavor coreForProfile(ParsedVpnProfile? profile) {
    return _resolveCore(profile);
  }

  CoreFlavor? configCoreForProfile(ParsedVpnProfile? profile) {
    return profile?.nativeConfigCore;
  }

  CoreFlavor? displayCoreForProfile(ParsedVpnProfile? profile) {
    if (profile == null) {
      return null;
    }
    return profile.nativeConfigCore ?? _resolveCore(profile);
  }

  void setLanguage(AppLanguage language) {
    if (_language == language) {
      return;
    }
    _language = language;
    _queuePersistState();
    notifyListeners();
  }

  Future<void> setTrafficMode(
    TrafficMode mode, {
    bool ensureWindowsTunPrivileges = false,
  }) async {
    if (Platform.isAndroid) {
      return;
    }
    if (_trafficMode == mode || !canChangeTrafficMode) {
      return;
    }
    final previousTrafficMode = _trafficMode;
    final previousSplitTunnelSettings = _splitTunnelSettings;
    _trafficMode = mode;
    if (mode != TrafficMode.tun &&
        _splitTunnelSettings.mode != SplitTunnelMode.off) {
      _splitTunnelSettings = SplitTunnelSettings(
        apps: _splitTunnelSettings.apps,
      );
    }
    _setRuntimeError(null);
    notifyListeners();

    if (ensureWindowsTunPrivileges && mode == TrafficMode.tun) {
      await _persistStateAfterHydration();
      await _ensureWindowsTunPrivilegesOrRollback(
        previousTrafficMode: previousTrafficMode,
        previousSplitTunnelSettings: previousSplitTunnelSettings,
      );
      return;
    }

    _queuePersistState();
  }

  void setTunIpMode(TunIpMode mode) {
    if (!supportsTunIpModeSelection) {
      return;
    }
    if (_tunIpMode == mode || !canChangeTunIpMode) {
      return;
    }
    _tunIpMode = mode;
    _setRuntimeError(null);
    _queuePersistState();
    notifyListeners();
  }

  void setRawInput(String value) {
    _rawInput = value;
    _setInputError(null);
    _setRuntimeError(null);
    notifyListeners();
  }

  Future<bool> pasteSourceInput(
    String value, {
    AddSourceSuccessTarget successTarget = AddSourceSuccessTarget.paste,
  }) async {
    _rawInput = value;
    _setInputError(null);
    _setRuntimeError(null);
    notifyListeners();

    if (!_looksLikeAutoAddCandidate(value)) {
      return false;
    }

    return addSource(reportErrors: false, successTarget: successTarget);
  }

  bool isSourceActive(String sourceId) {
    if (!isConnected && !isBusy) {
      return false;
    }
    final activeSourceId = _activeSourceId ?? selectedSource?.id;
    return activeSourceId == sourceId;
  }

  bool canRemoveSource(String sourceId) {
    return canRemoveSources && !isSourceActive(sourceId);
  }

  Future<List<SplitTunnelApp>> loadSplitTunnelAppCatalog({
    bool refresh = false,
  }) {
    return _appCatalogService.loadApplications(refresh: refresh);
  }

  Future<void> setSplitTunnelMode(
    SplitTunnelMode mode, {
    bool ensureWindowsTunPrivileges = false,
  }) async {
    if (!canChangeSplitTunnel) {
      return;
    }
    if (_splitTunnelSettings.mode == mode) {
      return;
    }

    final previousTrafficMode = _trafficMode;
    final previousSplitTunnelSettings = _splitTunnelSettings;
    _splitTunnelSettings = SplitTunnelSettings(
      mode: mode,
      apps: _splitTunnelSettings.apps,
    ).normalized;
    if (mode != SplitTunnelMode.off) {
      _trafficMode = TrafficMode.tun;
    }
    _setRuntimeError(null);
    notifyListeners();

    if (ensureWindowsTunPrivileges && _trafficMode == TrafficMode.tun) {
      await _persistStateAfterHydration();
      await _ensureWindowsTunPrivilegesOrRollback(
        previousTrafficMode: previousTrafficMode,
        previousSplitTunnelSettings: previousSplitTunnelSettings,
      );
      return;
    }

    _queuePersistState();
  }

  void toggleSplitTunnelApp(SplitTunnelApp app) {
    if (!canChangeSplitTunnel) {
      return;
    }

    final normalizedApp = app.normalized;
    if (normalizedApp.path.isEmpty) {
      return;
    }

    final apps = <SplitTunnelApp>[..._splitTunnelSettings.normalized.apps];
    final index = apps.indexWhere((item) => item.id == normalizedApp.id);
    if (index >= 0) {
      apps.removeAt(index);
    } else {
      apps.add(normalizedApp);
    }

    _splitTunnelSettings = SplitTunnelSettings(
      mode: _splitTunnelSettings.mode,
      apps: apps,
    ).normalized;
    _setRuntimeError(null);
    _queuePersistState();
    notifyListeners();
  }

  Future<bool> addSource({
    bool reportErrors = true,
    AddSourceSuccessTarget successTarget = AddSourceSuccessTarget.add,
  }) async {
    await _hydration;

    if (!canAddSource) {
      return false;
    }

    final rawInput = _rawInput.trim();
    if (rawInput.isEmpty) {
      if (reportErrors) {
        _setInputError('Paste a config link or subscription URL first.');
      }
      notifyListeners();
      return false;
    }

    _recentAddSuccessTimer?.cancel();
    _didAddSourceRecently = false;
    _recentAddSuccessTarget = null;
    _addingSourceTarget = successTarget;
    _isAddingSource = true;
    _setInputError(null);
    _setRuntimeError(null);
    notifyListeners();

    try {
      final catalog = await _profileCatalogService.resolve(rawInput);
      final importedRawInput = catalog.sourceRawInput?.trim();
      final sourceRawInput =
          importedRawInput == null || importedRawInput.isEmpty
          ? rawInput
          : importedRawInput;
      final kind = catalog.isSubscription
          ? ConfigSourceKind.subscription
          : ConfigSourceKind.config;
      final existing = _findSourceByInput(sourceRawInput);
      final selectedKey = existing?.selectedProfile == null
          ? null
          : _profileKey(existing!.selectedProfile!);
      final selectedProfileIndex = _findProfileIndex(
        catalog.profiles,
        selectedKey,
      );

      final nextSource =
          (existing ??
                  ConfigSource(
                    id: DateTime.now().microsecondsSinceEpoch.toString(),
                    rawInput: sourceRawInput,
                    kind: kind,
                  ))
              .copyWith(
                rawInput: sourceRawInput,
                kind: kind,
                displayName: kind == ConfigSourceKind.subscription
                    ? catalog.sourceName ?? existing?.displayName
                    : null,
                clearDisplayName: kind == ConfigSourceKind.config,
                profiles: catalog.profiles,
                selectedProfileIndex: selectedProfileIndex,
                isUpdating: false,
                lastUpdatedAt: kind == ConfigSourceKind.subscription
                    ? DateTime.now()
                    : existing?.lastUpdatedAt,
                clearLastUpdatedAt: kind == ConfigSourceKind.config,
                clearLastUpdateError: true,
                autoUpdateIntervalMinutes: kind == ConfigSourceKind.subscription
                    ? existing?.normalizedAutoUpdateIntervalMinutes ??
                          defaultSubscriptionAutoUpdateMinutes
                    : defaultSubscriptionAutoUpdateMinutes,
                trafficUsage: catalog.trafficUsage,
                clearTrafficUsage:
                    kind == ConfigSourceKind.config ||
                    catalog.trafficUsage == null,
              );

      final shouldSelectAddedSource = !isConnected;
      _upsertSource(nextSource);
      if (shouldSelectAddedSource) {
        _selectedSourceId = nextSource.id;
      }
      _rawInput = '';
      _setInputError(null);
      await _persistStateAfterHydration();
      _didAddSourceRecently = true;
      _recentAddSuccessTarget = successTarget;
      _recentAddSuccessTimer = Timer(const Duration(seconds: 1), () {
        _didAddSourceRecently = false;
        _recentAddSuccessTarget = null;
        notifyListeners();
      });
      return true;
    } on FormatException catch (error) {
      _setInputError(reportErrors ? error.message : null);
      return false;
    } catch (error) {
      _setInputError(reportErrors ? _renderError(error) : null);
      return false;
    } finally {
      _isAddingSource = false;
      _addingSourceTarget = null;
      notifyListeners();
    }
  }

  void selectSource(String sourceId) {
    if (!canEditSources) {
      return;
    }
    if (_selectedSourceId == sourceId) {
      return;
    }
    _selectedSourceId = sourceId;
    _setRuntimeError(null);
    _queuePersistState();
    notifyListeners();
  }

  Future<void> removeSource(String sourceId) async {
    await _hydration;

    if (!canRemoveSource(sourceId)) {
      return;
    }

    final index = _sources.indexWhere((item) => item.id == sourceId);
    if (index < 0) {
      return;
    }

    _sources.removeAt(index);
    _lastAutoUpdateAttemptAt.remove(sourceId);
    if (_selectedSourceId == sourceId) {
      _selectedSourceId = _sources.isEmpty ? null : _sources.first.id;
    }
    _setInputError(null);
    _setRuntimeError(null);
    await _persistStateAfterHydration();
    notifyListeners();
  }

  void setSelectedProfileIndex(int index) {
    final source = selectedSource;
    if (source == null || isConnected || isBusy) {
      return;
    }
    if (index < 0 || index >= source.profiles.length) {
      return;
    }
    if (index == source.selectedProfileIndex) {
      return;
    }

    _replaceSource(source.copyWith(selectedProfileIndex: index));
    _queuePersistState();
    notifyListeners();
  }

  Future<void> refreshSource(String sourceId) async {
    await _hydration;

    await _refreshSource(sourceId);
  }

  Future<void> refreshDueSubscriptions() async {
    await _hydration;

    final now = DateTime.now();
    final dueSources = _sources
        .where((source) => _isSubscriptionDueForAutoUpdate(source, now))
        .toList(growable: false);
    for (final source in dueSources) {
      _lastAutoUpdateAttemptAt[source.id] = now;
      await _refreshSource(source.id, automatic: true);
    }
  }

  void setSourceAutoUpdateInterval(String sourceId, Duration interval) {
    final source = _sourceById(sourceId);
    if (source == null || !source.isSubscription) {
      return;
    }

    final minutes = normalizeSubscriptionAutoUpdateMinutes(interval.inMinutes);
    if (source.normalizedAutoUpdateIntervalMinutes == minutes) {
      return;
    }

    _replaceSource(source.copyWith(autoUpdateIntervalMinutes: minutes));
    _queuePersistState();
    notifyListeners();
  }

  Future<void> toggleConnection() async {
    if (isConnected) {
      await disconnect();
      return;
    }
    await connect();
  }

  Future<void> connect() async {
    await _hydration;

    if (isBusy || isConnected) {
      return;
    }

    if (Platform.isAndroid) {
      try {
        await _syncAndroidRuntimeState(notify: false);
      } catch (_) {}
      if (isConnected) {
        notifyListeners();
        return;
      }
    }

    final source = selectedSource;
    final profile = source?.selectedProfile;
    if (source == null || profile == null) {
      _phase = ConnectionPhase.error;
      _setRuntimeError('Add a config or subscription first.');
      notifyListeners();
      return;
    }
    if (Platform.isAndroid &&
        _splitTunnelSettings.mode == SplitTunnelMode.whitelist &&
        !_splitTunnelSettings.hasSelectedApps) {
      _phase = ConnectionPhase.error;
      _setRuntimeError('Select at least one app for Android tunnel whitelist.');
      notifyListeners();
      return;
    }

    _phase = ConnectionPhase.connecting;
    _activeSourceId = source.id;
    _connectedAt = null;
    _setRuntimeError(null);
    notifyListeners();

    try {
      await _runtimeService.start(
        core: _resolveCore(profile),
        profile: profile,
        language: _language,
        trafficMode: _trafficMode,
        tunIpMode: _tunIpMode,
        splitTunnelSettings: splitTunnelSettings,
      );
      _activeProfile = profile;
      _activeSourceId = source.id;
      _connectedAt = DateTime.now();
      _phase = ConnectionPhase.connected;
    } catch (error) {
      _activeProfile = null;
      _activeSourceId = null;
      _connectedAt = null;
      _phase = ConnectionPhase.error;
      _setRuntimeError(_renderError(error));
    }

    notifyListeners();
  }

  Future<void> disconnect() async {
    if (isBusy || !isConnected && _phase != ConnectionPhase.error) {
      if (_phase == ConnectionPhase.disconnected) {
        return;
      }
    }

    _phase = ConnectionPhase.disconnecting;
    notifyListeners();

    try {
      await _runtimeService.stop();
    } finally {
      _activeProfile = null;
      _activeSourceId = null;
      _connectedAt = null;
      _phase = ConnectionPhase.disconnected;
      _setRuntimeError(null);
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _autoUpdateTimer?.cancel();
    _recentAddSuccessTimer?.cancel();
    _inputErrorTimer?.cancel();
    _runtimeErrorTimer?.cancel();
    unawaited(_incomingLinkSubscription?.cancel());
    _runtimeService.onLogUpdated = null;
    _runtimeService.onProcessExit = null;
    _runtimeService.dispose();
    super.dispose();
  }

  void _listenForAndroidIncomingLinks() {
    final bridge = _incomingLinkBridge;
    if (bridge == null) {
      return;
    }

    _incomingLinkSubscription = bridge.links.listen(_queueIncomingLink);
    unawaited(
      bridge.getInitialLink().then((link) {
        if (link != null) {
          _queueIncomingLink(link);
        }
      }),
    );
  }

  void _queueIncomingLink(String rawInput) {
    _incomingLinkImportQueue = _incomingLinkImportQueue
        .catchError((Object _) {})
        .then((_) => _importIncomingLink(rawInput));
  }

  Future<void> _importIncomingLink(String rawInput) async {
    final normalizedInput = rawInput.trim();
    if (normalizedInput.isEmpty) {
      return;
    }

    _rawInput = normalizedInput;
    _setInputError(null);
    _setRuntimeError(null);
    notifyListeners();
    await addSource();
  }

  bool _looksLikeAutoAddCandidate(String rawInput) {
    final primaryLine = _primaryInputLine(rawInput);
    if (primaryLine.isEmpty) {
      return false;
    }

    final uri = Uri.tryParse(primaryLine);
    final scheme = uri?.scheme.toLowerCase() ?? '';
    if ((scheme == 'http' || scheme == 'https') && uri!.host.isNotEmpty) {
      return true;
    }
    if (scheme == 'sing-box') {
      return true;
    }

    try {
      _profileCatalogService.resolveInline(rawInput);
      return true;
    } catch (_) {
      return false;
    }
  }

  String _primaryInputLine(String rawInput) {
    return rawInput
        .replaceAll('\uFEFF', '')
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.trim())
        .firstWhere((line) => line.isNotEmpty, orElse: () => '');
  }

  Future<void> _syncAndroidRuntimeAfterRestore() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _hydration;
      await _saveAndroidStartPayload();
      await _syncAndroidRuntimeState();
    } catch (_) {}
  }

  Future<void> _syncAndroidRuntimeState({bool notify = true}) async {
    if (!Platform.isAndroid) {
      return;
    }

    await _runtimeService.synchronizeState();
    if (!_runtimeService.isRunning) {
      return;
    }

    _activeProfile ??= previewProfile;
    _activeSourceId ??= selectedSource?.id;
    _connectedAt =
        _runtimeService.connectedAt ?? _connectedAt ?? DateTime.now();
    _phase = ConnectionPhase.connected;
    _setRuntimeError(null);
    if (notify) {
      notifyListeners();
    }
  }

  Future<void> _refreshSource(String sourceId, {bool automatic = false}) async {
    final source = _sourceById(sourceId);
    if (source == null || !source.isSubscription || source.isUpdating) {
      return;
    }

    _replaceSource(
      source.copyWith(isUpdating: true, clearLastUpdateError: true),
    );
    notifyListeners();

    try {
      final catalog = await _profileCatalogService.resolve(source.rawInput);
      final selectedKey = source.selectedProfile == null
          ? null
          : _profileKey(source.selectedProfile!);
      final nextIndex = _findProfileIndex(catalog.profiles, selectedKey);

      _replaceSource(
        source.copyWith(
          kind: ConfigSourceKind.subscription,
          displayName: catalog.sourceName ?? source.displayName,
          profiles: catalog.profiles,
          selectedProfileIndex: nextIndex,
          isUpdating: false,
          lastUpdatedAt: DateTime.now(),
          clearLastUpdateError: true,
          trafficUsage: catalog.trafficUsage,
          clearTrafficUsage: catalog.trafficUsage == null,
        ),
      );
    } catch (error) {
      final message = _renderError(error);
      _replaceSource(
        source.copyWith(isUpdating: false, lastUpdateError: message),
      );
      if (!automatic && selectedSource?.id == sourceId) {
        _setRuntimeError(message);
      }
    }

    _queuePersistState();
    notifyListeners();
  }

  bool _isSubscriptionDueForAutoUpdate(ConfigSource source, DateTime now) {
    if (!source.isSubscription || source.isUpdating) {
      return false;
    }

    final lastRefreshReference = _latestDateTime(
      source.lastUpdatedAt,
      _lastAutoUpdateAttemptAt[source.id],
    );
    if (lastRefreshReference == null) {
      return true;
    }

    final elapsed = now.difference(lastRefreshReference);
    return !elapsed.isNegative && elapsed >= source.autoUpdateInterval;
  }

  DateTime? _latestDateTime(DateTime? first, DateTime? second) {
    if (first == null) {
      return second;
    }
    if (second == null) {
      return first;
    }
    return first.isAfter(second) ? first : second;
  }

  ConfigSource? _resolveSelectedSource() {
    if (_sources.isEmpty) {
      return null;
    }

    if (_selectedSourceId == null) {
      return _sources.first;
    }

    for (final source in _sources) {
      if (source.id == _selectedSourceId) {
        return source;
      }
    }

    return _sources.first;
  }

  ConfigSource? _findSourceByInput(String rawInput) {
    for (final source in _sources) {
      if (source.rawInput.trim() == rawInput.trim()) {
        return source;
      }
    }
    return null;
  }

  ConfigSource? _sourceById(String sourceId) {
    for (final source in _sources) {
      if (source.id == sourceId) {
        return source;
      }
    }
    return null;
  }

  void _upsertSource(ConfigSource source) {
    final index = _sources.indexWhere((item) => item.id == source.id);
    if (index < 0) {
      _sources.add(source);
      return;
    }
    _sources[index] = source;
  }

  void _replaceSource(ConfigSource source) {
    final index = _sources.indexWhere((item) => item.id == source.id);
    if (index < 0) {
      return;
    }
    _sources[index] = source;
  }

  int _findProfileIndex(List<ParsedVpnProfile> profiles, String? key) {
    if (profiles.isEmpty || key == null) {
      return 0;
    }
    for (var i = 0; i < profiles.length; i += 1) {
      if (_profileKey(profiles[i]) == key) {
        return i;
      }
    }
    return 0;
  }

  String _profileKey(ParsedVpnProfile profile) {
    return <Object?>[
      profile.isSingBoxConfig,
      profile.singBoxConfigJson,
      profile.isXrayConfig,
      profile.xrayConfigJson,
      profile.protocol.name,
      profile.server,
      profile.port,
      profile.remark,
      profile.userId,
      profile.password,
      profile.method,
      profile.path,
      profile.serviceName,
    ].join('|');
  }

  CoreFlavor _resolveCore(ParsedVpnProfile? profile) {
    if (profile?.isSingBoxConfig == true) {
      return CoreFlavor.singBox;
    }
    if (profile?.isXrayConfig == true) {
      return CoreFlavor.xray;
    }

    if (profile == null) {
      return CoreFlavor.xray;
    }

    final hasPlugin = (profile.plugin?.trim().isNotEmpty).isTrue;
    if (hasPlugin) {
      return CoreFlavor.singBox;
    }

    if (profile.tlsMode == TlsMode.reality) {
      switch (profile.transport) {
        case TransportMode.raw:
        case TransportMode.grpc:
          return CoreFlavor.xray;
        case TransportMode.ws:
        case TransportMode.http:
        case TransportMode.httpUpgrade:
        case TransportMode.quic:
          return CoreFlavor.singBox;
      }
    }

    switch (profile.transport) {
      case TransportMode.http:
      case TransportMode.quic:
        return CoreFlavor.singBox;
      case TransportMode.raw:
      case TransportMode.ws:
      case TransportMode.grpc:
      case TransportMode.httpUpgrade:
        return CoreFlavor.xray;
    }
  }

  void _handleUnexpectedExit(String? error) {
    if (_phase != ConnectionPhase.connected &&
        _phase != ConnectionPhase.connecting) {
      return;
    }
    _activeProfile = null;
    _activeSourceId = null;
    _connectedAt = null;
    _phase = ConnectionPhase.error;
    _setRuntimeError(
      error == null || error.isEmpty
          ? 'The core process stopped unexpectedly.'
          : 'The core process stopped unexpectedly.\n$error',
    );
    notifyListeners();
  }

  void _handleRuntimeLogUpdated() {
    if (Platform.isAndroid) {
      _applyAndroidRuntimeSnapshot();
    }
    notifyListeners();
  }

  void _applyAndroidRuntimeSnapshot() {
    switch (_runtimeService.androidPhase) {
      case 'connecting':
        _connectedAt = null;
        _phase = ConnectionPhase.connecting;
        _setRuntimeError(null);
        return;
      case 'connected':
        _activeProfile ??= previewProfile;
        _activeSourceId ??= selectedSource?.id;
        _connectedAt =
            _runtimeService.connectedAt ?? _connectedAt ?? DateTime.now();
        _phase = ConnectionPhase.connected;
        _setRuntimeError(null);
        return;
      case 'disconnecting':
        if (_phase != ConnectionPhase.disconnected) {
          _phase = ConnectionPhase.disconnecting;
        }
        return;
      case 'disconnected':
        if (_phase == ConnectionPhase.connected ||
            _phase == ConnectionPhase.disconnecting ||
            _phase == ConnectionPhase.error) {
          _activeProfile = null;
          _activeSourceId = null;
          _connectedAt = null;
          _phase = ConnectionPhase.disconnected;
          _setRuntimeError(null);
        }
        return;
      default:
        return;
    }
  }

  Future<void> _restoreState() async {
    try {
      final state = await _appStateStore.load();
      if (state == null) {
        return;
      }

      _language = state.language;
      _trafficMode = Platform.isAndroid ? TrafficMode.tun : state.trafficMode;
      _tunIpMode = state.tunIpMode;
      _splitTunnelSettings = Platform.isWindows || Platform.isAndroid
          ? state.splitTunnelSettings.normalized
          : const SplitTunnelSettings();
      if (_splitTunnelSettings.mode != SplitTunnelMode.off) {
        _trafficMode = TrafficMode.tun;
      }
      _sources
        ..clear()
        ..addAll(state.sources);

      final hasSelectedSource =
          state.selectedSourceId != null &&
          state.sources.any((source) => source.id == state.selectedSourceId);
      _selectedSourceId = hasSelectedSource
          ? state.selectedSourceId
          : (state.sources.isEmpty ? null : state.sources.first.id);

      notifyListeners();
    } catch (_) {}
  }

  void _queuePersistState() {
    unawaited(_persistStateAfterHydration());
  }

  Future<void> _persistStateAfterHydration() async {
    await _hydration;
    await _appStateStore.save(
      PersistedAppState(
        language: _language,
        trafficMode: _trafficMode,
        tunIpMode: _tunIpMode,
        sources: List<ConfigSource>.unmodifiable(_sources),
        selectedSourceId: _selectedSourceId,
        splitTunnelSettings: _splitTunnelSettings.normalized,
      ),
    );
    await _saveAndroidStartPayload();
  }

  Future<void> _saveAndroidStartPayload() async {
    if (!Platform.isAndroid) {
      return;
    }
    final profile = previewProfile;
    if (profile == null) {
      return;
    }
    if (_splitTunnelSettings.mode == SplitTunnelMode.whitelist &&
        !_splitTunnelSettings.hasSelectedApps) {
      return;
    }

    await _runtimeService.saveAndroidStartPayload(
      core: _resolveCore(profile),
      profile: profile,
      language: _language,
      tunIpMode: _tunIpMode,
      splitTunnelSettings: _splitTunnelSettings,
    );
  }

  Future<void> _ensureWindowsTunPrivilegesOrRollback({
    required TrafficMode previousTrafficMode,
    required SplitTunnelSettings previousSplitTunnelSettings,
  }) async {
    if (!Platform.isWindows || _trafficMode != TrafficMode.tun) {
      return;
    }

    final ready = await _runtimeService.ensureWindowsTunPrivileges();
    if (ready) {
      return;
    }

    _trafficMode = previousTrafficMode;
    _splitTunnelSettings = previousSplitTunnelSettings;
    _setRuntimeError(
      'Administrator privileges are required for Windows TUN mode.',
    );
    await _persistStateAfterHydration();
    notifyListeners();
  }

  void _setInputError(String? message) {
    _inputErrorToken += 1;
    _inputErrorTimer?.cancel();
    _inputErrorTimer = null;
    _inputError = message;
    if (message == null) {
      return;
    }

    final token = _inputErrorToken;
    _inputErrorTimer = Timer(_transientErrorDuration, () {
      if (_inputErrorToken != token || _inputError != message) {
        return;
      }
      _inputError = null;
      _inputErrorTimer = null;
      notifyListeners();
    });
  }

  void _setRuntimeError(String? message) {
    _runtimeErrorToken += 1;
    _runtimeErrorTimer?.cancel();
    _runtimeErrorTimer = null;
    _runtimeError = message;
    if (message == null) {
      _resetRuntimeErrorPhase();
      return;
    }

    final token = _runtimeErrorToken;
    _runtimeErrorTimer = Timer(_transientErrorDuration, () {
      if (_runtimeErrorToken != token || _runtimeError != message) {
        return;
      }
      _runtimeError = null;
      _runtimeErrorTimer = null;
      _resetRuntimeErrorPhase();
      notifyListeners();
    });
  }

  void _resetRuntimeErrorPhase() {
    if (_phase != ConnectionPhase.error) {
      return;
    }
    _activeProfile = null;
    _activeSourceId = null;
    _connectedAt = null;
    _phase = ConnectionPhase.disconnected;
  }

  String _renderError(Object error) {
    if (error is FormatException) {
      return error.message;
    }
    final text = error.toString().trim();
    return text.startsWith('StateError: ') ? text.substring(12) : text;
  }
}

extension on bool? {
  bool get isTrue => this == true;
}
