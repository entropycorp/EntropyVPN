import 'dart:async';
import 'dart:io';

import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:flutter/material.dart';

import 'l10n/app_strings.dart';
import 'main_helpers.dart';
import 'services/app_update_service.dart';
import 'services/vpn_controller.dart';

Future<void> showAppUpdateNotificationDialog(
  BuildContext context, {
  required VpnController controller,
  required AppStrings strings,
  required AppUpdateInfo update,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => _AppUpdateNotificationDialog(
      controller: controller,
      strings: strings,
      update: update,
    ),
  );
}

class _AppUpdateNotificationDialog extends StatefulWidget {
  const _AppUpdateNotificationDialog({
    required this.controller,
    required this.strings,
    required this.update,
  });

  final VpnController controller;
  final AppStrings strings;
  final AppUpdateInfo update;

  @override
  State<_AppUpdateNotificationDialog> createState() =>
      _AppUpdateNotificationDialogState();
}

// Phases of the Windows in-app update flow.
enum _Phase { prompt, downloading, ready, applying, upToDate, failed }

class _AppUpdateNotificationDialogState
    extends State<_AppUpdateNotificationDialog> {
  bool _isOpeningRelease = false;
  _Phase _phase = _Phase.prompt;
  WindowsUpdateStatus? _status;
  String? _errorText;
  Timer? _pollTimer;

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final currentVersion = widget.update.currentVersion;
    final publishedAt = widget.update.publishedAt;

    return AlertDialog(
      title: Row(
        children: <Widget>[
          Icon(Icons.notifications_active_rounded, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(child: Text(strings.appUpdateDialogTitle)),
        ],
      ),
      content: SizedBox(
        width: _updateDialogWidth(context),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              strings.appUpdateAvailableMessage(widget.update.versionLabel),
              style: theme.textTheme.bodyLarge,
            ),
            if (currentVersion != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                strings.appUpdateCurrentVersion(currentVersion),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            if (publishedAt != null) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                strings.appUpdatePublishedAt(formatCompactDate(publishedAt)),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 22),
            Platform.isWindows
                ? _buildWindowsAction(theme, scheme)
                : _buildOpenReleaseAction(scheme),
          ],
        ),
      ),
    );
  }

  // --- Android / other: open the GitHub release page -------------------------

  Widget _buildOpenReleaseAction(ColorScheme scheme) {
    return Center(
      child: FilledButton.icon(
        onPressed: _isOpeningRelease ? null : _openRelease,
        icon: _isOpeningRelease
            ? SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: scheme.onPrimary,
                ),
              )
            : const FaIcon(FontAwesomeIcons.github, size: 18),
        label: Text(widget.strings.appUpdateOpenReleaseAction),
      ),
    );
  }

  Future<void> _openRelease() async {
    setState(() => _isOpeningRelease = true);
    try {
      await widget.controller.openAppUpdateRelease(widget.update);
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _isOpeningRelease = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.strings.appUpdateOpenFailedMessage)),
      );
    }
  }

  // --- Windows: in-app download + install ------------------------------------

  Widget _buildWindowsAction(ThemeData theme, ColorScheme scheme) {
    final strings = widget.strings;
    switch (_phase) {
      case _Phase.prompt:
        // Primary: in-app download. Secondary: an escape hatch to the GitHub
        // release page, in case the user prefers to download the installer
        // themselves (or the in-app updater fails for some reason).
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            FilledButton.icon(
              onPressed: _startDownload,
              icon: const Icon(Icons.download_rounded, size: 18),
              label: Text(strings.appUpdateDownloadAction),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _isOpeningRelease ? null : _openRelease,
              icon: _isOpeningRelease
                  ? SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: scheme.primary,
                      ),
                    )
                  : const FaIcon(FontAwesomeIcons.github, size: 16),
              label: Text(strings.appUpdateOpenReleaseAction),
            ),
          ],
        );
      case _Phase.downloading:
        final fraction = _status?.fraction;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            LinearProgressIndicator(value: fraction),
            const SizedBox(height: 10),
            Text(
              fraction == null
                  ? strings.appUpdatePreparingMessage
                  : strings.appUpdateDownloadingMessage(_status!.percent),
              style: theme.textTheme.bodyMedium,
            ),
          ],
        );
      case _Phase.ready:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(strings.appUpdateReadyMessage,
                style: theme.textTheme.bodyMedium),
            const SizedBox(height: 14),
            Center(
              child: FilledButton.icon(
                onPressed: _apply,
                icon: const Icon(Icons.restart_alt_rounded, size: 18),
                label: Text(strings.appUpdateApplyAction),
              ),
            ),
          ],
        );
      case _Phase.applying:
        return Row(
          children: <Widget>[
            const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(strings.appUpdateInstallingMessage,
                  style: theme.textTheme.bodyMedium),
            ),
          ],
        );
      case _Phase.upToDate:
        return Text(strings.appUpdateUpToDateMessage,
            style: theme.textTheme.bodyMedium);
      case _Phase.failed:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              strings.appUpdateFailedMessage(_errorText ?? ''),
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error),
            ),
            const SizedBox(height: 14),
            Center(
              child: FilledButton.icon(
                onPressed: _startDownload,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text(strings.appUpdateDownloadAction),
              ),
            ),
          ],
        );
    }
  }

  Future<void> _startDownload() async {
    _pollTimer?.cancel();
    setState(() {
      _phase = _Phase.downloading;
      _status = null;
      _errorText = null;
    });

    bool started;
    try {
      started = await widget.controller.startWindowsUpdateDownload();
    } catch (error) {
      _fail(error.toString());
      return;
    }
    if (!started) {
      _fail('the EntropyVPN service is not reachable');
      return;
    }
    if (!mounted) {
      return;
    }
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: 800),
      (_) => unawaited(_poll()),
    );
  }

  Future<void> _poll() async {
    WindowsUpdateStatus status;
    try {
      status = await widget.controller.windowsUpdateStatus();
    } catch (_) {
      return; // transient — retry on the next tick
    }
    if (!mounted) {
      return;
    }
    switch (status.state) {
      case WindowsUpdateState.checking:
      case WindowsUpdateState.downloading:
        setState(() {
          _status = status;
          _phase = _Phase.downloading;
        });
        break;
      case WindowsUpdateState.ready:
        _pollTimer?.cancel();
        setState(() {
          _status = status;
          _phase = _Phase.ready;
        });
        // If the user opted into "automatically install update after
        // downloading", skip the manual "Install and restart" button and
        // kick off the apply right now. _apply() flips _phase to applying
        // and then exits the process so the service can swap files.
        if (widget.controller.autoInstallUpdateAfterDownload) {
          unawaited(_apply());
        }
        break;
      case WindowsUpdateState.applying:
        setState(() => _phase = _Phase.applying);
        break;
      case WindowsUpdateState.idle:
        _pollTimer?.cancel();
        setState(() => _phase = _Phase.upToDate);
        break;
      case WindowsUpdateState.error:
        _fail(status.error ?? 'unknown error');
        break;
    }
  }

  Future<void> _apply() async {
    _pollTimer?.cancel();
    setState(() => _phase = _Phase.applying);
    try {
      await widget.controller.applyWindowsUpdate();
    } catch (error) {
      _fail(error.toString());
      return;
    }
    // The service is now closing this UI to swap files; exit cleanly so it
    // does not have to force-terminate us.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(0);
  }

  void _fail(String message) {
    _pollTimer?.cancel();
    if (!mounted) {
      return;
    }
    setState(() {
      _phase = _Phase.failed;
      _errorText = message;
    });
  }
}

double _updateDialogWidth(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  return width < 420 ? width - 64 : 360;
}
