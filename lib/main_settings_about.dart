part of 'main_settings.dart';

const String _aboutGithubUrl = 'https://github.com/entropycorp/EntropyVPN';
const String _aboutGithubDisplayText = 'EntropyVPN';

class AboutSettingsTile extends StatelessWidget {
  const AboutSettingsTile({super.key, required this.strings});

  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    return _SettingsNavigationTile(
      icon: Icons.info_outline_rounded,
      title: strings.aboutAppLabel,
      enabled: true,
      onTap: () => unawaited(_showAboutAppDialog(context, strings: strings)),
    );
  }
}

Future<void> _showAboutAppDialog(
  BuildContext context, {
  required AppStrings strings,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => _AboutAppDialog(strings: strings),
  );
}

class _AboutAppDialog extends StatelessWidget {
  const _AboutAppDialog({required this.strings});

  final AppStrings strings;

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
      title: Text(strings.aboutAppLabel),
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
                        decoration: TextDecoration.underline,
                        decorationColor: scheme.primary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
