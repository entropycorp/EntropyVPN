import 'dart:async';

import 'package:flutter/material.dart';

import 'l10n/app_strings.dart';
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

class _SettingsNavigationTile extends StatelessWidget {
  const _SettingsNavigationTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
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
