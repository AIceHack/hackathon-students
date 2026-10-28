CREATE SCHEMA IF NOT EXISTS core;

DROP TABLE IF EXISTS core.customers CASCADE;
CREATE TABLE core.customers (
    customer_id              TEXT PRIMARY KEY,
    customer_unique_id       TEXT NOT NULL,
    customer_city            TEXT,
    customer_state           TEXT,
    customer_zip_code_prefix TEXT
);

INSERT INTO core.customers (
    customer_id, customer_unique_id,
    customer_city, customer_state, customer_zip_code_prefix
)
SELECT
    NULLIF(BTRIM(customer_id), ''),
    NULLIF(BTRIM(customer_unique_id), ''),
    NULLIF(BTRIM(customer_city), ''),
    NULLIF(BTRIM(customer_state), ''),
    NULLIF(BTRIM(customer_zip_code_prefix), '')
FROM raw.customers;


DROP TABLE IF EXISTS core.sellers CASCADE;
CREATE TABLE core.sellers (
    seller_id              TEXT PRIMARY KEY,
    seller_city            TEXT,
    seller_state           TEXT,
    seller_zip_code_prefix TEXT
);

INSERT INTO core.sellers (
    seller_id, seller_city, seller_state, seller_zip_code_prefix
)
SELECT
    NULLIF(BTRIM(seller_id), ''), NULLIF(BTRIM(seller_city), ''),
    NULLIF(BTRIM(seller_state), ''), NULLIF(BTRIM(seller_zip_code_prefix), '')
FROM raw.sellers;


DROP TABLE IF EXISTS core.categories CASCADE;
CREATE TABLE core.categories (
    category_code    TEXT PRIMARY KEY,
    category_name_pt TEXT,
    category_name_en TEXT,
    is_translation_missing BOOLEAN NOT NULL
);

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM raw.products WHERE NULLIF(BTRIM(product_category_name), '') = '__unknown__') THEN
        RAISE EXCEPTION 'Reserved category code __unknown__ exists in raw.products';
    END IF;
    IF EXISTS (
        SELECT 1 FROM raw.product_category_translation
        WHERE NULLIF(BTRIM(product_category_name), '') IS NOT NULL
        GROUP BY NULLIF(BTRIM(product_category_name), '') HAVING COUNT(*) > 1
    ) THEN
        RAISE EXCEPTION 'Duplicate category codes in raw.product_category_translation';
    END IF;
END $$;

INSERT INTO core.categories (
    category_code, category_name_pt, category_name_en, is_translation_missing
)
SELECT
    p.category_code,
    CASE WHEN p.category_code = '__unknown__' THEN NULL ELSE p.category_code END,
    CASE WHEN p.category_code = '__unknown__' THEN NULL ELSE NULLIF(BTRIM(t.product_category_name_english), '') END,
    p.category_code <> '__unknown__' AND NULLIF(BTRIM(t.product_category_name_english), '') IS NULL
FROM (
    SELECT DISTINCT NULLIF(BTRIM(product_category_name), '') AS category_code
    FROM raw.products
    WHERE NULLIF(BTRIM(product_category_name), '') IS NOT NULL
    UNION ALL SELECT '__unknown__'
) AS p
LEFT JOIN raw.product_category_translation AS t
       ON p.category_code = NULLIF(BTRIM(t.product_category_name), '');


DROP TABLE IF EXISTS core.products CASCADE;
CREATE TABLE core.products (
    product_id                 TEXT PRIMARY KEY,
    category_code              TEXT NOT NULL REFERENCES core.categories(category_code),
    product_name_lenght        INTEGER,
    product_description_lenght INTEGER,
    product_photos_qty         INTEGER,
    product_weight_g           INTEGER,
    product_length_cm          INTEGER,
    product_height_cm          INTEGER,
    product_width_cm           INTEGER
);

INSERT INTO core.products (
    product_id, category_code,
    product_name_lenght, product_description_lenght,
    product_photos_qty,
    product_weight_g, product_length_cm, product_height_cm, product_width_cm
)
SELECT
    NULLIF(BTRIM(product_id), ''),
    COALESCE(NULLIF(BTRIM(product_category_name), ''), '__unknown__') AS category_code,

    NULLIF(BTRIM(product_name_lenght),        '')::INTEGER,
    NULLIF(BTRIM(product_description_lenght), '')::INTEGER,
    NULLIF(BTRIM(product_photos_qty),         '')::INTEGER,
    NULLIF(BTRIM(product_weight_g),           '')::INTEGER,
    NULLIF(BTRIM(product_length_cm),          '')::INTEGER,
    NULLIF(BTRIM(product_height_cm),          '')::INTEGER,
    NULLIF(BTRIM(product_width_cm),           '')::INTEGER
FROM raw.products;
