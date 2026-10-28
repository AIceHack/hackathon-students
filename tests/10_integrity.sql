-- Run after all core tables have been loaded, in the build transaction.
-- The temporary raw snapshot and assertion are created by 00_schema.sql.
SELECT pg_temp.assert_raw_unchanged();

DO $$
DECLARE
    spec record;
    actual_type text;
    actual_not_null boolean;
    actual_count bigint;
    raw_count bigint;
    bad_count bigint;
    core_columns text;
    source_columns text;
    business_hash text;
    price_sum numeric;
    freight_sum numeric;
    payment_sum numeric;
BEGIN
    -- Check every column in the published core contract, including nullability.
    FOR spec IN SELECT * FROM (VALUES
        ('categories', 'category_code', 'text', true),
        ('categories', 'category_name_pt', 'text', false),
        ('categories', 'category_name_en', 'text', false),
        ('categories', 'is_translation_missing', 'boolean', true),
        ('customers', 'customer_id', 'text', true),
        ('customers', 'customer_unique_id', 'text', true),
        ('customers', 'customer_zip_code_prefix', 'text', false),
        ('customers', 'customer_city', 'text', false),
        ('customers', 'customer_state', 'text', false),
        ('sellers', 'seller_id', 'text', true),
        ('sellers', 'seller_zip_code_prefix', 'text', false),
        ('sellers', 'seller_city', 'text', false),
        ('sellers', 'seller_state', 'text', false),
        ('products', 'product_id', 'text', true),
        ('products', 'category_code', 'text', true),
        ('products', 'product_name_lenght', 'integer', false),
        ('products', 'product_description_lenght', 'integer', false),
        ('products', 'product_photos_qty', 'integer', false),
        ('products', 'product_weight_g', 'integer', false),
        ('products', 'product_length_cm', 'integer', false),
        ('products', 'product_height_cm', 'integer', false),
        ('products', 'product_width_cm', 'integer', false),
        ('orders', 'order_id', 'text', true),
        ('orders', 'customer_id', 'text', true),
        ('orders', 'order_status', 'text', true),
        ('orders', 'order_purchase_timestamp', 'timestamp without time zone', true),
        ('orders', 'order_approved_at', 'timestamp without time zone', false),
        ('orders', 'order_delivered_carrier_date', 'timestamp without time zone', false),
        ('orders', 'order_delivered_customer_date', 'timestamp without time zone', false),
        ('orders', 'order_estimated_delivery_date', 'timestamp without time zone', false),
        ('order_items', 'order_id', 'text', true),
        ('order_items', 'order_item_id', 'integer', true),
        ('order_items', 'product_id', 'text', true),
        ('order_items', 'seller_id', 'text', true),
        ('order_items', 'shipping_limit_date', 'timestamp without time zone', false),
        ('order_items', 'price', 'numeric(14,2)', true),
        ('order_items', 'freight_value', 'numeric(14,2)', true),
        ('payments', 'order_id', 'text', true),
        ('payments', 'payment_sequential', 'integer', true),
        ('payments', 'payment_type', 'text', false),
        ('payments', 'payment_installments', 'integer', false),
        ('payments', 'payment_value', 'numeric(14,2)', true),
        ('reviews', 'review_id', 'text', true),
        ('reviews', 'order_id', 'text', true),
        ('reviews', 'review_score', 'integer', false),
        ('reviews', 'review_comment_title', 'text', false),
        ('reviews', 'review_comment_message', 'text', false),
        ('reviews', 'review_creation_date', 'timestamp without time zone', false),
        ('reviews', 'review_answer_timestamp', 'timestamp without time zone', false)
    ) AS x(table_name, column_name, expected_type, expected_not_null)
    LOOP
        SELECT format_type(a.atttypid, a.atttypmod), a.attnotnull
        INTO actual_type, actual_not_null
        FROM pg_attribute AS a
        WHERE a.attrelid = to_regclass(format('core.%I', spec.table_name))
          AND a.attname = spec.column_name AND a.attnum > 0 AND NOT a.attisdropped;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'missing core column: %.%', spec.table_name, spec.column_name;
        END IF;
        IF actual_type <> spec.expected_type OR actual_not_null <> spec.expected_not_null THEN
            RAISE EXCEPTION 'core.%.%: expected % (NOT NULL %), got % (NOT NULL %)',
                spec.table_name, spec.column_name, spec.expected_type, spec.expected_not_null,
                actual_type, actual_not_null;
        END IF;
    END LOOP;

    -- Check real, validated primary keys and their column order.
    FOR spec IN SELECT * FROM (VALUES
        ('categories', ARRAY['category_code']::text[]),
        ('customers', ARRAY['customer_id']::text[]),
        ('sellers', ARRAY['seller_id']::text[]),
        ('products', ARRAY['product_id']::text[]),
        ('orders', ARRAY['order_id']::text[]),
        ('order_items', ARRAY['order_id', 'order_item_id']::text[]),
        ('payments', ARRAY['order_id', 'payment_sequential']::text[]),
        ('reviews', ARRAY['review_id', 'order_id']::text[])
    ) AS x(table_name, key_columns)
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_constraint c
            WHERE c.conrelid = to_regclass(format('core.%I', spec.table_name))
              AND c.contype = 'p' AND c.convalidated
              AND ARRAY(SELECT a.attname::text
                        FROM unnest(c.conkey) WITH ORDINALITY AS k(attnum, pos)
                        JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
                        ORDER BY k.pos) = spec.key_columns
        ) THEN
            RAISE EXCEPTION 'missing or invalid primary key core.%(%)',
                spec.table_name, array_to_string(spec.key_columns, ', ');
        END IF;
    END LOOP;

    -- A real validated FK is required, not merely a matching JOIN today.
    FOR spec IN SELECT * FROM (VALUES
        ('products', 'category_code', 'categories', 'category_code'),
        ('orders', 'customer_id', 'customers', 'customer_id'),
        ('order_items', 'order_id', 'orders', 'order_id'),
        ('order_items', 'product_id', 'products', 'product_id'),
        ('order_items', 'seller_id', 'sellers', 'seller_id'),
        ('payments', 'order_id', 'orders', 'order_id'),
        ('reviews', 'order_id', 'orders', 'order_id')
    ) AS x(child_table, child_column, parent_table, parent_column)
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_constraint c
            WHERE c.conrelid = to_regclass(format('core.%I', spec.child_table))
              AND c.confrelid = to_regclass(format('core.%I', spec.parent_table))
              AND c.contype = 'f' AND c.convalidated
              AND ARRAY(SELECT a.attname::text
                        FROM unnest(c.conkey) WITH ORDINALITY AS k(attnum, pos)
                        JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
                        ORDER BY k.pos) = ARRAY[spec.child_column]::text[]
              AND ARRAY(SELECT a.attname::text
                        FROM unnest(c.confkey) WITH ORDINALITY AS k(attnum, pos)
                        JOIN pg_attribute a ON a.attrelid = c.confrelid AND a.attnum = k.attnum
                        ORDER BY k.pos) = ARRAY[spec.parent_column]::text[]
        ) THEN
            RAISE EXCEPTION 'missing or invalid FK core.%.% -> core.%.%',
                spec.child_table, spec.child_column, spec.parent_table, spec.parent_column;
        END IF;
    END LOOP;

    -- Compare multisets of source and model keys in both directions. Equal
    -- counts alone would miss one deleted row replaced with a different row.
    FOR spec IN SELECT * FROM (VALUES
        ('customers', 'customers', 'customer_id', 'NULLIF(BTRIM(customer_id), '''')'),
        ('sellers', 'sellers', 'seller_id', 'NULLIF(BTRIM(seller_id), '''')'),
        ('products', 'products', 'product_id', 'NULLIF(BTRIM(product_id), '''')'),
        ('orders', 'orders', 'order_id', 'NULLIF(BTRIM(order_id), '''')'),
        ('order_items', 'order_items', 'order_id, order_item_id',
            'NULLIF(BTRIM(order_id), ''''), NULLIF(BTRIM(order_item_id), '''')::integer'),
        ('payments', 'order_payments', 'order_id, payment_sequential',
            'NULLIF(BTRIM(order_id), ''''), NULLIF(BTRIM(payment_sequential), '''')::integer'),
        ('reviews', 'order_reviews', 'review_id, order_id',
            'NULLIF(BTRIM(review_id), ''''), NULLIF(BTRIM(order_id), '''')')
    ) AS x(core_table, raw_table, model_keys, raw_keys)
    LOOP
        core_columns := spec.model_keys;
        source_columns := spec.raw_keys;
        EXECUTE format('SELECT count(*) FROM core.%I', spec.core_table) INTO actual_count;
        EXECUTE format('SELECT count(*) FROM raw.%I', spec.raw_table) INTO raw_count;
        RAISE NOTICE 'raw.% -> core.%: % -> % rows (difference %)',
            spec.raw_table, spec.core_table, raw_count, actual_count, actual_count - raw_count;
        EXECUTE format(
            'SELECT count(*) FROM ((SELECT %s FROM core.%I EXCEPT ALL SELECT %s FROM raw.%I) '
            'UNION ALL (SELECT %s FROM raw.%I EXCEPT ALL SELECT %s FROM core.%I)) AS changed',
            core_columns, spec.core_table, source_columns, spec.raw_table,
            source_columns, spec.raw_table, core_columns, spec.core_table
        ) INTO bad_count;
        IF bad_count <> 0 THEN
            RAISE EXCEPTION 'source/model key mismatch for raw.% and core.%: % rows',
                spec.raw_table, spec.core_table, bad_count;
        END IF;

        -- Compare all mapped business fields as well as the keys. The source
        -- expression applies the same declared normalization and target type.
        SELECT string_agg(format('%I', c.attname), ', ' ORDER BY c.attnum),
               string_agg(
                   CASE WHEN spec.core_table = 'products' AND c.attname = 'category_code'
                       THEN 'COALESCE(NULLIF(BTRIM(product_category_name), ''''), ''__unknown__'')'
                       ELSE format('(NULLIF(BTRIM(%I), ''''))::%s', r.attname,
                                   format_type(c.atttypid, c.atttypmod))
                   END, ', ' ORDER BY c.attnum)
        INTO core_columns, source_columns
        FROM pg_attribute c
        JOIN pg_attribute r
          ON r.attrelid = to_regclass(format('raw.%I', spec.raw_table))
         AND r.attname = CASE WHEN spec.core_table = 'products' AND c.attname = 'category_code'
                              THEN 'product_category_name' ELSE c.attname::text END
         AND r.attnum > 0 AND NOT r.attisdropped
        WHERE c.attrelid = to_regclass(format('core.%I', spec.core_table))
          AND c.attnum > 0 AND NOT c.attisdropped;
        EXECUTE format(
            'SELECT count(*) FROM ((SELECT %s FROM core.%I EXCEPT ALL SELECT %s FROM raw.%I) '
            'UNION ALL (SELECT %s FROM raw.%I EXCEPT ALL SELECT %s FROM core.%I)) AS changed',
            core_columns, spec.core_table, source_columns, spec.raw_table,
            source_columns, spec.raw_table, core_columns, spec.core_table
        ) INTO bad_count;
        IF bad_count <> 0 THEN
            RAISE EXCEPTION 'source/model business fields differ for raw.% and core.%: % rows',
                spec.raw_table, spec.core_table, bad_count;
        END IF;
        EXECUTE format(
            'SELECT md5(coalesce(string_agg(md5(to_jsonb(model_row)::text), '''' '
            'ORDER BY md5(to_jsonb(model_row)::text)), '''')) '
            'FROM (SELECT %s FROM core.%I) AS model_row', core_columns, spec.core_table
        ) INTO business_hash;
        RAISE NOTICE 'core.% business hash: %', spec.core_table, business_hash;
    END LOOP;

    -- The reference dataset counts are diagnostics, not hard-coded load rules.
    FOR spec IN SELECT * FROM (VALUES
        ('orders', 99441), ('order_items', 112650), ('order_payments', 103886),
        ('order_reviews', 99224), ('products', 32951), ('sellers', 3095),
        ('customers', 99441), ('product_category_translation', 71)
    ) AS x(table_name, reference_count)
    LOOP
        SELECT row_count INTO actual_count FROM pg_temp.raw_snapshot WHERE table_name = spec.table_name;
        RAISE NOTICE 'raw.%: % rows (reference %, difference %)',
            spec.table_name, actual_count, spec.reference_count, actual_count - spec.reference_count;
    END LOOP;
    FOR spec IN SELECT * FROM pg_temp.raw_snapshot ORDER BY table_name LOOP
        RAISE NOTICE 'raw.% content hash: %', spec.table_name, spec.content_hash;
    END LOOP;

    SELECT count(*) INTO bad_count FROM core.customers
    WHERE NULLIF(BTRIM(customer_id), '') IS NULL OR NULLIF(BTRIM(customer_unique_id), '') IS NULL;
    IF bad_count > 0 THEN RAISE EXCEPTION 'customers with blank identifiers: %', bad_count; END IF;
    SELECT count(*) INTO bad_count FROM core.orders
    WHERE NULLIF(BTRIM(order_id), '') IS NULL OR NULLIF(BTRIM(customer_id), '') IS NULL
       OR NULLIF(BTRIM(order_status), '') IS NULL OR order_purchase_timestamp IS NULL;
    IF bad_count > 0 THEN RAISE EXCEPTION 'orders with critical NULL/blank fields: %', bad_count; END IF;
    SELECT count(*) INTO bad_count FROM core.order_items
    WHERE NULLIF(BTRIM(order_id), '') IS NULL OR NULLIF(BTRIM(product_id), '') IS NULL
       OR NULLIF(BTRIM(seller_id), '') IS NULL OR price IS NULL OR freight_value IS NULL
       OR price < 0 OR freight_value < 0 OR price = 'NaN'::numeric OR freight_value = 'NaN'::numeric;
    IF bad_count > 0 THEN RAISE EXCEPTION 'items with invalid identifiers or amounts: %', bad_count; END IF;
    SELECT count(*) INTO bad_count FROM core.payments
    WHERE NULLIF(BTRIM(order_id), '') IS NULL OR payment_value IS NULL OR payment_value = 'NaN'::numeric;
    IF bad_count > 0 THEN RAISE EXCEPTION 'payments with invalid identifiers or amounts: %', bad_count; END IF;
    SELECT count(*) INTO bad_count FROM core.reviews
    WHERE NULLIF(BTRIM(review_id), '') IS NULL OR NULLIF(BTRIM(order_id), '') IS NULL
       OR (review_score IS NOT NULL AND review_score NOT BETWEEN 1 AND 5);
    IF bad_count > 0 THEN RAISE EXCEPTION 'reviews with invalid identifiers or scores: %', bad_count; END IF;
    SELECT count(*) INTO bad_count FROM core.products WHERE NULLIF(BTRIM(product_id), '') IS NULL;
    IF bad_count > 0 THEN RAISE EXCEPTION 'products with blank identifiers: %', bad_count; END IF;
    SELECT count(*) INTO bad_count FROM core.sellers WHERE NULLIF(BTRIM(seller_id), '') IS NULL;
    IF bad_count > 0 THEN RAISE EXCEPTION 'sellers with blank identifiers: %', bad_count; END IF;

    IF EXISTS (SELECT 1 FROM raw.products WHERE NULLIF(BTRIM(product_category_name), '') = '__unknown__') THEN
        RAISE EXCEPTION 'reserved category code __unknown__ exists in raw.products';
    END IF;
    SELECT count(*) INTO bad_count FROM (
        SELECT NULLIF(BTRIM(product_category_name), '') AS code
        FROM raw.product_category_translation
        WHERE NULLIF(BTRIM(product_category_name), '') IS NOT NULL
        GROUP BY 1 HAVING count(*) > 1
    ) AS duplicates;
    IF bad_count > 0 THEN RAISE EXCEPTION 'duplicate raw translation category codes: %', bad_count; END IF;

    SELECT count(*) INTO bad_count FROM (
        (SELECT category_code FROM core.categories EXCEPT
         SELECT COALESCE(NULLIF(BTRIM(product_category_name), ''), '__unknown__') FROM raw.products
         EXCEPT SELECT '__unknown__'::text)
        UNION ALL
        ((SELECT COALESCE(NULLIF(BTRIM(product_category_name), ''), '__unknown__') FROM raw.products
          UNION SELECT '__unknown__'::text)
         EXCEPT SELECT category_code FROM core.categories)
    ) AS changed;
    IF bad_count > 0 THEN RAISE EXCEPTION 'category codes differ from source plus unknown: %', bad_count; END IF;

    SELECT count(*) INTO bad_count
    FROM raw.products r JOIN core.products p ON p.product_id = NULLIF(BTRIM(r.product_id), '')
    WHERE p.category_code IS DISTINCT FROM COALESCE(NULLIF(BTRIM(r.product_category_name), ''), '__unknown__');
    IF bad_count > 0 THEN RAISE EXCEPTION 'products with wrong source category: %', bad_count; END IF;

    SELECT count(*) INTO bad_count
    FROM core.categories c
    LEFT JOIN raw.product_category_translation t
        ON NULLIF(BTRIM(t.product_category_name), '') = c.category_code
    WHERE c.category_name_pt IS DISTINCT FROM CASE WHEN c.category_code = '__unknown__' THEN NULL ELSE c.category_code END
       OR c.category_name_en IS DISTINCT FROM CASE WHEN c.category_code = '__unknown__' THEN NULL ELSE NULLIF(BTRIM(t.product_category_name_english), '') END
       OR c.is_translation_missing IS DISTINCT FROM (c.category_code <> '__unknown__' AND NULLIF(BTRIM(t.product_category_name_english), '') IS NULL);
    IF bad_count > 0 THEN RAISE EXCEPTION 'category names or translation flags do not match source: %', bad_count; END IF;

    SELECT count(*) INTO actual_count FROM core.categories;
    SELECT md5(coalesce(string_agg(md5(to_jsonb(c)::text), ''
        ORDER BY md5(to_jsonb(c)::text)), '')) INTO business_hash FROM core.categories c;
    RAISE NOTICE 'core.categories business hash: %', business_hash;
    SELECT count(*) INTO raw_count FROM (SELECT DISTINCT NULLIF(BTRIM(product_category_name), '') AS code
        FROM raw.products WHERE NULLIF(BTRIM(product_category_name), '') IS NOT NULL) AS categories;
    RAISE NOTICE 'categories: % distinct source codes + unknown -> % core rows', raw_count, actual_count;
    SELECT count(*) INTO actual_count FROM core.products WHERE category_code = '__unknown__';
    SELECT count(*) INTO raw_count FROM core.categories WHERE is_translation_missing;
    RAISE NOTICE 'products without category: %; categories without translation: %', actual_count, raw_count;
    SELECT count(*) INTO actual_count FROM core.orders o WHERE NOT EXISTS
        (SELECT 1 FROM core.order_items i WHERE i.order_id = o.order_id);
    SELECT count(*) INTO raw_count FROM core.orders o WHERE NOT EXISTS
        (SELECT 1 FROM core.payments p WHERE p.order_id = o.order_id);
    RAISE NOTICE 'orders without items: %; orders without payments: %', actual_count, raw_count;
    SELECT count(*) INTO actual_count FROM core.orders WHERE order_delivered_customer_date IS NULL;
    RAISE NOTICE 'orders without customer delivery timestamp: %', actual_count;
    SELECT coalesce(sum(price), 0), coalesce(sum(freight_value), 0)
        INTO price_sum, freight_sum FROM core.order_items;
    SELECT coalesce(sum(payment_value), 0) INTO payment_sum FROM core.payments;
    RAISE NOTICE 'all-status amounts: items %, freight %, payments %', price_sum, freight_sum, payment_sum;
    RAISE NOTICE 'integrity checks passed';
END;
$$;
