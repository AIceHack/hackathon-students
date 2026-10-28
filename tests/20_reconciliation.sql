DO $$
DECLARE
    -- Сценарий 1: объёмы и дубли
    v_raw_items_cnt          bigint;
    v_core_items_cnt         bigint;
    v_dup_items_cnt          bigint;
    v_raw_payments_cnt       bigint;
    v_core_payments_cnt      bigint;
    v_raw_reviews_cnt        bigint;
    v_core_reviews_cnt       bigint;

    -- Сценарий 2: сверка сумм price без JOIN и после JOIN со справочниками
    v_rev_exists_no_join     numeric(14, 2);
    v_rev_after_joins        numeric(14, 2);

    -- Сценарий 3: демонстрация размножения при прямом JOIN с payments vs безопасная агрегация
    v_multi_pay_orders_cnt   bigint;
    v_naive_join_rev         numeric(14, 2);
    v_safe_agg_join_rev      numeric(14, 2);
    v_leader_rev_safe        numeric(14, 2);
    v_leader_rev_naive       numeric(14, 2);

    -- Сценарий 4: сироты и сверка заказов (позиции vs платежи)
    v_orphan_items           bigint;
    v_orphan_payments        bigint;
    v_orphan_reviews         bigint;
    v_orders_without_pay     bigint;
    v_orders_pay_diff_cnt    bigint;

    -- Сценарий 5: категории (включая NULL/unknown) и помесячная выручка
    v_cat_count              bigint;
    v_cat_total_rev          numeric(14, 2);
    v_cat_max_rev            numeric(14, 2);
    v_unknown_cat_rev        numeric(14, 2);
    v_months_count           bigint;
    v_zero_months_count      bigint;
    v_months_total_rev       numeric(14, 2);

    -- Сценарий 6: диагностика уровней среднего чека (заказ vs позиция)
    v_wrong_avg_price_item   numeric(14, 2);
    v_wrong_avg_full_item    numeric(14, 2);
    v_order_avg_check_price  numeric(14, 2);
    v_order_avg_check_full   numeric(14, 2);

    -- Сценарий 7: проверка типов numeric для денежных полей в core
    v_non_numeric_money_cols bigint;
