import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'l10n/app_strings.dart';
import 'main_helpers.dart';
import 'main_input.dart';
import 'main_settings.dart';
import 'services/vpn_controller.dart';

class SettingsPageBody extends StatelessWidget {
  const SettingsPageBody({
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
        final isCompact = constraints.maxWidth < 520;
        final panelMaxWidth = constraints.maxWidth >= 1650
            ? 1120.0
            : constraints.maxWidth >= 1250
            ? 960.0
            : 760.0;
        final settingsHorizontalPadding = isCompact ? 6.0 : 24.0;
        final settingsVerticalPadding = isCompact ? 4.0 : 6.0;
        final settingsGap = isCompact ? 4.0 : 6.0;

        return SingleChildScrollView(
          key: const PageStorageKey<String>('settings-scroll'),
          padding: EdgeInsets.zero,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: panelMaxWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (controller.supportsTrafficModeSelection) ...<Widget>[
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: settingsHorizontalPadding,
                        vertical: settingsVerticalPadding,
                      ),
                      child: TrafficModeSelector(
                        controller: controller,
                        strings: strings,
                      ),
                    ),
                    SizedBox(height: settingsGap),
                  ],
                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: settingsHorizontalPadding,
                      vertical: settingsVerticalPadding,
                    ),
                    child: TunIpModeSelector(
                      controller: controller,
                      strings: strings,
                    ),
                  ),
                  SizedBox(height: settingsGap),
                  if (controller.supportsSplitTunneling) ...<Widget>[
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: settingsHorizontalPadding,
                        vertical: settingsVerticalPadding,
                      ),
                      child: SplitTunnelSettingsTile(
                        controller: controller,
                        strings: strings,
                      ),
                    ),
                    SizedBox(height: settingsGap),
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: settingsHorizontalPadding,
                        vertical: settingsVerticalPadding,
                      ),
                      child: DomainSplitTunnelSettingsTile(
                        controller: controller,
                        strings: strings,
                      ),
                    ),
                    SizedBox(height: settingsGap),
                  ],
                ],
              ),
            ),
          ),
        );
      },
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
