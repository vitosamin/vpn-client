import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/directories.dart';
import 'package:hiddify/core/model/region.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/route_rules/data/bundled_geo_rules.dart';
import 'package:hiddify/features/route_rules/data/effective_route_rules.dart';
import 'package:hiddify/features/route_rules/notifier/rules_notifier.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/hiddifycore/generated/v2/config/route_rule.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The rules file lives in [dir], as in the app's base directory.
class _Directories extends AppDirectories {
  _Directories(this.dir);

  final Directory dir;

  @override
  Future<Directories> build() async => (baseDir: dir, workingDir: dir, tempDir: dir);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUpAll(() async {
    await BundledGeoRules.load();
  });

  setUp(() {
    dir = Directory.systemTemp.createTempSync('bundled_geo_rules_test');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  /// The app's providers with [region] saved; null means a fresh install with no region saved.
  Future<ProviderContainer> open({Region? region = Region.ru, Map<String, Object> saved = const {}}) async {
    SharedPreferences.setMockInitialValues({if (region != null) 'region': region.name, ...saved});
    final container = ProviderContainer(
      overrides: [
        appDirectoriesProvider.overrideWith(() => _Directories(dir)),
        translationsProvider.overrideWith((ref) => AppLocale.en.build()),
      ],
    );
    addTearDown(container.dispose);
    await container.read(appDirectoriesProvider.future);
    await container.read(sharedPreferencesProvider.future);
    await container.read(translationsProvider.future);
    container.listen(rulesNotifierProvider, (_, _) {});
    return container;
  }

  group('the bundled lists', () {
    test('are loaded from assets and keep the country entries', () {
      final geo = BundledGeoRules.instance;
      expect(geo.domains, isNotEmpty);
      expect(geo.domainSuffixes, contains('yandex.ru'));
      expect(geo.domainSuffixes, contains('vk.com'));
      expect(geo.domainSuffixes, contains('gosuslugi.ru'));
      expect(geo.ipCidrs.length, greaterThan(20000));
      expect(geo.ipCidrs, contains('98.98.136.0/22'));
      // one malformed entry would make the core drop the rule's whole IP condition silently
      final malformed = geo.ipCidrs.where((cidr) => !RegExp(r'^[0-9a-fA-F:.]+/\d{1,3}$').hasMatch(cidr));
      expect(malformed, isEmpty);
    });
  });

  group('the region rule', () {
    test('is built from the bundled lists for Russia, without a remote rule-set', () {
      final rule = BuiltinRule.bypassRegion.rule(Region.ru);
      expect(rule.outbound, Outbound.direct);
      expect(rule.ruleSets, isEmpty);
      expect(rule.domains, BundledGeoRules.instance.domains);
      expect(rule.domainSuffixes, BundledGeoRules.instance.domainSuffixes);
    });

    test('stays a remote rule-set for every other region', () {
      final rule = BuiltinRule.bypassRegion.rule(Region.ir);
      expect(rule.outbound, Outbound.direct);
      expect(rule.ruleSets, [
        'https://raw.githubusercontent.com/hiddify/hiddify-geo/rule-set/country/geosite-{region}.srs',
        'https://raw.githubusercontent.com/hiddify/hiddify-geo/rule-set/country/geoip-{region}.srs',
      ]);
      expect(rule.domains, isEmpty);
    });
  });

  group('the rules the core gets', () {
    List<Rule> rulesOf(ProviderContainer container) => container.read(rulesNotifierProvider);

    test('hold the RU domains and the RU ranges as two direct rules', () async {
      final rules = effectiveRouteRules(rulesOf(await open()));

      final names = [for (final rule in rules) rule.name];
      expect(names, ['builtin:bypassLan', 'builtin:blockAds', 'builtin:bypassRegion', 'builtin:bypassRegion:ip']);
      expect([for (final rule in rules) rule.listOrder], [0, 1, 2, 3]);

      final domainsRule = rules[2];
      expect(domainsRule.outbound, Outbound.direct);
      expect(domainsRule.ruleSets, isEmpty);
      expect(domainsRule.domainSuffixes, contains('yandex.ru'));
      // a rule with IP ranges gets no direct DNS rule from the core, so names go alone
      expect(domainsRule.ipCidrs, isEmpty);

      final rangesRule = rules[3];
      expect(rangesRule.outbound, Outbound.direct);
      expect(rangesRule.domains, isEmpty);
      expect(rangesRule.domainSuffixes, isEmpty);
      expect(rangesRule.ipCidrs, BundledGeoRules.instance.ipCidrs);
    });

    test('keep the remote rule-set for a region with no bundled lists', () async {
      final rules = effectiveRouteRules(rulesOf(await open(region: Region.ir)));
      expect([for (final rule in rules) rule.name], ['builtin:bypassLan', 'builtin:blockAds', 'builtin:bypassRegion']);
      expect(rules.last.ruleSets, isNotEmpty);
    });

    test('add no ranges when the region rule is switched off', () async {
      final container = await open();
      await container.read(rulesNotifierProvider.notifier).updateEnabled(false, 2);
      final rules = effectiveRouteRules(rulesOf(container));
      expect([for (final rule in rules) rule.name], ['builtin:bypassLan', 'builtin:blockAds', 'builtin:bypassRegion']);
    });

    test('reach the core as the config options it builds', () async {
      final container = await open();
      final options = container.read(ConfigOptions.singboxConfigOptions);
      final rules = (options.routeRule['rules']! as List).cast<Map<String, dynamic>>();

      final regionRule = rules.firstWhere((rule) => rule['name'] == 'builtin:bypassRegion');
      expect(regionRule['outbound'], 'direct');
      expect(regionRule.containsKey('rule_set'), isFalse);
      expect(regionRule['domain_suffix'], contains('yandex.ru'));

      final rangesRule = rules.firstWhere((rule) => rule['name'] == 'builtin:bypassRegion:ip');
      expect(rangesRule['outbound'], 'direct');
      expect((rangesRule['ip_cidr']! as List).length, greaterThan(20000));
      expect(rangesRule.containsKey('rule_set'), isFalse);

      // nothing in the default options asks GitHub for the RU lists
      final remote = rules.expand((rule) => (rule['rule_set'] as List?) ?? const []).cast<String>();
      expect(remote.where((url) => url.contains('country/geosite-{region}')), isEmpty);
    });

    test('come from the default region on a new install', () async {
      final container = await open(region: null);
      expect(container.read(ConfigOptions.region), Region.ru);
      final rules = rulesOf(container);
      expect([for (final rule in rules) rule.name], ['builtin:bypassLan', 'builtin:blockAds', 'builtin:bypassRegion']);
      expect(rules[2].enabled, isTrue);
    });
  });
}
