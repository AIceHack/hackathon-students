-- RAW-слой: таблицы повторяют структуру исходных CSV один в один.
--
-- Все колонки — text. Это сознательное решение: в raw-слой данные
-- кладутся «как пришли», без приведения типов и без потерь. Если
-- объявить дату как timestamp, а в файле окажется пустая строка или
-- мусор, загрузка упадёт целиком. Приводить типы и чистить данные
-- нужно уже при переносе в свою модель (схема core).
--
-- Служебные колонки _source_file и _loaded_at заполняются автоматически
-- и показывают, откуда и когда приехала строка.

DROP TABLE IF EXISTS raw.orders;
DROP TABLE IF EXISTS raw.order_items;
DROP TABLE IF EXISTS raw.order_payments;
DROP TABLE IF EXISTS raw.order_reviews;
DROP TABLE IF EXISTS raw.products;
DROP TABLE IF EXISTS raw.sellers;
DROP TABLE IF EXISTS raw.customers;
DROP TABLE IF EXISTS raw.product_category_translation;


-- Заказы. Одна строка — один заказ.
-- Источник: olist_orders_dataset.csv
CREATE TABLE raw.orders (
    order_id                      text,
    customer_id                   text,
    order_status                  text,
    order_purchase_timestamp      text,  -- момент оформления
    order_approved_at             text,  -- момент подтверждения оплаты
    order_delivered_carrier_date  text,  -- передан в доставку
    order_delivered_customer_date text,  -- вручён покупателю
    order_estimated_delivery_date text,  -- обещанная дата доставки
    _source_file                  text,
    _loaded_at                    timestamptz DEFAULT now()
);

-- Позиции заказа. Одна строка — один товар одного продавца в заказе.
-- Источник: olist_order_items_dataset.csv
CREATE TABLE raw.order_items (
    order_id            text,
    order_item_id       text,  -- порядковый номер позиции ВНУТРИ заказа
    product_id          text,
    seller_id           text,
    shipping_limit_date text,  -- крайний срок отгрузки продавцом
    price               text,  -- цена товара в этой позиции
    freight_value       text,  -- стоимость доставки этой позиции
    _source_file        text,
    _loaded_at          timestamptz DEFAULT now()
);

-- Платежи. Заказ может быть оплачен несколькими способами.
-- Источник: olist_order_payments_dataset.csv
CREATE TABLE raw.order_payments (
    order_id             text,
    payment_sequential   text,  -- номер платежа внутри заказа
    payment_type         text,  -- credit_card, boleto, voucher, debit_card
    payment_installments text,  -- число частей рассрочки
    payment_value        text,
    _source_file         text,
    _loaded_at           timestamptz DEFAULT now()
);

-- Отзывы покупателей о заказе.
-- Источник: olist_order_reviews_dataset.csv
CREATE TABLE raw.order_reviews (
    review_id               text,
    order_id                text,
    review_score            text,  -- оценка от 1 до 5
    review_comment_title    text,
    review_comment_message  text,
    review_creation_date    text,
    review_answer_timestamp text,
    _source_file            text,
    _loaded_at              timestamptz DEFAULT now()
);

-- Карточки товаров.
-- Источник: olist_products_dataset.csv
CREATE TABLE raw.products (
    product_id                 text,
    product_category_name      text,  -- категория на португальском
    product_name_lenght        text,  -- опечатка в названии — из исходника
    product_description_lenght text,
    product_photos_qty         text,
    product_weight_g           text,
    product_length_cm          text,
    product_height_cm          text,
    product_width_cm           text,
    _source_file               text,
    _loaded_at                 timestamptz DEFAULT now()
);

-- Продавцы.
-- Источник: olist_sellers_dataset.csv
CREATE TABLE raw.sellers (
    seller_id              text,
    seller_zip_code_prefix text,
    seller_city            text,
    seller_state           text,
    _source_file           text,
    _loaded_at             timestamptz DEFAULT now()
);

-- Покупатели.
-- Источник: olist_customers_dataset.csv
CREATE TABLE raw.customers (
    customer_id              text,
    customer_unique_id       text,
    customer_zip_code_prefix text,
    customer_city            text,
    customer_state           text,
    _source_file             text,
    _loaded_at               timestamptz DEFAULT now()
);

-- Справочник перевода категорий: португальский -> английский.
-- Источник: product_category_name_translation.csv
CREATE TABLE raw.product_category_translation (
    product_category_name         text,
    product_category_name_english text,
    _source_file                  text,
    _loaded_at                    timestamptz DEFAULT now()
);
