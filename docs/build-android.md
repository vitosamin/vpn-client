# Android-тулчейн и базовая сборка Hiddify APK

**Статус: собралось.** Basic debug-сборка форка Hiddify App v5.3.0 воспроизведена на
NAS 31.10.2026: `dist/hiddify-5.3.0-debug.apk` (универсальный, 3 ABI) и
`dist/hiddify-5.3.0-debug-arm64-v8a.apk` (для реального телефона).

Этот документ — про **тулчейн и сборку**. Про подпись, хранение keystore и
публикацию — отдельно в [android-release.md](android-release.md).

Окружение: Debian GNU/Linux 13 (trixie), x86_64, 8 vCPU, 31 ГБ RAM, 826 ГБ свободно,
сборка под root. Всё, что относится к SDK, стоит **вне** `/root/MyHome` (`/opt`), в
проекте — только артефакты и этот файл.

---

## 1. Какие версии требует проект

Версии взяты из самого репозитория (не «на глаз»):

| Компонент | Версия | Откуда следует |
|---|---|---|
| Flutter / Dart | **3.38.5 / 3.10.4** | `pubspec.yaml` (`environment.flutter: ^3.38.5`, `sdk: ^3.10.4`); Makefile парсит эту строку; `.github/workflows/build.yml` → `FLUTTER_VERSION: '3.38.5'` |
| JDK | **17** | `.github/workflows/build.yml` → `actions/setup-java`, `java-version: 17`; `android/app/build.gradle` → `sourceCompatibility 17`, `jvmTarget 17` |
| Gradle | **8.7** | `android/gradle/wrapper/gradle-wrapper.properties` (`gradle-8.7-all.zip`) |
| Android Gradle Plugin | **8.6.0** | `android/settings.gradle` |
| Kotlin | **2.1.0** | `android/settings.gradle` |
| compileSdk / targetSdk | **36** | `android/app/build.gradle` |
| minSdk | **24** | `flutter.minSdkVersion` (Flutter 3.38.5) |
| Build-tools | **36.0.0** | под compileSdk 36 (AGP также ставит 34.0.0 для старых плагинов) |
| NDK | **28.2.13676358 (r28c)** | `android/app/build.gradle` → `ndkVersion`, workflow → `NDK_VERSION: r28c` |
| hiddify-core | **v5.3.0** (готовый `hiddify-core.aar`) | `dependencies.properties` → `core.version=5.3.0`; `Makefile` → `CORE_URL` |
| Java-плагины сборки | protobuf 0.9.4, wire 5.3.1 | `android/app/build.gradle` (кодогенерация из `src/main/protos`) |

Нюанс: Go для сборки APK **не нужен**. Ядро `hiddify-core` скачивается готовым
архивом с GitHub Releases (`Makefile`, цель `android-libs`) и кладётся в
`android/app/libs/` как `hiddify-core.aar`. Собирать ядро из исходников (submodule)
не требуется.

---

## 2. Что установлено (факт)

| Что | Версия | Путь | Размер | Как ставилось |
|---|---|---|---|---|
| JDK | Temurin **17.0.21+9** | `/opt/jdk` | 319 МБ | tar.gz с api.adoptium.net |
| Android cmdline-tools | **23.0.0** (build 16111833) | `/opt/android-sdk/cmdline-tools/latest` | — | zip с dl.google.com |
| platform-tools | **37.0.1** | `/opt/android-sdk/platform-tools` | — | `sdkmanager` |
| platforms | **android-36** (и 31/33/34/35 — докачал AGP) | `/opt/android-sdk/platforms` | — | `sdkmanager` / AGP |
| build-tools | **36.0.0** (и 34.0.0) | `/opt/android-sdk/build-tools` | — | `sdkmanager` / AGP |
| NDK | **28.2.13676358 (r28c)** | `/opt/android-sdk/ndk` | — | `sdkmanager` |
| CMake | **3.22.1** | `/opt/android-sdk/cmake` | — | AGP докачал при первой сборке |
| Flutter | **3.38.5** stable, Dart **3.10.4**, engine `1527ae0ec5`, framework `f6ff1529fd` | `/opt/flutter` | 2,3 ГБ | tar.xz с storage.googleapis.com |
| Gradle | **8.7** + зависимости | `/root/.gradle` | ~11 ГБ после debug+release сборок | wrapper качает сам |
| Pub-кэш | по `pubspec.lock` (183 пакета) | `/root/.pub-cache` | 0,76 ГБ | `flutter pub get` |

