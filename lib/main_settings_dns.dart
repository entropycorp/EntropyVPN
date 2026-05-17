part of 'main_settings.dart';

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
  late DnsMode _mode;
  late final _Ipv4AddressInputController _primaryIpv4Controller;
  late final _Ipv4AddressInputController _secondaryIpv4Controller;
  late final TextEditingController _primaryIpv6Controller;
  late final TextEditingController _secondaryIpv6Controller;
  late final FocusNode _primaryIpv6FocusNode;
  late final FocusNode _secondaryIpv6FocusNode;
  late final TextEditingController _primaryDohController;
  late final FocusNode _primaryDohFocusNode;
  late final TextEditingController _primaryDotController;
  late final FocusNode _primaryDotFocusNode;

  @override
  void initState() {
    super.initState();
    final settings = widget.controller.dnsSettings;
    final initialMode = settings.mode;
    _mode = (initialMode == DnsMode.dot && !widget.controller.activeCoreSupportsDoT)
        ? DnsMode.doh
        : initialMode;
    final ipv4Servers = settings.ipv4Servers;
    final ipv6Servers = settings.ipv6Servers;
    final dohServers = settings.dohServers;
    final dotServers = settings.dotServers;
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
    _primaryDohController = TextEditingController(
      text: dohServers.isNotEmpty
          ? dohServers[0]
          : DnsSettings.defaultDohServers[0],
    )..addListener(_handleTextChanged);
    _primaryDohFocusNode = FocusNode();
    _primaryDotController = TextEditingController(
      text: dotServers.isNotEmpty
          ? dotServers[0]
          : DnsSettings.defaultDotServers[0],
    )..addListener(_handleTextChanged);
    _primaryDotFocusNode = FocusNode();
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
    _primaryDohController
      ..removeListener(_handleTextChanged)
      ..dispose();
    _primaryDohFocusNode.dispose();
    _primaryDotController
      ..removeListener(_handleTextChanged)
      ..dispose();
    _primaryDotFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    final canSave = widget.controller.canChangeDnsSettings && _isModeComplete;

    return AlertDialog(
      title: Text(strings.dnsSettingsLabel),
      content: SizedBox(
        width: _settingsDialogWidth(context),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: _buildContent(context),
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

  bool get _isModeComplete {
    return switch (_mode) {
      DnsMode.classic => _isVisibleIpv4Complete && _isVisibleIpv6Complete,
      DnsMode.doh => DnsSettings.isValidDohServer(_primaryDohController.text),
      DnsMode.dot => DnsSettings.isValidDotServer(_primaryDotController.text),
    };
  }

  List<Widget> _buildContent(BuildContext context) {
    final widgets = <Widget>[
      _DnsModeSelector(
        mode: _mode,
        enabled: widget.controller.canChangeDnsSettings,
        supportsDot: widget.controller.activeCoreSupportsDoT,
        strings: widget.strings,
        onChanged: _setMode,
      ),
      const SizedBox(height: 14),
    ];
    widgets.addAll(switch (_mode) {
      DnsMode.classic => _buildClassicFields(context),
      DnsMode.doh => _buildDohFields(context),
      DnsMode.dot => _buildDotFields(context),
    });
    return widgets;
  }

  void _setMode(DnsMode mode) {
    if (_mode == mode) {
      return;
    }
    setState(() {
      _mode = mode;
    });
  }

  List<Widget> _buildClassicFields(BuildContext context) {
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
          enabled: enabled,
          errorText: _ipv4ErrorText(_primaryIpv4Controller),
        ),
      );
      fields.add(const SizedBox(height: 10));
      fields.add(
        _Ipv4AddressField(
          controller: _secondaryIpv4Controller,
          previousController: _primaryIpv4Controller,
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
          enabled: enabled,
          errorText: _ipv6ErrorText(_primaryIpv6Controller),
          onSubmitted: () =>
              _moveTextFocus(_secondaryIpv6FocusNode, _secondaryIpv6Controller),
        ),
      );
      fields.add(const SizedBox(height: 10));
      fields.add(
        _DnsTextAddressField(
          controller: _secondaryIpv6Controller,
          focusNode: _secondaryIpv6FocusNode,
          previousController: _primaryIpv6Controller,
          previousFocusNode: _primaryIpv6FocusNode,
          enabled: enabled,
          errorText: _ipv6ErrorText(_secondaryIpv6Controller),
        ),
      );
    }

    return fields;
  }

  List<Widget> _buildDohFields(BuildContext context) {
    final strings = widget.strings;
    final enabled = widget.controller.canChangeDnsSettings;
    return <Widget>[
      _DnsTextAddressField(
        controller: _primaryDohController,
        focusNode: _primaryDohFocusNode,
        hintText: strings.dohServerHint,
        enabled: enabled,
        errorText: _dohErrorText(_primaryDohController),
      ),
    ];
  }

  List<Widget> _buildDotFields(BuildContext context) {
    final strings = widget.strings;
    final enabled = widget.controller.canChangeDnsSettings;
    return <Widget>[
      _DnsTextAddressField(
        controller: _primaryDotController,
        focusNode: _primaryDotFocusNode,
        hintText: strings.dotServerHint,
        enabled: enabled,
        errorText: _dotErrorText(_primaryDotController),
      ),
    ];
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

  String? _dohErrorText(TextEditingController controller) {
    if (DnsSettings.isValidDohServer(controller.text)) {
      return null;
    }
    final text = controller.text.trim();
    if (text.isEmpty) {
      return widget.strings.dnsServersIncompleteMessage;
    }
    return widget.strings.dohServerInvalidMessage;
  }

  String? _dotErrorText(TextEditingController controller) {
    if (DnsSettings.isValidDotServer(controller.text)) {
      return null;
    }
    final text = controller.text.trim();
    if (text.isEmpty) {
      return widget.strings.dnsServersIncompleteMessage;
    }
    return widget.strings.dotServerInvalidMessage;
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
    switch (_mode) {
      case DnsMode.classic:
        if (_showsIpv4) {
          _primaryIpv4Controller.setAddress(DnsSettings.defaultIpv4Servers[0]);
          _secondaryIpv4Controller.setAddress(
            DnsSettings.defaultIpv4Servers[1],
          );
        }
        if (_showsIpv6) {
          _primaryIpv6Controller.text = DnsSettings.defaultIpv6Servers[0];
          _secondaryIpv6Controller.text = DnsSettings.defaultIpv6Servers[1];
        }
      case DnsMode.doh:
        _primaryDohController.text = DnsSettings.defaultDohServers[0];
      case DnsMode.dot:
        _primaryDotController.text = DnsSettings.defaultDotServers[0];
    }
  }

  void _save() {
    final currentSettings = widget.controller.dnsSettings;
    final ipv4Servers = _mode == DnsMode.classic && _showsIpv4
        ? <String>[
            _primaryIpv4Controller.address,
            _secondaryIpv4Controller.address,
          ]
        : currentSettings.ipv4Servers;
    final ipv6Servers = _mode == DnsMode.classic && _showsIpv6
        ? <String>[
            _primaryIpv6Controller.text.trim(),
            _secondaryIpv6Controller.text.trim(),
          ]
        : currentSettings.ipv6Servers;
    final dohServers = _mode == DnsMode.doh
        ? <String>[_primaryDohController.text.trim()]
        : currentSettings.dohServers;
    final dotServers = _mode == DnsMode.dot
        ? <String>[_primaryDotController.text.trim()]
        : currentSettings.dotServers;

    widget.controller.setDnsSettings(
      DnsSettings(
        mode: _mode,
        ipv4Servers: ipv4Servers,
        ipv6Servers: ipv6Servers,
        dohServers: dohServers,
        dotServers: dotServers,
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
    final errorStyle = theme.textTheme.bodySmall?.copyWith(color: scheme.error);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
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
    required this.enabled,
    this.previousController,
    this.previousFocusNode,
    this.nextController,
    this.nextFocusNode,
    this.errorText,
    this.hintText,
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
  final bool enabled;
  final String? errorText;
  final String? hintText;
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
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
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 6),
              hintText: hintText,
              border: UnderlineInputBorder(
                borderSide: BorderSide(color: scheme.outlineVariant),
              ),
              enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: scheme.outlineVariant),
              ),
              focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: scheme.primary, width: 2),
              ),
              disabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(
                  color: scheme.onSurface.withValues(alpha: 0.12),
                ),
              ),
            ),
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

