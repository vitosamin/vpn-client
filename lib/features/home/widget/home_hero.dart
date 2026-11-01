import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/home/widget/connection_button.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_card.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/proxy/model/connection_health.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:simple_icons/simple_icons.dart';

/// The brand colors of the hero. The card is dark in both themes, so everything on it is drawn
/// with these instead of the theme colors.
abstract final class _Hero {
  static const navy = Color(0xFF16243D);
  static const navyLight = Color(0xFF1E3150);
  static const accent = Color(0xFF5B79FF);
  static const ok = Color(0xFF52C97A);
  static const bad = Color(0xFFFF7A7A);
  static const idle = Color(0xB3FFFFFF); // white70

  static const radius = 28.0;
}

/// The home hero: the monogram, the connection status, the button, the active server and the
/// subscription numbers, all on one branded card.
///
/// No VPN imagery (shields, locks, globes): the mark is the monogram and the look is a soft
/// navy gradient with one accent glow.
class HomeHero extends HookConsumerWidget {
  const HomeHero({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final status = ref.watch(connectionNotifierProvider);
    final health = ref.watch(connectionHealthProvider);
    final profile = ref.watch(activeProfileProvider).valueOrNull;

    final state = _presentation(t, status, health);

    return Container(
      key: const ValueKey('home_hero'),
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_Hero.radius),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_Hero.navy, _Hero.navyLight],
        ),
        boxShadow: [BoxShadow(color: _Hero.navy.withValues(alpha: .30), blurRadius: 28, offset: const Offset(0, 14))],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          // one soft accent glow, top right, and a fainter one at the bottom left
          const Positioned(top: -130, right: -90, child: _Glow(color: _Hero.accent, size: 300, opacity: .30)),
          const Positioned(bottom: -150, left: -110, child: _Glow(color: _Hero.accent, size: 280, opacity: .16)),
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(20, 18, 20, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _HeroHeader(),
                const Gap(18),
                // the status is drawn here, the button below only acts
                _StatusBlock(state: state),
                const Gap(16),
                // a normal primary action instead of the big white circle: the brand gradient
                // carries the state, the power glyph and the verb say what a tap does
                const ConnectionButton(showLabel: false, variant: ConnectionButtonVariant.pill),
                const Gap(10),
                const ActiveProxyFooter(embedded: true),
                if (profile != null) ...[const Gap(8), _SubscriptionCard(profile: profile)],
                const Gap(12),
                const _TelegramTile(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// What the hero says about the connection. The words come from the status translations, so
  /// the hero and the rest of the app never disagree.
  static ({String title, String? subtitle, Color color}) _presentation(
    TranslationsEn t,
    AsyncValue<ConnectionStatus> status,
    ConnectionHealth? health,
  ) {
    final value = status.valueOrNull;
    final failure = switch (status) {
      AsyncError(:final Object error) => error,
      AsyncValue(valueOrNull: Disconnected(connectionFailure: final failure?)) => failure,
      _ => null,
    };
    if (failure != null) {
      return (title: t.connection.failed, subtitle: t.connection.tapToRetry, color: _Hero.bad);
    }
    return switch (value) {
      // the pill below says "connect", so the status does not repeat it
      null => (title: t.pages.home.notConnected, subtitle: null, color: _Hero.idle),
      Disconnected() => (title: t.pages.home.notConnected, subtitle: null, color: _Hero.idle),
      Connecting() => (title: t.connection.connecting, subtitle: null, color: _Hero.accent),
      Waiting() => (title: t.connection.connecting, subtitle: t.connection.waiting, color: _Hero.accent),
      HotReloading() => (title: t.connection.hotReloading, subtitle: null, color: _Hero.accent),
      Disconnecting() => (title: t.connection.disconnecting, subtitle: null, color: _Hero.idle),
      NoAvailableProxies() => (title: t.connection.noAvailableProxies, subtitle: null, color: _Hero.bad),
      Connected() when health?.degraded ?? false => (
        title: t.connection.connected,
        subtitle: health!.pick == HealthState.failed
            ? t.connection.health.pickDead
            : t.connection.health.hopFailed(chain: health.chain?.present(t) ?? ''),
        color: const Color(0xFFE3A63A),
      ),
      Connected() => (title: t.connection.connected, subtitle: t.pages.home.protectedConnection, color: _Hero.ok),
    };
  }
}

/// The mark and the brand name, small and quiet, so the status and the button stay the focus.
class _HeroHeader extends StatelessWidget {
  const _HeroHeader();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SvgPicture.asset(
          'assets/images/logo.svg',
          width: 22,
          height: 22,
          colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
        ),
        const Gap(8),
        Text(Constants.appName, style: theme.textTheme.labelLarge?.copyWith(color: Colors.white70, letterSpacing: .4)),
      ],
    );
  }
}

class _StatusBlock extends StatelessWidget {
  const _StatusBlock({required this.state});

  final ({String title, String? subtitle, Color color}) state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              width: 9,
              height: 9,
              decoration: BoxDecoration(color: state.color, shape: BoxShape.circle),
            ),
            const Gap(8),
            Flexible(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: Text(
                  state.title,
                  key: ValueKey(state.title),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
        // the subtitle explains a problem or says what to do; it appears without moving the button
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          alignment: Alignment.topCenter,
          child: state.subtitle == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    state.subtitle!,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(color: Colors.white54),
                  ),
                ),
        ),
      ],
    );
  }
}

