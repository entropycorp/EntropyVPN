import 'dart:async';

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

class _AppUpdateNotificationDialogState
    extends State<_AppUpdateNotificationDialog> {
  bool _isOpeningRelease = false;

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
            const SizedBox(height: 26),
            Center(
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
                label: Text(strings.appUpdateOpenReleaseAction),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openRelease() async {
    setState(() {
      _isOpeningRelease = true;
    });

    try {
      await widget.controller.openAppUpdateRelease(widget.update);
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isOpeningRelease = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.strings.appUpdateOpenFailedMessage)),
      );
    }
  }
}

double _updateDialogWidth(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  return width < 420 ? width - 64 : 360;
}
