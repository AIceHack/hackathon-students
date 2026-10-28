-- ============================================================================
-- Диагностический аналитический запрос: Качество и сроки доставки заказов
-- ============================================================================
-- Назначение:
--   Комплексная диагностика логистического сервиса маркетплейса Capibara (Olist)
--   в помесячном разрезе.
--
-- Источник данных:
--   mart.order_delivery (витрина этапов доставки, grain: 1 заказ = 1 строка).
--
-- Метрики:
--   1. delivered_orders       - Число заказов со статусом 'delivered'.
--   2. valid_dates_orders     - Число доставленных заказов с полным комплектом дат
--                               (факт вручения и обещанная дата).
--   3. late_orders            - Количество заказов, доставленных позже обещанного срока.
--   4. late_orders_pct        - Процент просроченных доставок (SLA breach rate).
--   5. ontime_orders_pct      - Процент своевременных доставок (On-Time Delivery Rate).
--   6. avg_delivery_days      - Средняя длительность доставки от оформления до вручения.
--   7. median_delivery_days   - Медианная длительность доставки (устойчива к выбросам).
--   8. avg_delay_days_if_late - Среднее опоздание в днях среди задержанных заказов.
--   9. missing_dates_pct      - Доля заказов с неполными временными метками.
--
-- Примечания по применимости периодов:
--   - Сентябрь 2016: Пилотный запуск маркетплейса (единичные заказы).
--   - Ноябрь 2016: Техническая пауза / отсутствие зафиксированных доставок.
--   - Сентябрь-Октябрь 2018: Хвостовые заказы на момент среза выгрузки.
--   - Для расчета долей используется NULLIF для гарантированной защиты от деления на 0.
-- ============================================================================

WITH monthly_delivery_stats AS (
    SELECT
        purchase_month,
        COUNT(*)::integer AS total_orders,
        COUNT(*) FILTER (WHERE order_status = 'delivered')::integer AS delivered_orders,
        COUNT(*) FILTER (
            WHERE order_status = 'delivered'
              AND order_delivered_customer_date IS NOT NULL
              AND order_estimated_delivery_date IS NOT NULL
        )::integer AS valid_dates_orders,
        COUNT(*) FILTER (WHERE is_late = true)::integer AS late_orders,
        COUNT(*) FILTER (WHERE is_late = false)::integer AS ontime_orders,
        AVG(days_purchase_to_delivery) FILTER (WHERE order_status = 'delivered')::numeric AS raw_avg_delivery_days,
        PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY days_purchase_to_delivery
        ) FILTER (WHERE order_status = 'delivered')::numeric AS raw_median_delivery_days,
        AVG(delivery_delay_days) FILTER (WHERE is_late = true)::numeric AS raw_avg_delay_if_late,
        COUNT(*) FILTER (WHERE has_missing_dates = true)::integer AS missing_dates_orders
    FROM mart.order_delivery
    WHERE purchase_month IS NOT NULL
    GROUP BY purchase_month
)
SELECT
    TO_CHAR(purchase_month, 'YYYY-MM') AS month_label,
    purchase_month,
    total_orders,
    delivered_orders,
    valid_dates_orders,
    late_orders,

    -- Доля просроченных доставок (%) с защитой от деления на 0
    COALESCE(
        ROUND((100.0 * late_orders / NULLIF(valid_dates_orders, 0))::numeric, 2),
        0.00
    ) AS late_orders_pct,

    -- Доля своевременных доставок (%) (SLA compliance)
    COALESCE(
        ROUND((100.0 * ontime_orders / NULLIF(valid_dates_orders, 0))::numeric, 2),
        0.00
    ) AS ontime_orders_pct,

    -- Средняя длительность доставки в днях
    ROUND(raw_avg_delivery_days, 2) AS avg_delivery_days,

    -- Медианная длительность доставки в днях
    ROUND(raw_median_delivery_days, 2) AS median_delivery_days,

    -- Среднее опоздание в днях (среди опоздавших)
    ROUND(raw_avg_delay_if_late, 2) AS avg_delay_days_if_late,

    -- Доля заказов с неполными датами среди всех оформленных заказов месяца (%)
    ROUND((100.0 * missing_dates_orders / NULLIF(total_orders, 0))::numeric, 2) AS missing_dates_pct
FROM monthly_delivery_stats
ORDER BY purchase_month;
