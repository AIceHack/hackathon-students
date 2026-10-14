#!/usr/bin/env bash
# =====================================================================
#  Полная установка окружения: база, схемы, сырые данные.
#
#  Запуск из любого места:
#      bash scripts/setup.sh            обычная установка
#      bash scripts/setup.sh --reset    снести базу и поставить заново
#
#  Скрипт проверяет каждый шаг и останавливается на первом сломанном,
#  объясняя, что делать.
# =====================================================================

set -uo pipefail

# Скрипт лежит в scripts/, а работать надо из корня проекта.
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPTS/.." && pwd)"
cd "$ROOT"

RESET=0
for arg in "$@"; do
  case "$arg" in
    --reset) RESET=1 ;;
    *) echo "Неизвестный аргумент: $arg"; exit 1 ;;
  esac
done

step()  { echo; echo "==> $1"; }
ok()    { echo "    ок: $1"; }
die()   { echo; echo "ОШИБКА: $1"; echo; [ $# -gt 1 ] && echo "$2"; exit 1; }

# --- 1. Docker ------------------------------------------------------
step "Проверяю Docker"

command -v docker >/dev/null 2>&1 \
  || die "команда docker не найдена" \
         "Установите Docker Desktop и запустите его, потом повторите."

docker info >/dev/null 2>&1 \
  || die "Docker установлен, но не запущен" \
         "Откройте Docker Desktop и дождитесь, пока значок перестанет мигать."

if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC="docker-compose"
else
  die "не найден docker compose" "Обновите Docker Desktop."
fi
ok "Docker работает, команда: $DC"

# --- 2. Файлы -------------------------------------------------------
step "Проверяю файлы проекта"

[ -f docker-compose.yml ] || die "в корне проекта нет docker-compose.yml" \
  "Похоже, структура папки нарушена. Ожидается: docker-compose.yml в корне,
скрипты в scripts/, данные в data/."
[ -f scripts/init/01_init.sql ]   || die "нет scripts/init/01_init.sql" \
  "Файлы 01_init.sql и 02_raw_ddl.sql должны лежать ВНУТРИ папки scripts/init."
[ -f scripts/init/02_raw_ddl.sql ] || die "нет scripts/init/02_raw_ddl.sql" \
  "Файлы 01_init.sql и 02_raw_ddl.sql должны лежать ВНУТРИ папки scripts/init."
ok "init на месте"

CSV_COUNT=$(ls data/*.csv 2>/dev/null | wc -l | tr -d ' ')
if [ "$CSV_COUNT" -lt 8 ]; then
  echo "    в data только $CSV_COUNT файлов, качаю недостающие"
  bash scripts/download_data.sh || die "не удалось скачать данные" \
    "Проверьте интернет или скачайте файлы вручную,
список в scripts/download_data.sh"
  CSV_COUNT=$(ls data/*.csv 2>/dev/null | wc -l | tr -d ' ')
fi
[ "$CSV_COUNT" -ge 8 ] || die "в папке data всё ещё $CSV_COUNT файлов вместо 8"
ok "данные на месте: $CSV_COUNT файлов"

# --- 3. Python ------------------------------------------------------
step "Проверяю Python"

if command -v python3 >/dev/null 2>&1; then PY=python3
elif command -v python >/dev/null 2>&1; then PY=python
else die "не найден python" "Установите Python 3.10 или новее."; fi

$PY -c "import psycopg2" 2>/dev/null || {
  echo "    ставлю psycopg2-binary"
  $PY -m pip install --quiet psycopg2-binary 2>/dev/null \
    || $PY -m pip install --quiet --break-system-packages psycopg2-binary \
    || die "не удалось поставить psycopg2-binary" \
           "Поставьте вручную:  $PY -m pip install psycopg2-binary"
}
ok "python и psycopg2 готовы"

# --- 4. Контейнер ---------------------------------------------------
if [ "$RESET" = "1" ]; then
  step "Сношу старую базу (--reset)"
  $DC --profile tools down -v --remove-orphans
  ok "удалено"
fi

step "Поднимаю PostgreSQL"
# Только postgres: pgadmin лежит в профиле tools и тянет лишние 400 МБ.
$DC up -d postgres || die "не удалось запустить контейнер" \
  "Посмотрите, что пишет:  $DC logs postgres"

printf "    жду готовности базы"
READY=0
for _ in $(seq 1 60); do
  if $DC exec -T postgres pg_isready -U hack -d marketplace >/dev/null 2>&1; then
    READY=1; break
  fi
  printf "."
  sleep 2
done
echo
[ "$READY" = "1" ] || die "база не ответила за две минуты" \
  "Посмотрите логи:  $DC logs postgres
Если порт 5432 занят другим постгресом, поменяйте проброс в docker-compose.yml
на \"5433:5432\" и запустите:  bash setup.sh --reset"
ok "база принимает подключения"

# --- 5. Загрузка ----------------------------------------------------
step "Загружаю сырые данные в схему raw"

PORT=$(awk -F'"' '/- "[0-9]+:5432"/ {split($2,a,":"); print a[1]; exit}' docker-compose.yml)
PORT=${PORT:-5432}

$PY scripts/load_raw.py --port "$PORT" || die "загрузка не прошла" \
  "Сообщение об ошибке выше. Частые причины:
  - контейнер ещё не готов, подождите полминуты и повторите
  - порт 5432 занят, смотрите подсказку про 5433"

# --- 6. Итог --------------------------------------------------------
step "Проверяю, что получилось"

$DC exec -T postgres psql -U hack -d marketplace -c "
SELECT s.schema_name AS shema, count(t.table_name) AS tablic
FROM information_schema.schemata s
LEFT JOIN information_schema.tables t ON t.table_schema = s.schema_name
WHERE s.schema_name IN ('raw','core','mart')
GROUP BY 1 ORDER BY 1;"

$DC exec -T postgres psql -U hack -d marketplace -c "
SELECT 'raw.orders' t, count(*) FROM raw.orders
UNION ALL SELECT 'raw.order_items', count(*) FROM raw.order_items;"

echo
echo "====================================================================="
echo " Готово."
echo
echo " Подключение:  postgresql://hack:hack@localhost:$PORT/marketplace"
echo " Схемы:        raw (данные), core (ваша модель), mart (витрины)"
echo
echo " Задание и описание данных:  docs/handout.md"
echo " Вопросы к модели:           docs/tasks.md"
echo
echo " Веб-клиент, если нужен:  $DC --profile tools up -d"
echo "                          потом http://localhost:8080"
echo "====================================================================="
