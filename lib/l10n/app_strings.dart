import 'package:flutter/widgets.dart';

import '../models/split_tunnel.dart';
import '../models/vpn_profile.dart';

class AppStrings {
  const AppStrings(this.language);

  final AppLanguage language;

  static const LocalizationsDelegate<AppStrings> delegate =
      _AppStringsDelegate();
  static const supportedLocales = <Locale>[Locale('ru'), Locale('en')];

  static AppStrings of(BuildContext context) {
    final strings = Localizations.of<AppStrings>(context, AppStrings);
    assert(strings != null, 'AppStrings not found in context');
    return strings!;
  }

  bool get _ru => language == AppLanguage.ru;

  String get trafficModeLabel => _ru ? 'Режим' : 'Mode';
  String get systemProxyModeLabel => _ru ? 'Системный proxy' : 'System proxy';
  String get tunModeLabel => 'TUN';
  String get tunIpModeLabel => _ru ? 'IP-режим TUN' : 'TUN IP mode';
  String get splitTunnelLabel => _ru ? 'Сплит-туннелинг' : 'Split tunneling';
  String get splitTunnelAppsLabel => _ru ? 'Приложения' : 'Applications';
  String get splitTunnelSearchHint =>
      _ru ? 'Поиск приложения' : 'Search applications';
  String get splitTunnelRefreshTooltip =>
      _ru ? 'Обновить список приложений' : 'Refresh application list';
  String get splitTunnelOffModeLabel =>
      _ru ? 'Без сплита' : 'No split tunneling';
  String get splitTunnelWhitelistModeLabel =>
      _ru ? 'Whitelist туннеля' : 'Tunnel whitelist';
  String get splitTunnelBlacklistModeLabel =>
      _ru ? 'Blacklist туннеля' : 'Tunnel blacklist';
  String splitTunnelSelectedCount(int count) =>
      _ru ? 'Выбрано: $count' : 'Selected: $count';
  String get splitTunnelNoAppsFound =>
      _ru ? 'Приложения не найдены.' : 'No applications found.';
  String get splitTunnelTunHint => _ru
      ? 'При включении сплита приложение использует TUN-режим.'
      : 'Enabling split tunneling switches the app to TUN mode.';
  String get logsLabel => _ru ? 'Логи' : 'Logs';
  String get copyLogsAction => _ru ? 'Копировать логи' : 'Copy logs';
  String get noLogsYet => _ru ? 'Логи пока не появились.' : 'No logs yet.';
  String get logsCopiedMessage => _ru ? 'Логи скопированы.' : 'Logs copied.';
  String get inputLabel =>
      _ru ? 'Добавить конфиг или подписку' : 'Add a config or subscription';
  String get inputHint => _ru
      ? 'Вставьте ссылку vless://, vmess://, trojan://, ss:// или http(s)-подписку'
      : 'Paste a vless://, vmess://, trojan://, ss:// link, sing-box:// import link, sing-box JSON, or an http(s) subscription URL';
  String get addSourceAction => _ru ? 'Добавить' : 'Add';
  String get pasteFromClipboardAction =>
      _ru ? 'Вставить из буфера' : 'Paste from clipboard';
  String get clearInputAction => _ru ? 'Clear input' : 'Clear input';
  String get importFromJsonAction =>
      _ru ? 'Импортировать JSON файл' : 'Import from JSON';
  String get exportJsonAction => _ru ? 'Сохранить как JSON' : 'Save as JSON';
  String get jsonExportedMessage => 'JSON file exported.';
  String get jsonExportFailedMessage => 'Could not export the JSON file.';
  String get jsonImportFailedMessage =>
      'Could not import the selected JSON file.';
  String get scanQrAction => _ru ? 'Сканировать QR' : 'Scan QR';
  String get qrGalleryAction => _ru ? 'Галерея' : 'Gallery';
  String get qrCameraAction => _ru ? 'Камера' : 'Camera';
  String get qrPasteImageAction =>
      _ru ? 'Вставить изображение с QR' : 'Paste QR image';
  String get qrBrowseImageAction =>
      _ru ? 'Выбрать изображение' : 'Select image';
  String get qrClipboardImageMissingMessage =>
      _ru ? 'Clipboard has no image.' : 'Clipboard has no image.';
  String get turnFlashOnAction => _ru ? 'Turn flash on' : 'Turn flash on';
  String get turnFlashOffAction => _ru ? 'Turn flash off' : 'Turn flash off';
  String get qrCodeNotFoundMessage =>
      _ru ? 'No QR code found.' : 'No QR code found.';
  String get qrScanFailedMessage =>
      _ru ? 'Could not scan QR code.' : 'Could not scan QR code.';
  String get cameraUnavailableMessage =>
      _ru ? 'Camera unavailable.' : 'Camera unavailable.';
  String get clipboardEmptyMessage =>
      _ru ? 'Буфер обмена пуст.' : 'Clipboard is empty.';
  String get autoUpdateLabel => _ru ? 'Автообновление' : 'Auto-update';
  String get subscriptionTrafficLabel => _ru ? 'Трафик' : 'Traffic';
  String subscriptionTrafficUsedOf(String used, String total) =>
      '$used / $total';
  String subscriptionTrafficExpires(String date) =>
      _ru ? 'до $date' : 'until $date';
  String autoUpdateIntervalValue(Duration interval) {
    final minutes = interval.inMinutes;
    if (minutes < 60) {
      return _ru ? 'Каждые $minutes мин' : 'Every ${minutes}m';
    }

    final hours = minutes ~/ 60;
    final remainingMinutes = minutes.remainder(60);
    if (remainingMinutes == 0) {
      if (_ru && hours == 1) {
        return 'Каждый час';
      }
      return _ru ? 'Каждые $hours ч' : 'Every ${hours}h';
    }
    return _ru
        ? 'Каждые $hours ч $remainingMinutes мин'
        : 'Every ${hours}h ${remainingMinutes}m';
  }

