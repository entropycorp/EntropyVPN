import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'l10n/app_strings.dart';
import 'main_flags.dart';
import 'main_helpers.dart';
import 'main_input.dart';
import 'main_settings.dart';
import 'services/vpn_controller.dart';

enum _SettingsPage { root, notifications }

class SettingsPageBody extends StatefulWidget {
  const SettingsPageBody({
    super.key,
    required this.controller,
    required this.strings,
  });

  final VpnController controller;
  final AppStrings strings;

  @override
  State<SettingsPageBody> createState() => _SettingsPageBodyState();
}

class _SettingsPageBodyState extends State<SettingsPageBody> {
  _SettingsPage _page = _SettingsPage.root;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 520;
        final panelMaxWidth = constraints.maxWidth >= 1650
            ? 1120.0
            : constraints.maxWidth >= 1250
            ? 960.0
            : 760.0;
        final settingsHorizontalPadding = isCompact ? 6.0 : 24.0;
        final settingsVerticalPadding = isCompact ? 4.0 : 6.0;
        final settingsGap = isCompact ? 4.0 : 6.0;

        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          layoutBuilder: (currentChild, previousChildren) {
            final children = <Widget>[...previousChildren];
            if (currentChild != null) {
              children.add(currentChild);
            }
            return Stack(
              alignment: Alignment.topCenter,
              clipBehavior: Clip.none,
              children: children,
            );
          },
          child: _SettingsScrollPage(
            key: ValueKey<_SettingsPage>(_page),
            pageStorageKey: PageStorageKey<String>(switch (_page) {
              _SettingsPage.root => 'settings-scroll',
              _SettingsPage.notifications => 'settings-notifications-scroll',
            }),
            panelMaxWidth: panelMaxWidth,
            child: _page == _SettingsPage.notifications
                ? NotificationSettingsSubPage(
                    controller: widget.controller,
                    strings: widget.strings,
                    onBack: _showRootSettings,
                    horizontalPadding: settingsHorizontalPadding,
                    verticalPadding: settingsVerticalPadding,
                    gap: settingsGap,
                  )
                : _SettingsRootPage(
                    controller: widget.controller,
                    strings: widget.strings,
                    horizontalPadding: settingsHorizontalPadding,
                    verticalPadding: settingsVerticalPadding,
                    gap: settingsGap,
                    onOpenNotifications: _showNotificationSettings,
                  ),
          ),
        );
      },
    );
  }

  void _showRootSettings() {
    setState(() {
      _page = _SettingsPage.root;
    });
  }

  void _showNotificationSettings() {
    setState(() {
      _page = _SettingsPage.notifications;
    });
  }
}

class _SettingsScrollPage extends StatelessWidget {
  const _SettingsScrollPage({
    super.key,
    required this.pageStorageKey,
    required this.panelMaxWidth,
    required this.child,
  });

  final PageStorageKey<String> pageStorageKey;
  final double panelMaxWidth;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      key: pageStorageKey,
      padding: EdgeInsets.zero,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: panelMaxWidth),
          child: child,
        ),
      ),
    );
  }
}

class _SettingsRootPage extends StatelessWidget {
  const _SettingsRootPage({
    required this.controller,
    required this.strings,
    required this.horizontalPadding,
    required this.verticalPadding,
    required this.gap,
    required this.onOpenNotifications,
  });

  final VpnController controller;
  final AppStrings strings;
  final double horizontalPadding;
  final double verticalPadding;
  final double gap;
  final VoidCallback onOpenNotifications;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _SettingsSectionHeader(
          title: strings.appSettingsCategoryLabel,
          horizontalPadding: horizontalPadding,
          verticalPadding: verticalPadding,
        ),
        SizedBox(height: gap),
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: horizontalPadding,
            vertical: verticalPadding,
          ),
          child: _LanguageSettingsTile(
            controller: controller,
            strings: strings,
          ),
        ),
        SizedBox(height: gap),
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: horizontalPadding,
            vertical: verticalPadding,
          ),
          child: NotificationSettingsTile(
            strings: strings,
            onTap: onOpenNotifications,
          ),
        ),
        SizedBox(height: gap),
        _SettingsSectionHeader(
          title: strings.vpnSettingsCategoryLabel,
          horizontalPadding: horizontalPadding,
          verticalPadding: verticalPadding,
        ),
        SizedBox(height: gap),
        if (controller.supportsTrafficModeSelection) ...<Widget>[
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: horizontalPadding,
              vertical: verticalPadding,
            ),
            child: TrafficModeSelector(
              controller: controller,
              strings: strings,
            ),
          ),
          SizedBox(height: gap),
        ],
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: horizontalPadding,
            vertical: verticalPadding,
          ),
          child: TunIpModeSelector(controller: controller, strings: strings),
        ),
        SizedBox(height: gap),
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: horizontalPadding,
            vertical: verticalPadding,
          ),
          child: DnsSettingsTile(controller: controller, strings: strings),
        ),
        SizedBox(height: gap),
        if (controller.supportsSplitTunneling) ...<Widget>[
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: horizontalPadding,
              vertical: verticalPadding,
            ),
            child: SplitTunnelSettingsTile(
              controller: controller,
              strings: strings,
            ),
          ),
          SizedBox(height: gap),
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: horizontalPadding,
              vertical: verticalPadding,
            ),
            child: DomainSplitTunnelSettingsTile(
              controller: controller,
              strings: strings,
            ),
          ),
          SizedBox(height: gap),
        ],
        SizedBox(height: gap),
      ],
    );
  }
}

