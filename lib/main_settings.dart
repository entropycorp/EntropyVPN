import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'l10n/app_strings.dart';
import 'models/dns_settings.dart';
import 'models/split_tunnel.dart';
import 'models/vpn_profile.dart';
import 'services/vpn_controller.dart';

class TrafficModeSelector extends StatelessWidget {
  const TrafficModeSelector({
    super.key,
    required this.controller,
    required this.strings,
  });

  final VpnController controller;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<TrafficMode>(
      key: ValueKey<TrafficMode>(controller.trafficMode),
      initialValue: controller.trafficMode,
      isExpanded: true,
      decoration: InputDecoration(labelText: strings.trafficModeLabel),
      icon: const Icon(Icons.keyboard_arrow_down_rounded),
      items: <DropdownMenuItem<TrafficMode>>[
        DropdownMenuItem<TrafficMode>(
          value: TrafficMode.systemProxy,
          child: Text(strings.systemProxyModeLabel),
        ),
        DropdownMenuItem<TrafficMode>(
          value: TrafficMode.tun,
          child: Text(strings.tunModeLabel),
        ),
      ],
      onChanged: controller.canChangeTrafficMode
          ? (mode) {
              if (mode != null) {
                unawaited(
                  controller.setTrafficMode(
                    mode,
                    ensureWindowsTunPrivileges: true,
                  ),
                );
              }
            }
          : null,
    );
  }
}

class TunIpModeSelector extends StatelessWidget {
  const TunIpModeSelector({
    super.key,
    required this.controller,
    required this.strings,
  });

  final VpnController controller;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<TunIpMode>(
      key: ValueKey<TunIpMode>(controller.tunIpMode),
      initialValue: controller.tunIpMode,
      isExpanded: true,
      decoration: InputDecoration(labelText: strings.tunIpModeLabel),
      icon: const Icon(Icons.keyboard_arrow_down_rounded),
      items: <DropdownMenuItem<TunIpMode>>[
        for (final mode in TunIpMode.values)
          DropdownMenuItem<TunIpMode>(
            value: mode,
            child: Text(strings.tunIpModeName(mode)),
          ),
      ],
      onChanged: controller.canChangeTunIpMode
          ? (mode) {
              if (mode != null) {
                controller.setTunIpMode(mode);
              }
            }
          : null,
    );
  }
}

class NotificationSettingsTile extends StatelessWidget {
  const NotificationSettingsTile({
    super.key,
    required this.strings,
    required this.onTap,
  });

  final AppStrings strings;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _SettingsNavigationTile(
      icon: Icons.notifications_rounded,
      title: strings.notificationsSettingsLabel,
      enabled: true,
      onTap: onTap,
    );
  }
}

class NotificationSettingsSubPage extends StatefulWidget {
  const NotificationSettingsSubPage({
    super.key,
    required this.controller,
    required this.strings,
    required this.onBack,
    required this.horizontalPadding,
    required this.verticalPadding,
    required this.gap,
  });

  final VpnController controller;
  final AppStrings strings;
  final VoidCallback onBack;
  final double horizontalPadding;
  final double verticalPadding;
  final double gap;

  @override
  State<NotificationSettingsSubPage> createState() =>
      _NotificationSettingsSubPageState();
}

class _NotificationSettingsSubPageState
    extends State<NotificationSettingsSubPage> {
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: widget.horizontalPadding,
            vertical: widget.verticalPadding,
          ),
          child: _SettingsSubPageHeader(
            icon: Icons.notifications_rounded,
            title: widget.strings.notificationsSettingsLabel,
            onBack: widget.onBack,
          ),
        ),
        SizedBox(height: widget.gap),
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: widget.horizontalPadding,
            vertical: widget.verticalPadding,
          ),
          child: _SettingsCheckboxTile(
            title: widget.strings.inAppUpdateNotificationsLabel,
            value: widget.controller.showInAppUpdateNotifications,
            onChanged: _setInAppUpdateNotifications,
          ),
        ),
        if (widget.controller.supportsAndroidUpdateNotifications) ...<Widget>[
          SizedBox(height: widget.gap),
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: widget.horizontalPadding,
              vertical: widget.verticalPadding,
            ),
            child: _SettingsCheckboxTile(
              title: widget.strings.androidUpdateNotificationsLabel,
              value: widget.controller.showAndroidUpdateNotifications,
              onChanged: _setAndroidUpdateNotifications,
            ),
          ),
        ],
      ],
    );
  }

  void _setInAppUpdateNotifications(bool value) {
    widget.controller.setShowInAppUpdateNotifications(value);
    setState(() {});
  }

  void _setAndroidUpdateNotifications(bool value) {
    widget.controller.setShowAndroidUpdateNotifications(value);
    setState(() {});
  }
}

class _SettingsSubPageHeader extends StatelessWidget {
  const _SettingsSubPageHeader({
    required this.icon,
    required this.title,
    required this.onBack,
  });

