# Раздельная маршрутизация «только сервисы через VPN» (1.0.5)

Дата: 2026-11-01. Источник правил — набор **`vitosamin-full`** из проекта
`singbox-manager` (`internal/config/presets/vitosamin-full.json`), на котором работает
домашний роутер владельца. В роутере `final` — **direct**: через VPN идут только
перечисленные сервисы, всё остальное — напрямую. Приложение же по умолчанию гнало через
VPN весь трафик, из-за чего посторонние сайты (в том числе `google.com`) шли через
медленный/блокирующий их выход.

## Что перенесено

`assets/routing/services.json` — 23 сервиса, 2408 записей (домены, суффиксы, CIDR):

| Источник | Что |
|---|---|
| `enabled_geo` набора (21 тег) | Twitter, Meta, TikTok, Discord, Viber, Netflix, Twitch, TMDB, RuTracker, GitHub, Intel, Notion, Speedtest, Telegram, Facebook, Instagram, OpenAI, WhatsApp, Spotify |
| свои списки владельца | `YOUTUBE` (+ geosite-youtube, `googleusercontent.com`, `gstatic.com`, `googleapis.com` — картинки и статика), `CloudFMy` (+ geosite-cloudflare), `Block` (355 доменов), `AI` (OpenAI, Claude, Gemini, Perplexity и т.п.) |
| Telegram | добавлены его сети (`149.154.160.0/20`, `91.108.x`) — без них часть Telegram уходила бы напрямую |
| `Ru` | домены добавлены в `assets/geo/ru_extra.txt` (правило России и так пускает `.ru`/`.su` напрямую) |

Данные взяты из `SagerNet/sing-geosite` (rule-set, декомпилировано sing-box 1.13.0),
поэтому в APK всё лежит готовым: core ничего не скачивает.

## Как это работает в конфиге

`effectiveRouteRules(..., servicesOnly: true)` добавляет после правил приложения:

0. `preset:block-quic` — reject UDP/443. Как и в роутере (`block_quic`), QUIC
   блокируется, приложения откатываются на TCP: иначе UDP-запрос картинок уходил
   мимо правил (прямо) и превью YouTube не грузились, хотя видео шло;
1. по правилу `preset:svc:<tag>` на сервис — `outbound: proxy`, домены/суффиксы/CIDR;
2. `preset:direct-names` — `outbound: direct`, `domain_regex: [".*"]`, последним:
   всё, что не поймали сервисы, идёт напрямую; ядро добавляет к нему DNS-правило, поэтому
   такие имена резолвятся прямым DNS;
3. `preset:direct-ip` — `outbound: direct`, `0.0.0.0/0` и `::/0`, для соединений, где
   домен не определился (sniff не дал имени).

Порядок важен: правила приложения (LAN, Россия) → сервисы → «всё остальное напрямую».
Ядро hiddify-core ставит `sniff` перед правилами приложения, поэтому доменные условия
работают.

Переключатель — «Настройки → Маршрутизация → Только нужные сервисы через VPN», по
умолчанию **включён**. Выключение возвращает прежнее поведение (весь трафик через VPN).

## DNS

Прямой DNS остаётся `udp://77.88.8.8` (Яндекс) с фолбэком группы на `8.8.8.8`; сервисные
имена резолвятся удалённым DNS через туннель. Заблокированные сервисы (YouTube, Telegram,
Instagram, …) идут через VPN, остальные сайты — напрямую и резолвятся прямым DNS.

## Проверка

- `flutter analyze` — чисто;
- `test/features/route_rules/effective_route_rules_services_test.dart` — порядок правил,
  outbound сервисов, два catch-all последними, выключенный режим не добавляет ничего;
- в собранном APK `assets/routing/services.json` и `assets/geo/*` лежат внутри.
