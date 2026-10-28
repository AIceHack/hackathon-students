WITH revenue_by_category AS (
    SELECT
        COALESCE(cat.category_name_en, cat.category_name_pt, 'Unknown') AS category,
        ROUND(SUM(oi.price)::NUMERIC, 2)    AS revenue
    FROM core.order_items oi
    JOIN core.orders    o   ON o.order_id    = oi.order_id
    JOIN core.products  p   ON p.product_id  = oi.product_id
    JOIN core.categories cat ON cat.category_code = p.category_code
    WHERE o.order_status = 'delivered'
    GROUP BY cat.category_code, cat.category_name_en, cat.category_name_pt
),
total AS (
    SELECT SUM(revenue) AS total_revenue
    FROM revenue_by_category
)
SELECT
    r.category,
    r.revenue,
    ROUND(r.revenue / NULLIF(t.total_revenue, 0) * 100, 2) AS share_pct
FROM revenue_by_category r
CROSS JOIN total t
ORDER BY r.revenue DESC, r.category;
