import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, Platform;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:jovial_svg/jovial_svg.dart';

import '../main_helpers.dart';
import '../models/config_source.dart';
import '../models/vpn_profile.dart';
import 'geo_ip_service.dart';
import 'vpn_controller.dart';

class WindowsTrayMenuService {
  WindowsTrayMenuService(this._controller);

  static const MethodChannel _channel = MethodChannel(
    'entropy_vpn/windows_tray_menu',
  );

  static const String _flagAssetDirectory = 'assets/flags';
  static const int _flagPngWidth = 64;
  static const int _flagPngHeight = 48;
  static const double _flagPngCornerRadius = 8;

  final VpnController _controller;
  final GeoIpService _geoIpService = GeoIpService.shared;
  final Map<String, String?> _serverCountryCodes = <String, String?>{};
  final Set<String> _pendingServerLookups = <String>{};
  final Map<String, String?> _flagPaths = <String, String?>{};
  final Set<String> _pendingFlagRenders = <String>{};

  bool _started = false;
  String? _lastPayload;

  void start() {
    if (!Platform.isWindows || _started) {
      return;
    }

    _started = true;
    _channel.setMethodCallHandler(_handleMethodCall);
    _controller.addListener(_handleControllerUpdated);
    unawaited(_sync());
  }

  void dispose() {
    if (!_started) {
      return;
    }

    _controller.removeListener(_handleControllerUpdated);
    _channel.setMethodCallHandler(null);
    _started = false;
  }

  void _handleControllerUpdated() {
    unawaited(_sync());
  }

