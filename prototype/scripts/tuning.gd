## Все настройки прототипа в одном файле.
##
## Меняйте числа здесь — они применятся при следующем запуске (F5).
## Это единственный файл, который нужно править для настройки ощущения.
extends RefCounted
class_name Tuning


# ─────────────────────────────────────────────── ДВИЖЕНИЕ
const WALK_SPEED := 3.4          ## м/с, обычная ходьба
const RUN_SPEED := 6.2           ## м/с, бег (на Shift)
const ACCELERATION := 16.0       ## как быстро набирается скорость
const DECELERATION := 20.0       ## как быстро гасится скорость
const TURN_SPEED := 14.0         ## скорость поворота тела к направлению движения
const GRAVITY := 24.0
const STEP_UP := 0.35            ## высота ступеньки, которую персонаж переступает

# ─────────────────────────────────────────────── КАМЕРА
const MOUSE_SENSITIVITY := 0.0022
const CAMERA_PITCH_MIN := -60.0  ## градусы, вниз
const CAMERA_PITCH_MAX := 45.0   ## градусы, вверх
const CAMERA_DISTANCE := 3.6
const CAMERA_HEIGHT := 1.45
const CAMERA_FOLLOW_SPEED := 12.0

# ─────────────────────────────────────────────── УВОРОТ
const DODGE_SPEED := 8.5
const DODGE_DURATION := 0.42     ## полная длительность переката
const DODGE_IFRAMES_START := 0.04  ## с какого момента включается неуязвимость
const DODGE_IFRAMES_END := 0.30    ## до какого момента действует неуязвимость
const DODGE_STAMINA := 22.0

# ─────────────────────────────────────────────── АТАКА
const ATTACK_WINDUP := 0.18      ## замах: ещё нет урона
const ATTACK_ACTIVE := 0.12      ## активные кадры: урон наносится
const ATTACK_RECOVERY := 0.26    ## восстановление: уязвим, но можно отменить уворотом
const ATTACK_RANGE := 1.9
const ATTACK_ANGLE := 70.0       ## половина угла конуса попадания, градусы
const ATTACK_DAMAGE := 24.0
const ATTACK_STAMINA := 18.0
const ATTACK_CANCEL_WINDOW := 0.12  ## за сколько до конца можно отменить уворотом

# ─────────────────────────────────────────────── ВВОД
const INPUT_BUFFER := 0.16       ## сколько помнится нажатие, если действие ещё занято

# ─────────────────────────────────────────────── ЗДОРОВЬЕ И СТАМИНА
const MAX_HEALTH := 100.0
const MAX_STAMINA := 100.0
const STAMINA_REGEN := 28.0      ## в секунду
const STAMINA_REGEN_DELAY := 0.55 ## пауза после траты, прежде чем начать восстановление

# ─────────────────────────────────────────────── СПРАЙТ-ПРОВЕРКА (заглушка врага)
const DUMMY_HEALTH := 60.0
const DUMMY_KNOCKBACK := 0.35

# ─────────────────────────────────────────────── ОКРУЖЕНИЕ
const ROOM_WIDTH := 18.0
const ROOM_DEPTH := 18.0
const ROOM_HEIGHT := 5.0
