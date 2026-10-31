import 'dart:async';

import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/proxy/active/priority_selector.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/features/proxy/data/proxy_repository.dart';
import 'package:hiddify/features/proxy/model/proxy_entity.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/hiddifycore/init_signal.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:rxdart/rxdart.dart';

part 'priority_failover_notifier.g.dart';

/// What the home proxy card shows about the priority auto-selection.
class PriorityAutoSelectStatus {
  const PriorityAutoSelectStatus.following({required this.activeTag, required this.priority, required this.total})
    : following = true;

  const PriorityAutoSelectStatus.idle()
    : activeTag = null,
      priority = null,
      total = null,
      following = false;

  /// The server the selector keeps active; null when it does not manage the traffic.
  final String? activeTag;

  /// The 1-based position of [activeTag] in the subscription order.
  final int? priority;

  /// How many servers the active profile lists.
  final int? total;

  /// Whether the priority selector owns the active server.
  final bool following;

  /// The active server is not the first one by priority: a failover is in effect.
  bool get isFailover => following && (priority ?? 1) > 1;
}

/// Every group with all of its members, so the priority selector sees each
/// server's own ping. The main list holds only the selection.
@Riverpod(keepAlive: true)
class AllProxiesNotifier extends _$AllProxiesNotifier with AppLogger {
  static const _minResubscribeDelay = Duration(seconds: 2);
  static const _maxResubscribeDelay = Duration(seconds: 30);
  Duration _resubscribeDelay = _minResubscribeDelay;

  @override
  Stream<OutboundGroupList> build() {
    final serviceRunning = ref.watch(serviceRunningProvider);
    // A core restart replaces the gRPC channel; the stream below lives on the old one.
    ref.watch(coreRestartSignalProvider);
    if (!serviceRunning) return Stream.value(OutboundGroupList());

    Timer? resubscribe;
    ref.onDispose(() => resubscribe?.cancel());
    var received = 0;
    return _repo
        .watchAllProxies()
        .where((event) => event.isRight())
        .map((event) => event.getOrElse((_) => OutboundGroupList()))
        .doOnData((_) {
          if (++received > 1) _resubscribeDelay = _minResubscribeDelay;
        })
        .doOnDone(() {
          loggy.debug("all proxies stream ended, resubscribing in $_resubscribeDelay");
          resubscribe = Timer(_resubscribeDelay, ref.invalidateSelf);
          final doubled = _resubscribeDelay * 2;
          _resubscribeDelay = doubled < _maxResubscribeDelay ? doubled : _maxResubscribeDelay;
        });
  }

  ProxyRepository get _repo => ref.read(proxyRepositoryProvider);
}

/// Keeps the first alive server by subscription priority active, fails over to
/// the next alive one when it stops answering, and returns to a recovered
/// higher-priority one with hysteresis, so two servers cannot pull the traffic
/// back and forth every few seconds.
///
/// The decision rules live in [PrioritySelector], which is pure and unit
/// tested; this notifier only feeds it snapshots, probes the servers and
/// carries the decision out through `SelectOutbound`.
@Riverpod(keepAlive: true)
class PriorityAutoSelectNotifier extends _$PriorityAutoSelectNotifier with AppLogger {
  /// How often the active server (and a recovered candidate) is pinged and the
  /// decision is re-evaluated.
  static const probeInterval = Duration(seconds: 15);

  /// After a switch the core's list needs a moment to show it; a mismatch
  /// within this window is not a hand pick.
  static const _switchGrace = Duration(seconds: 8);

  final _selector = PrioritySelector();
  Timer? _ticker;
  bool _connected = false;
  bool _initialProbed = false;
  String? _profileId;
  List<PriorityServer> _servers = const [];
  String? _pendingTag;
  DateTime? _pendingSince;
  bool _switching = false;
  int _probeCursor = 0;
  int _higherProbeCursor = 0;

