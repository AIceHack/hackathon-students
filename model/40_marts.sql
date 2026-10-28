-- ============================================================================
-- Слой витрин данных: mart
-- ============================================================================
-- Роль: Переиспользуемый аналитический слой поверх core для продуктовых,
--       финансовых и логистических отчетов.
-- Принципы:
--   1. Строгая гранулярность (grain) представлений:
--      - mart.order_financials: 1 заказ = 1 строка
--      - mart.order_delivery:   1 заказ = 1 строка
--      - mart.seller_summary:   1 продавец = 1 строка
--      - mart.monthly_sales:    1 календарный месяц = 1 строка
--   2. Отсутствие fan-out / дублирования сумм:
--      Предварительная группировка зависимых сущностей (items, payments)
--      до соединения с родительским заказом.
--   3. Нулевая зависимость от raw: все представления строятся исключительно
--      поверх схемы core.
--   4. Сохранение семантики NULL: отсутствие даты не заменяется нулями.
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS mart;

DROP VIEW IF EXISTS mart.monthly_sales CASCADE;
DROP VIEW IF EXISTS mart.seller_summary CASCADE;
DROP VIEW IF EXISTS mart.order_delivery CASCADE;
DROP VIEW IF EXISTS mart.order_financials CASCADE;

-- ----------------------------------------------------------------------------
-- 1. mart.order_financials
-- Гранулярность: 1 строка на заказ (order_id)
-- Описание: Финансовые показатели каждого заказа (товары, доставка, чек, оплаты)
-- ----------------------------------------------------------------------------
CREATE VIEW mart.order_financials AS
WITH agg_items AS (
    SELECT
        oi.order_id,
        COUNT(oi.order_item_id)::integer AS item_lines,
        COUNT(oi.order_item_id)::integer AS item_units,
        COALESCE(SUM(oi.price), 0.00)::numeric(12,2) AS items_amount,
        COALESCE(SUM(oi.freight_value), 0.00)::numeric(12,2) AS freight_amount,
        (COALESCE(SUM(oi.price), 0.00) + COALESCE(SUM(oi.freight_value), 0.00))::numeric(12,2) AS order_amount
    FROM core.order_items oi
    GROUP BY oi.order_id
),
agg_payments AS (
    SELECT
        op.order_id,
        COALESCE(SUM(op.payment_value), 0.00)::numeric(12,2) AS payments_amount,
        COUNT(op.payment_sequential)::integer AS payments_count
    FROM core.order_payments op
    GROUP BY op.order_id
)
SELECT
    o.order_id,
    o.customer_id,
    o.order_status,
    DATE_TRUNC('month', o.order_purchase_timestamp)::date AS purchase_month,
    COALESCE(i.item_lines, 0)::integer AS item_lines,
    COALESCE(i.item_units, 0)::integer AS item_units,
    COALESCE(i.items_amount, 0.00)::numeric(12,2) AS items_amount,
    COALESCE(i.freight_amount, 0.00)::numeric(12,2) AS freight_amount,
    COALESCE(i.order_amount, 0.00)::numeric(12,2) AS order_amount,
    (o.order_status = 'delivered') AS is_revenue_order,
    COALESCE(p.payments_amount, 0.00)::numeric(12,2) AS payments_amount,
    COALESCE(p.payments_count, 0)::integer AS payments_count
FROM core.orders o
LEFT JOIN agg_items i ON o.order_id = i.order_id
LEFT JOIN agg_payments p ON o.order_id = p.order_id;

COMMENT ON VIEW mart.order_financials IS 'Аналитическая витрина финансов заказов. Grain: 1 заказ = 1 строка.';


-- ----------------------------------------------------------------------------
-- 2. mart.order_delivery
-- Гранулярность: 1 строка на заказ (order_id)
-- Описание: Аналитика жизненного цикла исполнения и задержек доставки.
-- Внимание: Отсутствующие даты остаются NULL, расчет интервалов производится
--           только при наличии обеих временных меток.
-- ----------------------------------------------------------------------------
CREATE VIEW mart.order_delivery AS
SELECT
    o.order_id,
    o.customer_id,
    o.order_status,
    DATE_TRUNC('month', o.order_purchase_timestamp)::date AS purchase_month,
    o.order_purchase_timestamp,
    o.order_approved_at,
    o.order_delivered_carrier_date,
    o.order_delivered_customer_date,
    o.order_estimated_delivery_date,

    -- Длительность подтверждения оплаты -> передача перевозчику (в часах)
    CASE
        WHEN o.order_delivered_carrier_date IS NOT NULL AND o.order_approved_at IS NOT NULL
        THEN ROUND((EXTRACT(EPOCH FROM (o.order_delivered_carrier_date - o.order_approved_at)) / 3600.0)::numeric, 2)
        ELSE NULL
    END AS hours_approval_to_carrier,

    -- Полная длительность доставки: от оформления до покупателя (в днях)
    CASE
        WHEN o.order_delivered_customer_date IS NOT NULL AND o.order_purchase_timestamp IS NOT NULL
        THEN ROUND((EXTRACT(EPOCH FROM (o.order_delivered_customer_date - o.order_purchase_timestamp)) / 86400.0)::numeric, 2)
        ELSE NULL
    END AS days_purchase_to_delivery,

    -- Отклонение от обещанного срока: только для доставленных заказов с известными датами
    -- Положительное значение = задержка (опоздание), отрицательное/ноль = вовремя или раньше срока
    CASE
        WHEN o.order_status = 'delivered'
             AND o.order_delivered_customer_date IS NOT NULL
             AND o.order_estimated_delivery_date IS NOT NULL
        THEN ROUND((EXTRACT(EPOCH FROM (o.order_delivered_customer_date - o.order_estimated_delivery_date)) / 86400.0)::numeric, 2)
        ELSE NULL
    END AS delivery_delay_days,

    -- Булев флаг просрочки: TRUE если вручен позже обещанного
    CASE
        WHEN o.order_status = 'delivered'
             AND o.order_delivered_customer_date IS NOT NULL
             AND o.order_estimated_delivery_date IS NOT NULL
        THEN (o.order_delivered_customer_date > o.order_estimated_delivery_date)
        ELSE NULL
    END AS is_late,

    -- Флаг явной аномалии: передача в доставку зафиксирована раньше подтверждения оплаты
    -- В Olist наблюдается в ~1.3 тыс. заказов из-за асинхронного обновления систем
    CASE
        WHEN o.order_delivered_carrier_date IS NOT NULL
             AND o.order_approved_at IS NOT NULL
             AND o.order_delivered_carrier_date < o.order_approved_at
        THEN true
        ELSE false
    END AS is_carrier_before_approval,

    -- Флаг неполноты отметок жизненного цикла для аудита качества данных
    CASE
        WHEN o.order_status = 'delivered'
             AND (o.order_delivered_customer_date IS NULL
                  OR o.order_purchase_timestamp IS NULL
                  OR o.order_estimated_delivery_date IS NULL)
        THEN true
        WHEN o.order_status = 'shipped' AND o.order_delivered_carrier_date IS NULL
        THEN true
        ELSE false
    END AS has_missing_dates
