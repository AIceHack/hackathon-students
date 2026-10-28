-- The runner creates these temporary views from the exact five query files.
-- Control values apply to the original Olist dataset described in tasks.md.
DO $$
DECLARE
    differences bigint;
    expected_lines numeric;
BEGIN
    -- Follow view dependencies recursively: an answer must not read raw
    -- through a core/mart view either. The five views contain the exact files.
    WITH RECURSIVE dependencies(root_view, relation_id) AS (
        SELECT r.ev_class, d.refobjid
        FROM pg_rewrite r JOIN pg_depend d ON d.classid = 'pg_rewrite'::regclass AND d.objid = r.oid
        WHERE r.ev_class IN ('pg_temp.answer_01_monthly'::regclass,
                             'pg_temp.answer_02_top_sellers'::regclass,
                             'pg_temp.answer_03_average_check'::regclass,
                             'pg_temp.answer_04_retention'::regclass,
                             'pg_temp.answer_05_categories'::regclass)
          AND d.refclassid = 'pg_class'::regclass AND d.refobjid <> r.ev_class
        UNION
        SELECT v.root_view, d.refobjid
        FROM dependencies v JOIN pg_rewrite r ON r.ev_class = v.relation_id
        JOIN pg_depend d ON d.classid = 'pg_rewrite'::regclass AND d.objid = r.oid
        WHERE d.refclassid = 'pg_class'::regclass AND d.refobjid <> r.ev_class
    )
    SELECT COUNT(*) INTO differences
    FROM dependencies d JOIN pg_class c ON c.oid = d.relation_id
    JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'raw';
    IF differences <> 0 THEN RAISE EXCEPTION 'Official answers depend on raw: % references', differences; END IF;

    IF (SELECT COUNT(*) FROM pg_temp.answer_01_monthly) <> 24
       OR (SELECT COUNT(DISTINCT month) FROM pg_temp.answer_01_monthly) <> 24
       OR (SELECT MIN(month) FROM pg_temp.answer_01_monthly) IS DISTINCT FROM date '2016-09-01'
       OR (SELECT MAX(month) FROM pg_temp.answer_01_monthly) IS DISTINCT FROM date '2018-08-01'
       OR (SELECT SUM(revenue) FROM pg_temp.answer_01_monthly) IS DISTINCT FROM 13221498.11::numeric
       OR (SELECT COUNT(*) FROM pg_temp.answer_01_monthly WHERE revenue = 0) <> 1
       OR NOT EXISTS (SELECT 1 FROM pg_temp.answer_01_monthly
                      WHERE month = date '2016-11-01' AND orders_count = 0 AND revenue = 0) THEN
        RAISE EXCEPTION 'Answer 1: incorrect monthly calendar or revenue';
    END IF;

    WITH expected AS (
        SELECT m.month::date AS month, COUNT(DISTINCT o.order_id) AS orders_count,
               COALESCE(SUM(i.price), 0) AS revenue
        FROM generate_series(date '2016-09-01', date '2018-08-01', interval '1 month') m(month)
        LEFT JOIN core.orders o ON o.order_status = 'delivered'
            AND o.order_purchase_timestamp >= m.month
            AND o.order_purchase_timestamp < m.month + interval '1 month'
        LEFT JOIN core.order_items i ON i.order_id = o.order_id
        GROUP BY m.month
    ), changed AS (
        (SELECT month, orders_count, revenue FROM pg_temp.answer_01_monthly EXCEPT ALL SELECT * FROM expected)
        UNION ALL
        (SELECT * FROM expected EXCEPT ALL SELECT month, orders_count, revenue FROM pg_temp.answer_01_monthly)
    ) SELECT COUNT(*) INTO differences FROM changed;
    IF differences <> 0 THEN RAISE EXCEPTION 'Answer 1: % monthly rows differ from core', differences; END IF;
    RAISE NOTICE 'Answer 1 passed: 24 months; delivered revenue 13221498.11';

    IF (SELECT COUNT(*) FROM pg_temp.answer_02_top_sellers) <> 10
       OR (SELECT MAX(revenue) FROM pg_temp.answer_02_top_sellers) IS DISTINCT FROM 226987.93::numeric THEN
        RAISE EXCEPTION 'Answer 2: incorrect seller count or leader revenue';
    END IF;
    WITH expected AS (
        SELECT s.seller_id, s.seller_city, s.seller_state,
               COUNT(DISTINCT i.order_id) AS orders_count, COUNT(*) AS units_count,
               ROUND(SUM(i.price), 2) AS revenue
        FROM core.order_items i JOIN core.orders o ON o.order_id = i.order_id
        JOIN core.sellers s ON s.seller_id = i.seller_id
        WHERE o.order_status = 'delivered'
        GROUP BY s.seller_id, s.seller_city, s.seller_state
        ORDER BY revenue DESC, s.seller_id LIMIT 10
    ), changed AS (
        (SELECT seller_id, seller_city, seller_state, orders_count, units_count, revenue
         FROM pg_temp.answer_02_top_sellers EXCEPT ALL SELECT * FROM expected)
        UNION ALL
        (SELECT * FROM expected EXCEPT ALL SELECT seller_id, seller_city, seller_state, orders_count, units_count, revenue
         FROM pg_temp.answer_02_top_sellers)
    ) SELECT COUNT(*) INTO differences FROM changed;
    IF differences <> 0 THEN RAISE EXCEPTION 'Answer 2: % seller rows differ from core', differences; END IF;
    RAISE NOTICE 'Answer 2 passed: 10 sellers; leader revenue 226987.93';

    SELECT ROUND(COUNT(i.order_id)::numeric / NULLIF(COUNT(DISTINCT o.order_id), 0), 6)
    INTO expected_lines
    FROM core.orders o LEFT JOIN core.order_items i ON i.order_id = o.order_id
    WHERE o.order_status = 'delivered';
    IF (SELECT COUNT(*) FROM pg_temp.answer_03_average_check) <> 1
       OR (SELECT avg_order_value FROM pg_temp.answer_03_average_check) IS DISTINCT FROM 159.88::numeric
       OR (SELECT avg_lines_per_order FROM pg_temp.answer_03_average_check) IS DISTINCT FROM expected_lines
       OR (SELECT avg_units_per_order FROM pg_temp.answer_03_average_check) IS DISTINCT FROM expected_lines THEN
        RAISE EXCEPTION 'Answer 3: incorrect average check or item counts';
    END IF;
    RAISE NOTICE 'Answer 3 passed: average check 159.88; lines and units %', expected_lines;

    IF (SELECT COUNT(*) FROM pg_temp.answer_04_retention) <> 1
       OR (SELECT customers_total FROM pg_temp.answer_04_retention) IS DISTINCT FROM 96096::bigint
       OR (SELECT repeat_customers FROM pg_temp.answer_04_retention) IS DISTINCT FROM 2997::bigint
       OR (SELECT repeat_share_pct FROM pg_temp.answer_04_retention) IS DISTINCT FROM 3.12::numeric THEN
        RAISE EXCEPTION 'Answer 4: expected 96096 customers, 2997 repeat customers, 3.12%%';
    END IF;
    RAISE NOTICE 'Answer 4 passed: 96096 customers; 2997 repeat customers; 3.12%%';

    IF (SELECT COUNT(*) FROM pg_temp.answer_05_categories) <> 74
       OR (SELECT SUM(revenue) FROM pg_temp.answer_05_categories) IS DISTINCT FROM 13221498.11::numeric
       OR (SELECT MAX(revenue) FROM pg_temp.answer_05_categories) IS DISTINCT FROM 1233131.72::numeric
       OR NOT EXISTS (SELECT 1 FROM pg_temp.answer_05_categories WHERE category = 'Unknown' AND revenue > 0)
       OR EXISTS (SELECT 1 FROM pg_temp.answer_05_categories
                  WHERE share_pct IS DISTINCT FROM ROUND(revenue / 13221498.11::numeric * 100, 2)) THEN
        RAISE EXCEPTION 'Answer 5: incorrect categories, revenue, unknown category or shares';
    END IF;
    RAISE NOTICE 'Answer 5 passed: 74 categories; largest 1233131.72; revenue 13221498.11';
END;
$$;
