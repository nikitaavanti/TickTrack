# TickTrack

Приложение в строке меню macOS для учёта рабочего времени по задачам YouTrack. Утром вы составляете план из задач, днём переключаетесь между ними одним кликом или клавишей, а время сразу списывается в YouTrack как work items.

- Техническое задание: [docs/SPEC.md](docs/SPEC.md)
- Интерактивный прототип: [docs/prototype.html](docs/prototype.html), открывается в браузере
- Решения и отступления от ТЗ: [docs/decisions.md](docs/decisions.md)
- Изменения по версиям: [CHANGELOG.md](CHANGELOG.md)
- Идеи и предложения: [docs/ideas.md](docs/ideas.md)

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

## Ветки

- `develop` — текущая разработка. Все изменения коммитятся сюда.
- `main` — выпущенные версии. В `main` попадает только выпуск: `develop` вливается в `main`, и на этот коммит ставится метка версии.

## Версии

Версия по [SemVer](https://semver.org/lang/ru/): PATCH — исправления, MINOR — новые возможности, MAJOR — крупная веха (1.0.0 — когда пройдены критерии приёмки из ТЗ).

- Версия для людей — `CFBundleShortVersionString` в [Support/Info.plist](Support/Info.plist). Между выпусками не меняется.
- Номер сборки (`CFBundleVersion`) подставляет `scripts/build-app.sh`: это число коммитов, вручную не трогаем.

Выпуск версии:

1. Перенести изменения в [CHANGELOG.md](CHANGELOG.md) под новый номер и дату.
2. Поменять `CFBundleShortVersionString` в `Support/Info.plist`.
3. Закоммитить в `develop` («Release 0.2.0»).
4. Влить в `main`, поставить метку и отправить: `git switch main && git merge --ff-only develop && git tag v0.2.0 && git push && git push --tags`, затем вернуться в `develop`.
5. Собрать `scripts/build-app.sh` из этого коммита.
