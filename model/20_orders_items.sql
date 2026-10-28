-- Task 02. Requires core.customers, core.products and core.sellers (task 03).
-- Run with psql -X -v ON_ERROR_STOP=1. Never changes raw or other modules.
BEGIN ISOLATION LEVEL REPEATABLE READ;
SET LOCAL DateStyle = 'ISO, YMD';

DO $$
DECLARE
    dependency text;
BEGIN
    FOREACH dependency IN ARRAY ARRAY[
        'raw.orders', 'raw.order_items',
        'core.customers', 'core.products', 'core.sellers'
    ] LOOP
        IF to_regclass(dependency) IS NULL THEN
            RAISE EXCEPTION 'Task 02: missing %. Run schemas and task 03 dimensions first.', dependency;
        END IF;
    END LOOP;
END $$;

-- Normalize before checking keys: whitespace must not conceal duplicate IDs.
CREATE TEMP TABLE task02_orders_source ON COMMIT DROP AS
SELECT NULLIF(BTRIM(order_id), '') AS order_id,
       NULLIF(BTRIM(customer_id), '') AS customer_id,
       NULLIF(BTRIM(order_status), '') AS order_status,
       NULLIF(BTRIM(order_purchase_timestamp), '') AS order_purchase_timestamp,
       NULLIF(BTRIM(order_approved_at), '') AS order_approved_at,
       NULLIF(BTRIM(order_delivered_carrier_date), '') AS order_delivered_carrier_date,
       NULLIF(BTRIM(order_delivered_customer_date), '') AS order_delivered_customer_date,
       NULLIF(BTRIM(order_estimated_delivery_date), '') AS order_estimated_delivery_date
FROM raw.orders;

CREATE TEMP TABLE task02_items_source ON COMMIT DROP AS
SELECT NULLIF(BTRIM(order_id), '') AS order_id,
       NULLIF(BTRIM(order_item_id), '') AS order_item_id,
       NULLIF(BTRIM(product_id), '') AS product_id,
       NULLIF(BTRIM(seller_id), '') AS seller_id,
       NULLIF(BTRIM(shipping_limit_date), '') AS shipping_limit_date,
       NULLIF(BTRIM(price), '') AS price,
       NULLIF(BTRIM(freight_value), '') AS freight_value
FROM raw.order_items;

-- Validate text before casting. Invalid nonempty values are errors, not NULLs.
DO $$
DECLARE
    bad record;
BEGIN
    SELECT order_id INTO bad FROM task02_orders_source
    WHERE order_id IS NULL OR customer_id IS NULL OR order_status IS NULL
       OR order_purchase_timestamp IS NULL LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'Task 02: missing required order field; order_id=%', bad.order_id;
    END IF;

    SELECT order_id, order_item_id INTO bad FROM task02_items_source
    WHERE order_id IS NULL OR order_item_id IS NULL OR product_id IS NULL
       OR seller_id IS NULL OR price IS NULL OR freight_value IS NULL LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'Task 02: missing required item field; order_id=%, item=%', bad.order_id, bad.order_item_id;
    END IF;

    SELECT s.order_id, v.field_name, v.field_value INTO bad
    FROM task02_orders_source s
    CROSS JOIN LATERAL (VALUES
        ('order_purchase_timestamp', s.order_purchase_timestamp),
        ('order_approved_at', s.order_approved_at),
        ('order_delivered_carrier_date', s.order_delivered_carrier_date),
        ('order_delivered_customer_date', s.order_delivered_customer_date),
        ('order_estimated_delivery_date', s.order_estimated_delivery_date)
    ) v(field_name, field_value)
    WHERE v.field_value IS NOT NULL
      AND NOT pg_input_is_valid(v.field_value, 'timestamp without time zone') LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'Task 02: invalid %=%; order_id=%', bad.field_name, bad.field_value, bad.order_id;
    END IF;

    SELECT order_id, order_item_id, shipping_limit_date INTO bad FROM task02_items_source
    WHERE shipping_limit_date IS NOT NULL
      AND NOT pg_input_is_valid(shipping_limit_date, 'timestamp without time zone') LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'Task 02: invalid shipping_limit_date=%; order_id=%, item=%',
            bad.shipping_limit_date, bad.order_id, bad.order_item_id;
    END IF;

    SELECT order_id, order_item_id INTO bad FROM task02_items_source
    WHERE NOT pg_input_is_valid(order_item_id, 'integer') LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'Task 02: invalid integer order_item_id=%; order_id=%', bad.order_item_id, bad.order_id;
    END IF;

    SELECT s.order_id, s.order_item_id, v.field_name, v.field_value INTO bad
    FROM task02_items_source s
    CROSS JOIN LATERAL (VALUES ('price', s.price), ('freight_value', s.freight_value)) v(field_name, field_value)
    WHERE NOT pg_input_is_valid(v.field_value, 'numeric') LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'Task 02: invalid %=%; order_id=%, item=%',
            bad.field_name, bad.field_value, bad.order_id, bad.order_item_id;
    END IF;
