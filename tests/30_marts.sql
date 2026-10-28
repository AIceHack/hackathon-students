-- ============================================================================
-- Автоматизированные тесты витрин данных: tests/30_marts.sql
-- ============================================================================
-- Роль: Комплексная валидация контрактов данных, целостности зерна (grain),
--       математической сходимости выручки и отсутствия утечек в raw.
-- Поведение:
--   - При критическом нарушении: RAISE EXCEPTION с подробным описанием расхождения.
--   - При допустимых аномалиях: RAISE NOTICE со счётчиками и пояснениями.
--   - При полном успехе: итоговый NOTICE 'ALL MART TESTS PASSED SUCCESSFULLY'.
-- ============================================================================

DO $$
DECLARE
    -- Переменные для проверки order_financials
    v_total_orders_mart         integer;
    v_distinct_orders_mart      integer;
    v_total_orders_core         integer;
    v_rev_orders_mart           integer;
    v_mart_revenue              numeric(14,2);
    v_core_delivered_items_rev  numeric(14,2);
    v_rev_diff                  numeric(14,2);

    -- Переменные для проверки order_delivery
    v_delivery_rows             integer;
    v_delivery_distinct_orders  integer;
    v_non_delivered_with_delay  integer;
    v_negative_delivery_days    integer;
    v_carrier_before_approval   integer;
    v_missing_dates_delivered   integer;

    -- Переменные для проверки seller_summary
    v_sellers_mart_count        integer;
    v_sellers_core_count        integer;
    v_sellers_distinct_count    integer;
    v_seller_total_revenue      numeric(14,2);
    v_seller_rev_diff           numeric(14,2);
    v_top_seller_rev            numeric(14,2);

    -- Переменные для проверки зависимостей от raw
    v_raw_dependency_count      integer;