  @override
  PriorityAutoSelectStatus build() {
    ref.listen(connectionNotifierProvider, (_, next) => _onConnection(next.valueOrNull));
    ref.listen(allProxiesNotifierProvider, (_, next) => _onAllProxies(next.valueOrNull));
    ref.listen(mainOutboundsNotifierProvider, (_, next) => _onMainOutbounds(next.valueOrNull));
    ref.listen(activeProfileProvider, (_, next) => _onProfile(next.valueOrNull?.id));

    ref.onDispose(() => _ticker?.cancel());

    _profileId = ref.read(activeProfileProvider).valueOrNull?.id;
    // The connection may already be up when the card first builds this.
    final status = ref.read(connectionNotifierProvider).valueOrNull;
    if (status?.isConnected ?? false) {
      _connected = true;
      _startTicker();
      _readServers();
      unawaited(_probeAll());
      unawaited(_evaluate());
    }
    return _status();
  }

  ProxyRepository get _repo => ref.read(proxyRepositoryProvider);

  void _onProfile(String? profileId) {
    if (profileId == _profileId) return;
    _profileId = profileId;
    loggy.info("priority auto-select: active profile changed, starting over");
    _reset();
    _refreshStatus();
  }

  void _onConnection(ConnectionStatus? status) {
    final connected = status?.isConnected ?? false;
    if (connected == _connected) return;
    _connected = connected;

    if (!connected) {
      _ticker?.cancel();
      _ticker = null;
      _reset();
      loggy.info("priority auto-select: disconnected, stopped");
      _refreshStatus();
      return;
    }

    loggy.info("priority auto-select: connected, picking the first alive server");
    _reset();
    _startTicker();
    _readServers();
    unawaited(_probeAll());
    unawaited(_evaluate());
  }

  void _onAllProxies(OutboundGroupList? list) {
    if (!_connected || list == null) return;
    final servers = _serversOf(list);
    if (servers.isEmpty) return;
    final wasEmpty = _servers.isEmpty;
    _servers = servers;
    if (!_initialProbed && wasEmpty) {
      // The first snapshot after a connection: learn every server's ping at
      // once instead of waiting for the core's url-test interval.
      _initialProbed = true;
      unawaited(_probeAll());
    }
    _reconcileCorePick();
    if (_selector.currentTag == null) {
      // Nothing chosen yet: pick the first alive server as soon as the delays
      // are known.
      unawaited(_evaluate());
    } else {
      _refreshStatus();
    }
  }

  void _onMainOutbounds(OutboundGroupList? list) {
    if (!_connected || list == null) return;
    _reconcileCorePick(list);
  }

  /// Detects a hand pick in the proxies page. The notifier must not fight the
  /// user: a picked server is kept while it answers, a picked group suspends
  /// the priority selection until the next connection.
  void _reconcileCorePick([OutboundGroupList? list]) {
    final currentTag = _selector.currentTag;
    if (currentTag == null) return;
    final data = list ?? ref.read(mainOutboundsNotifierProvider).valueOrNull;
    if (data == null || data.items.isEmpty) return;
    final main = data.items.first;
    if (main.items.isEmpty) return;
    final picked = main.items.first;

    if (picked.tag == currentTag) {
      _pendingTag = null;
      return;
    }
    if (_pendingTag != null && picked.tag == _pendingTag) {
      // The core picked up our own switch.
      _pendingTag = null;
      return;
    }
    if (_selector.suspended) return;
    final now = DateTime.now();
    final pendingSince = _pendingSince;
    if (pendingSince != null && now.difference(pendingSince) < _switchGrace) return;

    if (picked.isGroup) {
      loggy.info("priority auto-select: the user picked the [${picked.tag}] group, suspending");
      _selector.suspend();
    } else {
      loggy.info("priority auto-select: the user picked [${picked.tag}] by hand");
      _selector.userPicked(picked.tag, now);
    }
    _refreshStatus();
  }

  void _reset() {
    _selector.reset();
    _servers = const [];
    _pendingTag = null;
    _pendingSince = null;
    _switching = false;
    _initialProbed = false;
    _probeCursor = 0;
    _higherProbeCursor = 0;
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(probeInterval, (_) => unawaited(_step()));
  }

  Future<void> _step() async {
    if (!_connected) return;
    _readServers();
    await _probeNext();
    await _evaluate();
  }

