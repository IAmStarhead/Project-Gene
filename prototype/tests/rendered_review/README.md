# Воспроизводимая запись кадров настоящего Godot

Это **авторский тестовый стенд, не часть управления игрой**. Production-скрипты,
модель, освещение, библиотека движений и JSON одежды копируются в отдельный
игнорируемый проект. `make_pack.py` не меняет `prototype/project.godot`.
Для обычного F5 нужны только Godot и включённые в Git ассеты — не этот стенд.

## Три разных вида проверки

| Режим | Что исполняется | Чего результат не доказывает |
| --- | --- | --- |
| `--driver game` + `capture.mjs` | настоящие `main.tscn`, игрок/клон, PhysicsServer, ввод, 60 Гц; fixture только между takes, observer-камера | не ручное прохождение; паузы между командами и пропуск промежуточного raster не являются real-time FPS |
| `--driver layers` + `layers.mjs` | нативный character/cloth, точные seek или явно помеченная инъекция записанной позы; нейтральный свет | не прохождение игровых переходов; полная кожа диагностическая, красные грани не измеряют глубину пробоя |
| `--driver production` + `production_smoke.mjs` | неизменённая главная сцена, клавиатура Chromium и обычный UI | фиксированное ожидание 2.5 с не подтверждает состояние само по себе; снимки нужно осмотреть |

Игровой драйвер отпускает сцену на **N настоящих физических тиков** и ждёт
`RenderingServer.frame_post_draw`. Клиент сверяет ID подтверждения и **16 SHA
production-источников** в каждом ответе, сохраняет PNG/SHA, состояния обоих
актёров и все ответы. Исходные изображения не кадрируются и не ретушируются.
Observer-камера отделена от player rig; её положение не является обычной
игровой камерой. У стены она остаётся **внутри** комнаты, не прячет препятствие;
в боевой паре расстояние учитывает реальную разницу высоты актёров. Четыре
консервативных head/feet probes должны оставаться в окне с запасом 8 пикселей
во **всех** кадрах combat (это не полный skin/silhouette test). Smoke отдельно
включает настоящую игровую камеру и F3.
Действия/Q/попадания не заменяются заранее сэмплированными скелетными позами.

## Зависимости и честная граница платформы

- Python 3.11+, установленный Godot **4.7.2**, Node.js 18+.
- `npm ci --prefix prototype/animation_preview` устанавливает `playwright-core`,
  **не скачивает браузер**. `CHROMIUM_EXECUTABLE` — путь к своему Chrome/Chromium.
- Для сборки видео/таблиц: Pillow, ffmpeg. Вместо системного ffmpeg поддержан
  необязательный `imageio-ffmpeg`. Для FCL — `tools/animation/requirements-review.txt`.
- Web bootstrap `web.html` написан для **custom Emscripten-пакета**
  **`@ringozz/godot-web-wasm32@4.7.2-685`**, не для официального export shell.
  Нативный движок данной среды также custom 4.7.2. Официальный Web export
  требует собственного shell/export-пресета; нельзя подменить им файлы молча.
- Клиенты записи включают ANGLE/SwiftShader. Это реальный renderer Godot
  Compatibility/WebGL2, **не Windows/OpenGL 3.3, не GeForce 940MX и не GPU-FPS**.
  Локально в этой среде движок был пересобран с fontconfig; ошибки импорта
  не фильтровались. Чужие движки/браузер/wasm/PCK в Git не включаются.

Дальше команды POSIX, **из корня репозитория**. Путь к движку/браузеру задаёт
автор, не production-скрипты и не браузер пользователя.

