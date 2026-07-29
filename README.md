# Armilen Remote

Форк клиента [RustDesk](https://github.com/rustdesk/rustdesk) для ИТ-студии
ARMILEN. Собран с предустановленным подключением к нашей инфраструктуре и
брендированием; выкладывается на https://www.armilen.ru/support.

Лицензия апстрима AGPL-3.0 сохраняется.

## Отличия от апстрима

- Имя приложения `ArmilenRemote`, свои иконки и логотипы, акцентный цвет как на
  сайте: green-700 `#15803D` на светлой теме, green-500 `#22C55E` на тёмной.
- Свои `hbbs`/`hbbr` и ключ сервера по умолчанию, свой адрес проверки версии.
  Всё это патчится при сборке, см. `.github/actions/apply-branding/action.yml`.
- Отключены регистрация, вход и синхронизация адресной книги через публичный
  сервер RustDesk.
- Ссылки на лицензионное соглашение ведут на `/legal/remote-privacy`.
- Автообновление включено по умолчанию (апстрим держит его выключенным).

## Иконки

Единственный источник — SVG в `scripts/branding/src/`, остальное генерируется:

```sh
SHARP_FROM=/путь/к/armilen-site/node_modules node scripts/branding/generate.mjs
```

Скрипт идемпотентный: пишет Windows `.ico`, macOS `.icns`, мипмапы Android
вместе с цветом фона adaptive-иконки, логотипы внутри Flutter и `res/*` для
Linux. Запускать после любой правки исходных SVG.

Два места, где легко ошибиться:

- **Скругление `rx=96` у `tile-dark.svg` обязательно.** Кадры `.ico` Windows
  рисует как есть, ничем не маскируя: квадратный исходник даст квадратную
  иконку в проводнике, на панели задач и в инсталляторе.
- **`res/scalable.svg` тоже наш.** В темах иконок Linux каталог `scalable`
  приоритетнее битмапов рядом, поэтому забытый файл покажет чужой логотип в
  меню приложений.

## Обновление клиента

Версию клиент узнаёт из `https://www.armilen.ru/api/version-check`: тот
возвращает `{"url": ".../api/download/<версия>"}`, клиент берёт последний
сегмент как номер версии и сравнивает со своим. Три пути обновления, все ведут
в `platform::update_me`:

| Путь | Как работает |
| --- | --- |
| Автообновление | Раз в сутки, установленный Windows-клиент, только без активных сессий. Отключается галкой «Auto update» |
| Кнопка «Update» | Скачивает сборку и перезапускает её с `--update` |
| Ручное скачивание | Свежий `.exe`, запущенный рядом со старой установкой, обновляет её на месте и просит UAC. Отказаться: `--noinstall` |

Ручной путь существует потому, что без него скачанная сборка выглядела
нерабочей: одиночный экземпляр Flutter-раннера находил окно уже запущенной
старой копии и просто поднимал его. Реализация — `upgrade_installed_copy_if_newer`
в `src/core_main.rs`.

## Сборка и выкладка

| Событие | Что происходит |
| --- | --- |
| push в `master` | `flutter-nightly.yml` собирает и перезаписывает релиз `nightly` |
| pull request | `flutter-ci.yml` собирает то же самое, ничего не публикуя |
| новый тег апстрима | таймер на VPS мержит его в `sync/upstream-<версия>`, открывает PR и запускает сборку |
| раз в полчаса на VPS | `armilen-deploy-clients.timer` тянет `nightly` в `/srv/www.armilen.ru/downloads` |

Выкладка сходится со стороны сервера, а не по сигналу из CI: пропущенное
уведомление или ненажатая кнопка не оставят пользователей на старой сборке.
Скрипт выкладки идемпотентный и умеет ждать, пока релиз не дособерётся.

По умолчанию собирается только то, что реально выкладывается:

| Файл на сайте | Джоб |
| --- | --- |
| `armilen-remote-windows.exe` | `build-for-windows-flutter` |
| `armilen-remote-macos.dmg` | `build-for-macOS` → `build-macos-universal` |
| `armilen-remote-linux.AppImage` | `build-rustdesk-linux` → `build-appimage` |
| `armilen-remote-android.apk` | `build-rustdesk-android` → `build-rustdesk-android-universal` |

Sciter, iOS, flatpak и ARM-сборки Linux закрыты входом `full-matrix`: он
включён для сборки по тегу и доступен через `workflow_dispatch`. Ветка
`aarch64-pc-windows-msvc` отключена отдельно — её шаг `Build msi` падает на
ARM-раннере нехваткой памяти, а Windows on ARM и так запускает x64 через
эмуляцию.

`build-macos-universal` склеивает поарочные бандлы в один универсальный
(`scripts/macos-universal.sh`), чтобы на странице загрузки не спрашивать
архитектуру: x86_64-сборка шла бы на Apple Silicon через Rosetta 2, которую
система предлагает доустановить при первом запуске. После `lipo` обязательна
ad-hoc подпись — он стирает существующую, а arm64-macOS неподписанный код не
запускает вообще.

## Операторские команды

Синхронизация с апстримом вручную, на VPS:

```sh
REPO_DIR=/opt/rustdesk-fork node scripts/sync-upstream/sync-upstream.mjs
REPO_DIR=/opt/rustdesk-fork node scripts/sync-upstream/sync-upstream.mjs --force
```

Переменные окружения синхронизации лежат в `/etc/armilen/rustdesk-sync.env`:
`GH_TOKEN` (запись в contents и workflow), `TG_BOT_TOKEN`, `TG_CHAT_ID`,
при необходимости `HTTPS_PROXY`.

Выкладка клиентов вне расписания:

```sh
sudo systemctl start armilen-deploy-clients.service
```
