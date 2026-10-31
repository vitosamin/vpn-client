import 'package:hiddify/core/model/constants.dart';

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
  /// [ConnectionConst.maxDelay] or more is a timeout.
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

  /// A server with a higher priority answers again; the traffic goes back to it.
  recovery,
}

/// Why the selector keeps the active server as it is.
enum PriorityHoldReason {
  /// The core has not reported any server yet.
  noServers,

  /// Every server is down (or still untested); the core's own connectivity tells the user.
  noAliveServer,

  /// The active server is the first alive one: nothing better exists.
  alreadyBest,

  /// The user picked this server by hand; automatic switching leaves it alone until it fails.
  manualPick,

  /// The active server looks down, but not for long enough yet (hysteresis).
  waitingForFailover,

  /// A higher-priority server answers again, but not for long enough yet (hysteresis).
  waitingForRecovery,

  /// A switch happened too recently; waiting protects against flapping.
  cooldown,

  /// The user took control (picked a group, "fastest", …) for the rest of the connection.
  suspended,
}

/// What [PrioritySelector.evaluate] decided for this step.
class PriorityDecision {
  const PriorityDecision.keep(PriorityHoldReason this.hold)
    : targetTag = null,
      reason = null;

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
/// subscription order, with failover to the next alive server and a hysteretic
/// return to a recovered higher-priority one.
///
/// The class is pure: it only reads the server list and the clock, and never
/// touches gRPC, so all of its rules are covered by unit tests. The notifier
/// feeds it snapshots and carries out [PriorityDecision]s.
///
/// Rules:
/// * nothing chosen yet → the first alive server ([PrioritySwitchReason.initial]);
/// * the active server is the first alive one → keep it, reset the counters;
/// * the active server is down for [failThreshold] evaluations in a row → switch
///   to the first alive server (the next one by priority, or a recovered one
///   above it);
/// * a server above the active one answers again for [recoveryThreshold]
///   evaluations in a row, and [recoveryCooldown] has passed since the last
///   switch → go back to it (the first alive one, so the result is stable);
/// * [switchCooldown] must pass between any two automatic switches, which —
///   together with the streaks — keeps two flapping servers from pulling the
///   traffic back and forth every few seconds;
/// * a server the user picked by hand is never replaced while it answers; a
///   group pick (or "fastest") suspends automatic switching until the next
///   connection.
class PrioritySelector {
  PrioritySelector({
    bool Function(int delay)? isAlive,
    this.failThreshold = 2,
    this.recoveryThreshold = 3,
    this.switchCooldown = const Duration(seconds: 20),
    this.recoveryCooldown = const Duration(seconds: 60),
  }) : assert(failThreshold > 0),
       assert(recoveryThreshold > 0),
       _isAlive = isAlive ?? ConnectionConst.isValidDelay;

  final bool Function(int delay) _isAlive;

  /// How many evaluations in a row the active server must look down before
  /// the traffic moves away.
  final int failThreshold;

  /// How many evaluations in a row a higher-priority server must look alive
  /// before the traffic goes back to it.
  final int recoveryThreshold;

  /// The least time between two automatic switches.
  final Duration switchCooldown;

  /// The least time after a switch before a recovered higher-priority server
  /// can pull the traffic back.
  final Duration recoveryCooldown;

  String? _currentTag;
  String? _manualTag;
  bool _suspended = false;
  int _invalidStreak = 0;
  int _recoveryStreak = 0;
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
    _recoveryStreak = 0;
    _lastSwitchAt = null;
  }

  /// Records that the traffic was moved to [tag] (the notifier calls this after
  /// the core accepted the selection).
  void switchedTo(String tag, DateTime now) {
    _currentTag = tag;
    _manualTag = null;
    _invalidStreak = 0;
    _recoveryStreak = 0;
    _lastSwitchAt = now;
  }

  /// The user picked [tag] by hand: keep it while it answers, fail over from it
  /// when it does not, and do not move back to a higher priority by itself.
  void userPicked(String tag, DateTime now) {
    _currentTag = tag;
    _manualTag = tag;
    _suspended = false;
    _invalidStreak = 0;
    _recoveryStreak = 0;
    _lastSwitchAt = now;
  }

  /// The user picked a group or another automatic mode, so the priority
  /// selection stops until the next connection.
  void suspend() {
    _suspended = true;
    _manualTag = null;
    _invalidStreak = 0;
    _recoveryStreak = 0;
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
      _recoveryStreak = 0;
      if (firstAliveIndex < 0) return const PriorityDecision.keep(PriorityHoldReason.noAliveServer);
      return PriorityDecision.change(servers[firstAliveIndex].tag, PrioritySwitchReason.initial);
    }

    final currentAlive = _isAlive(servers[currentIndex].delay);

    // A manual pick is left alone while it answers; a dead one fails over below.
    final manualAlive = _manualTag == _currentTag;
    if (manualAlive && currentAlive) {
      _invalidStreak = 0;
      _recoveryStreak = 0;
      return const PriorityDecision.keep(PriorityHoldReason.manualPick);
    }

    if (currentAlive) {
      _invalidStreak = 0;
      if (firstAliveIndex == currentIndex) {
        // Already the best alive server; nothing to recover.
        _recoveryStreak = 0;
        return const PriorityDecision.keep(PriorityHoldReason.alreadyBest);
      }

      // A higher-priority server answers again: wait for a steady result and
      // for the cooldown, then go back.
      _recoveryStreak++;
      if (_recoveryStreak < recoveryThreshold) {
        return const PriorityDecision.keep(PriorityHoldReason.waitingForRecovery);
      }
      if (_inCooldown(now, recoveryCooldown)) {
        return const PriorityDecision.keep(PriorityHoldReason.cooldown);
      }
      return PriorityDecision.change(servers[firstAliveIndex].tag, PrioritySwitchReason.recovery);
    }

    // The active server does not answer.
    _recoveryStreak = 0;
    _invalidStreak++;
    if (firstAliveIndex < 0) return const PriorityDecision.keep(PriorityHoldReason.noAliveServer);
    if (_invalidStreak < failThreshold) return const PriorityDecision.keep(PriorityHoldReason.waitingForFailover);
    if (_inCooldown(now, switchCooldown)) return const PriorityDecision.keep(PriorityHoldReason.cooldown);
    final reason = firstAliveIndex < currentIndex ? PrioritySwitchReason.recovery : PrioritySwitchReason.failover;
    return PriorityDecision.change(servers[firstAliveIndex].tag, reason);
  }

  bool _inCooldown(DateTime now, Duration window) {
    final last = _lastSwitchAt;
    return last != null && now.difference(last) < window;
  }
}