  final IconData icon;
  final String title;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: <Widget>[
            IconButton(
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            const SizedBox(width: 4),
            Icon(icon, color: scheme.primary),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsCheckboxTile extends StatelessWidget {
  const _SettingsCheckboxTile({
    required this.title,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(18),
      child: CheckboxListTile(
        value: value,
        onChanged: (checked) => onChanged(checked ?? false),
        title: Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        controlAffinity: ListTileControlAffinity.leading,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
    );
  }
}

class DnsSettingsTile extends StatelessWidget {
  const DnsSettingsTile({
    super.key,
    required this.controller,
    required this.strings,
  });

  final VpnController controller;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    return _SettingsNavigationTile(
      icon: Icons.dns_rounded,
      title: strings.dnsSettingsLabel,
      subtitle: controller.dnsSettings.displayFor(controller.tunIpMode),
      enabled: controller.canChangeDnsSettings,
      onTap: () => unawaited(_showDnsDialog(context)),
    );
  }

  Future<void> _showDnsDialog(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (context) =>
          _DnsSettingsDialog(controller: controller, strings: strings),
    );
  }
}

class _DnsSettingsDialog extends StatefulWidget {
  const _DnsSettingsDialog({required this.controller, required this.strings});

  final VpnController controller;
  final AppStrings strings;

  @override
  State<_DnsSettingsDialog> createState() => _DnsSettingsDialogState();
}

class _DnsSettingsDialogState extends State<_DnsSettingsDialog> {
  late final _Ipv4AddressInputController _primaryIpv4Controller;
  late final _Ipv4AddressInputController _secondaryIpv4Controller;
  late final TextEditingController _primaryIpv6Controller;
  late final TextEditingController _secondaryIpv6Controller;
  late final FocusNode _primaryIpv6FocusNode;
  late final FocusNode _secondaryIpv6FocusNode;

  @override
  void initState() {
    super.initState();
    final settings = widget.controller.dnsSettings;
    final ipv4Servers = settings.ipv4Servers;
    final ipv6Servers = settings.ipv6Servers;
    _primaryIpv4Controller = _Ipv4AddressInputController(
      address: ipv4Servers.isNotEmpty
          ? ipv4Servers[0]
          : DnsSettings.defaultIpv4Servers[0],
    )..addListener(_handleTextChanged);
    _secondaryIpv4Controller = _Ipv4AddressInputController(
      address: ipv4Servers.length > 1
          ? ipv4Servers[1]
          : DnsSettings.defaultIpv4Servers[1],
    )..addListener(_handleTextChanged);
    _primaryIpv6Controller = TextEditingController(
      text: ipv6Servers.isNotEmpty
          ? ipv6Servers[0]
          : DnsSettings.defaultIpv6Servers[0],
    )..addListener(_handleTextChanged);
    _secondaryIpv6Controller = TextEditingController(
      text: ipv6Servers.length > 1
          ? ipv6Servers[1]
          : DnsSettings.defaultIpv6Servers[1],
    )..addListener(_handleTextChanged);
    _primaryIpv6FocusNode = FocusNode();
    _secondaryIpv6FocusNode = FocusNode();
  }

  @override
  void dispose() {
    _primaryIpv4Controller
      ..removeListener(_handleTextChanged)
      ..dispose();
    _secondaryIpv4Controller
      ..removeListener(_handleTextChanged)
      ..dispose();
    _primaryIpv6Controller
      ..removeListener(_handleTextChanged)
      ..dispose();
    _secondaryIpv6Controller
      ..removeListener(_handleTextChanged)
      ..dispose();
    _primaryIpv6FocusNode.dispose();
    _secondaryIpv6FocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    final canSave =
        widget.controller.canChangeDnsSettings &&
        _isVisibleIpv4Complete &&
        _isVisibleIpv6Complete;

    return AlertDialog(
      title: Text(strings.dnsSettingsLabel),
      content: SizedBox(
        width: _settingsDialogWidth(context),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: _buildDnsFields(context),
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _resetToDefaults,
          child: Text(strings.resetAction),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: canSave ? _save : null,
          child: Text(strings.saveAction),
        ),
      ],
    );
  }

  bool get _showsIpv4 => widget.controller.tunIpMode != TunIpMode.ipv6;
  bool get _showsIpv6 => widget.controller.tunIpMode != TunIpMode.ipv4;
  bool get _showsBoth => _showsIpv4 && _showsIpv6;

  bool get _isVisibleIpv4Complete {
    return !_showsIpv4 ||
        (_primaryIpv4Controller.isComplete &&
            _secondaryIpv4Controller.isComplete);
  }

  bool get _isVisibleIpv6Complete {
    return !_showsIpv6 ||
        (_isValidIpv6Server(_primaryIpv6Controller.text) &&
            _isValidIpv6Server(_secondaryIpv6Controller.text));
  }

  List<Widget> _buildDnsFields(BuildContext context) {
    final strings = widget.strings;
    final enabled = widget.controller.canChangeDnsSettings;
    final fields = <Widget>[];

    if (_showsIpv4) {
      if (_showsBoth) {
        fields.add(_DnsFamilyLabel(label: strings.ipv4DnsServersLabel));
        fields.add(const SizedBox(height: 10));
      }
      fields.add(
        _Ipv4AddressField(
          controller: _primaryIpv4Controller,
          nextController: _secondaryIpv4Controller,
          label: strings.primaryDnsServerLabel,
          enabled: enabled,
          errorText: _ipv4ErrorText(_primaryIpv4Controller),
        ),
      );
      fields.add(const SizedBox(height: 14));
      fields.add(
        _Ipv4AddressField(
          controller: _secondaryIpv4Controller,
          previousController: _primaryIpv4Controller,
          label: strings.secondaryDnsServerLabel,
          enabled: enabled,
          errorText: _ipv4ErrorText(_secondaryIpv4Controller),
        ),
      );
    }

    if (_showsIpv6) {
      if (fields.isNotEmpty) {
        fields.add(const SizedBox(height: 20));
      }
      if (_showsBoth) {
        fields.add(_DnsFamilyLabel(label: strings.ipv6DnsServersLabel));
        fields.add(const SizedBox(height: 10));
      }
      fields.add(
        _DnsTextAddressField(
          controller: _primaryIpv6Controller,
          focusNode: _primaryIpv6FocusNode,
          nextController: _secondaryIpv6Controller,
          nextFocusNode: _secondaryIpv6FocusNode,
          label: strings.primaryDnsServerLabel,
          enabled: enabled,
          errorText: _ipv6ErrorText(_primaryIpv6Controller),
          onSubmitted: () =>
              _moveTextFocus(_secondaryIpv6FocusNode, _secondaryIpv6Controller),
        ),
      );
      fields.add(const SizedBox(height: 14));
      fields.add(
        _DnsTextAddressField(
          controller: _secondaryIpv6Controller,
          focusNode: _secondaryIpv6FocusNode,
          previousController: _primaryIpv6Controller,
          previousFocusNode: _primaryIpv6FocusNode,
          label: strings.secondaryDnsServerLabel,
          enabled: enabled,
          errorText: _ipv6ErrorText(_secondaryIpv6Controller),
        ),
      );
    }

    return fields;
  }

  String? _ipv4ErrorText(_Ipv4AddressInputController controller) {
    if (!_showsIpv4 || controller.isComplete) {
      return null;
    }
    return widget.strings.dnsServersIncompleteMessage;
  }

  String? _ipv6ErrorText(TextEditingController controller) {
    if (!_showsIpv6 || _isValidIpv6Server(controller.text)) {
      return null;
    }
    final text = controller.text.trim();
    if (text.isEmpty) {
      return widget.strings.dnsServersIncompleteMessage;
    }
    return widget.strings.dnsServersInvalid(text);
  }

  bool _isValidIpv6Server(String text) {
    final value = text.trim();
    final parsed = InternetAddress.tryParse(value);
    return parsed != null && parsed.type == InternetAddressType.IPv6;
  }

  void _handleTextChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _resetToDefaults() {
    if (_showsIpv4) {
      _primaryIpv4Controller.setAddress(DnsSettings.defaultIpv4Servers[0]);
      _secondaryIpv4Controller.setAddress(DnsSettings.defaultIpv4Servers[1]);
    }
    if (_showsIpv6) {
      _primaryIpv6Controller.text = DnsSettings.defaultIpv6Servers[0];
      _secondaryIpv6Controller.text = DnsSettings.defaultIpv6Servers[1];
    }
  }

  void _save() {
    final currentSettings = widget.controller.dnsSettings;
    widget.controller.setDnsSettings(
      DnsSettings(
        ipv4Servers: _showsIpv4
            ? <String>[
                _primaryIpv4Controller.address,
                _secondaryIpv4Controller.address,
              ]
            : currentSettings.ipv4Servers,
        ipv6Servers: _showsIpv6
            ? <String>[
                _primaryIpv6Controller.text.trim(),
                _secondaryIpv6Controller.text.trim(),
              ]
            : currentSettings.ipv6Servers,
      ),
    );
    Navigator.of(context).pop();
  }

  void _moveTextFocus(
    FocusNode focusNode,
    TextEditingController controller, {
    TextSelection? sourceSelection,
  }) {
    var offset = sourceSelection?.extentOffset ?? controller.text.length;
    if (offset < 0) {
      offset = 0;
    }
    if (offset > controller.text.length) {
      offset = controller.text.length;
    }
    focusNode.requestFocus();
    controller.selection = TextSelection.collapsed(offset: offset);
  }
}

class _Ipv4AddressInputController extends ChangeNotifier {
  _Ipv4AddressInputController({required String address}) {
    for (final controller in _octetControllers) {
      controller.addListener(notifyListeners);
    }
    setAddress(address);
  }

