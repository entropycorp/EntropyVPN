part of 'main_settings.dart';

class NotificationSettingsTile extends StatelessWidget {
  const NotificationSettingsTile({
    super.key,
    required this.strings,
    required this.onTap,
  });

  final AppStrings strings;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _SettingsNavigationTile(
      icon: Icons.notifications_rounded,
      title: strings.notificationsSettingsLabel,
      enabled: true,
      onTap: onTap,
    );
  }
}

class NotificationSettingsSubPage extends StatefulWidget {
  const NotificationSettingsSubPage({
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
  State<NotificationSettingsSubPage> createState() =>
      _NotificationSettingsSubPageState();
}

class _NotificationSettingsSubPageState
    extends State<NotificationSettingsSubPage> {
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
            icon: Icons.notifications_rounded,
            title: widget.strings.notificationsSettingsLabel,
            onBack: widget.onBack,
          ),
        ),
        SizedBox(height: widget.gap),
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: widget.horizontalPadding,
            vertical: widget.verticalPadding,
          ),
          child: _SettingsCheckboxTile(
            title: widget.strings.inAppUpdateNotificationsLabel,
            value: widget.controller.showInAppUpdateNotifications,
            onChanged: _setInAppUpdateNotifications,
          ),
        ),
        if (widget.controller.supportsAndroidUpdateNotifications) ...<Widget>[
          SizedBox(height: widget.gap),
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: widget.horizontalPadding,
              vertical: widget.verticalPadding,
            ),
            child: _SettingsCheckboxTile(
              title: widget.strings.androidUpdateNotificationsLabel,
              value: widget.controller.showAndroidUpdateNotifications,
              onChanged: _setAndroidUpdateNotifications,
            ),
          ),
        ],
      ],
    );
  }

  void _setInAppUpdateNotifications(bool value) {
    widget.controller.setShowInAppUpdateNotifications(value);
    setState(() {});
  }

  void _setAndroidUpdateNotifications(bool value) {
    widget.controller.setShowAndroidUpdateNotifications(value);
    setState(() {});
  }
}
