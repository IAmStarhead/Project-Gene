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
`RenderingServer.frame_post_draw`. Клиент сверяет ID подтверждения и **все SHA
выбранных production-источников** в каждом ответе (19 в правке 57; 18 в полной
базе `c9d24b1`, где ещё нет `move_catalog.gd`), сохраняет PNG/SHA, состояния обоих
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

## Правка 57: подошвы, воздух, лёгкий бег и три удара

`subject_scenarios.py` записывает **действительные** запуск/сход с существующей
площадки/посадку, а не seeks воздушных клипов. Обе одежды, обе стойки; observer
и неизменённая обычная камера подписаны отдельно. `subject-contact` перед
снимком **даёт телу осесть на пол**, после F действительно ждёт посадки,
показывает низкий боковой/задний ракурс с исходными тенями. В каждом ответе
независимо вычисляются все 2 410 низких вершин настоящей кожи стоп, отдельно
левая/правая, плюс физический луч пола. Заморозка корня на стартовой высоте
.08 м не является проверкой игровой опоры.

```sh
python prototype/tests/rendered_review/subject_scenarios.py \
  --work .local/review/current-runtime --pack runtime.pck
for part in contact air kicks jog plant; do
  node prototype/tests/rendered_review/capture.mjs \
    ".local/review/current-runtime/subject-$part.json" || break
done
python prototype/tests/rendered_review/assemble.py \
  .local/review/current-runtime/captures-subject-kicks/manifest.json \
  .local/review/subject-kicks.mp4
# Аналогично contact, air, jog, plant.
```

- `kicks` — **30 кадров/с**, остальные четыре группы — **20 кадров/с**; физика
  60 Гц. В видео 1× сохраняется именно записанная частота, без интерполяции.
- Новые удары выбираются настоящим обработчиком цифровой клавиши и тем же
  LMB-action, не приватным `_start_attack`. Клон включён и принимает
  подтверждённый leg-sweep; отдельно проверяются конец восстановления и опора.
- `plant` — реальные полные jog/sprint → торможение прежним контроллером →
  постановка → удар. Пока скорость не погашена, attack-time равен нулю, обычная
  походка продолжается; после постановки физическое тело действительно стоит.
- Capture сначала сохраняет manifest с `coverage_assertions_passed=false` и
  только после **всех** проверок ставит `true`. `assemble.py` не публикует видео
  при false/отсутствующей отметке, engine errors, подменённых PNG или неодинаковой
  длительности кадров. Это не художественная оценка и не обещание cloth collision.

### Полная историческая база, без смешивания production-исходников

В отличие от старого appearance-only слоя ниже, `--source-commit` берёт
**все** production-файлы заданного commit через `git archive`. Ветка и рабочая
копия не переключаются. В отдельную маркированную копию добавляются только
один и тот же текущий review-driver, его сцена/pack script и test-only helper
измерения подошв; entry point меняется явно. Исторический контроллер, одежда,
клипы, камера, физика и свет не подменяются текущими. Архив допускает только
обычные файлы под `prototype/`, не symlinks или выход за каталог.

```sh
python prototype/tests/rendered_review/make_pack.py --godot "$GODOT_BIN" \
  --driver game --source-commit c9d24b157ce7f8366f9a2712e87c01619192cfc8 \
  --work .local/review/before-runtime --output .local/godot-review/public/before.pck
python prototype/tests/rendered_review/subject_comparison.py \
  --before .local/review/before-runtime --after .local/review/current-runtime \
  --before-pack before.pck --after-pack runtime.pck
node prototype/tests/rendered_review/capture.mjs .local/review/before-runtime/subject-comparison.json
node prototype/tests/rendered_review/capture.mjs .local/review/current-runtime/subject-comparison.json
python prototype/tests/rendered_review/publish_subject_comparison.py \
  --before .local/review/before-runtime/captures-comparison/manifest.json \
  --after .local/review/current-runtime/captures-comparison/manifest.json \
  --out .local/review/subject-comparison
```

Одинаковая программа ввода, 10 пар/с, 1×; корень/скорость/опора/числовая
матрица observer проверяются **точно** в каждой паре. У старых idle/walk/jog/stop
дополнительно точно равны hips и все не-arm кости. Изменённые air-позы и новый
силуэт формы не должны совпадать. Опубликованные два окна **800×450** не
обрезаются/масштабируются; подписи добавлены снаружи. JSON фиксирует базовый
commit, stamps, исходные SHA и результат проверки пар.

## Headless preflight тех же игровых траекторий (не визуальная приёмка)

Изолированная `--driver game`-копия также содержит `native_trace.tscn`.
Она наследует **тот же** `driver.gd`: fixtures, обработчики ввода, production
`main.tscn`, 60 Гц физики/анимации/подола и остановки после N тиков одинаковы.
Заменён только ответ: без ожидания raster/IPC записываются снимки обоих актёров.
Это запуск файлов review-копии, **не рендер и не загрузка Web PCK**. Перед
началом helper требует точного равенства выбранных production stamps;
`pack.json` отдельно хранит SHA helper. Он не вызывается игровым entry point.

```sh
export GEN_REPLAY_CONFIG="$PWD/.local/review/current-runtime/subject-jog.json"
export GEN_REPLAY_TRACE="$PWD/.local/review/current-runtime/native-jog.json"
"$GODOT_BIN" --headless --path .local/review/current-runtime/prototype \
  --fixed-fps 60 res://native_trace.tscn
python prototype/tests/rendered_review/split_trace.py "$GEN_REPLAY_TRACE"
```

Частота определяется **явным `sample_ticks` в конфигурации**, не FPS хоста.
Для проверки каждого физического тика сделайте отдельную копию JSON с
`sample_ticks: 1`, не меняя timeline; для видео остаётся исходная конфигурация.
Снимки между редкими отсчётами способны пропустить короткое пересечение.
`check_garment_contacts.py` ниже работает и с этим полным trace. Счётчик
пересечений/нулевой результат не заменяет просмотр настоящих игровых кадров.

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
# Маленькие негативные/инвентарные тесты, без Godot/браузера/сети.
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
  целевой FPS ноутбука. Результаты и оставшееся:
  [отчёт 44](../../../reports/44-стрейф-костюмы-и-боевые-реакции.md) ·
  [отчёт 57: новая форма/воздух/кики и открытые дефекты](../../../reports/57-форма-испытуемого-прыжок-и-удары-ногами.md).
