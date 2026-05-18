import 'package:entropy_vpn/utils/flag_aspect_ratio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('uses 4:3 proportions for all country codes', () {
    expect(flagAspectRatioForCountryCode('CH'), 4 / 3);
    expect(flagAspectRatioForCountryCode('VA'), 4 / 3);
    expect(flagAspectRatioForCountryCode('KZ'), 4 / 3);
    expect(flagAspectRatioForCountryCode('QA'), 4 / 3);
    expect(flagAspectRatioForCountryCode('US'), 4 / 3);
    expect(flagAspectRatioForCountryCode('NP'), 4 / 3);
  });

  test('sizes flags from a fixed height using 4:3 proportions', () {
    expect(flagWidthForCountryCode('KZ', 42), 56);
    expect(flagWidthForCountryCode('CH', 42), 56);
    expect(flagWidthForCountryCode('NP', 42), 56);
  });

  test('bundles Lipis 4:3 Kazakhstan SVG art', () async {
    final svg = await rootBundle.loadString('assets/flags/kz.svg');
    final viewBox = _svgViewBox(svg);
    final width = viewBox[2];
    final height = viewBox[3];

    expect(width / height, flagAspectRatioForCountryCode('KZ'));
  });

  test('bundles renderer-friendly USA stars', () async {
    final svg = await rootBundle.loadString('assets/flags/us.svg');

    expect(svg, isNot(contains('<marker')));
    expect(svg, isNot(contains('marker-mid')));
    expect(RegExp(r'9 27-23-17h28l-23 17z').allMatches(svg), hasLength(50));
  });

  testWidgets('renders Lipis 4:3 Kazakhstan PNG without falling back', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 56,
          height: 42,
          child: Image.asset(
            'assets/flags/kz.png',
            fit: BoxFit.fill,
            errorBuilder: (_, _, _) => const Text('flag-error'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('flag-error'), findsNothing);
  });

  testWidgets('renders Lipis 4:3 USA PNG without falling back', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 56,
          height: 42,
          child: Image.asset(
            'assets/flags/us.png',
            fit: BoxFit.fill,
            errorBuilder: (_, _, _) => const Text('flag-error'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('flag-error'), findsNothing);
  });

  test('falls back to 4:3 for unknown country codes', () {
    expect(flagAspectRatioForCountryCode('NL'), defaultFlagAspectRatio);
    expect(flagAspectRatioForCountryCode(''), defaultFlagAspectRatio);
    expect(flagAspectRatioForCountryCode(null), defaultFlagAspectRatio);
  });
}

List<double> _svgViewBox(String svg) {
  final match = RegExp(r'\bviewBox="([^"]+)"').firstMatch(svg);
  if (match == null) {
    throw StateError('Missing SVG viewBox.');
  }
  return match
      .group(1)!
      .split(RegExp(r'\s+'))
      .map(double.parse)
      .toList(growable: false);
}
