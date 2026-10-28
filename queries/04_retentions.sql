WITH orders_per_person AS (
    SELECT
        c.customer_unique_id,
        COUNT(DISTINCT o.order_id) AS orders_cnt
    FROM core.customers c
    JOIN core.orders    o ON o.customer_id = c.customer_id
    WHERE o.order_status = 'delivered' 
    GROUP BY c.customer_unique_id
)
SELECT
    COUNT(*)                                                          AS customers_total,
    COUNT(*) FILTER (WHERE orders_cnt >= 2)                           AS repeat_customers,
    ROUND(
        COUNT(*) FILTER (WHERE orders_cnt >= 2)::NUMERIC
        / NULLIF(COUNT(*), 0) * 100,
        2
    )                                                                 AS repeat_share_pct
FROM orders_per_person;