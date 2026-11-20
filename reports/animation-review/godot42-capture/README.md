# Архив драйверов записи 42

Это **использованные текстовые исходники изолированной проверки**, не новая
игровая сцена, не официальный web export и не установщик Godot. Они сохранены
для аудита команд/камер/условий, а не только как скриншоты. В игру на F5 эти
драйверы не подключены. **Не переносите полную диагностическую кожу `review.gd`
в рабочую сцену.**

Проверенный код — `469953c86ada848094c976e601bf44a86e6107e3`.
`source-hashes.json` — SHA ресурсов этого кода; baseline-модель/appearance/
библиотека/appearance runtime для сравнения взяты из
`1d5d20b2b4bf6ddf5250f7ef322f19db7d2f9d78`, остальные интегрированные функции
для baseline те же. `character_anim.gd` между ними одинаков.

## Что делает каждый файл

- `review_game.gd/.tscn`: настоящие `main.tscn` / `showcase.tscn`, заморозка
  дерева между командами, **реальные физические тики 1/60 с**, буферы ввода.
  Production свет/тени/PBR/среднее качество сохранены. Изменены только fixture
  старта, наблюдатель/видимость UI. В `stop-and-hit` урон вызывается напрямую;
  раздел `clone` использует реальную боевую логику.
- `runtime42.mjs`: пять записей, снимок после каждых пяти тиков (в конце
  42-tick отрезка — укороченный интервал); проверка **13 исходных SHA**, ID
  команды, окончания native `frame_post_draw`, ошибок и реальных состояний.
- `review.gd/.tscn`: точные позы, одинаковые диагностические свет/камера до/после.
  Только `layer=skin` восстанавливает исходные индексы тела в изолированной сцене.
- `review42.mjs` + `final-*-shots.json`: 33 кадра каждого варианта; проверка пяти
  SHA, команды и native post-draw. Файлы конфигурации содержат точные фазы/виды.
- `production42_roundtrip.mjs`: чистый production PCK **без драйвера**,
  реальные Tab/F3/H/G/B/F4, смена размера canvas, две пары H туда/обратно.
- `pack.gd`, `index.html`, `server.mjs`: упаковка уже импортированного проекта,
  запуск настоящей GDScript scene tree через WASM entry point и статический
  сервер `0.0.0.0:5175`. В Node используется loopback **только для локального
  тестового браузера**, не как адрес API для пользовательского приложения.

## Условия повторения

Архив сохраняет исходные рабочие пути. Из корня репозитория скопируйте
`*.mjs`, `pack.gd` в `.local/godot-visual/`, `index.html` — в
`.local/godot-visual/public/`, `source-hashes.json` и shot JSON — в
`.local/review/repair-42/`. Node-импорт Playwright относителен именно к этому
положению, а не к каталогу отчёта. Зависимости —
`npm --prefix prototype/animation_preview ci`.
В проверке использован Chromium по `/tmp/chromium`; для другой установки
поменяйте **только executablePath** в копиях драйверов.

Нужны совместимые JS/WASM-файлы `godot.web.template_release.wasm32.nothreads.*`.
В этой проверке они взяты из **`@ringozz/godot-web-wasm32@4.7.2-685`**, не из
официального Windows-экспорта; пакет/движок и зависимости в Git не включены.
Вывод движка: `4.7.2.stable.custom_build.3d95ead8f`, Compatibility/WebGL2,
Emscripten 4.0.14. Для Chromium использованы явно указанные в `.mjs`
SwiftShader-флаги. Нативная сборка и её недостаток fontconfig описаны в отчёте;
ошибки импорта не следует считать успешной строгой проверкой.

Создавайте **отдельные копии** `prototype/` под
`.local/review/repair-42/{game-project,after-project,before-project}/prototype/`,
без `animation_preview`, `tools`, `tests/output`, чужого кэша `.godot` и зависимостей.
Импортируйте в каждой соответствующую модель тем же нативным Godot.

- `game-project`: добавить только `review_game.gd/.tscn`, заменить
  `run/main_scene` на `res://review_game.tscn`.
- `after-project`: добавить `review.gd/.tscn`, заменить entry на `res://review.tscn`.
- `before-project`: такая же диагностическая сцена, но четыре baseline-ресурса
  (safe GLB, JSON/TRES motion set, appearance JSON, `character_appearance.gd`)
  из `1d5d20b`; импорт должен соответствовать именно baseline GLB.
- Production PCK упаковывается из **исходного `prototype/`**, без review entry.
  Нельзя подменять им игровой проект или менять в нём маску/контроллеры.

Пример упаковки одной копии (абсолютный `GODOT_BIN`):

```sh
PACK_OUTPUT="$PWD/.local/godot-visual/public/runtime42.pck" \
  "$GODOT_BIN" --headless \
  --path .local/review/repair-42/game-project/prototype \
  --script "$PWD/.local/godot-visual/pack.gd"
```

Аналогично получаются `review-42-before.pck`, `review-42-after.pck`,
`production42.pck`. Запустите `node .local/godot-visual/server.mjs`, затем:

```sh
node .local/godot-visual/review42.mjs .local/review/repair-42/final-before-shots.json
node .local/godot-visual/review42.mjs .local/review/repair-42/final-after-shots.json
node .local/godot-visual/runtime42.mjs --part=locomotion
node .local/godot-visual/runtime42.mjs --part=dodge
node .local/godot-visual/runtime42.mjs --part=actions
node .local/godot-visual/runtime42.mjs --part=clone
node .local/godot-visual/runtime42.mjs --part=lock
node .local/godot-visual/production42_roundtrip.mjs
```

На Linux из этой sandbox дополнительно требовался `LD_LIBRARY_PATH` для
библиотек Chromium; на другой машине нужны её собственные зависимости.
Большие PCK, `.godot`, сырые PNG/трейсы остаются в игнорируемой `.local/`.
Результат должен пройти проверки SHA и ошибок, а не просто создать картинку.

Это офлайн-запись с фиксацией завершённого framebuffer, **не замер FPS** и не
доказательство произвольного поведения игры. 258 различных снимков ролика
представлены на 1× как sample-and-hold в 60-fps контейнере. Проверка целостности
доставленных файлов: `python reports/animation-review/verify-godot42.py`.