class _DnsModeSelector extends StatelessWidget {
  const _DnsModeSelector({
    required this.mode,
    required this.enabled,
    required this.supportsDot,
    required this.strings,
    required this.onChanged,
  });

  final DnsMode mode;
  final bool enabled;
  final bool supportsDot;
  final AppStrings strings;
  final ValueChanged<DnsMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final segments = <ButtonSegment<DnsMode>>[
      ButtonSegment<DnsMode>(
        value: DnsMode.classic,
        label: Text(strings.dnsModeClassicLabel),
      ),
      ButtonSegment<DnsMode>(
        value: DnsMode.doh,
        label: Text(strings.dnsModeDohLabel),
      ),
      if (supportsDot)
        ButtonSegment<DnsMode>(
          value: DnsMode.dot,
          label: Text(strings.dnsModeDotLabel),
        ),
    ];
    return Align(
      alignment: Alignment.centerLeft,
      child: SegmentedButton<DnsMode>(
        segments: segments,
        selected: <DnsMode>{mode},
        showSelectedIcon: false,
        onSelectionChanged: enabled
            ? (selection) {
                if (selection.isNotEmpty) {
                  onChanged(selection.first);
                }
              }
            : null,
      ),
    );
  }
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
    final scheme = Theme.of(context).colorScheme;

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
          decoration: InputDecoration(
            counterText: '',
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 6),
            border: UnderlineInputBorder(
              borderSide: BorderSide(color: scheme.outlineVariant),
            ),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: scheme.outlineVariant),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: scheme.primary, width: 2),
            ),
            disabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(
                color: scheme.onSurface.withValues(alpha: 0.12),
              ),
            ),
          ),
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