  void _readServers() {
    final list = ref.read(allProxiesNotifierProvider).valueOrNull;
    if (list == null) return;
    final servers = _serversOf(list);
    if (servers.isNotEmpty) _servers = servers;
  }

  /// The profile's servers in subscription order, which is the priority order.
  List<PriorityServer> _serversOf(OutboundGroupList list) {
    final groups = list.items.where((group) => group.tag == selectGroupTag);
    if (groups.isEmpty) return const [];
    final main = groups.first;
    return [
      for (final item in main.items)
        if (!item.isGroup) PriorityServer(tag: item.tag, delay: item.urlTestDelay),
    ];
  }

  /// Pings the active server, and one higher-priority server that is down (in
  /// turn, so a recovered one is noticed and an unreachable one does not hide
  /// the rest). Without an active server yet, it probes the servers in turn.
  Future<void> _probeNext() async {
    if (_servers.isEmpty) return;
    final currentTag = _selector.currentTag;
    final currentIndex = currentTag == null ? -1 : _servers.indexWhere((server) => server.tag == currentTag);

    if (currentIndex < 0) {
      unawaited(_probe(_servers[_probeCursor % _servers.length].tag));
      _probeCursor++;
      return;
    }

    unawaited(_probe(_servers[currentIndex].tag));
    final down = [
      for (var i = 0; i < currentIndex; i++)
        if (!ConnectionConst.isValidDelay(_servers[i].delay)) _servers[i].tag,
    ];
    if (down.isEmpty) return;
    unawaited(_probe(down[_higherProbeCursor % down.length]));
    _higherProbeCursor++;
  }

  /// Pings every server once after a connection, so the first choice does not
  /// wait for the core's own url-test interval.
  Future<void> _probeAll() async {
    for (final server in _servers) {
      unawaited(_probe(server.tag));
    }
  }

  Future<void> _probe(String tag) async {
    final result = await _repo.urlTest(tag).run();
    result.match((error) => loggy.warning("priority auto-select: url test of [$tag] failed", error), (_) {});
  }

  Future<void> _evaluate() async {
    if (!_connected || _switching || _selector.suspended) {
      _refreshStatus();
      return;
    }
    if (_servers.isEmpty) return;
    final decision = _selector.evaluate(_servers, now: DateTime.now());
    if (!decision.shouldSwitch) {
      _refreshStatus();
      return;
    }

    final target = decision.targetTag!;
    final previous = _selector.currentTag;
    final reason = decision.reason!;
    _switching = true;
    _pendingSince = DateTime.now();
    final result = await _repo.selectProxy(selectGroupTag, target).run();
    _switching = false;

    var switched = false;
    result.match(
      (error) => loggy.warning("priority auto-select: could not select [$target]", error),
      (_) => switched = true,
    );
    if (!switched) return;

    _selector.switchedTo(target, DateTime.now());
    _pendingTag = target;
    _refreshStatus();
    _notify(reason, previous: previous, target: target);
  }

  void _refreshStatus() {
    state = _status();
  }

  PriorityAutoSelectStatus _status() {
    final tag = _selector.currentTag;
    if (tag == null || _selector.suspended) return const PriorityAutoSelectStatus.idle();
    final index = _servers.indexWhere((server) => server.tag == tag);
    if (index < 0) return const PriorityAutoSelectStatus.idle();
    return PriorityAutoSelectStatus.following(activeTag: tag, priority: index + 1, total: _servers.length);
  }

  void _notify(PrioritySwitchReason reason, {String? previous, required String target}) {
    final t = ref.read(translationsProvider).valueOrNull;
    if (t == null) return;
    final notifications = ref.read(inAppNotificationControllerProvider);
    final targetName = sanitizedTagName(target);
    switch (reason) {
      case PrioritySwitchReason.initial:
        break;
      case PrioritySwitchReason.failover:
        if (previous == null) break;
        notifications.showInfoToast(
          t.pages.proxies.priorityFailoverToast(server: sanitizedTagName(previous), target: targetName),
        );
      case PrioritySwitchReason.recovery:
        notifications.showInfoToast(t.pages.proxies.priorityRecoveryToast(server: targetName));
    }
  }
}