  final List<TextEditingController> _octetControllers =
      List<TextEditingController>.generate(4, (_) => TextEditingController());
  final List<FocusNode> _focusNodes = List<FocusNode>.generate(
    4,
    (_) => FocusNode(),
  );

  List<TextEditingController> get octetControllers => _octetControllers;
  List<FocusNode> get focusNodes => _focusNodes;

  bool get isComplete {
    return _octetControllers.every((controller) {
      final value = int.tryParse(controller.text);
      return value != null && value >= 0 && value <= 255;
    });
  }

  String get address {
    return _octetControllers
        .map((controller) => int.parse(controller.text).toString())
        .join('.');
  }

  void setAddress(String address) {
    final parts = address.split('.');
    for (var index = 0; index < _octetControllers.length; index += 1) {
      final text = index < parts.length ? parts[index].trim() : '';
      final value = int.tryParse(text);
      _octetControllers[index].text =
          value != null && value >= 0 && value <= 255 ? value.toString() : '';
    }
    notifyListeners();
  }

  @override
  void dispose() {
    for (final controller in _octetControllers) {
      controller
        ..removeListener(notifyListeners)
        ..dispose();
    }
    for (final focusNode in _focusNodes) {
      focusNode.dispose();
    }
    super.dispose();
  }
}

class _Ipv4AddressField extends StatelessWidget {
  const _Ipv4AddressField({
    required this.controller,
    required this.label,
    required this.enabled,
    this.previousController,
    this.nextController,
    this.errorText,
  });