```sh
export GODOT_BIN=/absolute/path/to/godot
export CHROMIUM_EXECUTABLE=/absolute/path/to/chromium
npm ci --prefix prototype/animation_preview
python -m pip install Pillow imageio-ffmpeg

mkdir -p .local/godot-review/engine .local/godot-review/public
(cd .local/godot-review && npm pack @ringozz/godot-web-wasm32@4.7.2-685)
tar -xzf .local/godot-review/ringozz-godot-web-wasm32-4.7.2-685.tgz \
  -C .local/godot-review/engine
cp .local/godot-review/engine/package/gen/godot.web.template_release.wasm32.nothreads.js \
   .local/godot-review/engine/package/gen/godot.web.template_release.wasm32.nothreads.wasm \
   .local/godot-review/engine/package/gen/audio.worklet.js \
   .local/godot-review/engine/package/gen/audio.position.worklet.js \
   .local/godot-review/public/
```

## Игра: движения, переходы, одежда и бой

```sh
python prototype/tests/rendered_review/make_pack.py --godot "$GODOT_BIN" \
  --driver game --work .local/review/current-runtime \
  --output .local/godot-review/public/runtime.pck
python prototype/tests/rendered_review/scenarios.py \
  --work .local/review/current-runtime --pack runtime.pck
node prototype/tests/rendered_review/serve.mjs \
  --root .local/godot-review/public --port 5182
```

HTTP-сервер — долгоживущий процесс; в Arena запускайте его через процессную
панель, не короткую bash-команду. Он слушает **0.0.0.0**, принимает preview-host,
не ставит iframe-блокировку и не обслуживает репозиторий. JS/wasm/PCK загружаются
по **относительным same-origin URL**. Адрес 127.0.0.1 ниже — только для процесса
Chromium внутри того же авторского хоста, не для браузера пользователя.

В другом терминале:

```sh
export REVIEW_URL=http://127.0.0.1:5182
for part in smoke wardrobe strafe combat gaits; do
  node prototype/tests/rendered_review/capture.mjs ".local/review/current-runtime/$part.json" || break
done
```

Запускайте **последовательно**: параллельные программные WebGL-контексты
существенно увеличивают память и время. Каждый capture проверяет native errors
и покрытие: стена действительно останавливает фазу, движения проходят полные
четверти фазы, обе одежды, реальные jump/dodge, Q и подтверждённые зоны обоих
актёров. `smoke` — отдельные кадры с игровой камерой/UI. `scenario.json` —
точная воспроизводимая программа, `captures-*/manifest.json` — результат.

```sh
python prototype/tests/rendered_review/assemble.py \
  .local/review/current-runtime/captures-strafe/manifest.json .local/review/strafe.mp4
# Аналогично wardrobe, combat, gaits. --ffmpeg и --font необязательны.
python prototype/tests/rendered_review/publish_wardrobe.py \
  .local/review/current-runtime/captures-wardrobe/manifest.json .local/review/comparison
```

По умолчанию кадр каждые 6 тиков: физика/одежда **60 Гц**, запись **10 fps**,
видео **1× времени симуляции**, без интерполяции или дублирования до 60 fps.
UI-подписи добавляются снаружи неизменённых игровых пикселей. JSON рядом с
видео содержит длительность, число **различных** исходных PNG, источник/SHA,
условия и состояния каждого кадра. Кодек с потерями не сохраняет PNG побайтно.
Успешное декодирование не надо выдавать за непрерывный ручной просмотр на 1×.

## FCL: все snapshots обоих актёров, а не удобный поднабор

```sh
python -m pip install -r prototype/tools/animation/requirements-review.txt
python prototype/tests/rendered_review/split_trace.py \
  .local/review/current-runtime/captures-wardrobe/contact-trace.json
python prototype/tools/animation/check_garment_contacts.py \
  .local/review/current-runtime/captures-wardrobe/trace-dress.json \
  --outfit dress --require-skirt-clear --output .local/review/contacts-dress.json
python prototype/tools/animation/check_garment_contacts.py \
  .local/review/current-runtime/captures-wardrobe/trace-suit.json \
  --outfit suit --output .local/review/contacts-suit.json
```

