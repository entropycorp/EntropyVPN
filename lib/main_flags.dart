part of 'main.dart';

class _ServerFlagBadge extends StatefulWidget {
  const _ServerFlagBadge({
    super.key,
    required this.server,
    required this.selected,
    required this.size,
  });

  final String server;
  final bool selected;
  final double size;

  @override
  State<_ServerFlagBadge> createState() => _ServerFlagBadgeState();
}

class _ServerFlagBadgeState extends State<_ServerFlagBadge> {
  static final GeoIpService _geoIpService = GeoIpService();

  late Future<GeoIpInfo?> _lookup;

  @override
  void initState() {
    super.initState();
    _lookup = _geoIpService.resolveServer(widget.server);
  }

  @override
  void didUpdateWidget(covariant _ServerFlagBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.server != widget.server) {
      _lookup = _geoIpService.resolveServer(widget.server);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final backgroundColor = widget.selected
        ? scheme.primaryContainer
        : scheme.surfaceContainerHighest;
    final foregroundColor = widget.selected
        ? scheme.onPrimaryContainer
        : scheme.onSurfaceVariant;

    return FutureBuilder<GeoIpInfo?>(
      future: _lookup,
      builder: (context, snapshot) {
        final info = snapshot.data;
        final fallbackIcon = snapshot.connectionState == ConnectionState.waiting
            ? Icons.travel_explore_rounded
            : Icons.public_rounded;
        final badgeWidth = flagWidthForCountryCode(
          info?.countryCode,
          widget.size,
        );
        final fallbackBadge = SizedBox(
          width: badgeWidth,
          height: widget.size,
          child: Center(
            child: Container(
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                color: backgroundColor,
                borderRadius: BorderRadius.circular(widget.size * 0.33),
                border: Border.all(
                  color: widget.selected
                      ? scheme.primary.withValues(alpha: 0.35)
                      : scheme.outlineVariant.withValues(alpha: 0.34),
                ),
              ),
              alignment: Alignment.center,
              child: Icon(
                fallbackIcon,
                size: widget.size * 0.46,
                color: foregroundColor,
              ),
            ),
          ),
        );

        final Widget badge;
        if (info == null) {
          badge = fallbackBadge;
        } else {
          final flagWidth = badgeWidth;
          final flagHeight = widget.size;
          final flagRadius = math.min(flagWidth, flagHeight) * 0.2;

          badge = SizedBox(
            width: flagWidth,
            height: flagHeight,
            child: _CountryFlagAssetImage(
              countryCode: info.countryCode,
              borderRadius: flagRadius,
              errorChild: DecoratedBox(
                decoration: BoxDecoration(
                  color: backgroundColor,
                  borderRadius: BorderRadius.circular(flagRadius),
                  border: Border.all(
                    color: widget.selected
                        ? scheme.primary.withValues(alpha: 0.35)
                        : scheme.outlineVariant.withValues(alpha: 0.34),
                  ),
                ),
                child: Center(
                  child: Icon(
                    Icons.public_rounded,
                    size: math.min(flagWidth, flagHeight) * 0.46,
                    color: foregroundColor,
                  ),
                ),
              ),
            ),
          );
        }

        final child = SizedBox(
          width: badgeWidth,
          height: widget.size,
          child: badge,
        );

        if (info == null) {
          return child;
        }

        return Tooltip(
          message: info.tooltipLabel,
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.all(Radius.circular(4)),
          ),
          textStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: const Color(0xFF000000),
            fontSize: 12,
          ),
          child: child,
        );
      },
    );
  }
}

const _flagAssetDirectory = 'assets/flags';

class _CountryFlagAssetImage extends StatelessWidget {
  const _CountryFlagAssetImage({
    required this.countryCode,
    required this.borderRadius,
    required this.errorChild,
  });

  static final ScalableImageCache _cache = ScalableImageCache(size: 80);

  final String countryCode;
  final double borderRadius;
  final Widget errorChild;

  @override
  Widget build(BuildContext context) {
    final flagCode = countryCode.trim().toLowerCase();

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: ScalableImageWidget.fromSISource(
        si: ScalableImageSource.fromSvg(
          rootBundle,
          '$_flagAssetDirectory/$flagCode.svg',
          warnF: (_) {},
        ),
        fit: BoxFit.fill,
        cache: _cache,
        onLoading: (_) => errorChild,
        onError: (_) => errorChild,
      ),
    );
  }
}

class _LanguageSelector extends StatelessWidget {
  const _LanguageSelector({required this.controller, required this.strings});

  final VpnController controller;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SegmentedButton<AppLanguage>(
      segments: <ButtonSegment<AppLanguage>>[
        ButtonSegment<AppLanguage>(
          value: AppLanguage.ru,
          icon: Tooltip(
            message: strings.russianLabel,
            child: SizedBox(
              width: 24,
              height: 18,
              child: _CountryFlagAssetImage(
                countryCode: 'RU',
                borderRadius: 4,
                errorChild: const SizedBox.shrink(),
              ),
            ),
          ),
        ),
        ButtonSegment<AppLanguage>(
          value: AppLanguage.en,
          icon: Tooltip(
            message: strings.englishLabel,
            child: SizedBox(
              width: 24,
              height: 18,
              child: _CountryFlagAssetImage(
                countryCode: 'GB',
                borderRadius: 4,
                errorChild: const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ],
      selected: <AppLanguage>{controller.language},
      showSelectedIcon: false,
      style: SegmentedButton.styleFrom(
        foregroundColor: scheme.onSurface,
        selectedForegroundColor: scheme.onSecondaryContainer,
        selectedBackgroundColor: scheme.secondaryContainer,
        backgroundColor: Colors.transparent,
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.3)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        textStyle: theme.textTheme.titleSmall,
      ),
      onSelectionChanged: (selection) {
        if (selection.isNotEmpty) {
          controller.setLanguage(selection.first);
        }
      },
    );
  }
}
