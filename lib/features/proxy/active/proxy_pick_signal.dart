import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'proxy_pick_signal.g.dart';

/// What the user picked in the proxies page.
enum ProxyPickKind {
  /// One server by hand: the priority selector keeps it while it answers.
  server,

  /// A selector group ("lowest", "balance", …): automatic priority selection steps aside.
  group,
}

/// One explicit pick of the user, published from the proxies page.
class ProxyPick {
  const ProxyPick(this.kind, this.tag);

  final ProxyPickKind kind;
  final String tag;
}

/// The last pick the user made. The proxies page writes it, the priority auto-selection listens.
///
/// The auto-selection used to guess a hand pick by comparing the core's selected outbound with
/// its own choice. That misread the core's own reports (a stale list, its own switch landing late)
/// as a hand pick, so the two could take turns selecting servers. An explicit signal removes the
/// guessing: only a real tap in the list is a hand pick.
@Riverpod(keepAlive: true)
class ProxyPickSignal extends _$ProxyPickSignal {
  @override
  ProxyPick? build() => null;

  /// The user tapped a server in the list.
  void pickedServer(String tag) => state = ProxyPick(ProxyPickKind.server, tag);

  /// The user tapped a group ("fastest", "balance", …) or "switch to the fastest".
  void pickedGroup(String tag) => state = ProxyPick(ProxyPickKind.group, tag);
}
