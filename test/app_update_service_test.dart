import 'package:entropy_vpn/services/app_update_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AppVersion compares release tags against app versions', () {
    final current = AppVersion.tryParse('1.3.1+7');
    final sameRelease = AppVersion.tryParse('v1.3.1');
    final newerPatch = AppVersion.tryParse('v1.3.2');
    final newerMinor = AppVersion.tryParse('EntropyVPN 1.4.0');

    expect(current, isNotNull);
    expect(sameRelease, isNotNull);
    expect(newerPatch, isNotNull);
    expect(newerMinor, isNotNull);
    expect(sameRelease!.compareTo(current!), 0);
    expect(newerPatch!.compareTo(current), greaterThan(0));
    expect(newerMinor!.compareTo(current), greaterThan(0));
  });

  test('AppVersion keeps prereleases lower than final releases', () {
    final beta = AppVersion.tryParse('v2.0.0-beta.1');
    final stable = AppVersion.tryParse('2.0.0');

    expect(beta, isNotNull);
    expect(stable, isNotNull);
    expect(beta!.compareTo(stable!), lessThan(0));
  });
}