Итого вне проекта занято ~18 ГБ (SDK 3,4 + Flutter 2,3 + JDK 0,3 + Gradle 11 + pub 0,8).

### 2.1. JDK

В Debian 13 (trixie) пакета `openjdk-17-jdk-headless` **нет** (в репозитории только
`openjdk-21`/`openjdk-25`). Поставила официальный Temurin 17 — ровно как в CI:

```bash
mkdir -p /opt/jdk
curl -fL --retry 5 --retry-all-errors -o /tmp/temurin17.tar.gz \
  "https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jdk/hotspot/normal/eclipse"
tar -xzf /tmp/temurin17.tar.gz -C /opt/jdk --strip-components=1
/opt/jdk/bin/java -version   # openjdk 17.0.21 2026-10-20 (Temurin)
```

### 2.2. Android SDK

```bash
mkdir -p /opt/android-sdk/cmdline-tools
curl -fL --retry 5 -o /tmp/cmdline-tools.zip \
  https://dl.google.com/android/repository/commandlinetools-linux-16111833_latest.zip
unzip -q /tmp/cmdline-tools.zip -d /tmp/cmdline-tools-extract
mv /tmp/cmdline-tools-extract/cmdline-tools /opt/android-sdk/cmdline-tools/latest

export JAVA_HOME=/opt/jdk
export ANDROID_SDK_ROOT=/opt/android-sdk
/opt/android-sdk/cmdline-tools/latest/bin/sdkmanager --sdk_root=/opt/android-sdk \
  "platform-tools" "platforms;android-36" "build-tools;36.0.0" "ndk;28.2.13676358"
```

Лицензии: в cmdline-tools 23.0 `sdkmanager --licenses` объявлен устаревшим
(«option is no longer needed»), лицензия пишется в
`/opt/android-sdk/licenses/android-sdk-license` сама при установке пакетов. Если
файла нет — можно создать вручную с хэшем `24333f8a63b6825ea9c5514f83c2829b004d1fee`
(то же, что делает CI при `setup-android`).

### 2.3. Flutter

Ставится **вне** проекта, версия строго 3.38.5 (как в `pubspec.yaml`):

```bash
curl -fL --retry 5 --retry-all-errors -o /opt/flutter_linux_3.38.5-stable.tar.xz \
  https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.38.5-stable.tar.xz
tar -xf /opt/flutter_linux_3.38.5-stable.tar.xz -C /opt
git config --global --add safe.directory /opt/flutter   # обязательно под root
/opt/flutter/bin/flutter --version                        # Flutter 3.38.5 • Dart 3.10.4
```

### 2.4. Переменные окружения (в каждом shell перед сборкой)

```bash
export JAVA_HOME=/opt/jdk
export ANDROID_SDK_ROOT=/opt/android-sdk
export ANDROID_HOME=/opt/android-sdk
export PATH=/opt/flutter/bin:/opt/jdk/bin:$PATH
export FLUTTER_SUPPRESS_ANALYTICS=true
```

`flutter pub get` сам создаёт `android/local.properties`:
`sdk.dir=/opt/android-sdk`, `flutter.sdk=/opt/flutter`.

---

## 3. Подготовка проекта

### 3.1. Submodule hiddify-core (по HTTPS)