BEGIN
    RAISE NOTICE '============================================================';
    RAISE NOTICE 'ЗАПУСК АВТОТЕСТОВ АНАЛИТИЧЕСКИХ ВИТРИН (SCHEMA: MART)';
    RAISE NOTICE '============================================================';

    -- ------------------------------------------------------------------------
    -- ТЕСТ 1: Проверка mart.order_financials (Grain, Row Count, Non-null PK)
    -- ------------------------------------------------------------------------
    SELECT COUNT(*), COUNT(DISTINCT order_id)
    INTO v_total_orders_mart, v_distinct_orders_mart
    FROM mart.order_financials;

    SELECT COUNT(*)
    INTO v_total_orders_core
    FROM core.orders;

    IF v_total_orders_mart <> v_distinct_orders_mart THEN
        RAISE EXCEPTION 'TEST 1 FAILED: Дублирование order_id в mart.order_financials! Total: %, Distinct: %',
            v_total_orders_mart, v_distinct_orders_mart;
    END IF;

    IF v_total_orders_mart <> v_total_orders_core THEN
        RAISE EXCEPTION 'TEST 1 FAILED: Число строк mart.order_financials (%) не совпадает с core.orders (%)!',
            v_total_orders_mart, v_total_orders_core;
    END IF;

    RAISE NOTICE 'OK: mart.order_financials grain соблюдён (1 заказ = 1 строка, % строк).', v_total_orders_mart;

    -- ------------------------------------------------------------------------
    -- ТЕСТ 2: Сверка выручки (Revenue Reconciliation)
    -- ------------------------------------------------------------------------
    SELECT COALESCE(SUM(items_amount), 0.00), COUNT(*)
    INTO v_mart_revenue, v_rev_orders_mart
    FROM mart.order_financials
    WHERE is_revenue_order = true;

    SELECT COALESCE(SUM(oi.price), 0.00)
    INTO v_core_delivered_items_rev
    FROM core.order_items oi
    JOIN core.orders o ON oi.order_id = o.order_id
    WHERE o.order_status = 'delivered';

    v_rev_diff := ABS(v_mart_revenue - v_core_delivered_items_rev);

    IF v_rev_diff > 0.001 THEN
        RAISE EXCEPTION 'TEST 2 FAILED: Выручка в mart.order_financials (%) не сходится с core.order_items (%)! Расхождение: %',
            v_mart_revenue, v_core_delivered_items_rev, v_rev_diff;
    END IF;

    -- Проверка на точное совпадение с контрольной суммой хакатона 13 221 498.11
    IF ABS(v_mart_revenue - 13221498.11) > 0.001 THEN
        RAISE EXCEPTION 'TEST 2 FAILED: Выручка mart (%) отличается от контрольной суммы хакатона (13221498.11)!',
            v_mart_revenue;
    END IF;

    RAISE NOTICE 'OK: Сверка выручки успешна (13 221 498.11 BRL по % доставленным заказам). Расхождение: 0.00.',
        v_rev_orders_mart;

    -- ------------------------------------------------------------------------
    -- ТЕСТ 3: Проверка mart.order_delivery (Grain, даты, отсутствие ложных нулей)
    -- ------------------------------------------------------------------------
    SELECT COUNT(*), COUNT(DISTINCT order_id)
    INTO v_delivery_rows, v_delivery_distinct_orders
    FROM mart.order_delivery;

    IF v_delivery_rows <> v_delivery_distinct_orders OR v_delivery_rows <> v_total_orders_core THEN
        RAISE EXCEPTION 'TEST 3 FAILED: Нарушение зерна в mart.order_delivery! Строк: %, Уникальных: %, Core: %',
            v_delivery_rows, v_delivery_distinct_orders, v_total_orders_core;
    END IF;

    -- Проверка, что для недоставленных заказов delay/is_late строго NULL (не 0)
    SELECT COUNT(*)
    INTO v_non_delivered_with_delay
    FROM mart.order_delivery
    WHERE order_status <> 'delivered'
      AND (delivery_delay_days IS NOT NULL OR is_late IS NOT NULL);

    IF v_non_delivered_with_delay > 0 THEN
        RAISE EXCEPTION 'TEST 3 FAILED: Для % недоставленных заказов найдены непустые задержки! Должен быть NULL.',
            v_non_delivered_with_delay;
    END IF;

    -- Проверка на невозможное отрицательное время в пути (доставка раньше оформления)
    SELECT COUNT(*)
    INTO v_negative_delivery_days
    FROM mart.order_delivery
    WHERE days_purchase_to_delivery < 0;

    IF v_negative_delivery_days > 0 THEN
        RAISE EXCEPTION 'TEST 3 FAILED: Найдено % заказов, где доставка произошла раньше покупки!',
            v_negative_delivery_days;
    END IF;

    -- Подсчет допустимых аномалий данных источника
    SELECT COUNT(*) INTO v_carrier_before_approval
    FROM mart.order_delivery WHERE is_carrier_before_approval = true;

    SELECT COUNT(*) INTO v_missing_dates_delivered
    FROM mart.order_delivery WHERE order_status = 'delivered' AND has_missing_dates = true;

    RAISE NOTICE 'OK: mart.order_delivery проверена. Корректных строк: %. Допустимые аномалии источника: % заказов с передачей перевозчику до оплаты (рассинхрон систем), % доставленных заказов без полных дат.',
        v_delivery_rows, v_carrier_before_approval, v_missing_dates_delivered;

    -- ------------------------------------------------------------------------
    -- ТЕСТ 4: Проверка mart.seller_summary (Grain, полнота продавцов, выручка)
    -- ------------------------------------------------------------------------
    SELECT COUNT(*), COUNT(DISTINCT seller_id), COALESCE(SUM(revenue_amount), 0.00)
    INTO v_sellers_mart_count, v_sellers_distinct_count, v_seller_total_revenue
    FROM mart.seller_summary;

    SELECT COUNT(*)
    INTO v_sellers_core_count
    FROM core.sellers;

    IF v_sellers_mart_count <> v_sellers_distinct_count OR v_sellers_mart_count <> v_sellers_core_count THEN
        RAISE EXCEPTION 'TEST 4 FAILED: Нарушение зерна в mart.seller_summary! Mart: %, Distinct: %, Core: %',
            v_sellers_mart_count, v_sellers_distinct_count, v_sellers_core_count;
    END IF;

    v_seller_rev_diff := ABS(v_seller_total_revenue - 13221498.11);
    IF v_seller_rev_diff > 0.001 THEN
        RAISE EXCEPTION 'TEST 4 FAILED: Сумма выручки по всем продавцам (%) не равна контрольной выручке (13221498.11)! Разница: %',
            v_seller_total_revenue, v_seller_rev_diff;
    END IF;

    -- Проверка выручки топ-1 продавца (контроль вопроса 2 хакатона: 226 987.93)
    SELECT revenue_amount INTO v_top_seller_rev
    FROM mart.seller_summary
    ORDER BY revenue_amount DESC
    LIMIT 1;

    IF ABS(v_top_seller_rev - 226987.93) > 0.001 THEN
        RAISE EXCEPTION 'TEST 4 FAILED: Выручка топ-1 продавца (%) не равна 226 987.93!', v_top_seller_rev;
    END IF;

    RAISE NOTICE 'OK: mart.seller_summary проверена (% продавцов, выручка 13 221 498.11, топ-1 продавец 226 987.93).',
        v_sellers_mart_count;

    -- ------------------------------------------------------------------------
    -- ТЕСТ 5: Проверка отсутствия прямых ссылок на raw (Zero-Raw Dependency)
    -- ------------------------------------------------------------------------
    SELECT COUNT(*)
    INTO v_raw_dependency_count
    FROM information_schema.view_table_usage
    WHERE view_schema = 'mart'
      AND table_schema = 'raw';

    IF v_raw_dependency_count > 0 THEN
        RAISE EXCEPTION 'TEST 5 FAILED: Найдено % прямых обращений к схеме raw из витрин mart!',
            v_raw_dependency_count;
    END IF;

    RAISE NOTICE 'OK: Витрины mart не имеют прямых зависимостей от схемы raw.';

    RAISE NOTICE '============================================================';
    RAISE NOTICE 'ВСЕ ТЕСТЫ СЛОЯ MART УСПЕШНО ПРОЙДЕНЫ (5/5 PASS)';
    RAISE NOTICE '============================================================';
END $$;