END $$;

ALTER TABLE task02_orders_source
    ALTER COLUMN order_purchase_timestamp TYPE timestamp without time zone USING order_purchase_timestamp::timestamp,
    ALTER COLUMN order_approved_at TYPE timestamp without time zone USING order_approved_at::timestamp,
    ALTER COLUMN order_delivered_carrier_date TYPE timestamp without time zone USING order_delivered_carrier_date::timestamp,
    ALTER COLUMN order_delivered_customer_date TYPE timestamp without time zone USING order_delivered_customer_date::timestamp,
    ALTER COLUMN order_estimated_delivery_date TYPE timestamp without time zone USING order_estimated_delivery_date::timestamp;

ALTER TABLE task02_items_source
    ALTER COLUMN order_item_id TYPE integer USING order_item_id::integer,
    ALTER COLUMN shipping_limit_date TYPE timestamp without time zone USING shipping_limit_date::timestamp,
    ALTER COLUMN price TYPE numeric USING price::numeric,
    ALTER COLUMN freight_value TYPE numeric USING freight_value::numeric;

-- LIMIT 1 diagnostics need indexed lookups, even before permanent tables exist.
CREATE INDEX ON task02_orders_source (order_id);
ANALYZE task02_orders_source;
ANALYZE task02_items_source;

DO $$
DECLARE
    bad record;
BEGIN
    SELECT order_id INTO bad FROM task02_orders_source GROUP BY order_id HAVING COUNT(*) > 1 LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'Task 02: duplicate normalized order_id=%', bad.order_id;
    END IF;
    SELECT order_id, order_item_id INTO bad FROM task02_items_source
    GROUP BY order_id, order_item_id HAVING COUNT(*) > 1 LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'Task 02: duplicate typed item key; order_id=%, item=%', bad.order_id, bad.order_item_id;
    END IF;

    SELECT s.order_id, v.field_name INTO bad FROM task02_orders_source s
    CROSS JOIN LATERAL (VALUES
        ('order_purchase_timestamp', s.order_purchase_timestamp),
        ('order_approved_at', s.order_approved_at),
        ('order_delivered_carrier_date', s.order_delivered_carrier_date),
        ('order_delivered_customer_date', s.order_delivered_customer_date),
        ('order_estimated_delivery_date', s.order_estimated_delivery_date)
    ) v(field_name, field_value)
    WHERE NOT isfinite(v.field_value) LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'Task 02: nonfinite %; order_id=%', bad.field_name, bad.order_id;
    END IF;

    SELECT order_id, order_item_id INTO bad FROM task02_items_source
    WHERE order_item_id <= 0 OR NOT isfinite(shipping_limit_date)
       OR NOT (price >= 0 AND price < 1000000000000 AND price = ROUND(price, 2))
       OR NOT (freight_value >= 0 AND freight_value < 1000000000000 AND freight_value = ROUND(freight_value, 2))
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'Task 02: invalid item number/date or money (must be finite, nonnegative, fit numeric(14,2) without rounding); order_id=%, item=%',
            bad.order_id, bad.order_item_id;
    END IF;

    SELECT s.order_id, s.customer_id INTO bad FROM task02_orders_source s
    WHERE NOT EXISTS (SELECT 1 FROM core.customers c WHERE c.customer_id = s.customer_id) LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'Task 02: missing customer_id=% for order_id=%', bad.customer_id, bad.order_id;
    END IF;
    SELECT s.order_id, s.order_item_id INTO bad FROM task02_items_source s
    WHERE NOT EXISTS (SELECT 1 FROM task02_orders_source o WHERE o.order_id = s.order_id) LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'Task 02: item references missing source order_id=%, item=%', bad.order_id, bad.order_item_id;
    END IF;
    SELECT s.order_id, s.product_id INTO bad FROM task02_items_source s
    WHERE NOT EXISTS (SELECT 1 FROM core.products p WHERE p.product_id = s.product_id) LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'Task 02: missing product_id=% for order_id=%', bad.product_id, bad.order_id;
    END IF;
    SELECT s.order_id, s.seller_id INTO bad FROM task02_items_source s
    WHERE NOT EXISTS (SELECT 1 FROM core.sellers p WHERE p.seller_id = s.seller_id) LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'Task 02: missing seller_id=% for order_id=%', bad.seller_id, bad.order_id;
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS core.orders (
    order_id text PRIMARY KEY,
    customer_id text NOT NULL REFERENCES core.customers(customer_id),
    order_status text NOT NULL,
    order_purchase_timestamp timestamp without time zone NOT NULL,
    order_approved_at timestamp without time zone,
    order_delivered_carrier_date timestamp without time zone,
    order_delivered_customer_date timestamp without time zone,
    order_estimated_delivery_date timestamp without time zone
);

