# Продажи: контракт и проверка ТЗ № 2

## Определения для всей команды

| Метрика | Определение |
|---|---|
| Дата отчёта | `core.orders.order_purchase_timestamp`, момент оформления; не дата оплаты или вручения |
| Выручкообразующий заказ | `order_status = 'delivered'` |
| Товарная выручка | `SUM(core.order_items.price)` по выручкообразующим заказам; без доставки и платежей |
| Число заказов в месячном отчёте | Доставленные заказы, включая возможные заказы без позиций |
| Полный чек заказа | `SUM(price) + SUM(freight_value)` на уровне одного заказа |
| Средний чек | Среднее полных чеков доставленных заказов; все доставленные заказы входят в знаменатель |
| Строки / единицы | `COUNT(*)` позиций заказа; одна исходная строка — одна товарная единица, отдельного `quantity` нет |
| Платёжная сумма | Отдельный факт: `SUM(core.payments.payment_value)` по заказу; не заменяет товарную выручку |

`orders_count` учитывает доставленные заказы в отчётном месяце. Средний чек
использует доставленные заказы всей выгрузки; периоды следует сопоставлять
перед сравнением показателей. Средние нельзя складывать или усреднять по месяцам
без весов.

Месячный отчёт охватывает `[2016-09-01 00:00:00, 2018-09-01 00:00:00)`:
ровно 24 календарных месяца. Календарь создаётся внутри запроса, поэтому
ноябрь 2016 года остаётся строкой с нулями. Средний чек считается по всей
выгрузке без дополнительного ограничения дат. В текущей выгрузке все
доставленные заказы попадают и в период месячного отчёта; это свойство данных,
а не причина неявно ограничивать остальные аналитические вопросы.

Все суммы точные, `numeric`, без `float`. Деньги округляются до двух знаков
только на выходе; среднее число строк и единиц — до шести. Исходные суммы
с ненулевыми знаками после сотых отклоняются до загрузки, а не округляются
молча. Валюта выгрузки Olist — BRL; пересчёта валют нет.

## Интерфейс модели

Модуль: `model/20_orders_items.sql`. Ответы: `queries/01_monthly.sql`
и `queries/03_average_check.sql`. Оба ответа используют только `core`.

| Таблица | Ключ и типы | Связи |
|---|---|---|
| `core.orders` | `order_id text PRIMARY KEY`; `customer_id`, `order_status` — обязательные `text`; `order_purchase_timestamp` — обязательный `timestamp without time zone` | `customer_id → core.customers.customer_id` |
| `core.order_items` | PK `(order_id text, order_item_id integer)`; положительный номер внутри заказа; `product_id`, `seller_id` обязательны; `price`, `freight_value` — обязательные неотрицательные `numeric(14,2)` | Заказ → `core.orders`; товар → `core.products`; продавец → `core.sellers` |

В заказе сохранены `order_approved_at`, `order_delivered_carrier_date`,
`order_delivered_customer_date`, `order_estimated_delivery_date`.
В позиции сохранён `shipping_limit_date`. Все эти даты допускают `NULL`.
Пустые значения и пробелы нормализуются через `NULLIF(BTRIM(...), '')`;
идентификаторы и статусы обрабатываются так же. Непустая некорректная дата
вызывает ошибку, а не превращается в `NULL`. Бесконечные даты и денежные
`NaN`/`Infinity` отклоняются. Часовой пояс источником не задан и не выдумывается.

Заказы всех статусов сохраняются. Новые непустые статусы не запрещаются
перечислением: они остаются доступны для анализа, но не становятся выручкой
автоматически. Пропущенная дата этапа не означает нулевую длительность,
возврат или изменение статуса. Полная история переходов не восстанавливается.

Если доставленный заказ не имеет позиций, запрос среднего чека сохраняет его
в знаменателе с нулевой суммой и числом строк; диагностика ниже показывает
такие заказы отдельно. В проверенной выгрузке их нет.

