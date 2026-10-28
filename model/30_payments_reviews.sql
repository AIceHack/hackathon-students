BEGIN;

CREATE SCHEMA IF NOT EXISTS core;

-- ----------------------------------------------------------------------------
-- 0. Журнал аномалий качества данных (не скрываем проблемы через INNER JOIN)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core.dq_anomalies (
    anomaly_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    detected_at      timestamp NOT NULL DEFAULT clock_timestamp(),
    source_table    text NOT NULL,
    anomaly_type    text NOT NULL,
    entity_key      text NOT NULL,
    details         text
);

DELETE FROM core.dq_anomalies
WHERE source_table IN ('raw.order_payments', 'raw.order_reviews');

-- ----------------------------------------------------------------------------
-- 1. Диагностика и создание таблицы core.payments
--    Grain: одна платёжная запись внутри заказа (order_id, payment_sequential)
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    v_dup_payments bigint;
BEGIN
    SELECT COUNT(*) INTO v_dup_payments
    FROM (
        SELECT btrim(order_id), NULLIF(btrim(payment_sequential), '')::integer
        FROM raw.order_payments
        GROUP BY 1, 2
        HAVING COUNT(*) > 1
    ) d;

    IF v_dup_payments > 0 THEN
        RAISE EXCEPTION 'КРИТИЧЕСКАЯ ОШИБКА: В raw.order_payments обнаружено % дублей ключа (order_id, payment_sequential)!', v_dup_payments;
    END IF;
END $$;

DROP VIEW IF EXISTS core.v_order_payments_summary CASCADE;
DROP TABLE IF EXISTS core.payments CASCADE;

CREATE TABLE core.payments (
    order_id             text           NOT NULL,
    payment_sequential   integer        NOT NULL CHECK (payment_sequential >= 1),
    payment_type         text           NOT NULL,
    payment_installments integer        NOT NULL CHECK (payment_installments >= 0),
    payment_value        numeric(14, 2) NOT NULL CHECK (payment_value >= 0),
    CONSTRAINT pk_core_payments PRIMARY KEY (order_id, payment_sequential)
);

COMMENT ON TABLE core.payments IS 'Платежи по заказам. Grain: (order_id, payment_sequential). payment_installments — число частей рассрочки, НЕ множитель payment_value.';

INSERT INTO core.payments (
    order_id,
    payment_sequential,
    payment_type,
    payment_installments,
    payment_value
)
SELECT
    btrim(order_id)                                      AS order_id,
    NULLIF(btrim(payment_sequential), '')::integer       AS payment_sequential,
    COALESCE(NULLIF(btrim(payment_type), ''), 'unknown') AS payment_type,
    NULLIF(btrim(payment_installments), '')::integer     AS payment_installments,
    ROUND(NULLIF(btrim(payment_value), '')::numeric, 2)  AS payment_value
FROM raw.order_payments;

-- Фиксация аномалий платежей в журнале
-- 1.1. Осиротевшие платежи (если в core.orders отсутствуют заказы из raw)
INSERT INTO core.dq_anomalies (source_table, anomaly_type, entity_key, details)
SELECT
    'raw.order_payments',
    'orphan_payment_order_id',
    p.order_id,
    format('payment_sequential=%s, payment_value=%s отсутствует в core.orders', p.payment_sequential, p.payment_value)
FROM core.payments p
LEFT JOIN core.orders o ON o.order_id = p.order_id
WHERE o.order_id IS NULL;

-- 1.2. Заказы из core.orders без единого платежа
INSERT INTO core.dq_anomalies (source_table, anomaly_type, entity_key, details)
SELECT
    'raw.order_payments',
    'order_without_payments',
    o.order_id,
    format('order_status=%s не имеет строк в core.payments', o.order_status)
FROM core.orders o
LEFT JOIN core.payments p ON p.order_id = o.order_id
WHERE p.order_id IS NULL;

-- 1.3. Неопознанные типы оплаты, нулевая рассрочка и нулевые суммы
INSERT INTO core.dq_anomalies (source_table, anomaly_type, entity_key, details)
SELECT
    'raw.order_payments',
    CASE
        WHEN payment_type = 'not_defined' THEN 'unrecognized_payment_type'
        WHEN payment_installments = 0     THEN 'zero_installments'
        WHEN payment_value = 0            THEN 'zero_payment_value'
    END,
    order_id || '#' || payment_sequential::text,
    format('type=%s, installments=%s, value=%s', payment_type, payment_installments, payment_value)
FROM core.payments
WHERE payment_type = 'not_defined'
   OR payment_installments = 0
   OR payment_value = 0;

-- Добавление FK на core.orders только после проверки отсутствия сирот
DO $$
DECLARE
    v_orphans bigint;
BEGIN
    SELECT COUNT(*) INTO v_orphans
    FROM core.payments p
    LEFT JOIN core.orders o ON o.order_id = p.order_id
    WHERE o.order_id IS NULL;

    IF v_orphans = 0 THEN
        ALTER TABLE core.payments
            ADD CONSTRAINT fk_payments_orders
            FOREIGN KEY (order_id) REFERENCES core.orders (order_id);
    ELSE
        RAISE WARNING 'ВНИМАНИЕ: Обнаружено % осиротевших платежей (вероятно, core.orders отфильтрована). Записи сохранены в core.dq_anomalies, FK не наложен во избежание потери строк.', v_orphans;
    END IF;