  static final List<TextInputFormatter> _octetFormatters = <TextInputFormatter>[
    FilteringTextInputFormatter.digitsOnly,
    LengthLimitingTextInputFormatter(3),
    _Ipv4OctetFormatter(),
  ];

  final _Ipv4AddressInputController controller;
  final _Ipv4AddressInputController? previousController;
  final _Ipv4AddressInputController? nextController;
  final String label;
  final bool enabled;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final textStyle = theme.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w400,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      letterSpacing: 0,
    );

    final labelStyle = theme.textTheme.bodyMedium?.copyWith(
      color: enabled
          ? scheme.onSurfaceVariant
          : scheme.onSurface.withValues(alpha: 0.38),
    );
    final errorStyle = theme.textTheme.bodySmall?.copyWith(color: scheme.error);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: labelStyle),
        const SizedBox(height: 6),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (var index = 0; index < 4; index += 1) ...<Widget>[
              _Ipv4OctetField(
                controller: controller,
                previousController: previousController,
                nextController: nextController,
                index: index,
                enabled: enabled,
                inputFormatters: _octetFormatters,
                textStyle: textStyle,
              ),
              if (index < 3)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  child: Text(
                    '.',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w400,
                      color: enabled
                          ? scheme.onSurfaceVariant
                          : scheme.onSurface.withValues(alpha: 0.38),
                    ),
                  ),
                ),
            ],
          ],
        ),
        if (errorText != null) ...<Widget>[
          const SizedBox(height: 4),
          Text(errorText!, style: errorStyle),
        ],
      ],
    );
  }
}

class _DnsFamilyLabel extends StatelessWidget {
  const _DnsFamilyLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        label,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.onSurface,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _DnsTextAddressField extends StatelessWidget {
  const _DnsTextAddressField({
    required this.controller,
    required this.focusNode,
    required this.label,
    required this.enabled,
    this.previousController,
    this.previousFocusNode,
    this.nextController,
    this.nextFocusNode,
    this.errorText,
    this.onSubmitted,
  });

  static final List<TextInputFormatter> _inputFormatters = <TextInputFormatter>[
    FilteringTextInputFormatter.deny(RegExp(r'\s')),
  ];

  final TextEditingController controller;
  final FocusNode focusNode;
  final TextEditingController? previousController;
  final FocusNode? previousFocusNode;
  final TextEditingController? nextController;
  final FocusNode? nextFocusNode;
  final String label;
  final bool enabled;
  final String? errorText;
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final labelStyle = theme.textTheme.bodyMedium?.copyWith(
      color: enabled
          ? scheme.onSurfaceVariant
          : scheme.onSurface.withValues(alpha: 0.38),
    );
    final textStyle = theme.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w400,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      letterSpacing: 0,
    );
    final errorStyle = theme.textTheme.bodySmall?.copyWith(color: scheme.error);

