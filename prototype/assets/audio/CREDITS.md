# Звуки прототипа — источники

Записи включены в репозиторий, для игры доступ к интернету не нужен. Все
перечисленные исходные записи выпущены под [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/).
Благодарим авторов; имена приведены даже там, где атрибуция не обязательна.

| Файлы здесь | Автор и исходник | Полученная копия и обработка |
| --- | --- | --- |
| `barefoot_0.wav` … `barefoot_7.wav` | SpliceSound, [Footsteps, barefoot on wet tile](https://freesound.org/people/SpliceSound/sounds/338106/) | [dirien/backrooms, dad09c6](https://github.com/dirien/backrooms/blob/dad09c6a14112dd3b20051d84e748e8763192b5d/public/sounds/pools/barefoot-wet-tile.mp3): их 8 нормализованных фрагментов из preview, разрезаны на отдельные 0,38-секундные моно WAV. Это **мокрая** плитка; пока используется как заменитель и для сухого пола лаборатории. |
| `hit_body.wav` | Independent.nu, загрузил qubodup, [37 hits/punches](https://opengameart.org/content/37-hitspunches) | [bonesvt/GodotFall, ad59aac](https://github.com/bonesvt/GodotFall/blob/ad59aac4726cf18382fcd272742991c70fcc4d1a/assets/audio/sfx/hit_body.ogg), их обработанный фрагмент `hit25`; декодирован в моно WAV. |
| `knife_swish.wav` | artisticdude, [Swishes Sound Pack](https://opengameart.org/content/swishes-sound-pack) | [bonesvt/GodotFall, ad59aac](https://github.com/bonesvt/GodotFall/blob/ad59aac4726cf18382fcd272742991c70fcc4d1a/assets/audio/sfx/knife_swish.ogg), их обработанный `swish-3`; декодирован в моно WAV и тихо используется как воздух при ударе рукой. |
| `grunt-f.wav`, `hurt-1-f.wav` … `hurt-3-f.wav` | Nocturnal_Vanguard / AuraVoice, [Female Hurt Grunts & Groans](https://opengameart.org/content/female-hurt-grunts-groans) | [Beenster99/crownandpunchbowl, ef684cb](https://github.com/Beenster99/crownandpunchbowl/tree/ef684cb9cff9909b713adfcd898ece4b3bb59781/assets/audio/voice): их `grunt_f_01`, `oof_f_01`–`03`, фрагменты записи; декодированы в моно WAV. Это записи голоса, не сгенерированная речь. |

## Музыка

| Файл | Автор и исходник | Полученная копия |
| --- | --- | --- |
| `music/calm_ambient_1.ogg` | The Cynic Project / cynicmusic.com / pixelsphere.org, [Calm Ambient 1 (Synthwave 4k)](https://opengameart.org/content/calm-ambient-1-synthwave-4k), CC0 1.0 | [dineshsalunke/slur, 671972c](https://github.com/dineshsalunke/slur/blob/671972c6c5908a3833cbbd56335420787368bd92/apps/client/public/audio/music/lobby_calm_ambient.mp3); исходный MP3 перекодирован в Ogg Vorbis (44,1 кГц, стерео). В игре добавлены ослабление громкости и плавное наложение при повторе. |

WAV — 44,1 кГц, моно, 16 бит; Godot импортирует их как `AudioStreamWAV`.
См. также [рецепты GodotFall](https://github.com/bonesvt/GodotFall/blob/ad59aac4726cf18382fcd272742991c70fcc4d1a/tools/audio/overrides.json)
и [рецепт фрагментов голоса](https://github.com/Beenster99/crownandpunchbowl/blob/ef684cb9cff9909b713adfcd898ece4b3bb59781/assets/audio/tools/import_recordings.py).
