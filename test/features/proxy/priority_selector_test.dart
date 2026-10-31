import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/proxy/active/priority_selector.dart';
import 'package:hiddify/features/proxy/model/proxy_entity.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';

// The engine is pure Dart + the app's delay rule, so every rule is tested here
// without a core, gRPC or a clock of its own.

const _alive = 120;
const _alive2 = 400;
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

PrioritySelector _selector({
  int failThreshold = 2,
  int recoveryThreshold = 2,
  Duration switchCooldown = const Duration(seconds: 20),
  Duration recoveryCooldown = const Duration(seconds: 60),
}) => PrioritySelector(
  failThreshold: failThreshold,
  recoveryThreshold: recoveryThreshold,
  switchCooldown: switchCooldown,
  recoveryCooldown: recoveryCooldown,
);

void main() {
  group("initial selection", () {
    test("picks the first alive server, not the fastest one", () {
      final selector = _selector();
      final decision = selector.evaluate(_servers([(_a, _alive2), (_b, _alive), (_c, 50)]), now: _t0);
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
      expect(selector.evaluate(_servers([(_a, _alive)]), now: _at(15)).hold, PriorityHoldReason.alreadyBest);
    });
  });

  group("failover", () {
    test("moves to the next alive server only after the fail threshold", () {
      final selector = _selector();
      selector.evaluate(_servers([(_a, _alive), (_b, _alive)]), now: _t0);
      selector.switchedTo(_a, _t0);

      final first = selector.evaluate(_servers([(_a, _dead), (_b, _alive)]), now: _at(15));
      expect(first.hold, PriorityHoldReason.waitingForFailover);

      final second = selector.evaluate(_servers([(_a, _dead), (_b, _alive)]), now: _at(30));
      expect(second.targetTag, _b);
      expect(second.reason, PrioritySwitchReason.failover);
    });

    test("skips the dead servers between the active one and the first alive one", () {
      final selector = _selector();
      selector.evaluate(_servers([(_a, _alive), (_b, _dead), (_c, _dead)]), now: _t0);
      selector.switchedTo(_a, _t0);

      expect(selector.evaluate(_servers([(_a, _dead), (_b, _dead), (_c, _alive)]), now: _at(15)).shouldSwitch, isFalse);
      expect(selector.evaluate(_servers([(_a, _dead), (_b, _dead), (_c, _alive)]), now: _at(30)).targetTag, _c);
    });

    test("a single failed ping does not move the traffic", () {
      final selector = _selector();
      selector.evaluate(_servers([(_a, _alive), (_b, _alive)]), now: _t0);
      selector.switchedTo(_a, _t0);

      expect(selector.evaluate(_servers([(_a, _dead), (_b, _alive)]), now: _at(15)).shouldSwitch, isFalse);
      // the server answers again on the next step: the streak resets
      expect(selector.evaluate(_servers([(_a, _alive), (_b, _alive)]), now: _at(30)).hold, PriorityHoldReason.alreadyBest);
      expect(selector.evaluate(_servers([(_a, _dead), (_b, _alive)]), now: _at(45)).shouldSwitch, isFalse);
    });

    test("keeps the active server when every server is down", () {
      final selector = _selector();
      selector.evaluate(_servers([(_a, _alive), (_b, _alive)]), now: _t0);
      selector.switchedTo(_a, _t0);
      selector.evaluate(_servers([(_a, _dead), (_b, _dead)]), now: _at(15));
      final decision = selector.evaluate(_servers([(_a, _dead), (_b, _dead)]), now: _at(30));
      expect(decision.shouldSwitch, isFalse);
      expect(decision.hold, PriorityHoldReason.noAliveServer);
    });

    test("does not switch again inside the cooldown", () {
      final selector = _selector(switchCooldown: const Duration(seconds: 120));
      selector.evaluate(_servers([(_a, _alive), (_b, _alive), (_c, _alive)]), now: _t0);
      selector.switchedTo(_a, _t0);
      selector.evaluate(_servers([(_a, _dead), (_b, _alive), (_c, _alive)]), now: _at(15));
      selector.evaluate(_servers([(_a, _dead), (_b, _alive), (_c, _alive)]), now: _at(30));
      selector.switchedTo(_b, _at(30));

      // B dies at once, but the cooldown since the switch keeps the traffic on it
      selector.evaluate(_servers([(_a, _dead), (_b, _dead), (_c, _alive)]), now: _at(45));
      final decision = selector.evaluate(_servers([(_a, _dead), (_b, _dead), (_c, _alive)]), now: _at(60));
      expect(decision.shouldSwitch, isFalse);
      expect(decision.hold, PriorityHoldReason.cooldown);
      // after the cooldown the failover goes through
      expect(selector.evaluate(_servers([(_a, _dead), (_b, _dead), (_c, _alive)]), now: _at(160)).targetTag, _c);
    });
  });

  group("recovery to a higher priority", () {
    test("returns to the recovered server after the streak and the cooldown", () {
      final selector = _selector();
      selector.evaluate(_servers([(_a, _alive), (_b, _alive)]), now: _t0);
      selector.switchedTo(_a, _t0);
      // A fails, the traffic goes to B
      selector.evaluate(_servers([(_a, _dead), (_b, _alive)]), now: _at(15));
      selector.evaluate(_servers([(_a, _dead), (_b, _alive)]), now: _at(30));
      selector.switchedTo(_b, _at(30));

      // A answers again; two steps are needed, and the cooldown holds it for 60s more
      expect(
        selector.evaluate(_servers([(_a, _alive), (_b, _alive)]), now: _at(45)).hold,
        PriorityHoldReason.waitingForRecovery,
      );
      expect(
        selector.evaluate(_servers([(_a, _alive), (_b, _alive)]), now: _at(60)).hold,
        PriorityHoldReason.cooldown,
      );
      final back = selector.evaluate(_servers([(_a, _alive), (_b, _alive)]), now: _at(90));
      expect(back.targetTag, _a);
      expect(back.reason, PrioritySwitchReason.recovery);
    });

    test("a recovered server is not taken when the active one still answers and is above it", () {
      final selector = _selector();
      selector.evaluate(_servers([(_a, _alive), (_b, _alive)]), now: _t0);
      selector.switchedTo(_a, _t0);
      for (var i = 1; i <= 10; i++) {
        final decision = selector.evaluate(_servers([(_a, _alive), (_b, _alive)]), now: _at(15 * i));
        expect(decision.hold, PriorityHoldReason.alreadyBest);
      }
    });

    test("keeps the fallback when the recovered server flaps", () {
      final selector = _selector(recoveryThreshold: 3, recoveryCooldown: const Duration(seconds: 30));
      selector.evaluate(_servers([(_a, _alive), (_b, _alive)]), now: _t0);
      selector.switchedTo(_a, _t0);
      selector.evaluate(_servers([(_a, _dead), (_b, _alive)]), now: _at(15));
      selector.evaluate(_servers([(_a, _dead), (_b, _alive)]), now: _at(30));
      selector.switchedTo(_b, _at(30));

      // A jumps up and down: the recovery streak resets each time it dies
      expect(selector.evaluate(_servers([(_a, _alive), (_b, _alive)]), now: _at(45)).shouldSwitch, isFalse);
      expect(selector.evaluate(_servers([(_a, _alive), (_b, _alive)]), now: _at(60)).shouldSwitch, isFalse);
      expect(selector.evaluate(_servers([(_a, _dead), (_b, _alive)]), now: _at(75)).shouldSwitch, isFalse);
      expect(selector.evaluate(_servers([(_a, _alive), (_b, _alive)]), now: _at(90)).shouldSwitch, isFalse);
      expect(selector.evaluate(_servers([(_a, _alive), (_b, _alive)]), now: _at(105)).shouldSwitch, isFalse);
      // three steady steps and the cooldown have passed: back to A
      expect(selector.evaluate(_servers([(_a, _alive), (_b, _alive)]), now: _at(120)).targetTag, _a);
    });

    test("returns to the first alive recovered server, not a dead one above it", () {
      final selector = _selector(recoveryCooldown: const Duration(seconds: 30));
      selector.evaluate(_servers([(_a, _dead), (_b, _alive), (_c, _alive)]), now: _t0);
      selector.switchedTo(_b, _t0);
      // C takes over when B dies
      selector.evaluate(_servers([(_a, _dead), (_b, _dead), (_c, _alive)]), now: _at(15));
      selector.evaluate(_servers([(_a, _dead), (_b, _dead), (_c, _alive)]), now: _at(30));
      selector.switchedTo(_c, _at(30));

      // B recovers, A stays dead: B is the first alive and the target
      expect(selector.evaluate(_servers([(_a, _dead), (_b, _alive), (_c, _alive)]), now: _at(45)).shouldSwitch, isFalse);
      expect(selector.evaluate(_servers([(_a, _dead), (_b, _alive), (_c, _alive)]), now: _at(60)).targetTag, _b);
    });
  });

  group("manual control", () {
    test("a hand-picked server is not replaced by a higher-priority one", () {
      final selector = _selector();
      selector.evaluate(_servers([(_a, _alive), (_b, _alive)]), now: _t0);
      selector.switchedTo(_a, _t0);
      selector.userPicked(_b, _at(5));

      for (var i = 1; i <= 10; i++) {
        final decision = selector.evaluate(_servers([(_a, _alive), (_b, _alive)]), now: _at(15 * i));
        expect(decision.hold, PriorityHoldReason.manualPick);
      }
      expect(selector.manualTag, _b);
    });

    test("a hand-picked server still fails over when it dies", () {
      final selector = _selector();
      selector.evaluate(_servers([(_a, _alive), (_b, _alive)]), now: _t0);
      selector.switchedTo(_a, _t0);
      selector.userPicked(_b, _at(5));

      expect(selector.evaluate(_servers([(_a, _alive), (_b, _dead)]), now: _at(30)).shouldSwitch, isFalse);
      final decision = selector.evaluate(_servers([(_a, _alive), (_b, _dead)]), now: _at(45));
      expect(decision.targetTag, _a);
      // the automatic pick is not a manual one any more
      selector.switchedTo(_a, _at(45));
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
}
