import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/proxy/active/priority_selector.dart';
import 'package:hiddify/features/proxy/model/proxy_entity.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';

// The engine is pure Dart + the app's delay rule, so every rule is tested here
// without a core, gRPC or a clock of its own.

const _alive = 120;
const _alive2 = 400;
const _slow = 5000;
const _fast = 20;
const _dead = 65000; // a url-test timeout, as the core reports it
const _unknown = 0; // "not measured yet", also not alive

const _a = "A";
const _b = "B";
const _c = "C";

PriorityServer _server(String tag, int delay) => PriorityServer(tag: tag, delay: delay);

List<PriorityServer> _servers(List<(String, int)> entries) =>
    entries.map((entry) => _server(entry.$1, entry.$2)).toList();

final _t0 = DateTime(2026, 1, 1, 12);

DateTime _at(int seconds) => _t0.add(Duration(seconds: seconds));

PrioritySelector _selector({Duration switchCooldown = const Duration(seconds: 45)}) =>
    PrioritySelector(switchCooldown: switchCooldown);

/// Three failed evaluations in a row, as the notifier makes them every 15 s.
void _failThree(PrioritySelector selector, List<(String, int)> current) {
  for (final seconds in [15, 30, 45]) {
    selector.evaluate(_servers(current), now: _at(seconds));
  }
}