    return Focus(
      onKeyEvent: (_, event) => _handleKeyEvent(event),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: labelStyle),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            focusNode: focusNode,
            enabled: enabled,
            maxLines: 1,
            style: textStyle,
            keyboardType: TextInputType.text,
            textInputAction: nextFocusNode == null
                ? TextInputAction.done
                : TextInputAction.next,
            inputFormatters: _inputFormatters,
            decoration: const _DnsTextInputDecoration(),
            onSubmitted: (_) => onSubmitted?.call(),
          ),
          if (errorText != null) ...<Widget>[
            const SizedBox(height: 4),
            Text(errorText!, style: errorStyle),
          ],
        ],
      ),
    );
  }

  KeyEventResult _handleKeyEvent(KeyEvent event) {
    final isNavigationPress = event is KeyDownEvent || event is KeyRepeatEvent;
    if (!isNavigationPress) {
      return KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (previousFocusNode != null && previousController != null) {
        _moveFocus(previousFocusNode!, previousController!);
      }
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (nextFocusNode != null && nextController != null) {
        _moveFocus(nextFocusNode!, nextController!);
      }
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _moveFocus(
    FocusNode nextFocusNode,
    TextEditingController nextController,
  ) {
    var offset = controller.selection.extentOffset;
    if (offset < 0) {
      offset = nextController.text.length;
    }
    if (offset > nextController.text.length) {
      offset = nextController.text.length;
    }
    nextFocusNode.requestFocus();
    nextController.selection = TextSelection.collapsed(offset: offset);
  }
}

class _DnsTextInputDecoration extends InputDecoration {
  const _DnsTextInputDecoration()
    : super(
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        disabledBorder: InputBorder.none,
        errorBorder: InputBorder.none,
        focusedErrorBorder: InputBorder.none,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 2),
      );
}

class _Ipv4OctetInputDecoration extends InputDecoration {
  const _Ipv4OctetInputDecoration()
    : super(
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        disabledBorder: InputBorder.none,
        errorBorder: InputBorder.none,
        focusedErrorBorder: InputBorder.none,
        counterText: '',
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 2),
      );
}

class _Ipv4OctetField extends StatelessWidget {
  const _Ipv4OctetField({
    required this.controller,
    required this.index,
    required this.enabled,
    required this.inputFormatters,
    required this.textStyle,
    this.previousController,
    this.nextController,
  });

  final _Ipv4AddressInputController controller;
  final _Ipv4AddressInputController? previousController;
  final _Ipv4AddressInputController? nextController;
  final int index;
  final bool enabled;
  final List<TextInputFormatter> inputFormatters;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    final octetController = controller.octetControllers[index];
    final focusNode = controller.focusNodes[index];

    return Focus(
      onKeyEvent: (_, event) => _handleKeyEvent(event),
      child: SizedBox(
        width: 44,
        child: TextField(
          controller: octetController,
          focusNode: focusNode,
          enabled: enabled,
          textAlign: TextAlign.center,
          style: textStyle,
          keyboardType: TextInputType.number,
          textInputAction: index < 3
              ? TextInputAction.next
              : TextInputAction.done,
          maxLength: 3,
          inputFormatters: inputFormatters,
          decoration: const _Ipv4OctetInputDecoration(),
          onChanged: (value) {
            if (value.length == 3 && index < 3) {
              _moveFocus(index + 1, selectAll: true);
            }
          },
          onSubmitted: (_) {
            if (index < 3) {
              _moveFocus(index + 1, selectAll: true);
            }
          },
        ),
      ),
    );
  }

  KeyEventResult _handleKeyEvent(KeyEvent event) {
    final isNavigationPress = event is KeyDownEvent || event is KeyRepeatEvent;
    if (!isNavigationPress) {
      return KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      if (index > 0) {
        _moveFocus(index - 1, caretAtEnd: true);
      }
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      if (index < 3) {
        _moveFocus(index + 1);
      }
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (previousController != null) {
        _moveVerticalFocus(previousController!);
      }
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (nextController != null) {
        _moveVerticalFocus(nextController!);
      }
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.backspace &&
        _currentText.isEmpty &&
        index > 0) {
      _moveFocus(index - 1, caretAtEnd: true);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  String get _currentText => controller.octetControllers[index].text;

  void _moveFocus(
    int nextIndex, {
    bool caretAtEnd = false,
    bool selectAll = false,
  }) {
    final focusNode = controller.focusNodes[nextIndex];
    final textController = controller.octetControllers[nextIndex];
    focusNode.requestFocus();
    if (selectAll && textController.text.isNotEmpty) {
      textController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: textController.text.length,
      );
      return;
    }
    final offset = caretAtEnd ? textController.text.length : 0;
    textController.selection = TextSelection.collapsed(offset: offset);
  }

  void _moveVerticalFocus(_Ipv4AddressInputController targetController) {
    final targetFocusNode = targetController.focusNodes[index];
    final targetTextController = targetController.octetControllers[index];
    var offset = controller.octetControllers[index].selection.extentOffset;
    if (offset < 0) {
      offset = targetTextController.text.length;
    }
    if (offset > targetTextController.text.length) {
      offset = targetTextController.text.length;
    }
    targetFocusNode.requestFocus();
    targetTextController.selection = TextSelection.collapsed(offset: offset);
  }
}

