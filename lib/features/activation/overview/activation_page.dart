import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/failures.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/activation/activation_constants.dart';
import 'package:hiddify/features/activation/model/activation_result.dart';
import 'package:hiddify/features/activation/notifier/activation_notifier.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// The activation screen: a code from the bot, then a subscription profile from the API.
///
/// It is reachable in three ways, all leading here with the same page: the key icon on the
/// home screen, the link on the intro screen, and the `vpn://activate?code=…` deep link
/// (the code arrives as [initialCode]).
class ActivationPage extends HookConsumerWidget {
  const ActivationPage({super.key, this.initialCode});

  /// The `code` query parameter of a deep link, prefilled into the field.
  final String? initialCode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = ref.watch(translationsProvider).requireValue;
    final state = ref.watch(activationNotifierProvider);
    final notifier = ref.read(activationNotifierProvider.notifier);

    final formKey = useMemoized(() => GlobalKey<FormState>());
    final codeController = useTextEditingController(text: initialCode?.trim() ?? '');
    useMemoized(() {
      if (initialCode?.trim().isNotEmpty ?? false) {
        // the code came with the link: activate right away, one tap saved for the user
        WidgetsBinding.instance.addPostFrameCallback((_) => notifier.activate(initialCode!.trim()));
      }
    });

    final isBusy = state.isLoading;
    final result = state.valueOrNull;
    final failure = state.error;

    void activate() {
      if (isBusy) return;
      if (!(formKey.currentState?.validate() ?? false)) return;
      notifier.activate(codeController.text.trim());
    }

    Future<void> leave() async {
      if (!context.mounted) return;
      final introCompleted = ref.read(Preferences.introCompleted);
      context.go(introCompleted ? '/home' : '/intro');
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(t.pages.activation.title),
        actions: [
          IconButton(
            key: const ValueKey('activation_close_button'),
            tooltip: t.common.close,
            icon: const Icon(Icons.close_rounded),
            onPressed: isBusy ? null : leave,
          ),
          const Gap(4),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              if (result == null) ...[
                Icon(Icons.key_rounded, size: 56, color: theme.colorScheme.primary),
                const Gap(16),
                Text(t.pages.activation.description, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
                const Gap(24),
                Form(
                  key: formKey,
                  child: CustomTextFormField(
                    key: const ValueKey('activation_code_field'),
                    controller: codeController,
                    label: t.pages.activation.code,
                    hint: t.pages.activation.codeHint,
                    onChanged: (_) {
                      if (failure != null) notifier.reset();
                    },
                    validator: (value) {
                      final code = value?.trim() ?? '';
                      if (code.isEmpty) return t.pages.activation.emptyCode;
                      if (!ActivationConst.codePattern.hasMatch(code)) {
                        return t.pages.activation.invalidCodeFormat;
                      }
                      return null;
                    },
                    suffixIcon: IconButton(
                      key: const ValueKey('activation_paste_button'),
                      tooltip: t.pages.activation.paste,
                      icon: const Icon(Icons.content_paste_rounded),
                      onPressed: isBusy
                          ? null
                          : () async {
                              final clipboard = await Clipboard.getData(Clipboard.kTextPlain).then(
                                (value) => value?.text?.trim(),
                              );
                              if (clipboard == null || clipboard.isEmpty) {
                                ref
                                    .read(inAppNotificationControllerProvider)
                                    .showErrorToast(t.pages.activation.pasteFailed);
                                return;
                              }
                              codeController.text = clipboard;
                              ref.read(activationNotifierProvider.notifier).reset();
                            },
                    ),
                  ),
                ),
                if (failure != null) ...[
                  const Gap(16),
                  _FailureCard(
                    message: t.presentShortError(failure),
                    retryLabel: t.pages.activation.activate,
                    onRetry: isBusy ? null : activate,
                  ),
                ],
                const Gap(24),
                FilledButton(
                  key: const ValueKey('activation_submit_button'),
                  onPressed: isBusy ? null : activate,
                  child: isBusy
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                            const Gap(12),
                            Text(t.pages.activation.activating),
                          ],
                        )
                      : Text(t.pages.activation.activate),
                ),
              ] else
                _SuccessCard(
                  result: result,
                  onDone: leave,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FailureCard extends StatelessWidget {
  const _FailureCard({required this.message, required this.retryLabel, this.onRetry});

  final String message;
  final String retryLabel;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.error_outline_rounded, color: theme.colorScheme.onErrorContainer),
                const Gap(8),
                Expanded(
                  child: Text(message, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onErrorContainer)),
                ),
              ],
            ),
            const Gap(8),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(
                onPressed: onRetry,
                child: Text(retryLabel, style: TextStyle(color: theme.colorScheme.onErrorContainer)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SuccessCard extends ConsumerWidget {
  const _SuccessCard({required this.result, required this.onDone});

  final ActivationResult result;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = ref.watch(translationsProvider).requireValue;
    final name = result.preferredName;
    final expire = result.expireDate;
    final traffic = result.traffic;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Icons.check_circle_rounded, size: 64, color: theme.colorScheme.primary),
        const Gap(16),
        Text(t.pages.activation.successTitle, textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
        const Gap(8),
        Text(
          t.pages.activation.successBody(name: name),
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium,
        ),
        const Gap(24),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              children: [
                if (name.isNotEmpty)
                  ListTile(
                    leading: const Icon(Icons.vpn_key_rounded),
                    title: Text(t.common.name),
                    subtitle: Text(name),
                    dense: true,
                  ),
                ListTile(
                  leading: const Icon(Icons.event_rounded),
                  title: Text(t.pages.activation.expire),
                  subtitle: Text(expire == null ? t.pages.activation.noExpiry : expire.format()),
                  dense: true,
                ),
                if (traffic != null)
                  ListTile(
                    leading: const Icon(Icons.data_usage_rounded),
                    title: Text(t.pages.activation.trafficLeft),
                    subtitle: Text(
                      traffic.isUnlimited
                          ? t.pages.activation.unlimitedTraffic
                          : (traffic.remaining ?? 0).sizeGB(),
                    ),
                    dense: true,
                  ),
              ],
            ),
          ),
        ),
        const Gap(24),
        FilledButton(
          key: const ValueKey('activation_done_button'),
          onPressed: onDone,
          child: Text(t.pages.activation.done),
        ),
      ],
    );
  }
}
