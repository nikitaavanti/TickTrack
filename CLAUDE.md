# TickTrack — памятка для Claude

Трекер времени для YouTrack в строке меню macOS. Источник требований — `docs/SPEC.md`. Если ТЗ и `docs/prototype.html` расходятся, прав SPEC. Отступления от ТЗ записываются в `docs/decisions.md`.

## Команды

- Сборка: `swift build`
- Тесты: `scripts/test.sh`. Голый `swift test` без Xcode не находит модуль `Testing`, скрипт добавляет нужные флаги.
- Приложение: `scripts/build-app.sh [debug]`, затем `open build/TickTrack.app`.
- Демо без сервера: `TICKTRACK_DEMO=1 swift run`.
- Проверка вёрстки без доступа к экрану: `TICKTRACK_DEMO=1 TICKTRACK_SNAPSHOTS=<папка> .build/debug/TickTrack` отрисует экраны в PNG (светлая и тёмная тема) и завершится. Стекло и разделители в таком рендере не видны, это нормально.

## Окружение

Xcode не установлен, есть только Command Line Tools (Swift 6.2, SDK macOS 26). Поэтому:
- нет `xcodebuild` и `xcstringstool`, String Catalog не компилируется (см. `docs/decisions.md`);
- скриншот экрана из терминала недоступен (нет разрешения на запись экрана).

## Устройство

- `TickTrackCore` — чистая логика без UI. Любое правило учёта (отрезки, округление, простой, перенос, очередь) пишется здесь как метод `TrackerState` и покрывается тестом.
- `AppModel` (`@Observable`) — время, система (простой, сон, блокировка), YouTrack, окна. Менять `state` только через методы модели или `mutateState`, после изменения состояние сохраняется.
- Таргет приложения собирается с `defaultIsolation(MainActor)`.
- Меню — своя `NSPanel` (`MenuBarController`), а не `MenuBarExtra`; карточки списания — `CardPanelController`. Обе панели неактивирующиеся.
- Подтверждения «Списано / Изменено / Удалено в YouTrack» показываются только после ответа сервера (`AppModel.sync`).

## Соглашения

- Интерфейс и комментарии в коде — на русском, тексты берутся из SPEC.
- Строки интерфейса пишутся как ключи локализации (`Text("…")`), данные из YouTrack — через `Text(verbatim:)`.
- Коммиты — с почтой `nikita.avanti@gmail.com` (задана в локальном конфиге репозитория). Пушит пользователь сам: у сессии нет доступа к GitHub.
