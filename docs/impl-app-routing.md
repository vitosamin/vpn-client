# Маршрутизация по приложениям (2.0.0)

Гео-списки и доменные правила убраны: приложение больше не решает, куда отправить
`google.com` или `.ru`, по адресу. Вместо этого выбираются **приложения**, чей трафик
идёт через VPN; всё остальное идёт напрямую — как в режиме раздельного туннеля на
роутере, только критерий не домен, а приложение.

## Что это значит

- режим `include`: выбранные приложения — через VPN, все остальные — напрямую;
- режим `exclude`: наоборот, выбранные приложения — мимо VPN;
- выключено — весь трафик через VPN (поведение стокового Hiddify).

По умолчанию включён `include` и заготовка популярных приложений: YouTube, Telegram,
Instagram, Facebook, WhatsApp, Discord, TikTok, Netflix, Spotify, X, Viber, Snapchat,
Reddit, Pinterest, ChatGPT, Gemini, Claude и YouTube Music. При первом запуске
выбираются только те, что установлены на телефоне; список можно менять: «Настройки →
Маршрутизация → Приложения через VPN» и выбрать любое установленное приложение.

Кнопка с ракетой в списке приложений заново добавляет установленные приложения из
заготовки, не сбрасывая ваш выбор.

## Где что

| Файл | Что |
|---|---|
| `lib/features/app_based_routing/data/popular_apps.dart` | заготовка пакетов |
| `lib/features/app_based_routing/overview/app_based_routing_notifier.dart` | первый запуск: выбор установленных популярных приложений, включение `include`, отключение удалённого авто-списка |
| `lib/core/preferences/general_preferences.dart` | `per_app_proxy_enabled` (по умолчанию `true`), `per_app_proxy_mode` (`include`) |
| `lib/features/app_based_routing/overview/app_list_page.dart` | список установленных приложений, кнопка «Популярные» |
| `android/.../Settings.kt`, `VPNService.kt` | нативная часть: `addAllowedApplication`/`addDisallowedApplication` |

## Что удалено

- `assets/geo/*` (RU-домены, суффиксы, CIDR) и `assets/routing/services.json`;
- `BundledGeoRules`, `BundledServiceRules`, `effectiveRouteRules` больше не добавляют
  правил; `preset:block-quic`, `preset:direct-*`, правило `builtin:bypassRegion`
  (сохранённое правило региона вычищается при сборке списка);
- скрипт `scripts/update-geo-rules.sh`.

DNS: прямой DNS остаётся `udp://77.88.8.8`, удалённый — `tcp://8.8.8.8` через туннель;
для приложений вне VPN DNS системный.

## Проверка

`flutter analyze` — чисто; тесты маршрутов (`test/features/route_rules`) проверяют, что
остались только встроенные LAN и блокировка рекламы, а удалённое правило региона
выбрасывается и не превращается в пользовательское.