END $$;

CREATE INDEX idx_core_payments_order_id ON core.payments (order_id);
CREATE INDEX idx_core_payments_type ON core.payments (payment_type);

-- Вспомогательное представление: агрегация платежей до уровня заказа (order_id)
-- Защищает от умножения строк при соединении заказов/позиций с платежами
CREATE OR REPLACE VIEW core.v_order_payments_summary AS
SELECT
    order_id,
    COUNT(*)::integer                       AS payment_rows_count,
    COUNT(DISTINCT payment_type)::integer   AS distinct_payment_types,
    MAX(payment_installments)::integer      AS max_installments,
    SUM(payment_value)::numeric(14, 2)      AS total_payment_value
FROM core.payments
GROUP BY order_id;

-- ----------------------------------------------------------------------------
-- 2. Диагностика и создание таблицы core.reviews
--    Grain: одна исходная строка отзыва из raw.order_reviews
--    review_id НЕ уникален глобально (один отзыв может относиться к нескольким заказам),
--    поэтому вводим суррогатный PK review_row_id, а review_id оставляем бизнес-полем.
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS core.reviews CASCADE;

CREATE TABLE core.reviews (
    review_row_id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    review_id               text      NOT NULL,
    order_id                text      NOT NULL,
    review_score            integer   NOT NULL CHECK (review_score BETWEEN 1 AND 5),
    review_comment_title    text,
    review_comment_message  text,
    review_creation_date    timestamp NOT NULL,
    review_answer_timestamp timestamp NOT NULL
);

COMMENT ON TABLE core.reviews IS 'Отзывы покупателей. Grain: исходная строка отзыва. NULL в тексте комментария не означает негативный отзыв или возврат.';

INSERT INTO core.reviews (
    review_id,
    order_id,
    review_score,
    review_comment_title,
    review_comment_message,
    review_creation_date,
    review_answer_timestamp
)
SELECT
    btrim(review_id)                                           AS review_id,
    btrim(order_id)                                            AS order_id,
    NULLIF(btrim(review_score), '')::integer                   AS review_score,
    NULLIF(btrim(review_comment_title), '')                    AS review_comment_title,
    NULLIF(btrim(review_comment_message), '')                  AS review_comment_message,
    NULLIF(btrim(review_creation_date), '')::timestamp         AS review_creation_date,
    NULLIF(btrim(review_answer_timestamp), '')::timestamp      AS review_answer_timestamp
FROM raw.order_reviews
ORDER BY
    btrim(order_id),
    btrim(review_id),
    NULLIF(btrim(review_creation_date), '')::timestamp,
    NULLIF(btrim(review_answer_timestamp), '')::timestamp;

-- Фиксация особенностей ключей отзывов в журнале аномалий
-- 2.1. Повторяющиеся review_id (один review_id на несколько заказов)
INSERT INTO core.dq_anomalies (source_table, anomaly_type, entity_key, details)
SELECT
    'raw.order_reviews',
    'non_unique_review_id',
    review_id,
    format('review_id встречается %s раз(а) в разных заказах', COUNT(*))
FROM core.reviews
GROUP BY review_id
HAVING COUNT(*) > 1;

-- 2.2. Заказы с несколькими отзывами
INSERT INTO core.dq_anomalies (source_table, anomaly_type, entity_key, details)
SELECT
    'raw.order_reviews',
    'multiple_reviews_per_order',
    order_id,
    format('order_id имеет %s строк(и) отзывов', COUNT(*))
FROM core.reviews
GROUP BY order_id
HAVING COUNT(*) > 1;

-- 2.3. Осиротевшие отзывы (если в core.orders нет заказа)
INSERT INTO core.dq_anomalies (source_table, anomaly_type, entity_key, details)
SELECT
    'raw.order_reviews',
    'orphan_review_order_id',
    r.order_id,
    format('review_id=%s отсутствует в core.orders', r.review_id)
FROM core.reviews r
LEFT JOIN core.orders o ON o.order_id = r.order_id
WHERE o.order_id IS NULL;

-- Проверка FK для core.reviews
DO $$
DECLARE
    v_orphans bigint;
BEGIN
    SELECT COUNT(*) INTO v_orphans
    FROM core.reviews r
    LEFT JOIN core.orders o ON o.order_id = r.order_id
    WHERE o.order_id IS NULL;

    IF v_orphans = 0 THEN
        ALTER TABLE core.reviews
            ADD CONSTRAINT fk_reviews_orders
            FOREIGN KEY (order_id) REFERENCES core.orders (order_id);
    ELSE
        RAISE WARNING 'ВНИМАНИЕ: Обнаружено % осиротевших отзывов. Записи сохранены в core.dq_anomalies, FK не наложен.', v_orphans;
    END IF;
END $$;

CREATE INDEX idx_core_reviews_order_id ON core.reviews (order_id);
CREATE INDEX idx_core_reviews_review_id ON core.reviews (review_id);

COMMIT;