## Сборка и зависимости

Порядок: схема `core` от № 1 → справочники № 3 → этот модуль →
платежи/отзывы № 4 → витрины № 5. Для FK необходимы уникальные
`core.customers.customer_id`, `core.products.product_id`, `core.sellers.seller_id`
типа `text`. Если зависимость отсутствует, модуль завершается с её названием.

Модуль выполняется в одной транзакции с согласованным снимком источника.
Перед DDL проверяются обязательные поля, типы, нормализованные/типизированные
ключи, суммы и связи. Аномалии не скрываются соединениями или `DISTINCT`.
Исключение откатывает весь модуль. Контрольные бизнес-цифры не зашиты в DDL.

Повторный запуск делает UPSERT по PK и обновляет исходные атрибуты без
удаления таблиц или зависимых объектов. Если в источнике удалены ключи,
проверка количества строк отклонит запуск: нужна полная пересборка собственных
слоёв раннером № 1. Это не инкрементальный CDC-конвейер и не миграция схемы.
При изменении DDL также нужна полная пересборка или согласованная миграция.

Команды из корня проекта для PowerShell с доступным Docker:

```powershell
docker compose cp ./model/20_orders_items.sql postgres:/tmp/20_orders_items.sql
if ($LASTEXITCODE -ne 0) { throw 'Не скопирован SQL задачи 2' }
docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 --single-transaction -U hack -d marketplace -f /tmp/20_orders_items.sql
if ($LASTEXITCODE -ne 0) { throw 'Ошибка модели задачи 2' }
docker compose cp ./queries/01_monthly.sql postgres:/tmp/01_monthly.sql
if ($LASTEXITCODE -ne 0) { throw 'Не скопирован месячный запрос' }
docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U hack -d marketplace -f /tmp/01_monthly.sql
if ($LASTEXITCODE -ne 0) { throw 'Ошибка месячного запроса' }
docker compose cp ./queries/03_average_check.sql postgres:/tmp/03_average_check.sql
if ($LASTEXITCODE -ne 0) { throw 'Не скопирован запрос чека' }
docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U hack -d marketplace -f /tmp/03_average_check.sql
if ($LASTEXITCODE -ne 0) { throw 'Ошибка запроса чека' }
```

Если Docker доступен только в WSL, те же команды выполняются в WSL из
каталога проекта (либо с префиксом `wsl --exec` из PowerShell).
`setup.sh --reset` для повторной сборки не используется.

## Проверки для № 1 и № 4

Следующий блок предназначен для включения в общий набор SQL-тестов.
Сравнения с `raw` здесь — проверки переноса, а не официальные ответы.
Нарушение должно завершать `psql -v ON_ERROR_STOP=1` с ошибкой.

