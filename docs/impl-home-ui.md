> **Обновлено в 1.0.2:** круг заменён кнопкой-pill, см. [impl-1.0.2.md](impl-1.0.2.md). Ниже — отчёт о версии 1.0.1.

# Главный экран Vitosamin и ссылка на Telegram

**Статус: готово.** Ветка `feat/home-ui`, worktree `/root/MyHome/vpn-client/app-ui`
(от `main` 7a37aba — с активацией, брендом и автоселектом).

| | |
|---|---|
| Коммиты | `feat(home): brand hero, empty state and Telegram group link`<br>`fix(home): use the real Telegram group invite link` |
| `flutter analyze` | No issues found |
| `flutter test` | 287 passed |
| Debug APK | `app-ui/build/app/outputs/flutter-apk/app-debug.apk` (248 МБ, universal debug) |
| sha256 | `de28561ff8cbb371790e28d41e509babbf7c65205bdb0d5015f27ab9d3f85c7c` |
| Логика | активация, автоселект, регион, ядро — **не менялись** |

---

## 1. Hero-блок на главной

Новый файл `lib/features/home/widget/home_hero.dart`, класс `HomeHero`:

- карточка с мягким градиентом `#16243D → #1E3150` и двумя размытыми свечениями
  акцента `#5B79FF` (без резких пятен, без «кислотности»); радиус 28, тень в тон;
- шапка: белая монограмма **V** (`assets/images/logo.svg`) + имя бренда;
- крупный статус: «Не подключено» / «Подключение…» / «Подключено» / «Не удалось
  подключиться» и подпись-пояснение (что делать или что мешает: мёртвый выбранный
  сервер, проблема хопа). Текст берётся из тех же состояний ядра, что и раньше —
  ничего не придумано, статус сменяется через `AnimatedSwitcher`, точка — `AnimatedContainer`;
- кнопка подключения — существующий `ConnectionButton` (вся логика ядра, ошибки,
  haptics, цепочка — без изменений). У него появился параметр `showLabel = true`:
  в hero подпись под кругом выключена, потому что статус теперь над кнопкой;
- активный сервер — существующий `ActiveProxyFooter` (строка сервера + бейдж
  «авто»/«фейловер» из автоселекта). Код автоселекта не трогался;
- подписка: имя профиля, остаток трафика и срок из `subscription-userinfo`
  (`activeProfileProvider` → `RemoteProfileEntity.subInfo`), тап открывает шторку
  профилей — как раньше открывалась карточка профиля на главной;
- внизу — плитка «Мы в Telegram» (см. §3).

Фон страницы: вместо картинки карты мира (похожа на «глобус» и была декором
апстрима) — спокойный радиальный градиент: в тёмной теме едва заметное свечение,
в светлой — слабый акцентный ореол. Hero тёмный в обеих темах (брендовое решение):
все тексты на нём рисуются явными белыми цветами, поэтому контраст не зависит от темы.

Ширина ограничена 620 px — на планшете/десктопе карточка не растягивается.

## 2. Пустое состояние

`HomeEmptyView` в том же файле, показывается, когда профилей нет
(`hasAnyProfile == false`):

- монограмма V акцентным цветом;
- «Введите код доступа или добавьте подписку» + пояснение, откуда берётся код;
- кнопки **«У меня есть код»** (→ `/activate`) и **«Добавить подписку»**
  (→ существующая шторка `showAddProfile`, FixBtns не менялись);
- ненавязчивая ссылка на Telegram.

AppBar не менялся: логотип, название, версия, иконка ключа (активация) и «+»
(добавить профиль) — все входы на месте. Нижняя плашка «Быстрые настройки»
(входы: маршрутизация, логи и т.п.) сохранена.

## 3. Telegram

- `lib/core/model/constants.dart` (ссылка **уже реальная**, приглашение в приватную
  группу владельца):
  ```dart
  /// The owner's Telegram group: a private-group invite link. Change it here only — the home
  /// tile, the empty home and the About row all read this constant.
  static const telegramGroupUrl = "https://t.me/+0PsfppRewaRiOTYy";
  ```
  **Менять ссылку только здесь** — её используют три места: плитка на главной,
  пустое состояние и строка в About. Если владелец сменит группу, достаточно
  заменить строку и пересобрать APK (ключи строк/переводы не затрагиваются).
- Открытие — существующим механизмом `UriUtils.tryLaunch`
  (`url_launcher`, `LaunchMode.externalApplication`), как privacy/terms в About;
  новых зависимостей нет. Иконка — `SimpleIcons.telegram` (пакет `simple_icons`
  уже в проекте).
