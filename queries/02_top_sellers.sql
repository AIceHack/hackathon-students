SELECT
    oi.seller_id,
    s.seller_city,
    s.seller_state,
    COUNT(DISTINCT oi.order_id)              AS orders_count,
    COUNT(*)                                 AS units_count,
    ROUND(SUM(oi.price)::numeric, 2)         AS revenue
FROM core.order_items oi
INNER JOIN core.orders o
    ON o.order_id = oi.order_id
LEFT JOIN core.sellers s
    ON s.seller_id = oi.seller_id
WHERE o.order_status = 'delivered'
GROUP BY
    oi.seller_id,
    s.seller_city,
    s.seller_state
ORDER BY
    revenue DESC,
    oi.seller_id ASC
LIMIT 10;
