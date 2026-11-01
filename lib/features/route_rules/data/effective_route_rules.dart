import 'package:hiddify/features/route_rules/data/bundled_geo_rules.dart';
import 'package:hiddify/features/route_rules/data/bundled_service_rules.dart';
import 'package:hiddify/features/route_rules/notifier/rules_notifier.dart';
import 'package:hiddify/hiddifycore/generated/v2/config/route_rule.pb.dart';

/// The app's list as sing-box should see it.
///
/// The core turns one rule of the list into one sing-box rule, and it adds the "resolve with the
/// direct DNS" DNS rule only for a rule that matches on names alone: a rule with IP ranges is not
/// given one, as a DNS query has no destination address to check. The bundled region rule matches
/// domains and IP ranges together, so it is sent as two rules with the same outbound: the names go
/// in one (it keeps the direct DNS, so RU names keep resolving to RU addresses) and the ranges in
/// the other (RU addresses reached without a name still bypass the proxy).
///
/// It is the same match: sing-box rules with a name condition and an address condition match when
/// either matches, so the pair covers exactly what the single rule did.
List<Rule> effectiveRouteRules(List<Rule> rules, {bool servicesOnly = false}) {
  final effective = <Rule>[];
  for (final rule in rules) {
    final copy = rule.deepCopy()..listOrder = effective.length;
    effective.add(copy);
    final ranges = _regionRanges(copy);
    if (ranges != null) {
      effective.add(ranges..listOrder = effective.length);
    }
  }
  // Without the loaded preset the catch-alls would send everything direct, so the split only
  // applies when the services are really there.
  if (servicesOnly && BundledServiceRules.rules.isNotEmpty) {
    // The router's own preset: the listed services go through the VPN, everything else direct.
    // These rules are injected here, not kept in the user's list: the list stays the small,
    // editable set, while the config gets the full preset in a fixed order.
    for (final service in BundledServiceRules.rules) {
      effective.add(service.deepCopy()..listOrder = effective.length);
    }
    // Every name the service rules did not catch goes direct, and resolves with the direct DNS.
    effective.add(
      Rule(name: "preset:direct-names", enabled: true, outbound: Outbound.direct, domainRegexes: [".*"])
        ..listOrder = effective.length,
    );
    // A connection known only by its address (nothing to sniff) goes direct as well.
    effective.add(
      Rule(name: "preset:direct-ip", enabled: true, outbound: Outbound.direct, ipCidrs: ["0.0.0.0/0", "::/0"])
        ..listOrder = effective.length,
    );
  }
  return effective;
}

/// The IP part of the bundled region rule, or null when [rule] is not that rule.
///
/// The app's rule keeps the domains only, so the list stays small to save and to export; the RU
/// ranges come from the same bundled lists and are added here, where the core's config is built.
Rule? _regionRanges(Rule rule) {
  final geo = BundledGeoRules.instance;
  if (!rule.enabled || rule.name != BuiltinRule.bypassRegion.key) return null;
  // a remote rule-set brings its own IP ranges with it
  if (rule.ruleSets.isNotEmpty) return null;
  if (geo.ipCidrs.isEmpty || (rule.domains.isEmpty && rule.domainSuffixes.isEmpty)) return null;
  return Rule(name: '${rule.name}:ip', enabled: true, outbound: rule.outbound, ipCidrs: geo.ipCidrs);
}
