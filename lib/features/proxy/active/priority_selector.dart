import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/features/proxy/model/proxy_entity.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';

/// A server as the core reports it, with the subscription position as its priority.
///
/// The list handed to [PrioritySelector.evaluate] is ordered: the first entry is the
/// most preferred server, exactly as the outbounds of the active profile were built
/// (the order the 3x-ui subscription lists them).
class PriorityServer {
  const PriorityServer({required this.tag, required this.delay});

  /// The outbound tag the core knows the server by.
  final String tag;

  /// The last url-test delay in ms: `0` is "not measured yet", a value of
  /// [ConnectionConst.maxDelay] or more is a timeout. The delay is only read as
  /// "alive or not", never compared between servers: a faster server does not
  /// take the traffic away.
  final int delay;

  @override
  String toString() => "PriorityServer($tag, $delay)";
}

/// Why the selector wants to move the traffic to another server.
enum PrioritySwitchReason {
  /// Nothing was chosen yet, or the chosen server disappeared from the profile.
  initial,

  /// The active server stopped answering; the next alive one in priority order takes over.
  failover,
}

/// Why the selector keeps the active server as it is.
enum PriorityHoldReason {
  /// The core has not reported any server yet.
  noServers,

  /// Every server is down (or still untested); the core's own connectivity tells
  /// the user, and the traffic stays where it is instead of hopping around.
  noAliveServer,

  /// The active server answers: whatever else is alive, the traffic stays on it.
  /// There is no automatic return to a higher-priority server.
  activeAlive,

  /// The user picked this server by hand; automatic switching leaves it alone until it fails.
  manualPick,

  /// The active server's ping is unknown ("not measured yet"), so there is no
  /// evidence of a failure. It stays, instead of being counted as dead.
  unknownPing,

  /// The active server looks down, but not for long enough yet (hysteresis).
  waitingForFailover,

  /// A switch happened too recently; waiting protects against a series of switches.
  cooldown,

  /// The user took control (picked a group, "fastest", …) for the rest of the connection.
  suspended,
}

/// What [PrioritySelector.evaluate] decided for this step.
class PriorityDecision {
  const PriorityDecision.keep(PriorityHoldReason this.hold) : targetTag = null, reason = null;

  const PriorityDecision.change(String this.targetTag, PrioritySwitchReason this.reason) : hold = null;

  /// The server to select, or null when the active one stays.
  final String? targetTag;

  /// Why the switch is wanted; null when [targetTag] is null.
  final PrioritySwitchReason? reason;

  /// Why the active server stays; null when [targetTag] is set.
  final PriorityHoldReason? hold;

  bool get shouldSwitch => targetTag != null;

  @override
  String toString() => shouldSwitch ? "PriorityDecision.change($targetTag, $reason)" : "PriorityDecision.keep($hold)";
}

/// Decides which server the main selector should use: the first alive one in
/// subscription order, and a switch only when the active server is unavailable.
///
/// The class is pure: it only reads the server list and the clock, and never
/// touches gRPC, so all of its rules are covered by unit tests. The notifier
/// feeds it snapshots and carries out [PriorityDecision]s.
///
/// Rules:
/// * nothing chosen yet → the first alive server ([PrioritySwitchReason.initial]);
/// * the active server answers → keep it; there is **no** automatic return to a
///   higher-priority (or faster) server, so two servers cannot pull the traffic
///   back and forth;
/// * the active server is down for [failThreshold] evaluations in a row → switch
///   to the first alive server by subscription order (a recovered higher-priority
///   one included: the switch is still caused by the active one being dead);
/// * [switchCooldown] must pass between any two automatic switches, so a chain of
///   dead servers does not turn into a burst of switches;
/// * every server is down → keep the active one and let the core report "no
///   connection"; do not hop between dead servers;
/// * a server the user picked by hand is never replaced while it answers; a
///   group pick (or "fastest") suspends automatic switching until the next
///   connection.
class PrioritySelector {
  PrioritySelector({
    bool Function(int delay)? isAlive,
    bool Function(int delay)? isDead,
    this.failThreshold = 3,
    this.switchCooldown = const Duration(seconds: 45),
  }) : assert(failThreshold > 0),
       _isAlive = isAlive ?? ConnectionConst.isValidDelay,
       _isDead = isDead ?? ConnectionConst.isDeadDelay;

  final bool Function(int delay) _isAlive;

  /// Whether a delay is an observed failure (a timeout) rather than "not measured".
  final bool Function(int delay) _isDead;

  /// How many evaluations in a row the active server must look down before the
  /// traffic moves away. With the notifier's 15-second steps this is ~45 s, so a
  /// short packet loss or a slow answer does not cause a switch.
  final int failThreshold;