class _LanguageSettingsTile extends StatelessWidget {
  const _LanguageSettingsTile({
    required this.controller,
    required this.strings,
  });

  final VpnController controller;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: <Widget>[
            Icon(Icons.language_rounded, color: scheme.primary),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                strings.languageSettingsLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
            ),
            const SizedBox(width: 12),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: LanguageSelector(controller: controller, strings: strings),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsSectionHeader extends StatelessWidget {
  const _SettingsSectionHeader({
    required this.title,
    required this.horizontalPadding,
    required this.verticalPadding,
  });

  final String title;
  final double horizontalPadding;
  final double verticalPadding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final headerColor = scheme.onSurfaceVariant.withValues(alpha: 0.86);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        horizontalPadding + 4,
        verticalPadding + 4,
        horizontalPadding + 4,
        verticalPadding,
      ),
      child: Row(
        children: <Widget>[
          Text(
            title.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(
              color: headerColor,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Divider(
              color: scheme.outlineVariant.withValues(alpha: 0.42),
            ),
          ),
        ],
      ),
    );
  }
}

class AddSourcePageBody extends StatelessWidget {
  const AddSourcePageBody({
    super.key,
    required this.controller,
    required this.strings,
    required this.textController,
  });

  final VpnController controller;
  final AppStrings strings;
  final TextEditingController textController;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final panelMaxWidth = constraints.maxWidth >= 1250 ? 820.0 : 720.0;

        return SingleChildScrollView(
          key: const PageStorageKey<String>('add-source-scroll'),
          padding: EdgeInsets.zero,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: panelMaxWidth),
              child: InputPanel(
                controller: controller,
                strings: strings,
                textController: textController,
              ),
            ),
          ),
        );
      },
    );
  }
}

class LogsPageBody extends StatelessWidget {
  const LogsPageBody({
    super.key,
    required this.controller,
    required this.strings,
  });

  final VpnController controller;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final panelMaxWidth = constraints.maxWidth >= 1650
            ? 1460.0
            : constraints.maxWidth >= 1250
            ? 1220.0
            : 1040.0;

        return SingleChildScrollView(
          key: const PageStorageKey<String>('logs-scroll'),
          padding: EdgeInsets.zero,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: panelMaxWidth),
              child: _RuntimeLogsPanel(
                controller: controller,
                strings: strings,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RuntimeLogsPanel extends StatelessWidget {
  const _RuntimeLogsPanel({required this.controller, required this.strings});

  final VpnController controller;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final logs = controller.runtimeLogs;
    final canCopyLogs = logs.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(strings.logsLabel, style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            height: 220,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.44),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.24),
              ),
            ),
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 42),
                    child: logs.isEmpty
                        ? Align(
                            alignment: Alignment.topLeft,
                            child: Text(
                              strings.noLogsYet,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          )
                        : ListView.separated(
                            reverse: true,
                            itemCount: logs.length,
                            separatorBuilder: (context, index) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final line = logs[logs.length - 1 - index];
                              return Text(
                                line,
                                style: monoStyle(
                                  theme,
                                  color: scheme.onSurface,
                                  fontSize: 12.2,
                                  weight: FontWeight.w500,
                                ),
                              );
                            },
                          ),
                  ),
                ),
                Align(
                  alignment: Alignment.topRight,
                  child: Tooltip(
                    message: strings.copyLogsAction,
                    child: IconButton(
                      onPressed: canCopyLogs
                          ? () async {
                              await Clipboard.setData(
                                ClipboardData(text: controller.runtimeLogsText),
                              );
                              if (!context.mounted) {
                                return;
                              }
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(strings.logsCopiedMessage),
                                ),
                              );
                            }
                          : null,
                      icon: const Icon(Icons.content_copy_rounded, size: 17),
                      style: IconButton.styleFrom(
                        fixedSize: const Size(34, 34),
                        minimumSize: const Size(34, 34),
                        maximumSize: const Size(34, 34),
                        padding: EdgeInsets.zero,
                        backgroundColor: Colors.transparent,
                        disabledBackgroundColor: Colors.transparent,
                        focusColor: Colors.transparent,
                        hoverColor: scheme.onSurface.withValues(alpha: 0.12),
                        highlightColor: scheme.onSurface.withValues(
                          alpha: 0.16,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