В `.gitmodules` upstream URL был SSH (`ssh://git@github.com/...`), на NAS SSH-ключ
к GitHub не настроен. URL переключён на HTTPS (это единственное изменение
отслеживаемого файла в `app/`, отмечено в отчёте):

```bash
cd /root/MyHome/vpn-client/app
git config -f .gitmodules submodule.hiddify-core.url https://github.com/hiddify/hiddify-core.git
git submodule sync
git submodule update --init --recursive
```

Вложенный `hiddify-core/ray2sing` тоже прописан по SSH — его клонировала с
подменой на лету, без правки `.gitmodules` ядра:

```bash
git -c url."https://github.com/".insteadOf=git@github.com: submodule update --init --recursive
git submodule status   # hiddify-core db79454 (v3.2.0-247-gdb79454), оба вложенных checked out
```

Для сборки APK submodule не обязателен (ядро берётся из релиза готовым), но
нужен для будущей сборки/патча ядра из исходников.

### 3.2. Кодогенерация и зависимости

```bash
cd /root/MyHome/vpn-client/app
flutter pub get      # ~183 пакета, предупреждение «183 packages have newer versions» — норма
make gen             # dart run build_runner build --delete-conflicting-outputs (~2 мин)
make translate       # dart run slang, генерация lib/gen/translations*.g.dart (~1 c)
```

`make gen` и `make translate` создают `*.g.dart`, `*.freezed.dart`,
`lib/gen/*` — они в `.gitignore` и в репозитории отсутствуют, без них сборка не
скомпилируется. Предупреждения `analyzer version may not fully support SDK` — не
критичны, сборка проходит.

### 3.3. Готовое ядро

```bash
make android-libs CHANNEL=prod   # = curl hiddify-lib-android.tar.gz v5.3.0 → android/app/libs/
```

**Важно:** без `CHANNEL=prod` Makefile берёт `CHANNEL=dev` и качает ядро из
тега `draft` (`CORE_URL=.../download/draft`), а не из v5.3.0. Для релизной
версии нужен `CHANNEL=prod`.

Результат: `android/app/libs/hiddify-core.aar` (~164,7 МБ).

---

## 4. Сборка APK

```bash
cd /root/MyHome/vpn-client/app
# env из п.2.4
flutter build apk --debug
```

Что происходит: Gradle 8.7 wrapper качает сам себя и зависимости, AGP
докачивает недостающие платформы (android-31/33/34/35), build-tools 34.0.0 и
CMake 3.22.1, затем `assembleDebug`.

Тайминги на этом NAS (после установки SDK, «холодный» Gradle-кэш):

| Этап | Время |
|---|---|
| `flutter pub get` | ~1 мин |
| `make gen` (build_runner) | ~2 мин |
| `make android-libs` (скачать 165 МБ) | ~10 с |
| первая `flutter build apk --debug` (сеть + Gradle) | **519,5 с (~8,7 мин)**, из них загрузка зависимостей Gradle ~3–4 мин |
| повторная сборка (кэш тёплый) | ~1–2 мин |

Суммарно «с нуля» на чистой машине: ~20–30 мин при нормальной сети (SDK ~3,4 ГБ +
Flutter 1,46 ГБ + Gradle-зависимости ~9 ГБ). Диск: ~16 ГБ вне проекта.

Выход: `app/build/app/outputs/flutter-apk/`

| Файл | Размер | Комментарий |
|---|---|---|
| `app-debug.apk` | 262 379 704 Б (251 МиБ) | universal, все ABI (`splits.abi.universalApk true`) |
| `app-arm64-v8a-debug.apk` | 132 970 428 Б (127 МиБ) | только arm64 — для реального телефона |
| `app-armeabi-v7a-debug.apk` | ~120 МиБ | старые 32-битные |
| `app-x86_64-debug.apk` | ~127 МиБ | эмулятор |