FROM core.orders o;

COMMENT ON VIEW mart.order_delivery IS 'Витрина этапов доставки и соблюдения SLA. Grain: 1 заказ = 1 строка.';


-- ----------------------------------------------------------------------------
-- 3. mart.seller_summary
-- Гранулярность: 1 строка на продавца (seller_id)
-- Описание: Эффективность и оборот продавца по доставленным (выручкообразующим) заказам.
-- Важно: Запрещено присоединять сырые платежи/отзывы к позициям.
--        Сумма orders_count по продавцам не равна уникальным заказам площадки!
-- ----------------------------------------------------------------------------
CREATE VIEW mart.seller_summary AS
WITH seller_delivered_sales AS (
    SELECT
        oi.seller_id,
        COUNT(DISTINCT oi.order_id)::integer AS orders_count,
        COUNT(oi.order_item_id)::integer AS units_count,
        COALESCE(SUM(oi.price), 0.00)::numeric(12,2) AS revenue_amount,
        COALESCE(SUM(oi.freight_value), 0.00)::numeric(12,2) AS freight_amount
    FROM core.order_items oi
    JOIN core.orders o ON oi.order_id = o.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY oi.seller_id
)
SELECT
    s.seller_id,
    s.seller_city,
    s.seller_state,
    COALESCE(sds.orders_count, 0)::integer AS orders_count,
    COALESCE(sds.units_count, 0)::integer AS units_count,
    COALESCE(sds.revenue_amount, 0.00)::numeric(12,2) AS revenue_amount,
    COALESCE(sds.freight_amount, 0.00)::numeric(12,2) AS freight_amount,
    CASE
        WHEN COALESCE(sds.units_count, 0) > 0
        THEN ROUND((sds.revenue_amount / sds.units_count)::numeric, 2)
        ELSE NULL
    END AS avg_item_price
FROM core.sellers s
LEFT JOIN seller_delivered_sales sds ON s.seller_id = sds.seller_id;

COMMENT ON VIEW mart.seller_summary IS 'Витрина эффективности продавцов по доставленным заказам. Grain: 1 продавец = 1 строка.';


-- ----------------------------------------------------------------------------
-- 4. mart.monthly_sales (дополнительная аналитическая витрина P1)
-- Гранулярность: 1 строка на месяц
-- Описание: Динамика продаж по непрерывной календарной сетке (сентябрь 2016 - август 2018).
-- Гарантирует сохранение месяцев с нулевыми продажами (ноябрь 2016 и др.).
-- ----------------------------------------------------------------------------
CREATE VIEW mart.monthly_sales AS
WITH months_grid AS (
    SELECT generate_series(
        '2016-09-01'::date,
        '2018-08-01'::date,
        '1 month'::interval
    )::date AS month_start
),
monthly_metrics AS (
    SELECT
        f.purchase_month,
        COUNT(f.order_id)::integer AS total_orders,
        COUNT(f.order_id) FILTER (WHERE f.is_revenue_order)::integer AS revenue_orders,
        COALESCE(SUM(f.items_amount) FILTER (WHERE f.is_revenue_order), 0.00)::numeric(12,2) AS revenue_amount,
        COALESCE(SUM(f.order_amount) FILTER (WHERE f.is_revenue_order), 0.00)::numeric(12,2) AS delivered_gmv,
        ROUND((SUM(f.order_amount) FILTER (WHERE f.is_revenue_order) /
               NULLIF(COUNT(f.order_id) FILTER (WHERE f.is_revenue_order), 0))::numeric, 2) AS avg_order_check
    FROM mart.order_financials f
    GROUP BY f.purchase_month
)
SELECT
    mg.month_start,
    COALESCE(mm.total_orders, 0)::integer AS total_orders,
    COALESCE(mm.revenue_orders, 0)::integer AS revenue_orders,
    COALESCE(mm.revenue_amount, 0.00)::numeric(12,2) AS revenue_amount,
    COALESCE(mm.delivered_gmv, 0.00)::numeric(12,2) AS delivered_gmv,
    mm.avg_order_check
FROM months_grid mg
LEFT JOIN monthly_metrics mm ON mg.month_start = mm.purchase_month
ORDER BY mg.month_start;

COMMENT ON VIEW mart.monthly_sales IS 'Динамика продаж по непрерывной календарной сетке. Grain: 1 месяц = 1 строка.';