```sql
DO $$
BEGIN
    IF (SELECT COUNT(*) FROM core.orders) <> (SELECT COUNT(*) FROM raw.orders)
       OR (SELECT COUNT(*) FROM core.order_items) <> (SELECT COUNT(*) FROM raw.order_items) THEN
        RAISE EXCEPTION 'Sales QA: lost or extra orders/items';
    END IF;
    IF EXISTS (SELECT order_id FROM core.orders GROUP BY 1 HAVING COUNT(*) > 1)
       OR EXISTS (SELECT order_id, order_item_id FROM core.order_items GROUP BY 1,2 HAVING COUNT(*) > 1) THEN
        RAISE EXCEPTION 'Sales QA: duplicate keys';
    END IF;
    IF EXISTS (
        SELECT 1 FROM core.orders o
        LEFT JOIN core.customers c ON c.customer_id = o.customer_id
        WHERE c.customer_id IS NULL
    ) OR EXISTS (
        SELECT 1 FROM core.order_items i
        LEFT JOIN core.orders o ON o.order_id = i.order_id
        LEFT JOIN core.products p ON p.product_id = i.product_id
        LEFT JOIN core.sellers s ON s.seller_id = i.seller_id
        WHERE o.order_id IS NULL OR p.product_id IS NULL OR s.seller_id IS NULL
    ) THEN
        RAISE EXCEPTION 'Sales QA: orphan order/item';
    END IF;
    IF (SELECT SUM(price) FROM core.order_items) IS DISTINCT FROM (
        SELECT SUM(NULLIF(BTRIM(price), '')::numeric) FROM raw.order_items
    ) OR (SELECT SUM(freight_value) FROM core.order_items) IS DISTINCT FROM (
        SELECT SUM(NULLIF(BTRIM(freight_value), '')::numeric) FROM raw.order_items
    ) THEN
        RAISE EXCEPTION 'Sales QA: changed goods/freight totals';
    END IF;
    IF (SELECT SUM(price) FROM core.order_items) IS DISTINCT FROM (
        SELECT SUM(i.price) FROM core.order_items i
        JOIN core.orders o ON o.order_id = i.order_id
        JOIN core.products p ON p.product_id = i.product_id
        JOIN core.sellers s ON s.seller_id = i.seller_id
    ) THEN
        RAISE EXCEPTION 'Sales QA: dimension JOIN changes revenue';
    END IF;
END $$;
```

Диагностика состава данных и типичной ошибки среднего чека:

```sql
SELECT order_status, COUNT(*) AS orders_count
FROM core.orders GROUP BY 1 ORDER BY 2 DESC;

SELECT COUNT(*) FILTER (WHERE order_approved_at IS NULL) AS no_approval,
       COUNT(*) FILTER (WHERE order_delivered_carrier_date IS NULL) AS no_carrier,
       COUNT(*) FILTER (WHERE order_delivered_customer_date IS NULL) AS no_delivery
FROM core.orders;

SELECT COUNT(*) AS orders_without_items,
       COUNT(*) FILTER (WHERE o.order_status = 'delivered') AS delivered_without_items
FROM core.orders o
WHERE NOT EXISTS (SELECT 1 FROM core.order_items i WHERE i.order_id = o.order_id);

SELECT COUNT(DISTINCT o.order_id) AS delivered_orders,
       COUNT(*) AS delivered_units,
       SUM(i.price) AS goods,
       SUM(i.freight_value) AS freight,
       ROUND(AVG(i.price), 2) AS wrong_avg_item_price,
       ROUND(AVG(i.price + i.freight_value), 2) AS wrong_avg_line_with_freight
FROM core.orders o
JOIN core.order_items i ON i.order_id = o.order_id
WHERE o.order_status = 'delivered';
```

Для автоматической приёмки точных запросов раннер тестов должен выполнить
тексты обоих официальных файлов как подзапросы/временные представления и
проверить: 24 месяца, единственный нулевой месяц `2016-11-01`,
`SUM(revenue) = 13221498.11`, сумму `orders_count`, равную числу доставленных
заказов в периоде, и чек `159.88`. Дополнительно проверить, что сумма чека всех
доставленных заказов равна отдельным суммам товаров и доставки, а среднее
число строк совпадает с отношением числа их позиций к числу таких заказов.

Приёмку фактических файлов выполняет общий раннер. Он создаёт временные
представления из текстов пяти официальных запросов и запускает
`tests/40_official_answers.sql` в общей транзакции:

```powershell
./scripts/build_model.ps1
```

## Результаты выполнения

Показатели ниже относятся к исходной выгрузке Olist. Общая модель и точные
файлы запросов проверяются раннером на PostgreSQL 16; запуск в отдельной
тестовой базе не меняет рабочую базу.

