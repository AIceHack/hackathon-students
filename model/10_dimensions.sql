BEGIN;

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
    customer_id,
    customer_unique_id,
    customer_city,
    customer_state,
    customer_zip_code_prefix
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
    seller_id, seller_city, seller_state, seller_zip_code_prefix
FROM raw.sellers;


DROP TABLE IF EXISTS core.categories CASCADE;
CREATE TABLE core.categories (
    category_code    TEXT PRIMARY KEY,
    category_name_en TEXT NOT NULL,
    category_name_pt TEXT NOT NULL,
    has_translation  BOOLEAN NOT NULL
);

INSERT INTO core.categories (
    category_code, category_name_en, category_name_pt, has_translation
)
SELECT
    COALESCE(NULLIF(BTRIM(p.product_category_name), ''), '__UNKNOWN__') AS category_code,

    CASE
        WHEN NULLIF(BTRIM(p.product_category_name), '') IS NULL
            THEN 'Unknown'
        WHEN t.product_category_name_english IS NOT NULL
            THEN t.product_category_name_english
        ELSE p.product_category_name
    END AS category_name_en,

    COALESCE(NULLIF(BTRIM(p.product_category_name), ''), '__UNKNOWN__') AS category_name_pt,

    CASE WHEN t.product_category_name IS NOT NULL THEN TRUE ELSE FALSE END AS has_translation

FROM (
    SELECT DISTINCT product_category_name
    FROM raw.products
) AS p
LEFT JOIN raw.product_category_translation AS t
       ON p.product_category_name = t.product_category_name;


DROP TABLE IF EXISTS core.products CASCADE;
CREATE TABLE core.products (
    product_id                 TEXT PRIMARY KEY,
    category_code              TEXT NOT NULL REFERENCES core.categories(category_code),
    product_name_length        INTEGER,   -- маппинг: raw.product_name_lenght
    product_description_length INTEGER,   -- маппинг: raw.product_description_lenght
    product_photos_qty         INTEGER,
    product_weight_g           INTEGER,
    product_length_cm          INTEGER,
    product_height_cm          INTEGER,
    product_width_cm           INTEGER
);

INSERT INTO core.products (
    product_id, category_code,
    product_name_length, product_description_length,
    product_photos_qty,
    product_weight_g, product_length_cm, product_height_cm, product_width_cm
)
SELECT
    product_id,
    COALESCE(NULLIF(BTRIM(product_category_name), ''), '__UNKNOWN__') AS category_code,

    NULLIF(BTRIM(product_name_lenght),        '')::INTEGER,
    NULLIF(BTRIM(product_description_lenght), '')::INTEGER,
    NULLIF(BTRIM(product_photos_qty),         '')::INTEGER,
    NULLIF(BTRIM(product_weight_g),           '')::INTEGER,
    NULLIF(BTRIM(product_length_cm),          '')::INTEGER,
    NULLIF(BTRIM(product_height_cm),          '')::INTEGER,
    NULLIF(BTRIM(product_width_cm),           '')::INTEGER
FROM raw.products;

COMMIT;