/// Profile name and the subscription numbers from the `subscription-userinfo` headers; opens the
/// profiles sheet, which is where a profile is switched or updated.
class _SubscriptionCard extends ConsumerWidget {
  const _SubscriptionCard({required this.profile});

  final ProfileEntity profile;

  static const _tenTerabytes = 10 * 1099511627776; // the parser's "no limit" sentinel is above this

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final subInfo = switch (profile) {
      RemoteProfileEntity(:final subInfo) => subInfo,
      _ => null,
    };

    final traffic = switch (subInfo) {
      null => null,
      final s when s.total > _tenTerabytes => '∞',
      final s when s.isExpired => null,
      final s when s.ratio >= 1 => null,
      final s => s.remainingBW.sizeGB(),
    };
    final expiry = switch (subInfo) {
      null => null,
      final s when s.remaining.inDays > 365 => '∞',
      final s => s.expire.format(),
    };

    return Material(
      color: Colors.white.withValues(alpha: .07),
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => ref.read(bottomSheetsNotifierProvider.notifier).showProfilesOverview(),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(14, 10, 10, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.account_circle_outlined, size: 18, color: Colors.white70),
                  const Gap(8),
                  Expanded(
                    child: Text(
                      profile.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white),
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded, size: 20, color: Colors.white54),
                ],
              ),
              if (traffic != null || expiry != null) ...[
                const Gap(6),
                // two halves, each able to ellipsis: a long locale date cannot overflow the card
                Row(
                  children: [
                    Expanded(
                      child: traffic == null
                          ? const SizedBox.shrink()
                          : _Metric(icon: Icons.data_usage_rounded, text: traffic),
                    ),
                    const Gap(8),
                    Expanded(
                      child: expiry == null
                          ? const SizedBox.shrink()
                          : _Metric(icon: Icons.event_rounded, text: expiry, alignEnd: true),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One small number of the subscription: an icon and a value that may be cut with an ellipsis.
class _Metric extends StatelessWidget {
  const _Metric({required this.icon, required this.text, this.alignEnd = false});

  final IconData icon;
  final String text;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisAlignment: alignEnd ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: [
        Icon(icon, size: 15, color: Colors.white54),
        const Gap(5),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.white70),
          ),
        ),
      ],
    );
  }
}

/// The owner's Telegram group: noticeable, not loud. Opens outside the app.
class _TelegramTile extends ConsumerWidget {
  const _TelegramTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = ref.watch(translationsProvider).requireValue;
    return OutlinedButton(
      onPressed: () => UriUtils.tryLaunch(Uri.parse(Constants.telegramGroupUrl)),
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: Colors.white24),
        foregroundColor: Colors.white,
        padding: const EdgeInsetsDirectional.fromSTEB(14, 10, 14, 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(SimpleIcons.telegram, size: 20, color: Colors.white),
          const Gap(10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(t.pages.home.telegram, style: theme.textTheme.labelLarge?.copyWith(color: Colors.white)),
                Text(t.pages.home.telegramSubtitle, style: theme.textTheme.labelSmall?.copyWith(color: Colors.white54)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A soft round accent glow; purely decorative.
class _Glow extends StatelessWidget {
  const _Glow({required this.color, required this.size, required this.opacity});

  final Color color;
  final double size;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              color.withValues(alpha: opacity),
              color.withValues(alpha: 0),
            ],
          ),
        ),
      ),
    );
  }
}

/// The empty home: no profile yet. Two ways in — a code from the bot, or a subscription link.
class HomeEmptyView extends ConsumerWidget {
  const HomeEmptyView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = ref.watch(translationsProvider).requireValue;
    final addProfile = ref.read(bottomSheetsNotifierProvider.notifier);

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
      children: [
        SvgPicture.asset(
          'assets/images/logo.svg',
          width: 64,
          height: 64,
          colorFilter: ColorFilter.mode(theme.colorScheme.primary, BlendMode.srcIn),
        ),
        const Gap(24),
        Text(
          t.pages.home.emptyTitle,
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        const Gap(8),
        Text(
          t.pages.home.emptySubtitle,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const Gap(28),
        FilledButton.icon(
          key: const ValueKey('home_empty_have_code'),
          onPressed: () => context.go('/activate'),
          icon: const Icon(Icons.key_rounded),
          label: Text(t.pages.home.haveCode),
        ),
        const Gap(10),
        OutlinedButton.icon(
          key: const ValueKey('home_empty_add_subscription'),
          onPressed: addProfile.showAddProfile,
          icon: const Icon(Icons.add_rounded),
          label: Text(t.pages.home.addSubscription),
        ),
        const Gap(20),
        Center(
          child: TextButton.icon(
            onPressed: () => UriUtils.tryLaunch(Uri.parse(Constants.telegramGroupUrl)),
            icon: const Icon(SimpleIcons.telegram, size: 18),
            label: Text(t.pages.home.telegram),
          ),
        ),
      ],
    );
  }
}
