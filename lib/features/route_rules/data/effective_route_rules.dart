import 'package:hiddify/hiddifycore/generated/v2/config/route_rule.pb.dart';

/// The app's rule list as the core should see it, with the order the core sorts by.
///
/// The core turns one rule of the list into one sing-box rule. The list is passed almost as is:
/// no geo lists and no generated rules are added here any more, because routing is per app now
/// (see the app-based routing settings), not per domain.
List<Rule> effectiveRouteRules(List<Rule> rules) {
  return [for (final rule in rules) rule.deepCopy()..listOrder = rules.indexOf(rule)];
}