class _Ipv4OctetFormatter extends TextInputFormatter {
  const _Ipv4OctetFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.isEmpty) {
      return newValue;
    }
    final value = int.tryParse(newValue.text);
    if (value == null || value > 255) {
      return oldValue;
    }
    return newValue;
  }
}

class _SettingsNavigationTile extends StatelessWidget {
  const _SettingsNavigationTile({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final subtitle = this.subtitle;
    final disabledColor = scheme.onSurface.withValues(alpha: 0.38);
    final titleColor = enabled ? scheme.onSurface : disabledColor;
    final statusColor = enabled ? scheme.onSurfaceVariant : disabledColor;
    final iconColor = enabled ? scheme.primary : disabledColor;

    return Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: <Widget>[
              Icon(icon, color: iconColor),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: titleColor,
                      ),
                    ),
                    if (subtitle != null && subtitle.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: statusColor,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded, color: statusColor),
            ],
          ),
        ),
      ),
    );
  }
}

class SplitTunnelSettingsTile extends StatelessWidget {
  const SplitTunnelSettingsTile({
    super.key,
    required this.controller,
    required this.strings,
  });

  final VpnController controller;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    return _SettingsNavigationTile(
      icon: Icons.account_tree_rounded,
      title: strings.appSplitTunnelLabel,
      subtitle: strings.splitTunnelModeName(controller.splitTunnelMode),
      enabled: controller.canChangeSplitTunnel,
      onTap: () => unawaited(_showSplitTunnelDialog(context)),
    );
  }

  Future<void> _showSplitTunnelDialog(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (context) =>
          _SplitTunnelDialog(controller: controller, strings: strings),
    );
  }
}

class _SplitTunnelDialog extends StatefulWidget {
  const _SplitTunnelDialog({required this.controller, required this.strings});

  final VpnController controller;
  final AppStrings strings;

  @override
  State<_SplitTunnelDialog> createState() => _SplitTunnelDialogState();
}

class _SplitTunnelDialogState extends State<_SplitTunnelDialog> {
  late Future<List<SplitTunnelApp>> _appsFuture;
  late final TextEditingController _searchController;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController()
      ..addListener(() {
        if (mounted) {
          setState(() {});
        }
      });
    _appsFuture = widget.controller.loadSplitTunnelAppCatalog();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = widget.strings;
    final controller = widget.controller;
    final selectedApps = controller.splitTunnelApps;
    final selectedAppIds = <String>{for (final app in selectedApps) app.id};
    final splitTunnelEnabled =
        controller.splitTunnelMode != SplitTunnelMode.off;
    final dialogContentSize = _splitTunnelDialogContentSize(
      context,
      minWidth: 360,
      maxWidth: 720,
      minHeight: 420,
      maxHeight: 580,
      heightFactor: 0.72,
    );

    return AlertDialog(
      title: Row(
        children: <Widget>[
          Expanded(child: Text(strings.appSplitTunnelLabel)),
          if (splitTunnelEnabled)
            IconButton(
              tooltip: strings.splitTunnelRefreshTooltip,
              onPressed: _reloadApps,
              icon: const Icon(Icons.refresh_rounded),
            ),
        ],
      ),
      content: SizedBox(
        width: dialogContentSize.width,
        height: dialogContentSize.height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _SplitTunnelModePicker(
              strings: strings,
              selectedMode: controller.splitTunnelMode,
              enabled: controller.canChangeSplitTunnel,
              onChanged: _setSplitTunnelMode,
            ),
            if (splitTunnelEnabled) ...<Widget>[
              const SizedBox(height: 14),
              TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: strings.splitTunnelSearchHint,
                ),
              ),
              const SizedBox(height: 14),
              _SplitTunnelSectionHeader(
                label: strings.splitTunnelAppsLabel,
                countLabel: strings.splitTunnelSelectedCount(
                  selectedApps.length,
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: FutureBuilder<List<SplitTunnelApp>>(
                  future: _appsFuture,
                  builder: (context, snapshot) {
                    final apps = _filterApps(
                      _mergeApps(
                        snapshot.data ?? const <SplitTunnelApp>[],
                        selectedApps,
                        selectedAppIds,
                      ),
                    );

                    if (snapshot.connectionState == ConnectionState.waiting &&
                        apps.isEmpty) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    if (apps.isEmpty) {
                      return _SplitTunnelEmptyState(
                        message: strings.splitTunnelNoAppsFound,
                      );
                    }

                    return ListView.separated(
                      itemCount: apps.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 2),
                      itemBuilder: (context, index) {
                        final app = apps[index];
                        final selected = selectedAppIds.contains(app.id);
                        final enabled =
                            controller.canChangeSplitTunnel &&
                            controller.splitTunnelMode != SplitTunnelMode.off;
                        return CheckboxListTile(
                          value: selected,
                          enabled: enabled,
                          dense: true,
                          visualDensity: VisualDensity.compact,
                          onChanged: enabled
                              ? (_) {
                                  setState(() {
                                    controller.toggleSplitTunnelApp(app);
                                  });
                                }
                              : null,
                          title: Text(
                            app.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontSize: 15.5,
                            ),
                          ),
                          controlAffinity: ListTileControlAffinity.leading,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 4,
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).closeButtonLabel),
        ),
      ],
    );
  }