void main() {
  group("initial selection", () {
    test("picks the first alive server, not the fastest one", () {
      final selector = _selector();
      final decision = selector.evaluate(_servers([(_a, _alive2), (_b, _alive), (_c, _fast)]), now: _t0);
      expect(decision.targetTag, _a);
      expect(decision.reason, PrioritySwitchReason.initial);
    });

    test("skips dead servers above the first alive one", () {
      final selector = _selector();
      final decision = selector.evaluate(_servers([(_a, _dead), (_b, _unknown), (_c, _alive)]), now: _t0);
      expect(decision.targetTag, _c);
    });

    test("waits while every server is down or not measured", () {
      final selector = _selector();
      final decision = selector.evaluate(_servers([(_a, _dead), (_b, _unknown)]), now: _t0);
      expect(decision.shouldSwitch, isFalse);
      expect(decision.hold, PriorityHoldReason.noAliveServer);
    });

    test("picks nothing for an empty list", () {
      final selector = _selector();
      expect(selector.evaluate(const [], now: _t0).hold, PriorityHoldReason.noServers);
    });

    test("selects a lone server, then leaves it alone", () {
      final selector = _selector();
      expect(selector.evaluate(_servers([(_a, _alive)]), now: _t0).targetTag, _a);
      selector.switchedTo(_a, _t0);
      expect(selector.evaluate(_servers([(_a, _alive)]), now: _at(15)).hold, PriorityHoldReason.activeAlive);
    });
  });

  group("no automatic switching", () {
    test("stays on the active server while a higher-priority one answers again", () {
      final selector = _selector();
      // A is dead at the start, so B is the first alive server.
      selector.evaluate(_servers([(_a, _dead), (_b, _alive)]), now: _t0);
      selector.switchedTo(_b, _t0);

      // A recovers, but the traffic does not move back: only availability moves it.
      for (final seconds in [15, 30, 60, 120, 300]) {
        final decision = selector.evaluate(_servers([(_a, _alive), (_b, _alive)]), now: _at(seconds));
        expect(decision.shouldSwitch, isFalse);
        expect(decision.hold, PriorityHoldReason.activeAlive);
      }
      expect(selector.currentTag, _b);
    });

    test("does not move to a faster server", () {
      final selector = _selector();
      selector.evaluate(_servers([(_a, _slow), (_b, _fast)]), now: _t0);
      selector.switchedTo(_a, _t0);

      for (final seconds in [15, 30, 60, 120]) {
        expect(selector.evaluate(_servers([(_a, _slow), (_b, _fast)]), now: _at(seconds)).shouldSwitch, isFalse);
      }
    });

    test("does not move while the active server answers, whatever happens around it", () {
      final selector = _selector();
      selector.evaluate(_servers([(_a, _alive), (_b, _alive), (_c, _alive)]), now: _t0);
      selector.switchedTo(_b, _t0);

      for (final seconds in [15, 30, 45, 90, 180]) {
        final decision = selector.evaluate(_servers([(_a, _alive), (_b, _alive), (_c, _alive)]), now: _at(seconds));
        expect(decision.hold, PriorityHoldReason.activeAlive);
      }
    });
  });

  group("failover when the active server is unavailable", () {
    test("switches after three failed evaluations in a row", () {
      final selector = _selector();
      selector.evaluate(_servers([(_a, _alive), (_b, _alive)]), now: _t0);
      selector.switchedTo(_a, _t0);

      expect(
        selector.evaluate(_servers([(_a, _dead), (_b, _alive)]), now: _at(15)).hold,
        PriorityHoldReason.waitingForFailover,
      );
      expect(
        selector.evaluate(_servers([(_a, _dead), (_b, _alive)]), now: _at(30)).hold,
        PriorityHoldReason.waitingForFailover,
      );
      final third = selector.evaluate(_servers([(_a, _dead), (_b, _alive)]), now: _at(45));
      expect(third.targetTag, _b);
      expect(third.reason, PrioritySwitchReason.failover);
    });

    test("a short loss does not move the traffic", () {
      final selector = _selector();
      selector.evaluate(_servers([(_a, _alive), (_b, _alive)]), now: _t0);
      selector.switchedTo(_a, _t0);

      expect(selector.evaluate(_servers([(_a, _dead), (_b, _alive)]), now: _at(15)).shouldSwitch, isFalse);
      // The server answers again on the next step: the streak resets.
      expect(
        selector.evaluate(_servers([(_a, _alive), (_b, _alive)]), now: _at(30)).hold,
        PriorityHoldReason.activeAlive,
      );
      expect(selector.evaluate(_servers([(_a, _dead), (_b, _alive)]), now: _at(45)).shouldSwitch, isFalse);
      expect(selector.evaluate(_servers([(_a, _dead), (_b, _alive)]), now: _at(60)).shouldSwitch, isFalse);
    });

    test("takes the first alive server by priority, not the fastest", () {
      final selector = _selector();
      selector.evaluate(_servers([(_a, _alive), (_b, _alive), (_c, _alive)]), now: _t0);
      selector.switchedTo(_a, _t0);

      _failThree(selector, [(_a, _dead), (_b, _slow), (_c, _fast)]);
      final decision = selector.evaluate(_servers([(_a, _dead), (_b, _slow), (_c, _fast)]), now: _at(60));
      expect(decision.targetTag, _b);
    });

    test("skips the dead servers between the active one and the first alive one", () {
      final selector = _selector();
      selector.evaluate(_servers([(_a, _alive), (_b, _dead), (_c, _dead)]), now: _t0);
      selector.switchedTo(_a, _t0);

      expect(
        selector.evaluate(_servers([(_a, _dead), (_b, _dead), (_c, _alive)]), now: _at(15)).shouldSwitch,
        isFalse,
      );
      expect(
        selector.evaluate(_servers([(_a, _dead), (_b, _dead), (_c, _alive)]), now: _at(30)).shouldSwitch,
        isFalse,
      );
      expect(selector.evaluate(_servers([(_a, _dead), (_b, _dead), (_c, _alive)]), now: _at(45)).targetTag, _c);
    });

    test("switches to a recovered higher-priority server only because the active one died", () {
      final selector = _selector();
      // A is dead at the start, so B is the first alive server.
      selector.evaluate(_servers([(_a, _dead), (_b, _alive)]), now: _t0);
      selector.switchedTo(_b, _t0);

      // A recovers: no return while B answers.
      expect(selector.evaluate(_servers([(_a, _alive), (_b, _alive)]), now: _at(15)).shouldSwitch, isFalse);
      // B dies: after three failed evaluations the traffic goes to the first alive server, A.
      expect(selector.evaluate(_servers([(_a, _alive), (_b, _dead)]), now: _at(30)).shouldSwitch, isFalse);
      expect(selector.evaluate(_servers([(_a, _alive), (_b, _dead)]), now: _at(45)).shouldSwitch, isFalse);
      final decision = selector.evaluate(_servers([(_a, _alive), (_b, _dead)]), now: _at(60));
      expect(decision.targetTag, _a);
      expect(decision.reason, PrioritySwitchReason.failover);
    });

    test("waits while the active ping is not measured instead of counting it as dead", () {
      final selector = _selector();
      selector.evaluate(_servers([(_a, _alive), (_b, _alive)]), now: _t0);
      selector.switchedTo(_a, _t0);

      // 0 is "not measured yet", not a timeout: it must not move the traffic.
      for (final seconds in [15, 30, 45, 60, 90]) {
        final decision = selector.evaluate(_servers([(_a, _unknown), (_b, _alive)]), now: _at(seconds));
        expect(decision.shouldSwitch, isFalse);
        expect(decision.hold, PriorityHoldReason.unknownPing);
      }

      // Once the core really reports timeouts, the three strikes start from zero.
      _failThree(selector, [(_a, _dead), (_b, _alive)]);
      expect(selector.evaluate(_servers([(_a, _dead), (_b, _alive)]), now: _at(105)).targetTag, _b);
    });

    test("keeps the active server when every server is down", () {
      final selector = _selector();
      selector.evaluate(_servers([(_a, _alive), (_b, _alive)]), now: _t0);
      selector.switchedTo(_a, _t0);

      for (final seconds in [15, 30, 45, 60, 120]) {
        final decision = selector.evaluate(_servers([(_a, _dead), (_b, _dead)]), now: _at(seconds));
        expect(decision.shouldSwitch, isFalse);
        expect(decision.hold, PriorityHoldReason.noAliveServer);
      }
    });

    test("does not switch again inside the cooldown", () {
      final selector = _selector(switchCooldown: const Duration(seconds: 120));
      selector.evaluate(_servers([(_a, _alive), (_b, _alive), (_c, _alive)]), now: _t0);
      selector.switchedTo(_a, _t0);

      // Three failed evaluations, but the cooldown since the first switch has not passed yet.
      _failThree(selector, [(_a, _dead), (_b, _alive), (_c, _alive)]);
      var decision = selector.evaluate(_servers([(_a, _dead), (_b, _alive), (_c, _alive)]), now: _at(60));
      expect(decision.shouldSwitch, isFalse);
      expect(decision.hold, PriorityHoldReason.cooldown);

      decision = selector.evaluate(_servers([(_a, _dead), (_b, _alive), (_c, _alive)]), now: _at(120));
      expect(decision.targetTag, _b);
    });
  });

  group("manual control", () {
    test("a hand-picked server is not replaced by a higher-priority one", () {
      final selector = _selector();
      selector.evaluate(_servers([(_a, _alive), (_b, _alive)]), now: _t0);
      selector.switchedTo(_a, _t0);
      selector.userPicked(_b, _at(5));

      for (final seconds in [15, 30, 60, 120]) {
        final decision = selector.evaluate(_servers([(_a, _alive), (_b, _alive)]), now: _at(seconds));
        expect(decision.hold, PriorityHoldReason.manualPick);
      }
      expect(selector.manualTag, _b);
    });

    test("a hand-picked server still fails over when it dies", () {
      final selector = _selector();
      selector.evaluate(_servers([(_a, _alive), (_b, _alive)]), now: _t0);
      selector.switchedTo(_a, _t0);
      selector.userPicked(_b, _at(5));

      expect(
        selector.evaluate(_servers([(_a, _alive), (_b, _dead)]), now: _at(20)).hold,
        PriorityHoldReason.waitingForFailover,
      );
      expect(
        selector.evaluate(_servers([(_a, _alive), (_b, _dead)]), now: _at(35)).hold,
        PriorityHoldReason.waitingForFailover,
      );
      final decision = selector.evaluate(_servers([(_a, _alive), (_b, _dead)]), now: _at(50));
      expect(decision.targetTag, _a);
      expect(decision.reason, PrioritySwitchReason.failover);

      selector.switchedTo(_a, _at(50));
      expect(selector.manualTag, isNull);
    });

    test("a group pick suspends the priority selection", () {
      final selector = _selector();
      selector.evaluate(_servers([(_a, _alive), (_b, _alive)]), now: _t0);
      selector.switchedTo(_a, _t0);
      selector.suspend();

      final decision = selector.evaluate(_servers([(_a, _dead), (_b, _alive)]), now: _at(60));
      expect(decision.hold, PriorityHoldReason.suspended);

      selector.reset();
      expect(selector.evaluate(_servers([(_a, _dead), (_b, _alive)]), now: _at(75)).targetTag, _b);
    });
  });

  group("profile changes", () {
    test("a vanished active server starts the selection over", () {
      final selector = _selector();
      selector.evaluate(_servers([(_a, _alive), (_b, _alive)]), now: _t0);
      selector.switchedTo(_a, _t0);

      final decision = selector.evaluate(_servers([(_b, _alive)]), now: _at(15));
      expect(decision.targetTag, _b);
      expect(decision.reason, PrioritySwitchReason.initial);
    });

    test("reset makes the next step pick the first alive server again", () {
      final selector = _selector();
      selector.evaluate(_servers([(_a, _alive), (_b, _alive)]), now: _t0);
      selector.switchedTo(_b, _t0);
      selector.reset();
      expect(selector.currentTag, isNull);

      final decision = selector.evaluate(_servers([(_a, _alive), (_b, _alive)]), now: _at(15));
      expect(decision.targetTag, _a);
      expect(decision.reason, PrioritySwitchReason.initial);
    });
  });

  group("servers from the core list", () {
    OutboundGroup group(String tag, List<OutboundInfo> items) => OutboundGroup(tag: tag, items: items);
    OutboundInfo groupItem(String tag) => OutboundInfo(tag: tag, isGroup: true);
    OutboundInfo server(String tag, int delay) => OutboundInfo(tag: tag, urlTestDelay: delay);

    test("keeps the subscription order and skips the selector's groups", () {
      final list = OutboundGroupList(
        items: [
          group(selectGroupTag, [
            groupItem(lowestGroupTag),
            groupItem(balanceGroupTag),
            server(_c, 30),
            server(_a, 10),
            server(_b, 20),
          ]),
          group(lowestGroupTag, [server(_a, 10)]),
        ],
      );

      final servers = priorityServersOf(list);

      expect(servers.map((it) => it.tag).toList(), [_c, _a, _b]);
      expect(servers.map((it) => it.delay).toList(), [30, 10, 20]);
    });

    test("returns nothing when the main selector is missing", () {
      final list = OutboundGroupList(items: [group(lowestGroupTag, [server(_a, 10)])]);
      expect(priorityServersOf(list), isEmpty);
    });
  });
}
