-- All placed orders are counted; only delivered item prices form revenue.
-- Aggregate independently so orders without items remain in orders_count.
WITH calendar AS (
    SELECT month_start::date AS month
    FROM generate_series(
        timestamp '2016-09-01', timestamp '2018-08-01', interval '1 month'
    ) AS months(month_start)
), orders_in_period AS (
    SELECT order_id, order_status, date_trunc('month', order_purchase_timestamp)::date AS month
    FROM core.orders
    WHERE order_purchase_timestamp >= timestamp '2016-09-01'
      AND order_purchase_timestamp < timestamp '2018-09-01'
), monthly_orders AS (
    SELECT month, COUNT(*) AS orders_count
    FROM orders_in_period
    GROUP BY month
), monthly_revenue AS (
    SELECT o.month, SUM(i.price) AS revenue
    FROM orders_in_period o
    JOIN core.order_items i ON i.order_id = o.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY o.month
)
SELECT c.month,
       COALESCE(o.orders_count, 0::bigint) AS orders_count,
       ROUND(COALESCE(r.revenue, 0::numeric), 2) AS revenue
FROM calendar c
LEFT JOIN monthly_orders o ON o.month = c.month
LEFT JOIN monthly_revenue r ON r.month = c.month
ORDER BY c.month;