  void _setSplitTunnelMode(SplitTunnelMode mode) {
    if (mode == SplitTunnelMode.off) {
      _searchController.clear();
    }
    setState(() {
      unawaited(
        widget.controller.setSplitTunnelMode(
          mode,
          ensureWindowsTunPrivileges: true,
        ),
      );
    });
  }

  void _reloadApps() {
    setState(() {
      _appsFuture = widget.controller.loadSplitTunnelAppCatalog(refresh: true);
    });
  }

  List<SplitTunnelApp> _mergeApps(
    List<SplitTunnelApp> catalogApps,
    List<SplitTunnelApp> selectedApps,
    Set<String> selectedAppIds,
  ) {
    final appsById = <String, SplitTunnelApp>{
      for (final app in selectedApps) app.id: app,
    };
    for (final app in catalogApps) {
      appsById[app.id] = app;
    }
    final apps = appsById.values.toList(growable: false);
    apps.sort(
      (left, right) => _compareSplitTunnelApps(left, right, selectedAppIds),
    );
    return apps;
  }

  int _compareSplitTunnelApps(
    SplitTunnelApp left,
    SplitTunnelApp right,
    Set<String> selectedAppIds,
  ) {
    final leftSelected = selectedAppIds.contains(left.id);
    final rightSelected = selectedAppIds.contains(right.id);
    if (leftSelected != rightSelected) {
      return leftSelected ? -1 : 1;
    }

    final byName = left.name.toLowerCase().compareTo(right.name.toLowerCase());
    if (byName != 0) {
      return byName;
    }
    return left.path.toLowerCase().compareTo(right.path.toLowerCase());
  }

  List<SplitTunnelApp> _filterApps(List<SplitTunnelApp> apps) {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) {
      return apps;
    }
    return apps
        .where(
          (app) =>
              app.name.toLowerCase().contains(query) ||
              app.path.toLowerCase().contains(query),
        )
        .toList(growable: false);
  }
}

class DomainSplitTunnelSettingsTile extends StatelessWidget {
  const DomainSplitTunnelSettingsTile({
    super.key,
    required this.controller,
    required this.strings,
  });

  final VpnController controller;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    return _SettingsNavigationTile(
      icon: Icons.public_rounded,
      title: strings.domainSplitTunnelLabel,
      subtitle: strings.splitTunnelModeName(controller.domainSplitTunnelMode),
      enabled: controller.canChangeSplitTunnel,
      onTap: () => unawaited(_showDomainSplitTunnelDialog(context)),
    );
  }

  Future<void> _showDomainSplitTunnelDialog(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (context) =>
          _DomainSplitTunnelDialog(controller: controller, strings: strings),
    );
  }
}

class _DomainSplitTunnelDialog extends StatefulWidget {
  const _DomainSplitTunnelDialog({
    required this.controller,
    required this.strings,
  });

  final VpnController controller;
  final AppStrings strings;

  @override
  State<_DomainSplitTunnelDialog> createState() =>
      _DomainSplitTunnelDialogState();
}

class _DomainSplitTunnelDialogState extends State<_DomainSplitTunnelDialog> {
  late final TextEditingController _domainController;

  @override
  void initState() {
    super.initState();
    _domainController = TextEditingController()
      ..addListener(() {
        if (mounted) {
          setState(() {});
        }
      });
  }

