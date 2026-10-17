# TickTrack

Приложение в строке меню macOS для учёта рабочего времени по задачам YouTrack. Утром вы составляете план из задач, днём переключаетесь между ними одним кликом или клавишей, а время сразу списывается в YouTrack как work items.

- Техническое задание: [docs/SPEC.md](docs/SPEC.md)
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

Тесты покрывают ядро учёта: правило коротких отрезков, переключение задач, простой, «Я забыл переключиться», деление по полуночи, очередь отправки и сохранение состояния.

## Устройство

| Папка | Что внутри |
|---|---|
| `Sources/TickTrackCore` | Логика без UI: модели, правила списания, состояние учёта, очередь отправки, клиент YouTrack, хранение |
| `Sources/TickTrack` | Приложение: модель (`AppModel`), строка меню, плавающие панели, окна |
| `Sources/TickTrack/Views` | Экраны на SwiftUI |
| `Tests/TickTrackCoreTests` | Тесты ядра (swift-testing) |
| `Support/Info.plist` | `LSUIElement`, идентификатор приложения, версия |
| `Support/` | Графика: иконка, кот в строке меню, анимация (см. «Графика») |
| `scripts/` | Сборка `.app`, тесты, подготовка анимации |

Данные хранятся в `~/Library/Application Support/TickTrack/state.json` (демо-режим — `demo-state.json` рядом), настройки — в `UserDefaults`, токен — в Keychain.

## Графика

Все картинки лежат в `Support/`, в приложение их копирует `scripts/build-app.sh`. При `swift run` ресурсов нет: в строке меню вместо кота часы, в «О программе» — обычная иконка.

| Файл | Что это | Где используется |
|---|---|---|
| `Support/AppIcon.png` | Иконка приложения, 1024×1024, исходник для `.icns` | — |
| `Support/AppIcon.icns` | Иконка приложения | `CFBundleIconFile` в `Support/Info.plist`; бейдж на карточках списания |
| `Support/MenuBar/CatSleeping.png` | Кот в строке меню: учёт не идёт | `StatusIcon` в `Sources/TickTrack/MenuBarController.swift` |
| `Support/MenuBar/CatPaused.png` | Кот в строке меню: учёт остановлен посреди дня | то же |
| `Support/MenuBar/CatActive.png` | Кот в строке меню: учёт идёт | то же |
| `Support/AboutAnimation.webp` | Анимированный кот, 1024×1024, исходник | — |
| `Support/AboutAnimation.png` | Та же анимация в APNG 192×192, её читает приложение | `AppIconAnimation` в `Sources/TickTrack/Views/AboutView.swift`: «О программе» и вопрос при выходе |

У каждого кота есть пара `@2x`. Размеры: 28×22 px и 56×44 px.

Как заменить:

- **Кот в строке меню.** Значение имеет только прозрачность: приложение перекрашивает картинку в цвет текста строки меню, поэтому она одинаково видна в светлой и тёмной теме. В правом нижнем углу (5×5 pt) код рисует цветную точку состояния, там лучше оставить пусто. Если меняются имена файлов, их нужно поменять и в `StatusIcon`.
- **Анимация.** Положить новый анимированный WebP в `Support/AboutAnimation.webp` и выполнить `swift scripts/make-about-animation.swift`: он пересоберёт `AboutAnimation.png`.
- **Иконка.** Отдельного сценария нет, `.icns` собирается из PNG так:

  ```sh
  mkdir AppIcon.iconset
  for s in 16 32 128 256 512; do
    sips -z $s $s Support/AppIcon.png --out AppIcon.iconset/icon_${s}x${s}.png
    sips -z $((s*2)) $((s*2)) Support/AppIcon.png --out AppIcon.iconset/icon_${s}x${s}@2x.png
  done
  iconutil -c icns AppIcon.iconset -o Support/AppIcon.icns && rm -r AppIcon.iconset
  ```

  macOS 26 показывает `.icns` уменьшенной на серой подложке. Иконка под Liquid Glass (формат `.icon`) требует Xcode, см. [docs/ideas.md](docs/ideas.md).

## Своя сборка

Чтобы своя версия на одном Mac с TickTrack не делила с ним данные, поменяйте:

- `CFBundleIdentifier` в `Support/Info.plist` (`com.nikitaavanti.TickTrack`). От него зависят настройки в `UserDefaults` и автозапуск.
- Папку `TickTrack` в `StateStore.defaultURL` (`Sources/TickTrackCore/StateStore.swift`): там лежат `state.json` и `demo-state.json`.
- Службу Keychain `TickTrack.YouTrack` в `Sources/TickTrack/System.swift`: под ней хранится токен.
- Сочетание ⌥⇧T по умолчанию в `Sources/TickTrack/AppSettings.swift`: если запущены обе версии, оно достанется той, что запустилась первой.

Имя, создатель и копирайт: `CFBundleName`, `CFBundleDisplayName` и `NSHumanReadableCopyright` в `Support/Info.plist`, имя, почта и ссылка на исходный код (`sourceURL`, её нужно заменить на свой репозиторий) — в `Sources/TickTrack/Views/AboutView.swift`. Графика — в разделе выше.

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

## Лицензия

TickTrack распространяется по лицензии [GNU GPL v3](LICENSE). Код можно изменять и распространять, в том числе свою версию, если она тоже распространяется по GPL v3 вместе с исходным кодом и в ней отмечено, что и когда изменено.