  /// The least time between two automatic switches.
  final Duration switchCooldown;

  String? _currentTag;
  String? _manualTag;
  bool _suspended = false;
  int _invalidStreak = 0;
  DateTime? _lastSwitchAt;

  /// The server the selector keeps active; null until the first switch.
  String? get currentTag => _currentTag;

  /// Whether automatic switching is off for the rest of the connection.
  bool get suspended => _suspended;

  /// The server the user picked by hand, while it is the active one.
  String? get manualTag => _manualTag;

  /// Forgets everything, so the next [evaluate] starts from "nothing chosen".
  void reset() {
    _currentTag = null;
    _manualTag = null;
    _suspended = false;
    _invalidStreak = 0;
    _lastSwitchAt = null;
  }

  /// Records that the traffic was moved to [tag] (the notifier calls this after
  /// the core accepted the selection).
  void switchedTo(String tag, DateTime now) {
    _currentTag = tag;
    _manualTag = null;
    _invalidStreak = 0;
    _lastSwitchAt = now;
  }

  /// The user picked [tag] by hand: keep it while it answers, fail over from it
  /// when it does not, and do not move back to a higher priority by itself.
  void userPicked(String tag, DateTime now) {
    _currentTag = tag;
    _manualTag = tag;
    _suspended = false;
    _invalidStreak = 0;
    _lastSwitchAt = now;
  }

  /// The user picked a group or another automatic mode, so the priority
  /// selection stops until the next connection.
  void suspend() {
    _suspended = true;
    _manualTag = null;
    _invalidStreak = 0;
  }

  /// One step of the state machine.
  ///
  /// [servers] is the profile's server list in priority order; a server that
  /// disappeared from it (profile update) counts as "nothing chosen".
  PriorityDecision evaluate(List<PriorityServer> servers, {required DateTime now}) {
    if (_suspended) return const PriorityDecision.keep(PriorityHoldReason.suspended);
    if (servers.isEmpty) return const PriorityDecision.keep(PriorityHoldReason.noServers);

    final firstAliveIndex = servers.indexWhere((server) => _isAlive(server.delay));
    final currentIndex = _currentTag == null ? -1 : servers.indexWhere((server) => server.tag == _currentTag);

    // Nothing chosen yet, or the chosen server is no longer in the profile.
    if (currentIndex < 0) {
      _currentTag = null;
      _manualTag = null;
      _invalidStreak = 0;
      if (firstAliveIndex < 0) return const PriorityDecision.keep(PriorityHoldReason.noAliveServer);
      return PriorityDecision.change(servers[firstAliveIndex].tag, PrioritySwitchReason.initial);
    }

    final currentAlive = _isAlive(servers[currentIndex].delay);

    // A manual pick is left alone while it answers; a dead one fails over below.
    if (_manualTag == _currentTag && currentAlive) {
      _invalidStreak = 0;
      return const PriorityDecision.keep(PriorityHoldReason.manualPick);
    }

    if (currentAlive) {
      // The traffic never leaves a server that answers, even when a higher
      // priority or a faster one is available: only unavailability moves it.
      _invalidStreak = 0;
      return const PriorityDecision.keep(PriorityHoldReason.activeAlive);
    }

    // A ping of 0 means "not measured yet", not "dead". Counting it as a
    // failure made the app leave a working server on its first unknown
    // snapshots; only a measured timeout is evidence.
    if (!_isDead(servers[currentIndex].delay)) {
      _invalidStreak = 0;
      return const PriorityDecision.keep(PriorityHoldReason.unknownPing);
    }

    // The active server does not answer.
    _invalidStreak++;
    if (firstAliveIndex < 0) return const PriorityDecision.keep(PriorityHoldReason.noAliveServer);
    if (_invalidStreak < failThreshold) return const PriorityDecision.keep(PriorityHoldReason.waitingForFailover);
    if (_inCooldown(now)) return const PriorityDecision.keep(PriorityHoldReason.cooldown);
    return PriorityDecision.change(servers[firstAliveIndex].tag, PrioritySwitchReason.failover);
  }

  bool _inCooldown(DateTime now) {
    final last = _lastSwitchAt;
    return last != null && now.difference(last) < switchCooldown;
  }
}

/// The profile's servers in priority order, taken from the core's full outbound
/// list: the leaf members of the main selector, in the order the core built them
/// from the subscription. The selector's own group members (`lowest`, `balance`)
/// are skipped, they are not servers.
List<PriorityServer> priorityServersOf(OutboundGroupList list) {
  final groups = list.items.where((group) => group.tag == selectGroupTag);
  if (groups.isEmpty) return const [];
  return [
    for (final item in groups.first.items)
      if (!item.isGroup) PriorityServer(tag: item.tag, delay: item.urlTestDelay),
  ];
}
