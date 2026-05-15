import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'l10n/app_strings.dart';
import 'models/dns_settings.dart';
import 'models/split_tunnel.dart';
import 'models/vpn_profile.dart';
import 'services/vpn_controller.dart';

part 'main_settings_common.dart';
part 'main_settings_notifications.dart';
part 'main_settings_dns.dart';
part 'main_settings_split_tunnel.dart';

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
