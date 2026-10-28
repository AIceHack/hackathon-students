-- Full dataset, delivered orders, goods plus freight. No payment/review JOIN.
WITH items_per_order AS (
    SELECT order_id,
           SUM(price) AS items_amount,
           SUM(freight_value) AS freight_amount,
           COUNT(*) AS item_lines,
           COUNT(*) AS item_units
    FROM core.order_items
    GROUP BY order_id
)
SELECT ROUND(AVG(COALESCE(i.items_amount, 0) + COALESCE(i.freight_amount, 0)), 2) AS avg_order_value,
       ROUND(AVG(COALESCE(i.item_lines, 0)), 6) AS avg_lines_per_order,
       ROUND(AVG(COALESCE(i.item_units, 0)), 6) AS avg_units_per_order
FROM core.orders o
LEFT JOIN items_per_order i ON i.order_id = o.order_id
WHERE o.order_status = 'delivered';