| Проверка | Фактический результат |
|---|---:|
| Заказы / позиции | 99 441 / 112 650 |
| Оформленные заказы в отчётном периоде | 99 421 |
| Доставленные заказы / их позиции | 96 478 / 110 197 |
| Месяцы / нулевой месяц | 24 / ноябрь 2016 |
| Товарная выручка доставленных | 13 221 498.11 |
| Доставка доставленных | 2 202 965.54 |
| Средний полный чек | 159.88 |
| Средние строки / единицы | 1.142198 / 1.142198 |
| Ошибочное среднее по позиции, без / с доставкой | 119.98 / 139.97 |
| Заказы без позиций / доставленные без позиций | 775 / 0 |
| Нет даты подтверждения / передачи / вручения | 160 / 1 783 / 2 965 |
| Дубли ключей / отсутствующие FK | 0 / 0 |
| Категории / выручка крупнейшей | 74 / 1 233 131.72 |
| Выручка первого продавца | 226 987.93 |

Денежные пропуски, отрицательные суммы и некорректные даты заказов не
обнаружены. Все сохранённые пропуски дат и заказы без позиций показаны выше;
они не удалялись для достижения контрольных чисел. Значение 123.75 из
описания типичной ошибки в исходном [задании](tasks.md) не воспроизвелось для
`AVG(price)` доставленных позиций: фактический результат — 119.98. Исходный
текст задания сохранён; сравнение зависит от выбранного фильтра и уровня данных.

В предыдущей версии модуля проверены повторный UPSERT и две чистые сборки: одинаковы не только
суммы, но и хеши всех строк обеих таблиц. На синтетических данных проверены
обе границы периода, заказ с несколькими позициями, отменённый заказ без
позиций и доставленный заказ без позиций; сохранение пустого доставленного
заказа в знаменателе чека следует повторно проверить после изменения фильтра
месячного счётчика.

**В предыдущей версии модуля 21 сценарий отказа** проверен с откатом: отсутствующий справочник,
обязательное поле заказа, пустая сумма, дубль заказа, дубль пары после
приведения номера к integer, неверная дата заказа, бесконечная дата,
неверная дата отгрузки, нецелый/неположительный номер позиции,
нечисловая/отрицательная/излишне точная/слишком большая сумма, `NaN`,
`Infinity`, отсутствующий клиент/заказ/товар/продавец и удалённый исходный
заказ. Ни один не изменил итоговую модель. Синтетические изменения делались
только во временной базе в откатываемых транзакциях.

Хеши всех восьми `raw`-таблиц основной базы до и после проверки совпали.
Общая приёмка текущих файлов выполняется штатным раннером; прежние результаты
отдельного модуля не заменяют проверку полной сборки. В финансовом QA сценарий 6
считает равенство средних на уровне заказа и позиции ошибкой, хотя на других
данных равенство может быть корректным; этот тест необходимо пересмотреть.

## Передача другим участникам

- № 1: зависимости, типы, ключи, команда запуска и исполняемый блок QA выше.
  Нужны две последовательные общие сборки; локальный повтор модуля их не заменяет.
- № 3: для категорий применять `delivered` и `SUM(price)`; JOIN к товарам и
  категориям не должен терять позиции. Сверять суммы при одинаковом периоде.
  Заказ связывается с клиентом по `customer_id`; повторные покупки — по
  `customer_unique_id` из справочника.
- № 4: платежи и отзывы не присоединять строками к позициям. Сначала каждый
  факт агрегировать до общего уровня заказа. `payment_installments` не
  умножает платёж. Выручка продавца принадлежит только его позициям.
- № 5: `is_revenue_order = (order_status = 'delivered')`; `items_amount`,
  `freight_amount`, `order_amount`, `item_lines`, `item_units` агрегировать
  до заказа. Все оформленные и доставленные заказы — разные счётчики.
  Чек, уникальные заказы и покупатели не складываются произвольно по срезам.

Пример контроля AI для `docs/ai_usage.md` участника № 4: формулы проверены
независимым подсчётом CSV; до выполнения SQL подтверждено, что `AVG(price)`
по доставленным позициям даёт 119.98, а не указанные в ТЗ 123.75. Число из
подсказки не стало константой расчёта или ложным требованием теста.