CREATE TABLE IF NOT EXISTS core.order_items (
    order_id text NOT NULL REFERENCES core.orders(order_id),
    order_item_id integer NOT NULL CHECK (order_item_id > 0),
    product_id text NOT NULL REFERENCES core.products(product_id),
    seller_id text NOT NULL REFERENCES core.sellers(seller_id),
    shipping_limit_date timestamp without time zone,
    price numeric(14,2) NOT NULL CHECK (price >= 0 AND price < 1000000000000),
    freight_value numeric(14,2) NOT NULL CHECK (freight_value >= 0 AND freight_value < 1000000000000),
    PRIMARY KEY (order_id, order_item_id)
);

INSERT INTO core.orders (
    order_id, customer_id, order_status, order_purchase_timestamp, order_approved_at,
    order_delivered_carrier_date, order_delivered_customer_date, order_estimated_delivery_date
)
SELECT order_id, customer_id, order_status, order_purchase_timestamp, order_approved_at,
       order_delivered_carrier_date, order_delivered_customer_date, order_estimated_delivery_date
FROM task02_orders_source
WHERE true
ON CONFLICT (order_id) DO UPDATE SET
    customer_id = EXCLUDED.customer_id,
    order_status = EXCLUDED.order_status,
    order_purchase_timestamp = EXCLUDED.order_purchase_timestamp,
    order_approved_at = EXCLUDED.order_approved_at,
    order_delivered_carrier_date = EXCLUDED.order_delivered_carrier_date,
    order_delivered_customer_date = EXCLUDED.order_delivered_customer_date,
    order_estimated_delivery_date = EXCLUDED.order_estimated_delivery_date;

INSERT INTO core.order_items (
    order_id, order_item_id, product_id, seller_id, shipping_limit_date, price, freight_value
)
SELECT order_id, order_item_id, product_id, seller_id, shipping_limit_date, price, freight_value
FROM task02_items_source
WHERE true
ON CONFLICT (order_id, order_item_id) DO UPDATE SET
    product_id = EXCLUDED.product_id,
    seller_id = EXCLUDED.seller_id,
    shipping_limit_date = EXCLUDED.shipping_limit_date,
    price = EXCLUDED.price,
    freight_value = EXCLUDED.freight_value;

DO $$
BEGIN
    IF (SELECT COUNT(*) FROM core.orders) <> (SELECT COUNT(*) FROM task02_orders_source)
       OR (SELECT COUNT(*) FROM core.order_items) <> (SELECT COUNT(*) FROM task02_items_source) THEN
        RAISE EXCEPTION 'Task 02: source/model row counts differ. Source deletions require the architect full rebuild; no rows are silently deleted.';
    END IF;
END $$;

COMMIT;