Debug-APK большой, потому что внутри debug-символы Flutter и Go-ядро
`libhiddify-core.so` (126,9 МБ в распакованном виде на arm64). Release будет
заметно меньше.

### 4.1. Что внутри (проверка)

```bash
/opt/android-sdk/build-tools/36.0.0/aapt2 dump badging \
  build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk | head -4
# package: name='app.hiddify.com' versionCode='50300' versionName='5.3.0'
# compileSdkVersion='36'
# minSdkVersion:'24'  targetSdkVersion:'36'  native-code: 'arm64-v8a'

unzip -l build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk | grep libhiddify
# lib/arm64-v8a/libhiddify-core.so
```

`applicationId` пока дефолтный Hiddify — `app.hiddify.com`, подпись — debug-ключ.

### 4.2. Release-сборка (проверка «сборка возможна», но не для публикации)

Дополнительно проверена release-сборка:

```bash
flutter build apk --release
# Running Gradle task 'assembleRelease'... 312.0s
# ✓ Built build/app/outputs/flutter-apk/app-release.apk (174.4MB)
```

| Файл | Размер |
|---|---|
| `app-release.apk` (universal) | 174 398 739 Б (166 МиБ) |
| `app-arm64-v8a-release.apk` | 62 812 990 Б (60 МиБ) |
| `app-armeabi-v7a-release.apk` | ~59 МиБ |
| `app-x86_64-release.apk` | ~63 МиБ |

Подпись release-APK — **Android Debug** (`CN=Android Debug`): в
`android/app/build.gradle` при отсутствии `android/key.properties` используется
`signingConfigs.debug`. То есть release-сборка собирается, но **в сторы и на сайт
такой APK отдавать нельзя** — нужен настоящий keystore (см. раздел 7 и
[android-release.md](android-release.md)). В `dist/` положены только debug-APK;
release лежит в `app/build/app/outputs/flutter-apk/app-release.apk`.

Сборка `appbundle` (`flutter build appbundle --release`) не проверялась — тот же
Gradle-пайплайн, отдельного риска нет.

---

## 5. Артефакты в `dist/`

| Файл | Размер | SHA-256 |
|---|---|---|
| `vpn-client/dist/hiddify-5.3.0-debug.apk` (universal) | 262 379 704 Б | `efd7d27bffa28e1b828fc244777615446cbe13454e0f763144ccd3347e0b2e38` |
| `vpn-client/dist/hiddify-5.3.0-debug-arm64-v8a.apk` | 132 970 428 Б | `ca177058698545efdf03de60bff388651949a09e29e12a336cbed1c47b5e1e39` |

Контрольные суммы также лежат в `vpn-client/dist/SHA256SUMS.txt`.

Установка на телефон: `adb install -r dist/hiddify-5.3.0-debug-arm64-v8a.apk`
(на NAS нет подключённого устройства — проверка запуска на устройстве ещё
предстоит).

---

## 6. Встреченные проблемы и решения

1. **Нет JDK 17 в Debian 13.** Пакета `openjdk-17-*` в trixie нет → Temurin 17
   tar.gz в `/opt/jdk` (совпадает с CI: Java 17, Zulu/Temurin).
2. **Submodule по SSH.** `.gitmodules` указывал на `ssh://git@github.com/...`, а
   доступа по SSH-ключу нет. Исправлено на HTTPS (единственная правка
   отслеживаемого файла в `app/`), вложенный `ray2sing` — через
   `-c url.<https>.insteadOf=git@github.com:`. Первый запуск
   `git submodule update --recursive` при этом оборвался на SSH-вложенном, и
   `hiddify-core/hiddify-sing-box` остался с неполным worktree (в `git status`
   сотни `D`). Лечится одной командой в этом каталоге:
   `git reset --hard` (файлы восстановились из объекта, ничего не потеряно).