BEGIN
    RAISE NOTICE '=== ЗАПУСК НЕЗАВИСИМОГО DATA QA (tests/20_reconciliation.sql) ===';

    -- ------------------------------------------------------------------------
    -- 1. Проверка числа строк и отсутствия дублей (core vs raw)
    -- ------------------------------------------------------------------------
    SELECT COUNT(*) INTO v_raw_items_cnt FROM raw.order_items;
    SELECT COUNT(*) INTO v_core_items_cnt FROM core.order_items;

    IF v_core_items_cnt <> v_raw_items_cnt THEN
        RAISE EXCEPTION '[QA FAIL] Потеря или размножение строк в core.order_items: ожидалось %, получено %',
            v_raw_items_cnt, v_core_items_cnt;
    END IF;

    SELECT COUNT(*) INTO v_dup_items_cnt
    FROM (
        SELECT order_id, order_item_id
        FROM core.order_items
        GROUP BY 1, 2
        HAVING COUNT(*) > 1
    ) t;

    IF v_dup_items_cnt > 0 THEN
        RAISE EXCEPTION '[QA FAIL] В core.order_items найдено % дублей ключа (order_id, order_item_id)', v_dup_items_cnt;
    END IF;

    SELECT COUNT(*) INTO v_raw_payments_cnt FROM raw.order_payments;
    SELECT COUNT(*) INTO v_core_payments_cnt FROM core.payments;
    IF v_core_payments_cnt <> v_raw_payments_cnt THEN
        RAISE EXCEPTION '[QA FAIL] Несовпадение числа строк в core.payments: raw=%, core=%',
            v_raw_payments_cnt, v_core_payments_cnt;
    END IF;

    SELECT COUNT(*) INTO v_raw_reviews_cnt FROM raw.order_reviews;
    SELECT COUNT(*) INTO v_core_reviews_cnt FROM core.reviews;
    IF v_core_reviews_cnt <> v_raw_reviews_cnt THEN
        RAISE EXCEPTION '[QA FAIL] Несовпадение числа строк в core.reviews: raw=%, core=%',
            v_raw_reviews_cnt, v_core_reviews_cnt;
    END IF;

    RAISE NOTICE '[OK] Сценарий 1: Объёмы таблиц сохранены без потерь (items=%, payments=%, reviews=%), дублей ключей: 0.',
        v_core_items_cnt, v_core_payments_cnt, v_core_reviews_cnt;

    -- ------------------------------------------------------------------------
    -- 2. Сверка суммы price без JOIN (через EXISTS) и после JOIN к orders/products/sellers
    -- ------------------------------------------------------------------------
    SELECT ROUND(SUM(oi.price)::numeric, 2)
    INTO v_rev_exists_no_join
    FROM core.order_items oi
    WHERE EXISTS (
        SELECT 1
        FROM core.orders o
        WHERE o.order_id = oi.order_id
          AND o.order_status = 'delivered'
    );

    SELECT ROUND(SUM(oi.price)::numeric, 2)
    INTO v_rev_after_joins
    FROM core.order_items oi
    INNER JOIN core.orders o   ON o.order_id = oi.order_id
    INNER JOIN core.products p ON p.product_id = oi.product_id
    INNER JOIN core.sellers s  ON s.seller_id = oi.seller_id
    WHERE o.order_status = 'delivered';

    IF v_rev_exists_no_join <> v_rev_after_joins THEN
        RAISE EXCEPTION '[QA FAIL] Потеря или размножение выручки при JOIN со справочниками: без JOIN=%, после JOIN=%',
            v_rev_exists_no_join, v_rev_after_joins;
    END IF;

    IF v_rev_after_joins <> 13221498.11 THEN
        RAISE EXCEPTION '[QA FAIL] Контрольная сумма выручки (13221498.11) не сошлась: получено %',
            v_rev_after_joins;
    END IF;

    RAISE NOTICE '[OK] Сценарий 2: Выручка до и после JOIN совпадает и равна контрольной (13 221 498.11).';

    -- ------------------------------------------------------------------------
    -- 3. Демонстрация риска размножения при JOIN с платежами и проверка защиты
    -- ------------------------------------------------------------------------
    SELECT COUNT(*) INTO v_multi_pay_orders_cnt
    FROM (
        SELECT order_id
        FROM core.payments
        GROUP BY order_id
        HAVING COUNT(*) > 1
    ) mp;

    IF v_multi_pay_orders_cnt = 0 THEN
        RAISE EXCEPTION '[QA FAIL] Ожидались заказы с несколькими платежами, но найдено 0.';
    END IF;

    -- Ошибочный (наивный) прямой JOIN позиций и платежей:
    SELECT ROUND(SUM(oi.price)::numeric, 2)
    INTO v_naive_join_rev
    FROM core.order_items oi
    INNER JOIN core.orders o   ON o.order_id = oi.order_id
    INNER JOIN core.payments p ON p.order_id = oi.order_id
    WHERE o.order_status = 'delivered';

    -- Безопасный JOIN через предварительную агрегацию платежей по order_id:
    SELECT ROUND(SUM(oi.price)::numeric, 2)
    INTO v_safe_agg_join_rev
    FROM core.order_items oi
    INNER JOIN core.orders o ON o.order_id = oi.order_id
    LEFT JOIN core.v_order_payments_summary ps ON ps.order_id = oi.order_id
    WHERE o.order_status = 'delivered';

    IF v_safe_agg_join_rev <> 13221498.11 THEN
        RAISE EXCEPTION '[QA FAIL] Агрегированный JOIN платежей изменил сумму товарной выручки: %', v_safe_agg_join_rev;
    END IF;

    -- Контроль вопроса №2 (лидер топ-10 продавцов = 226987.93)
    SELECT ROUND(SUM(oi.price)::numeric, 2)
    INTO v_leader_rev_safe
    FROM core.order_items oi
    INNER JOIN core.orders o ON o.order_id = oi.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY oi.seller_id
    ORDER BY SUM(oi.price) DESC
    LIMIT 1;

    IF v_leader_rev_safe <> 226987.93 THEN
        RAISE EXCEPTION '[QA FAIL] Контроль вопроса №2 не пройден: выручка лидера = %, ожидалось 226987.93',
            v_leader_rev_safe;
    END IF;

    RAISE NOTICE '[OK] Сценарий 3: Заказов с >1 платежом: %. Прямой JOIN завышает выручку до % (+%), пред-агрегация сохраняет эталон %. Лидер продавцов = %.',
        v_multi_pay_orders_cnt, v_naive_join_rev, (v_naive_join_rev - v_safe_agg_join_rev), v_safe_agg_join_rev, v_leader_rev_safe;

    -- ------------------------------------------------------------------------
    -- 4. Проверка сирот (orphans) и диагностика расхождений позиций vs платежей
    -- ------------------------------------------------------------------------
    SELECT COUNT(*) INTO v_orphan_items
    FROM core.order_items oi
    LEFT JOIN core.orders o ON o.order_id = oi.order_id
    WHERE o.order_id IS NULL;

    SELECT COUNT(*) INTO v_orphan_payments
    FROM core.payments p
    LEFT JOIN core.orders o ON o.order_id = p.order_id
    WHERE o.order_id IS NULL;

    SELECT COUNT(*) INTO v_orphan_reviews
    FROM core.reviews r
    LEFT JOIN core.orders o ON o.order_id = r.order_id
    WHERE o.order_id IS NULL;

    IF v_orphan_items > 0 OR v_orphan_payments > 0 OR v_orphan_reviews > 0 THEN
        RAISE EXCEPTION '[QA FAIL] Найдены осиротевшие записи относительно core.orders: items=%, payments=%, reviews=%',
            v_orphan_items, v_orphan_payments, v_orphan_reviews;
    END IF;

    SELECT COUNT(*) INTO v_orders_without_pay
    FROM core.orders o
    LEFT JOIN core.v_order_payments_summary ps ON ps.order_id = o.order_id
    WHERE ps.order_id IS NULL;

    SELECT COUNT(*) INTO v_orders_pay_diff_cnt
    FROM (
        SELECT
            oi.order_id,
            ROUND(SUM(oi.price + oi.freight_value)::numeric, 2) AS items_total,
            COALESCE(ps.total_payment_value, 0)                 AS paid_total
        FROM core.order_items oi
        INNER JOIN core.orders o ON o.order_id = oi.order_id
        LEFT JOIN core.v_order_payments_summary ps ON ps.order_id = oi.order_id
        WHERE o.order_status = 'delivered'
        GROUP BY oi.order_id, ps.total_payment_value
        HAVING ABS(ROUND(SUM(oi.price + oi.freight_value)::numeric, 2) - COALESCE(ps.total_payment_value, 0)) > 0.01
    ) diff;

    RAISE NOTICE '[OK] Сценарий 4: Сирот (items/payments/reviews -> orders): 0. Допустимые аномалии: заказов без платежа = %, доставленных заказов с расхождением (price+freight vs payment_value) > 0.01 = %.',
        v_orders_without_pay, v_orders_pay_diff_cnt;

    -- ------------------------------------------------------------------------
    -- 5. Сверка категорий (включая неизвестные) и помесячной выручки с общим итогом
    -- ------------------------------------------------------------------------
    -- 5.1. Категории: исходный код с отдельным ключом неизвестной категории.
    WITH cat_rev AS (
        SELECT
            p.category_code AS category_key,
            ROUND(SUM(oi.price)::numeric, 2) AS revenue
        FROM core.order_items oi
        INNER JOIN core.orders o   ON o.order_id = oi.order_id
        LEFT JOIN core.products p  ON p.product_id = oi.product_id
        WHERE o.order_status = 'delivered'
        GROUP BY 1
    )
    SELECT
        COUNT(*),
        COALESCE(SUM(revenue), 0),
        COALESCE(MAX(revenue), 0),
        COALESCE(SUM(revenue) FILTER (WHERE category_key = '__unknown__'), 0)
    INTO v_cat_count, v_cat_total_rev, v_cat_max_rev, v_unknown_cat_rev
    FROM cat_rev;

    IF v_cat_count <> 74 THEN
        RAISE EXCEPTION '[QA FAIL] Ожидалось 74 категории (включая товары без категории), получено %', v_cat_count;
    END IF;

    IF v_cat_total_rev <> 13221498.11 OR v_cat_max_rev <> 1233131.72 THEN
        RAISE EXCEPTION '[QA FAIL] Не сошелся контроль по категориям: сумма=% (ожидалось 13221498.11), макс. категория=% (ожидалось 1233131.72)',
            v_cat_total_rev, v_cat_max_rev;
    END IF;

    -- 5.2. Помесячная выручка за сентябрь 2016 — август 2018 (24 месяца, 1 с нулевой выручкой)
    WITH months_grid AS (
        SELECT generate_series(
            '2016-09-01'::timestamp,
            '2018-08-01'::timestamp,
            interval '1 month'
        )::date AS month_start
    ),
    monthly_rev AS (
        SELECT
            date_trunc('month', o.order_purchase_timestamp)::date AS month_start,
            ROUND(SUM(oi.price)::numeric, 2) AS revenue
        FROM core.orders o
        INNER JOIN core.order_items oi ON oi.order_id = o.order_id
        WHERE o.order_status = 'delivered'
          AND o.order_purchase_timestamp >= '2016-09-01'
          AND o.order_purchase_timestamp <  '2018-09-01'
        GROUP BY 1
    )
    SELECT
        COUNT(*),
        COUNT(*) FILTER (WHERE COALESCE(mr.revenue, 0) = 0),
        COALESCE(SUM(mr.revenue), 0)
    INTO v_months_count, v_zero_months_count, v_months_total_rev
    FROM months_grid mg
    LEFT JOIN monthly_rev mr ON mr.month_start = mg.month_start;

    IF v_months_count <> 24 OR v_zero_months_count <> 1 OR v_months_total_rev <> 13221498.11 THEN
        RAISE EXCEPTION '[QA FAIL] Ошибка помесячной сверки (Вопрос №1): месяцев=%, нулевых=%, сумма=%',
            v_months_count, v_zero_months_count, v_months_total_rev;
    END IF;

    RAISE NOTICE '[OK] Сценарий 5: Сумма по 74 категориям (макс = %, unknown = %) и сумма по 24 месяцам (нулевых = %) равны 13 221 498.11.',
        v_cat_max_rev, v_unknown_cat_rev, v_zero_months_count;

    -- ------------------------------------------------------------------------
    -- 6. Диагностика типичных неправильных средних (позиция vs заказ, Вопрос №3)
    -- ------------------------------------------------------------------------
    -- Неправильные средние на уровне позиции/строки:
    SELECT
        ROUND(AVG(oi.price)::numeric, 2),
        ROUND(AVG(oi.price + oi.freight_value)::numeric, 2)
    INTO v_wrong_avg_price_item, v_wrong_avg_full_item
    FROM core.order_items oi
    INNER JOIN core.orders o ON o.order_id = oi.order_id
    WHERE o.order_status = 'delivered';

    -- Средний чек на уровне заказа:
    SELECT
        ROUND(AVG(order_price)::numeric, 2),
        ROUND(AVG(order_full)::numeric, 2)
    INTO v_order_avg_check_price, v_order_avg_check_full
    FROM (
        SELECT
            oi.order_id,
            SUM(oi.price) AS order_price,
            SUM(oi.price + oi.freight_value) AS order_full
        FROM core.order_items oi
        INNER JOIN core.orders o ON o.order_id = oi.order_id
        WHERE o.order_status = 'delivered'
        GROUP BY oi.order_id
    ) ord_totals;

    IF v_order_avg_check_price = v_wrong_avg_price_item OR v_order_avg_check_full = v_wrong_avg_full_item THEN
        RAISE EXCEPTION '[QA FAIL] Средний чек заказа совпал со средним на уровне позиции — перепутано зерно агрегации!';
    END IF;

    RAISE NOTICE '[OK] Сценарий 6 (Диагностика зерна №3): На уровне позиции AVG(price)=%, AVG(price+freight)=% (неверные уровни). На уровне заказа: без доставки=%, с доставкой=%.',
        v_wrong_avg_price_item, v_wrong_avg_full_item, v_order_avg_check_price, v_order_avg_check_full;

    -- ------------------------------------------------------------------------
    -- 7. Проверка типов денежных колонок (numeric, не float/text) в схеме core
    -- ------------------------------------------------------------------------
    SELECT COUNT(*) INTO v_non_numeric_money_cols
    FROM information_schema.columns
    WHERE table_schema = 'core'
      AND table_name IN ('order_items', 'payments')
      AND column_name IN ('price', 'freight_value', 'payment_value')
      AND data_type <> 'numeric';

    IF v_non_numeric_money_cols > 0 THEN
        RAISE EXCEPTION '[QA FAIL] Найдены денежные колонки в схеме core с типом, отличным от numeric!';
    END IF;

    RAISE NOTICE '[OK] Сценарий 7: Все денежные колонки (price, freight_value, payment_value) имеют тип numeric.';
    RAISE NOTICE '=== ВСЕ ПРОВЕРКИ DATA QA УСПЕШНО ПРОЙДЕНЫ ===';
END $$;