  String get noProfilesLoaded =>
      _ru ? 'Профили еще не загружены' : 'Profiles are not loaded yet';
  String get removeSourceAction => _ru ? 'Удалить' : 'Remove';
  String get updateNowAction => _ru ? 'Обновить' : 'Update';
  String get powerConnectedLabel => _ru ? 'Подключено' : 'Connected';
  String get powerDisconnectedLabel => _ru ? 'Отключено' : 'Disconnected';
  String get connectingLabel => _ru ? 'Подключение' : 'Connecting';
  String get disconnectingLabel => _ru ? 'Отключение' : 'Disconnecting';
  String get failedLabel => _ru ? 'Ошибка' : 'Error';
  String get profileSelectorLabel =>
      _ru ? 'Профиль из подписки' : 'Subscription profile';
  String profileSelectorHelper(int count) =>
      _ru ? 'Найдено профилей: $count' : 'Profiles found: $count';
  String get xrayLabel => 'Xray';
  String get singBoxLabel => 'Sing-box';
  String get russianLabel => _ru ? 'Русский' : 'Russian';
  String get englishLabel => 'English';

  String coreName(CoreFlavor core) => switch (core) {
    CoreFlavor.xray => xrayLabel,
    CoreFlavor.singBox => singBoxLabel,
  };

  String tunIpModeName(TunIpMode mode) => switch (mode) {
    TunIpMode.ipv4 => 'IPv4',
    TunIpMode.dualStack => 'IPv4 + IPv6',
    TunIpMode.ipv6 => 'IPv6',
  };

  String splitTunnelModeName(SplitTunnelMode mode) => switch (mode) {
    SplitTunnelMode.off => splitTunnelOffModeLabel,
    SplitTunnelMode.whitelist => splitTunnelWhitelistModeLabel,
    SplitTunnelMode.blacklist => splitTunnelBlacklistModeLabel,
  };

  String protocolName(LinkProtocol protocol) => switch (protocol) {
    LinkProtocol.vless => 'VLESS',
    LinkProtocol.vmess => 'VMess',
    LinkProtocol.trojan => 'Trojan',
    LinkProtocol.shadowsocks => 'Shadowsocks',
  };

  String transportName(TransportMode transport) => switch (transport) {
    TransportMode.raw => 'RAW/TCP',
    TransportMode.ws => 'WebSocket',
    TransportMode.grpc => 'gRPC',
    TransportMode.http => 'HTTP',
    TransportMode.httpUpgrade => 'HTTPUpgrade',
    TransportMode.quic => 'QUIC',
  };

  String tlsName(TlsMode tlsMode) => switch (tlsMode) {
    TlsMode.none => _ru ? 'Нет' : 'None',
    TlsMode.tls => 'TLS',
    TlsMode.reality => 'REALITY',
  };
}

class _AppStringsDelegate extends LocalizationsDelegate<AppStrings> {
  const _AppStringsDelegate();

  @override
  bool isSupported(Locale locale) {
    return locale.languageCode == 'ru' || locale.languageCode == 'en';
  }

  @override
  Future<AppStrings> load(Locale locale) async {
    return AppStrings(
      locale.languageCode == 'ru' ? AppLanguage.ru : AppLanguage.en,
    );
  }

  @override
  bool shouldReload(_AppStringsDelegate old) => false;
}