3. **cmdline-tools 23.0 (новый Android CLI).** `sdkmanager` помечен deprecated,
   `--licenses` ничего не спрашивает; `flutter doctor -v` пишет
   «Android license status unknown», хотя `android-sdk-license` на месте. На
   сборку не влияет: Gradle видит лицензии и ставит пакеты. Лечится установкой
   старого `cmdline-tools` (например 19.0), но необходимости нет.
4. **`make android-libs` без `CHANNEL=prod` тянет `draft`.** Для v5.3.0 обязательно
   `make android-libs CHANNEL=prod`.
5. **AGP сам докачивает SDK-компоненты.** В логе первой сборки видно установку
   CMake 3.22.1, platform 31/33/34/35, build-tools 34.0.0 — это нормально, нужен
   доступ в сеть к dl.google.com/maven.google.com и принятые лицензии.
6. **`flutter pub get` и `build_runner` ругаются на устаревшие версии**
   (analyzer/SDK, 183 пакета с новее) — это не ошибки, проект собран на
   зафиксированном `pubspec.lock`.
7. **`--debug` обязателен без keystore.** В `android/app/build.gradle` release
   подписывается debug-ключом, если нет `android/key.properties`; для публикации
   нужен настоящий keystore (см. [android-release.md](android-release.md)).

---

## 7. Что осталось для релиза (Android)

- [ ] **Keystore.** Сейчас его нет: release-сборка подписалась бы debug-ключом.
      Создать `release.jks`, хранить у Виталия (и в сейфе), прописать
      `android/key.properties` (`storeFile`, `storePassword`, `keyPassword`,
      `keyAlias`) — формат и `keytool`-команда в
      [android-release.md](android-release.md).
- [ ] **applicationId.** Сейчас `app.hiddify.com`; для нашего продукта —
      свой, например `ru.<brand>.vpn` (меняется в `android/app/build.gradle`,
      `namespace` трогать не обязательно; после смены приложение = новое для
      телефона/сторов).
- [ ] **Название, иконки, splash.** Сейчас: label `Hiddify`, иконки Hiddify
      (`res/mipmap-*`, `ic_launcher-playstore.png`), splash
      (`flutter_native_splash`). Нужны брендовые растр-иконки (в `brand/` пока пусто).
- [ ] **versionCode/versionName.** `5.3.0+50300` из `pubspec.yaml`; перед релизом
      поставить свою нумерацию (`version: x.y.z+build`).
- [ ] **Release-сборка и подпись.** `flutter build apk --release` уже проверена и
      собирается (312 с), но подписана debug-ключом — для релиза нужен keystore и
      `android/key.properties`, затем `flutter build apk --release` /
      `flutter build appbundle --release` и отправка в RuStore/на сайт/Play
      (решение владельца).
- [ ] **Проверка на устройстве.** Туннель поднимается, RU-трафик direct,
      автоселект/фолбэк, ввод кода активации — после интеграции наших правок.
- [ ] **SENTRY_DSN** (если оставляем телеметрию Hiddify) — задаётся
      `--dart-define sentry_dsn=...`; без него сборка проходит.

---

## 8. Воспроизведение с нуля (короткая шпаргалка)

```bash
# 1. JSON/JDK/Flutter/SDK — команды из п.2.1–2.3
# 2. env — п.2.4
# 3. проект
cd /root/MyHome/vpn-client/app
git config -f .gitmodules submodule.hiddify-core.url https://github.com/hiddify/hiddify-core.git
git submodule sync && git submodule update --init --recursive
flutter pub get && make gen && make translate
make android-libs CHANNEL=prod
# 4. сборка
flutter build apk --debug
# 5. артефакты
cp build/app/outputs/flutter-apk/app-debug.apk \
   /root/MyHome/vpn-client/dist/hiddify-5.3.0-debug.apk
cp build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk \
   /root/MyHome/vpn-client/dist/hiddify-5.3.0-debug-arm64-v8a.apk
```