Splitter явно сохраняет **каждый** actor snapshot ровно в одном файле и пишет
входной SHA/инвентарь. FCL проверяет **отображаемые** индексы кожи и тканевые
треугольники, отвергает устаревшие stamps. `--contact-details` сохраняет ID
граней; `contact_scenarios.py --runtime ... --work ... --pack layers.pck`
строит 24 диагностических вида восьми явно названных сложных snapshots.
Инъекция этой позы — **повторный рендер образца**, не новая проверка контроллера.
Красный overlay приподнят на **0.5 мм**; это не signed depth/visibility.
Construction labels `outer/facing/binding` — происхождение, **не исключение**
из видимых проблем. Открытые cuffs/foot crossings требуют осмотра, как и панели.
После `layers.mjs <work>/contacts.json` команда
`python prototype/tests/rendered_review/publish_contacts.py <work>/captures/manifest.json <out>`
публикует четыре таблицы с проверкой SHA и неизменности позы внутри трёх ракурсов.

## Одинаковые до/после — только изолированная внешность

```sh
python prototype/tests/rendered_review/make_pack.py --godot "$GODOT_BIN" \
  --driver layers --baseline-appearance d67fef739d1dc60cd43bf1aec3360a4e5e68f2f0 \
  --work .local/review/before --output .local/godot-review/public/before.pck
python prototype/tests/rendered_review/make_pack.py --godot "$GODOT_BIN" \
  --driver layers --work .local/review/after --output .local/godot-review/public/after.pck
python prototype/tests/rendered_review/comparison_scenarios.py \
  --before .local/review/before --after .local/review/after \
  --before-pack before.pck --after-pack after.pck
node prototype/tests/rendered_review/layers.mjs .local/review/before/comparison.json
node prototype/tests/rendered_review/layers.mjs .local/review/after/comparison.json
python prototype/tests/rendered_review/publish_comparisons.py \
  --before .local/review/before/comparison/manifest.json \
  --after .local/review/after/comparison/manifest.json --out .local/review/comparison
```

Исторически заменяются **только** safe GLB, appearance JSON и cloth runtime;
клипы/контроллер, свет, камера и драйвер остаются **текущими**. Это намеренно
**смешанный appearance-only diagnostic, не исторический игровой replay**.
Публикация требует побайтно равные камеры/hips/rotations/режимы покрытия для
всех 23 пар; сверяет SHA исходных PNG. Таблицы уменьшаются равномерно
1000×700 → 600×420, без crop/ретуши. Полные исходные индексы кожи разрешены
только при явном `layer=skin`; production-ресурс тела не подменяется.
`layer_scenarios.py` даёт более широкий непарный набор разных слоёв/ракурсов.

## Безопасность файлов и пределы

```sh
# Семь маленьких негативных/инвентарных тестов, без Godot/браузера/сети.
python -m unittest discover -s prototype/tests/rendered_review -p 'test_*.py' -v
```

- Builder отвергает production, `.git`, родителя репозитория, symlink-project
  и существующий **немаркированный** проект. Повторно пересоздаётся **только**
  `<work>/prototype` с правильным `.rendered-review` marker. Держите свои
  файлы за пределами этого принадлежащего стенду подкаталога.
- Импорт/пакетирование проверяют и exit code, и native `ERROR` / `SCRIPT ERROR` /
  `Parse Error`. Capture дополнительно требует native frame acknowledgement.
- Static host разрешает только нужные расширения внутри realpath public-root;
  dot-path, symlink-escape и неизвестные файлы не обслуживаются. Это локальный
  авторский host, не многоарендный production-сервис.
- Ни один из этих пунктов не обещает общую коллизию рук/стен/самоколлизию,
  анатомические hitboxes, художественную приёмку, Windows-совместимость или
  целевой FPS ноутбука. [Результаты и оставшееся — отчёт 44](../../../reports/44-стрейф-костюмы-и-боевые-реакции.md).