  @override
  void dispose() {
    _domainController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    final controller = widget.controller;
    final domains = controller.domainSplitTunnelDomains;
    final domainSplitTunnelEnabled =
        controller.domainSplitTunnelMode != SplitTunnelMode.off;
    final dialogContentSize = _splitTunnelDialogContentSize(
      context,
      minWidth: 360,
      maxWidth: 640,
      minHeight: 360,
      maxHeight: 520,
      heightFactor: 0.62,
    );
    final canEditDomains =
        controller.canChangeSplitTunnel &&
        controller.domainSplitTunnelMode != SplitTunnelMode.off;
    final canAddDomain =
        canEditDomains && _domainController.text.trim().isNotEmpty;

    return AlertDialog(
      title: Text(strings.domainSplitTunnelLabel),
      content: SizedBox(
        width: dialogContentSize.width,
        height: dialogContentSize.height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _SplitTunnelModePicker(
              strings: strings,
              selectedMode: controller.domainSplitTunnelMode,
              enabled: controller.canChangeSplitTunnel,
              onChanged: _setDomainSplitTunnelMode,
            ),
            if (domainSplitTunnelEnabled) ...<Widget>[
              const SizedBox(height: 14),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _domainController,
                      enabled: canEditDomains,
                      decoration: InputDecoration(
                        hintText: strings.domainSplitTunnelInputHint,
                      ),
                      onSubmitted: canEditDomains ? (_) => _addDomain() : null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: strings.domainSplitTunnelAddTooltip,
                    onPressed: canAddDomain ? _addDomain : null,
                    icon: const Icon(Icons.add_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _SplitTunnelSectionHeader(
                label: strings.domainSplitTunnelDomainsLabel,
                countLabel: strings.domainSplitTunnelSelectedCount(
                  domains.length,
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: domains.isEmpty
                    ? _SplitTunnelEmptyState(
                        message: strings.domainSplitTunnelNoDomains,
                      )
                    : ListView.separated(
                        itemCount: domains.length,
                        separatorBuilder: (context, index) =>
                            const SizedBox(height: 6),
                        itemBuilder: (context, index) {
                          final domain = domains[index];
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 4,
                            ),
                            leading: const Icon(Icons.language_rounded),
                            title: Text(
                              domain.value,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              domain.matchSuffix,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: IconButton(
                              onPressed: controller.canChangeSplitTunnel
                                  ? () {
                                      setState(() {
                                        controller
                                            .removeDomainSplitTunnelDomain(
                                              domain,
                                            );
                                      });
                                    }
                                  : null,
                              icon: const Icon(Icons.close_rounded),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).closeButtonLabel),
        ),
      ],
    );
  }

  void _setDomainSplitTunnelMode(SplitTunnelMode mode) {
    if (mode == SplitTunnelMode.off) {
      _domainController.clear();
    }
    setState(() {
      unawaited(
        widget.controller.setDomainSplitTunnelMode(
          mode,
          ensureWindowsTunPrivileges: true,
        ),
      );
    });
  }

  void _addDomain() {
    final input = _domainController.text;
    setState(() {
      widget.controller.addDomainSplitTunnelInput(input);
      _domainController.clear();
    });
  }
}

class _SplitTunnelModePicker extends StatelessWidget {
  const _SplitTunnelModePicker({
    required this.strings,
    required this.selectedMode,
    required this.enabled,
    required this.onChanged,
  });

  final AppStrings strings;
  final SplitTunnelMode selectedMode;
  final bool enabled;
  final ValueChanged<SplitTunnelMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<SplitTunnelMode>(
      segments: <ButtonSegment<SplitTunnelMode>>[
        ButtonSegment<SplitTunnelMode>(
          value: SplitTunnelMode.off,
          label: Text(strings.splitTunnelOffModeLabel),
        ),
        ButtonSegment<SplitTunnelMode>(
          value: SplitTunnelMode.whitelist,
          label: Text(strings.splitTunnelWhitelistModeLabel),
        ),
        ButtonSegment<SplitTunnelMode>(
          value: SplitTunnelMode.blacklist,
          label: Text(strings.splitTunnelBlacklistModeLabel),
        ),
      ],
      selected: <SplitTunnelMode>{selectedMode},
      showSelectedIcon: false,
      multiSelectionEnabled: false,
      onSelectionChanged: enabled
          ? (selection) {
              if (selection.isNotEmpty) {
                onChanged(selection.first);
              }
            }
          : null,
    );
  }
}

class _SplitTunnelSectionHeader extends StatelessWidget {
  const _SplitTunnelSectionHeader({
    required this.label,
    required this.countLabel,
  });

  final String label;
  final String countLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Row(
      children: <Widget>[
        Expanded(child: Text(label, style: theme.textTheme.titleSmall)),
        Text(
          countLabel,
          style: theme.textTheme.labelLarge?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _SplitTunnelEmptyState extends StatelessWidget {
  const _SplitTunnelEmptyState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Center(
      child: Text(
        message,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

Size _splitTunnelDialogContentSize(
  BuildContext context, {
  required double minWidth,
  required double maxWidth,
  required double minHeight,
  required double maxHeight,
  double widthFactor = 0.82,
  required double heightFactor,
}) {
  final dialogSize = MediaQuery.sizeOf(context);
  return Size(
    (dialogSize.width * widthFactor).clamp(minWidth, maxWidth).toDouble(),
    (dialogSize.height * heightFactor).clamp(minHeight, maxHeight).toDouble(),
  );
}

double _settingsDialogWidth(BuildContext context) {
  final dialogSize = MediaQuery.sizeOf(context);
  return (dialogSize.width * 0.78).clamp(320.0, 560.0).toDouble();
}