  Future<Object?> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'selectItem':
        final token = call.arguments;
        if (token is String) {
          _selectItem(token);
        }
        return null;
    }
    throw MissingPluginException();
  }

  Future<void> _sync() async {
    if (!_started) {
      return;
    }

    final items = _buildItems();
    final payload = jsonEncode(items);
    if (payload == _lastPayload) {
      return;
    }

    try {
      await _channel.invokeMethod<void>('setItems', items);
      _lastPayload = payload;
    } catch (_) {
      _lastPayload = null;
    }
  }

  List<Map<String, Object?>> _buildItems() {
    final sources = _controller.sources;
    final selectedSource = _controller.selectedSource;
    final selectedSourceId = selectedSource?.id;
    final canSwitch = _controller.canEditSources;
    final items = <Map<String, Object?>>[
      <String, Object?>{
        'token': 'action:toggleConnection',
        'label': _connectionActionLabel(),
        'selected': false,
        'enabled': _canUseConnectionAction(),
        'indent': 0,
      },
    ];

    if (sources.isNotEmpty) {
      items.add(<String, Object?>{'separator': true});
    }

    for (final source in sources) {
      final selected = source.id == selectedSourceId;
      final hasProfileSubmenu =
          source.isSubscription && source.hasMultipleProfiles;
      items.add(<String, Object?>{
        'token': 'source:${Uri.encodeComponent(source.id)}',
        'label': _sourceLabel(source),
        'flagPath': hasProfileSubmenu
            ? null
            : _flagPathForProfile(source.selectedProfile),
        'selected': selected && !hasProfileSubmenu,
        'enabled': canSwitch,
        'indent': 0,
        'children': hasProfileSubmenu
            ? _profileSubmenuItems(source, selected: selected)
            : null,
      });
    }

    return items;
  }

  String _connectionActionLabel() {
    return switch (_controller.phase) {
      ConnectionPhase.connected => 'Disconnect',
      ConnectionPhase.connecting => 'Connecting',
      ConnectionPhase.disconnecting => 'Disconnecting',
      ConnectionPhase.disconnected || ConnectionPhase.error => 'Connect',
    };
  }

  bool _canUseConnectionAction() {
    return switch (_controller.phase) {
      ConnectionPhase.connected => true,
      ConnectionPhase.disconnected ||
      ConnectionPhase.error => _controller.hasSources,
      ConnectionPhase.connecting || ConnectionPhase.disconnecting => false,
    };
  }

  List<Map<String, Object?>> _profileSubmenuItems(
    ConfigSource source, {
    required bool selected,
  }) {
    final items = <Map<String, Object?>>[];
    for (var index = 0; index < source.profiles.length; index += 1) {
      final profile = source.profiles[index];
      items.add(<String, Object?>{
        'token': 'profile:${Uri.encodeComponent(source.id)}:$index',
        'label': _profileLabel(profile, max: 40),
        'flagPath': _flagPathForProfile(profile),
        'selected': selected && index == source.selectedProfileIndex,
        'enabled': _controller.canEditSources,
        'indent': 0,
      });
    }

    return items;
  }

  String _sourceLabel(ConfigSource source) {
    final label = source.isSubscription
        ? sourceSubscriptionTitle(source)
        : sourceHeadline(source, source.selectedProfile);
    return _clipTrayLabel(label, max: 38);
  }

  String _profileLabel(ParsedVpnProfile profile, {required int max}) {
    return _clipTrayLabel(profileChoiceTitle(profile), max: max);
  }

  String? _flagPathForProfile(ParsedVpnProfile? profile) {
    return _flagPathForServer(profile?.server);
  }

  String? _flagPathForServer(String? server) {
    final normalizedServer = server?.trim().toLowerCase();
    if (normalizedServer == null || normalizedServer.isEmpty) {
      return null;
    }

    if (_serverCountryCodes.containsKey(normalizedServer)) {
      return _flagPathForCountryCode(_serverCountryCodes[normalizedServer]);
    }
    if (_pendingServerLookups.add(normalizedServer)) {
      unawaited(
        _geoIpService
            .resolveServer(normalizedServer)
            .then((info) {
              _serverCountryCodes[normalizedServer] = _normalizeCountryCode(
                info?.countryCode,
              );
            })
            .catchError((Object _) {
              _serverCountryCodes[normalizedServer] = null;
            })
            .whenComplete(() {
              _pendingServerLookups.remove(normalizedServer);
              _handleControllerUpdated();
            }),
      );
    }
    return null;
  }

  String? _flagPathForCountryCode(String? countryCode) {
    final normalizedCode = _normalizeCountryCode(countryCode);
    if (normalizedCode == null) {
      return null;
    }

    if (_flagPaths.containsKey(normalizedCode)) {
      return _flagPaths[normalizedCode];
    }
    if (_pendingFlagRenders.add(normalizedCode)) {
      unawaited(
        _renderFlagPng(normalizedCode)
            .then((path) {
              _flagPaths[normalizedCode] = path;
            })
            .catchError((Object _) {
              _flagPaths[normalizedCode] = null;
            })
            .whenComplete(() {
              _pendingFlagRenders.remove(normalizedCode);
              _handleControllerUpdated();
            }),
      );
    }
    return null;
  }

  String? _normalizeCountryCode(String? countryCode) {
    final normalizedCode = countryCode?.trim().toUpperCase();
    if (normalizedCode == null ||
        !RegExp(r'^[A-Z]{2}$').hasMatch(normalizedCode)) {
      return null;
    }
    return normalizedCode;
  }

  Future<String> _renderFlagPng(String countryCode) async {
    final lowerCode = countryCode.toLowerCase();
    final directory = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}entropyvpn-tray-flags',
    );
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }

    final output = File(
      '${directory.path}${Platform.pathSeparator}$lowerCode.png',
    );
    if (await output.exists() && await output.length() > 0) {
      return output.path;
    }

    final image = await ScalableImageSource.fromSvg(
      rootBundle,
      '$_flagAssetDirectory/$lowerCode.svg',
      warnF: (_) {},
    ).createSI();

    await image.prepareImages();
    try {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final size = ui.Size(_flagPngWidth.toDouble(), _flagPngHeight.toDouble());
      final bounds = ui.Offset.zero & size;
      canvas.clipRRect(
        ui.RRect.fromRectAndRadius(
          bounds,
          const ui.Radius.circular(_flagPngCornerRadius),
        ),
      );
      ScalingTransform(
        containerSize: size,
        siViewport: image.viewport,
        fit: BoxFit.fill,
        alignment: Alignment.center,
      ).applyToCanvas(canvas);
      image.paint(canvas);

      final picture = recorder.endRecording();
      try {
        final raster = await picture.toImage(_flagPngWidth, _flagPngHeight);
        try {
          final bytes = await raster.toByteData(format: ui.ImageByteFormat.png);
          if (bytes == null) {
            throw StateError('Could not encode $countryCode tray flag.');
          }
          await output.writeAsBytes(
            bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
            flush: true,
          );
        } finally {
          raster.dispose();
        }
      } finally {
        picture.dispose();
      }
    } finally {
      image.unprepareImages();
    }

    return output.path;
  }

  String _clipTrayLabel(String label, {required int max}) {
    final normalized = label.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.length <= max) {
      return normalized;
    }
    return '${normalized.substring(0, max - 3).trimRight()}...';
  }

  void _selectItem(String token) {
    if (token == 'action:toggleConnection') {
      unawaited(_controller.toggleConnection());
      return;
    }

    if (token.startsWith('source:')) {
      final sourceId = Uri.decodeComponent(token.substring('source:'.length));
      _controller.selectSource(sourceId);
      return;
    }

    if (!token.startsWith('profile:')) {
      return;
    }

    final payload = token.substring('profile:'.length);
    final separator = payload.lastIndexOf(':');
    if (separator <= 0 || separator == payload.length - 1) {
      return;
    }

    final sourceId = Uri.decodeComponent(payload.substring(0, separator));
    final profileIndex = int.tryParse(payload.substring(separator + 1));
    if (profileIndex == null) {
      return;
    }

    _controller.selectSource(sourceId);
    _controller.setSelectedProfileIndex(profileIndex);
  }
}
