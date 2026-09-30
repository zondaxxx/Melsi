# Melsi

Кроссплатформенный VPN-клиент на ядре [sing-box](https://github.com/SagerNet/sing-box) 1.14 — в духе Karing, с упором на умный автовыбор сервера, игровой режим и раздельную маршрутизацию по приложениям.

Платформы: **Android** (APK), **iOS** (IPA), **macOS** (DMG, universal), **Windows** (установщик и portable), **Linux** (deb, tar.gz, AppImage).

## Возможности

**Протоколы.** VLESS (Reality, Vision), VMess, Trojan, Shadowsocks (SIP002, SS2022, obfs / v2ray-plugin / shadow-tls), Hysteria, Hysteria2 (obfs, port hopping), TUIC v5, AnyTLS, Snell, WireGuard, SSH, SOCKS, HTTP, Naive (Android и iOS).

**Подписки.** base64 и обычные списки ссылок, Clash/Mihomo YAML, JSON sing-box и Xray, WireGuard `.conf`. Приложение показывает трафик и срок действия из заголовков провайдера и само обновляет подписки. Импорт: ссылка, буфер обмена, QR-код, файл и deep link (`melsi://`, `sing-box://`, `clash://`, `hiddify://`).

**Умный автовыбор.** Движок на Go непрерывно измеряет пинг, джиттер и потери каждого сервера.
- Режимы: «Пинг», «Баланс», «Стабильность» и «Игры».
- Защита от «прыганья»: сервер меняется, только если новый заметно лучше и текущий проработал минимальное время.
- Если текущий сервер падает, переключение происходит мгновенно.
- В интерфейсе видна причина переключения, например «джиттер 3 мс против 21 мс».

**Игровой режим.**
- 32 пресета игр для ПК и мобильных: CS2, Dota 2, Valorant, PUBG Mobile, Standoff 2, Genshin и другие.
- Игры идут через отдельную группу серверов. Она оценивает серверы по джиттеру и потерям и предпочитает UDP-протоколы (Hysteria2, TUIC, WireGuard).
- Загрузки из лаунчеров и CDN идут напрямую, чтобы не нагружать туннель.
- Стек с низкой задержкой: system TUN и TCP Fast Open.

**Маршрутизация.**
- Пресеты: «Весь трафик», «Умный РФ» (российские сайты напрямую), «Только заблокированное», «Напрямую».
- Раздельное туннелирование по приложениям: на Android по пакетам, на десктопе по процессам.
- Блокировка рекламы.
- Свои списки доменов: напрямую, через прокси и заблокировать.

**Защита.** Kill switch (strict route) и анти-DPI (фрагментация TLS ClientHello). Основные наборы правил встроены в приложение, поэтому первое подключение работает, даже если GitHub недоступен.

**Интерфейс.** Дизайн в стиле Apple: пружинные анимации, полупрозрачные материалы, светлая и тёмная темы, русский и английский языки. На Android есть плитка в шторке уведомлений, автоподключение после загрузки и поддержка постоянного VPN (Always-on).

## Архитектура

```
app/     Flutter: интерфейс, состояние, парсеры, генератор конфига sing-box
core/    Go: движок автовыбора и игрового режима, демон melsi-core, биндинг gomobile
docs/    CONTRACT.md — контракт между слоями
scripts/ сборка ядра и libbox
packaging/ установщики (deb, AppImage, DMG, Inno Setup)
```

- **Android / iOS.** sing-box работает внутри `VpnService` или Packet Tunnel через libbox. Движок `melsicore` собран в ту же библиотеку.
- **Windows / macOS / Linux.** Приложение запускает `melsi-core` с правами администратора. Это sing-box и движок в одном процессе.
- **Управление.** Интерфейс общается с ядром по HTTP на `127.0.0.1`: Clash API на порту 9790, API движка на порту 9791.

Подробности — в [docs/CONTRACT.md](docs/CONTRACT.md).

## Сборка

Нужны Flutter 3.47, Go 1.25.5+ и JDK 17. Для Android также нужен NDK, для iOS и macOS — Xcode.

```bash
# Android
scripts/build-libbox.sh android          # → app/android/app/libs/libbox.aar
cd app && flutter build apk --split-per-abi

# iOS (только macOS)
scripts/build-libbox.sh apple            # → app/ios/Frameworks/Libbox.xcframework
cd app && flutter build ios --no-codesign

# Десктоп: сначала ядро, затем приложение
scripts/build-core.sh darwin universal   # или: windows amd64 / linux amd64
cd app && flutter build macos            # или: windows / linux
```

Тесты:

```bash
cd core && go test ./...
cd app && flutter test    # с SING_BOX_BIN=<путь к sing-box> конфиги проверяются через sing-box check
```

Всё это собирает CI (`.github/workflows/build.yml`) и выкладывает в релиз при пуше тега `v*`. Секреты для подписи описаны в [packaging/README.md](packaging/README.md).

## Ограничения

- **iOS.** Packet Tunnel требует подписи командой с правом Network Extension. CI собирает неподписанный IPA, его нужно переподписать. Раздельное туннелирование по приложениям iOS не поддерживает.
- **Windows.** Приложение запускается от имени администратора: это нужно для TUN.
- **macOS.** DMG подписан ad-hoc, при первом запуске откройте его через ПКМ → «Открыть».
- **Naive** работает только на мобильных: на десктопе ядро собрано без cronet.
- **Нет в sing-box**, поэтому пропускаются: ShadowsocksR, транспорт xhttp, AmneziaWG.
