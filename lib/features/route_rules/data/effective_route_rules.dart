import 'package:hiddify/features/route_rules/data/bundled_geo_rules.dart';
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
List<Rule> effectiveRouteRules(List<Rule> rules) {
  final effective = <Rule>[];
  for (final rule in rules) {
    final copy = rule.deepCopy()..listOrder = effective.length;
    effective.add(copy);
    final ranges = _regionRanges(copy);
    if (ranges != null) {
      effective.add(ranges..listOrder = effective.length);
    }
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
