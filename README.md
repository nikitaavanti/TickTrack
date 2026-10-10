# TickTrack

Приложение в строке меню macOS для учёта рабочего времени по задачам YouTrack. Утром вы составляете план из задач, днём переключаетесь между ними одним кликом или клавишей, а время сразу списывается в YouTrack как work items.

- Техническое задание: [docs/SPEC.md](docs/SPEC.md)
- Интерактивный прототип: [docs/prototype.html](docs/prototype.html), открывается в браузере
- Решения и отступления от ТЗ: [docs/decisions.md](docs/decisions.md)

## Требования

- macOS 26 Tahoe.
- Swift 6.2. Хватает Command Line Tools, Xcode не обязателен.

## Сборка и запуск

```sh
scripts/build-app.sh          # собирает build/TickTrack.app (release)
open build/TickTrack.app
```

При первом запуске откроются настройки. Укажите адрес YouTrack и постоянный токен (Профиль → Account Security → New token).

Для разработки, без `.app`:

```sh
swift run                     # запуск из терминала
TICKTRACK_DEMO=1 swift run    # с тестовыми задачами вместо настоящего YouTrack
```

В демо-режиме состояние хранится отдельно и не смешивается с настоящим учётом.

## Тесты

```sh
scripts/test.sh
```

Тесты покрывают ядро учёта: правила округления и коротких отрезков, переключение задач, простой, «Я забыл переключиться», деление по полуночи, очередь отправки и сохранение состояния.

## Устройство

| Папка | Что внутри |
|---|---|
| `Sources/TickTrackCore` | Логика без UI: модели, правила списания, состояние учёта, очередь отправки, клиент YouTrack, хранение |
| `Sources/TickTrack` | Приложение: модель (`AppModel`), строка меню, плавающие панели, окна |
| `Sources/TickTrack/Views` | Экраны на SwiftUI |
| `Tests/TickTrackCoreTests` | Тесты ядра (swift-testing) |
| `Support/Info.plist` | `LSUIElement`, идентификатор приложения, версия |

Данные хранятся в `~/Library/Application Support/TickTrack/state.json`, настройки — в `UserDefaults`, токен — в Keychain.
