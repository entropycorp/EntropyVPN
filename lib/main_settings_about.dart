part of 'main_settings.dart';

const String _aboutGithubUrl = 'https://github.com/entropycorp/EntropyVPN';
const String _aboutGithubDisplayText = 'EntropyVPN';

class AboutSettingsTile extends StatelessWidget {
  const AboutSettingsTile({
    super.key,
    required this.controller,
    required this.strings,
  });

  final VpnController controller;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    return _SettingsNavigationTile(
      icon: Icons.info_outline_rounded,
      title: strings.aboutAppLabel,
      enabled: true,
      onTap: () => unawaited(
        _showAboutAppDialog(context, controller: controller, strings: strings),
      ),
    );
  }
}

Future<void> _showAboutAppDialog(
  BuildContext context, {
  required VpnController controller,
  required AppStrings strings,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) =>
        _AboutAppDialog(controller: controller, strings: strings),
  );
}

class _AboutAppDialog extends StatefulWidget {
  const _AboutAppDialog({required this.controller, required this.strings});

  final VpnController controller;
  final AppStrings strings;

  @override
  State<_AboutAppDialog> createState() => _AboutAppDialogState();
}

class _AboutAppDialogState extends State<_AboutAppDialog> {
  String? _xrayVersion;
  String? _singBoxVersion;
  bool _versionsLoaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadCoreVersions());
  }

  Future<void> _loadCoreVersions() async {
    final results = await Future.wait<String?>(<Future<String?>>[
      widget.controller.probeCoreVersion(CoreFlavor.xray),
      widget.controller.probeCoreVersion(CoreFlavor.singBox),
    ]);
    if (!mounted) {
      return;
    }
    setState(() {
      _xrayVersion = results[0];
      _singBoxVersion = results[1];
      _versionsLoaded = true;
    });
  }

  Future<void> _openGithub() async {
    await launchUrl(
      Uri.parse(_aboutGithubUrl),
      mode: LaunchMode.externalApplication,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return AlertDialog(
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => unawaited(_openGithub()),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  FaIcon(
                    FontAwesomeIcons.github,
                    size: 18,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      _aboutGithubDisplayText,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          _CoreVersionRow(
            label: 'Xray',
            version: _xrayVersion,
            loaded: _versionsLoaded,
          ),
          _CoreVersionRow(
            label: 'Sing-box',
            version: _singBoxVersion,
            loaded: _versionsLoaded,
          ),
        ],
      ),
    );
  }
}

class _CoreVersionRow extends StatelessWidget {
  const _CoreVersionRow({
    required this.label,
    required this.version,
    required this.loaded,
  });

  final String label;
  final String? version;
  final bool loaded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mutedColor = scheme.onSurface.withValues(alpha: 0.7);

    final String trailing;
    if (!loaded) {
      trailing = '…';
    } else if (version == null) {
      trailing = '—';
    } else {
      trailing = version!;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(color: mutedColor),
            ),
          ),
          Text(
            trailing,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurface,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
