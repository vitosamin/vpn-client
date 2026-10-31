import 'package:dartx/dartx.dart';
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:hiddify/features/home/widget/home_hero.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/gen/assets.gen.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class HomePage extends HookConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = ref.watch(translationsProvider).requireValue;
    // null while the profile list loads; only a known "no profiles" shows the empty home
    final hasAnyProfile = ref.watch(hasAnyProfileProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Assets.images.logo.svg(height: 24),
            const Gap(8),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: t.common.appTitle),
                  const TextSpan(text: " "),
                  const WidgetSpan(child: AppVersionLabel(), alignment: PlaceholderAlignment.middle),
                ],
              ),
            ),
          ],
        ),
        actions: [
          Semantics(
            key: const ValueKey("activation_button"),
            label: t.pages.activation.title,
            child: IconButton(
              icon: Icon(Icons.key_rounded, color: theme.colorScheme.primary),
              tooltip: t.pages.activation.title,
              onPressed: () => context.go('/activate'),
            ),
          ),
          Semantics(
            key: const ValueKey("profile_add_button"),
            label: t.pages.profiles.add,
            child: IconButton(
              icon: Icon(Icons.add_rounded, color: theme.colorScheme.primary),
              onPressed: () => ref.read(bottomSheetsNotifierProvider.notifier).showAddProfile(),
            ),
          ),
          const Gap(8),
        ],
      ),
      body: Stack(
        children: [
          // the page keeps a quiet depth of its own under the hero
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: theme.brightness == Brightness.dark
                    ? RadialGradient(
                        center: const Alignment(0, -.55),
                        radius: 1.15,
                        colors: [
                          Colors.white.withValues(alpha: .045),
                          Colors.white.withValues(alpha: .012),
                          Colors.white.withValues(alpha: 0),
                        ],
                        stops: const [0, .55, 1],
                      )
                    : RadialGradient(
                        center: const Alignment(0, -.55),
                        radius: 1.2,
                        colors: [
                          const Color(0xFF5B79FF).withValues(alpha: .10),
                          const Color(0xFF5B79FF).withValues(alpha: .025),
                          const Color(0xFF5B79FF).withValues(alpha: 0),
                        ],
                        stops: const [0, .55, 1],
                      ),
              ),
            ),
          ),
          if (hasAnyProfile == false)
            SafeArea(
              child: Center(
                child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520), child: const HomeEmptyView()),
              ),
            )
          else
            SafeArea(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 56),
                // phone-first: the hero keeps its width on a wide desktop window too
                children: [
                  Center(
                    child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 620), child: const HomeHero()),
                  ),
                ],
              ),
            ),
          if (hasAnyProfile ?? false)
            Positioned(
              right: 0,
              left: 0,
              bottom: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Material(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: const BorderRadius.only(topLeft: Radius.circular(16), topRight: Radius.circular(16)),
                    child: InkWell(
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(16),
                        topRight: Radius.circular(16),
                      ),
                      onTap: () => ref.read(bottomSheetsNotifierProvider.notifier).showQuickSettings(),
                      child: Container(
                        height: 32,
                        padding: const EdgeInsetsDirectional.only(start: 16, end: 8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(t.pages.home.quickSettings),
                            const Gap(4),
                            const Icon(Icons.arrow_drop_up_rounded, size: 16),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class AppVersionLabel extends HookConsumerWidget {
  const AppVersionLabel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);

    final version = ref.watch(appInfoProvider).requireValue.presentVersion;
    if (version.isBlank) return const SizedBox();

    return Semantics(
      label: t.common.version,
      button: false,
      child: Container(
        decoration: BoxDecoration(color: theme.colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(4)),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        child: Text(
          version,
          textDirection: TextDirection.ltr,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSecondaryContainer),
        ),
      ),
    );
  }
}
