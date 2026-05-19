part of 'main_settings.dart';

class UpdatesSettingsTile extends StatelessWidget {
  const UpdatesSettingsTile({
    super.key,
    required this.strings,
    required this.onTap,
  });

  final AppStrings strings;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _SettingsNavigationTile(
      icon: Icons.system_update_alt_rounded,
      title: strings.updatesSettingsLabel,
      enabled: true,
      onTap: onTap,
    );
  }
}

class UpdatesSettingsSubPage extends StatefulWidget {
  const UpdatesSettingsSubPage({
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
  State<UpdatesSettingsSubPage> createState() => _UpdatesSettingsSubPageState();
}

class _UpdatesSettingsSubPageState extends State<UpdatesSettingsSubPage> {
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
            icon: Icons.system_update_alt_rounded,
            title: widget.strings.updatesSettingsLabel,
            onBack: widget.onBack,
          ),
        ),
        if (widget.controller.supportsAutoInstallUpdate) ...<Widget>[
          SizedBox(height: widget.gap),
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: widget.horizontalPadding,
              vertical: widget.verticalPadding,
            ),
            child: _SettingsCheckboxTile(
              title: widget.strings.autoInstallUpdateLabel,
              value: widget.controller.autoInstallUpdateAfterDownload,
              onChanged: _setAutoInstallUpdate,
            ),
          ),
        ],
        SizedBox(height: widget.gap),
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: widget.horizontalPadding,
            vertical: widget.verticalPadding,
          ),
          child: _CheckForUpdatesTile(
            controller: widget.controller,
            strings: widget.strings,
          ),
        ),
      ],
    );
  }

  void _setAutoInstallUpdate(bool value) {
    widget.controller.setAutoInstallUpdateAfterDownload(value);
    setState(() {});
  }
}

class _CheckForUpdatesTile extends StatefulWidget {
  const _CheckForUpdatesTile({
    required this.controller,
    required this.strings,
  });

  final VpnController controller;
  final AppStrings strings;

  @override
  State<_CheckForUpdatesTile> createState() => _CheckForUpdatesTileState();
}

class _CheckForUpdatesTileState extends State<_CheckForUpdatesTile> {
  bool _isChecking = false;

  Future<void> _check() async {
    if (_isChecking) {
      return;
    }
    setState(() => _isChecking = true);
    final messenger = ScaffoldMessenger.of(context);

    await widget.controller.checkForAppUpdate(force: true);

    if (!mounted) {
      return;
    }
    setState(() => _isChecking = false);

    final update = widget.controller.availableAppUpdate;
    if (update == null) {
      messenger.showSnackBar(
        SnackBar(content: Text(widget.strings.appUpdateUpToDateMessage)),
      );
      return;
    }

    // The auto-flow in main_shell will show the dialog when in-app
    // notifications are enabled and this update hasn't been shown yet.
    // Otherwise, surface it manually so tapping the button always gives
    // feedback when an update is available.
    if (widget.controller.pendingAppUpdateNotification != null) {
      return;
    }
    await showAppUpdateNotificationDialog(
      context,
      controller: widget.controller,
      strings: widget.strings,
      update: update,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final disabledColor = scheme.onSurface.withValues(alpha: 0.38);
    final titleColor = _isChecking ? disabledColor : scheme.onSurface;
    final iconColor = _isChecking ? disabledColor : scheme.primary;

    return Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: _isChecking ? null : () => unawaited(_check()),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: <Widget>[
              SizedBox.square(
                dimension: 24,
                child: Center(
                  child: _isChecking
                      ? SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: scheme.primary,
                          ),
                        )
                      : Icon(Icons.refresh_rounded, color: iconColor),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  widget.strings.checkForUpdatesAction,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: titleColor,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