- About (`lib/features/about/widget/about_page.dart`): строка «Группа в Telegram»
  рядом с privacy/terms, перед обязательной строкой лицензии.
- Главная: плитка `OutlinedButton` с белой рамкой — заметная, но не кричащая;
  в пустом состоянии — `TextButton`.

## 4. Заодно убрано (Hiddify-арт на главной)

- Кнопка подключения больше не рисует **логотип «H» апстрима**: painter
  по-прежнему анимирует свет/радар, но `drawLogo: false`, а поверх круга —
  наша белая монограмма V (SVG, `ColorFilter`). Так же убран сезонный арт
  Nowruz (19–23 марта подменял иконку картинкой Hiddify): файлы
  `connect_norouz.PNG` / `disconnect_norouz.PNG` удалены из `pubspec.yaml` и с диска.
- Удалён декор `world_map.png` (карта мира — визуально «глобус», плюс не наш арт);
  файл убран из `pubspec.yaml` и с диска.
- Строка `connection.waiting` («Searching for freedom…») заменена на нейтральную
  «Ожидание ответа…» / «Waiting for a response…» — она видна под кнопкой.

## 5. Строки (ru/en, `dart run slang`)

`pages.home`:
`notConnected`, `protectedConnection`, `telegram`, `telegramSubtitle`,
`emptyTitle`, `emptySubtitle`, `haveCode`, `addSubscription`;
`pages.about.telegramGroup`; изменён `connection.waiting` (ru/en).

Остальные локали наследуют английский (slang fallback), новых дыр в переводе нет.

## 6. Файлы

```
новые:  lib/features/home/widget/home_hero.dart        (hero + пустое состояние)
изм.:   lib/features/home/widget/home_page.dart        (новая композиция, входы сохранены)
        lib/features/home/widget/connection_button.dart(showLabel, V-монограмма, без Nowruz-арта)
        lib/features/about/widget/about_page.dart      (строка Telegram)
        lib/core/model/constants.dart                  (telegramGroupUrl)
        assets/translations/en.i18n.json, ru.i18n.json (строки)
        pubspec.yaml                                   (минус connect/disconnect_norouz, world_map)
удалены: assets/images/connect_norouz.PNG, disconnect_norouz.PNG, world_map.png
```

Не тронуты: `active_proxy_card.dart` (бейдж авто/фейловер как есть), активация,
регион, автоселект, ядро.

## 7. Как проверить

```bash
cd /root/MyHome/vpn-client/app-ui
# если APK внезапно весит больше ~260 МБ, это кеш упаковки Gradle: flutter clean, затем сборка
/opt/flutter/bin/dart run slang
/opt/flutter/bin/dart run build_runner build --delete-conflicting-outputs   # после смены pubspec
/opt/flutter/bin/flutter analyze          # No issues found
/opt/flutter/bin/flutter test             # 287 passed
/opt/flutter/bin/flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

На устройстве:

1. Пустое состояние: удалить все профили → «Введите код доступа или добавьте
   подписку», обе кнопки работают (код → экран активации, подписка → шторка добавления).
2. Активировать код → на главной hero: статус, кнопка, имя профиля, остаток трафика,
   срок; тап по строке подписки открывает профили.
3. Подключиться → статус «Подключено», под кнопкой появляется сервер с бейджем
   «авто»/«фейловер», пинг; отключиться — статус «Не подключено».
4. Telegram (плитка на главной, ссылка в пустом состоянии, строка в About) →
   открывается клиент Telegram/браузер.
5. Светлая и тёмная темы: hero тёмный в обеих, текст читается.

## 8. Что осталось

- **Ссылка Telegram — реальная** (`https://t.me/+0PsfppRewaRiOTYy`, приглашение в
  приватную группу). Меняется в одном месте — `Constants.telegramGroupUrl`; после
  замены нужна пересборка APK.
- **Визуальная проверка на телефоне** — за Лидом/владельцем: в сессии нет ни
  эмулятора, ни устройства, поэтому вёрстка проверена анализом/тестами и статически,
  а не скриншотами. Риски, которые стоит глянуть первыми: узкие экраны (360 dp) —
  длинный русский статус переносится, длинная дата в строке подписки обрезается
  многоточием; высота hero на маленьких экранах (прокручивается).
- Десктопная раскладка не вылизывалась (задача — мобильный дизайн): hero ограничен
  620 px по центру, этого достаточно, чтобы не растягивался.
