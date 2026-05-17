part of 'main_settings.dart';

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
  late Future<List<_IndexedSplitTunnelApp>> _appsFuture;
  late final TextEditingController _searchController;
  late final FocusNode _searchFocusNode;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _searchFocusNode = FocusNode();
    _appsFuture = _loadIndexedAppCatalog();
  }

  Future<List<_IndexedSplitTunnelApp>> _loadIndexedAppCatalog({
    bool refresh = false,
  }) async {
    final apps = await widget.controller.loadSplitTunnelAppCatalog(
      refresh: refresh,
    );
    return apps
        .map(_IndexedSplitTunnelApp.fromApp)
        .toList(growable: false);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
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
    final dialogWidth = _splitTunnelDialogWidth(
      context,
      minWidth: 360,
      maxWidth: 720,
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
        width: dialogWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
              ListenableBuilder(
                listenable: _searchFocusNode,
                builder: (context, _) => TextField(
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  decoration: InputDecoration(
                    hintText: _searchFocusNode.hasFocus
                        ? null
                        : strings.splitTunnelSearchHint,
                  ),
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
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: FutureBuilder<List<_IndexedSplitTunnelApp>>(
                  future: _appsFuture,
                  builder: (context, snapshot) {
                    final merged = _mergeIndexedApps(
                      snapshot.data ?? const <_IndexedSplitTunnelApp>[],
                      selectedApps,
                      selectedAppIds,
                    );
                    final isWaiting =
                        snapshot.connectionState == ConnectionState.waiting;

                    return ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _searchController,
                      builder: (context, value, _) {
                        final apps = _filterIndexedApps(merged, value.text);

                        if (isWaiting && apps.isEmpty) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(vertical: 24),
                            child: Center(child: CircularProgressIndicator()),
                          );
                        }

                        if (apps.isEmpty) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 24),
                            child: _SplitTunnelEmptyState(
                              message: strings.splitTunnelNoAppsFound,
                            ),
                          );
                        }

                        return ListView.separated(
                          shrinkWrap: true,
                          itemCount: apps.length,
                          separatorBuilder: (context, index) =>
                              const SizedBox(height: 2),
                          itemBuilder: (context, index) {
                            final app = apps[index].app;
                            final selected = selectedAppIds.contains(app.id);
                            final enabled =
                                controller.canChangeSplitTunnel &&
                                controller.splitTunnelMode !=
                                    SplitTunnelMode.off;
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
                              controlAffinity:
                                  ListTileControlAffinity.leading,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                            );
                          },
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
      _appsFuture = _loadIndexedAppCatalog(refresh: true);
    });
  }

  List<_IndexedSplitTunnelApp> _mergeIndexedApps(
    List<_IndexedSplitTunnelApp> catalogApps,
    List<SplitTunnelApp> selectedApps,
    Set<String> selectedAppIds,
  ) {
    final appsById = <String, _IndexedSplitTunnelApp>{
      for (final app in selectedApps)
        app.id: _IndexedSplitTunnelApp.fromApp(app),
    };
    for (final indexed in catalogApps) {
      appsById[indexed.app.id] = indexed;
    }
    final apps = appsById.values.toList(growable: false);
    apps.sort(
      (left, right) => _compareIndexedApps(left, right, selectedAppIds),
    );
    return apps;
  }

  int _compareIndexedApps(
    _IndexedSplitTunnelApp left,
    _IndexedSplitTunnelApp right,
    Set<String> selectedAppIds,
  ) {
    final leftSelected = selectedAppIds.contains(left.app.id);
    final rightSelected = selectedAppIds.contains(right.app.id);
    if (leftSelected != rightSelected) {
      return leftSelected ? -1 : 1;
    }

    final byName = left.nameLower.compareTo(right.nameLower);
    if (byName != 0) {
      return byName;
    }
    return left.pathLower.compareTo(right.pathLower);
  }

  List<_IndexedSplitTunnelApp> _filterIndexedApps(
    List<_IndexedSplitTunnelApp> apps,
    String rawQuery,
  ) {
    final query = rawQuery.trim().toLowerCase();
    if (query.isEmpty) {
      return apps;
    }
    return apps
        .where(
          (indexed) =>
              indexed.nameLower.contains(query) ||
              indexed.pathLower.contains(query),
        )
        .toList(growable: false);
  }
}

class _IndexedSplitTunnelApp {
  const _IndexedSplitTunnelApp({
    required this.app,
    required this.nameLower,
    required this.pathLower,
  });

  factory _IndexedSplitTunnelApp.fromApp(SplitTunnelApp app) {
    return _IndexedSplitTunnelApp(
      app: app,
      nameLower: app.name.toLowerCase(),
      pathLower: app.path.toLowerCase(),
    );
  }

  final SplitTunnelApp app;
  final String nameLower;
  final String pathLower;
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
  late final FocusNode _domainFocusNode;

  @override
  void initState() {
    super.initState();
    _domainController = TextEditingController();
    _domainFocusNode = FocusNode();
  }

  @override
  void dispose() {
    _domainController.dispose();
    _domainFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    final controller = widget.controller;
    final domains = controller.domainSplitTunnelDomains;
    final domainSplitTunnelEnabled =
        controller.domainSplitTunnelMode != SplitTunnelMode.off;
    final dialogWidth = _splitTunnelDialogWidth(
      context,
      minWidth: 360,
      maxWidth: 640,
    );
    final canEditDomains =
        controller.canChangeSplitTunnel &&
        controller.domainSplitTunnelMode != SplitTunnelMode.off;

    return AlertDialog(
      title: Text(strings.domainSplitTunnelLabel),
      content: SizedBox(
        width: dialogWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
                    child: ListenableBuilder(
                      listenable: _domainFocusNode,
                      builder: (context, _) => TextField(
                        controller: _domainController,
                        focusNode: _domainFocusNode,
                        enabled: canEditDomains,
                        decoration: InputDecoration(
                          hintText: _domainFocusNode.hasFocus
                              ? null
                              : strings.domainSplitTunnelInputHint,
                        ),
                        onSubmitted:
                            canEditDomains ? (_) => _addDomain() : null,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _domainController,
                    builder: (context, value, _) {
                      final canAddDomain =
                          canEditDomains && value.text.trim().isNotEmpty;
                      return IconButton.filledTonal(
                        tooltip: strings.domainSplitTunnelAddTooltip,
                        onPressed: canAddDomain ? _addDomain : null,
                        icon: const Icon(Icons.add_rounded),
                      );
                    },
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
              if (domains.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: _SplitTunnelEmptyState(
                    message: strings.domainSplitTunnelNoDomains,
                  ),
                )
              else
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 260),
                  child: ListView.separated(
                    shrinkWrap: true,
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
                                    controller.removeDomainSplitTunnelDomain(
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
