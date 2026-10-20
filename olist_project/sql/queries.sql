-- ============================================================================
-- Olist E-Commerce analysis: SQL queries (SQLite dialect)
--
-- Tables expected (loaded from the Kaggle CSVs by analysis.py):
--   customers, orders, order_items, order_payments, order_reviews,
--   products, sellers, category_translation
--
-- Each block starts with "-- name: <id>". analysis.py runs them in order and
-- saves every result to outputs/tables/<id>.csv
-- ============================================================================

-- name: setup
-- Indexes on the join keys: without them every JOIN scans the whole table
-- and the queries take minutes instead of seconds.
CREATE INDEX IF NOT EXISTS ix_orders_id          ON orders(order_id);
CREATE INDEX IF NOT EXISTS ix_orders_customer    ON orders(customer_id);
CREATE INDEX IF NOT EXISTS ix_customers_id       ON customers(customer_id);
CREATE INDEX IF NOT EXISTS ix_items_order        ON order_items(order_id);
CREATE INDEX IF NOT EXISTS ix_items_product      ON order_items(product_id);
CREATE INDEX IF NOT EXISTS ix_items_seller       ON order_items(seller_id);
CREATE INDEX IF NOT EXISTS ix_payments_order     ON order_payments(order_id);
CREATE INDEX IF NOT EXISTS ix_reviews_order      ON order_reviews(order_id);
CREATE INDEX IF NOT EXISTS ix_products_id        ON products(product_id);
CREATE INDEX IF NOT EXISTS ix_sellers_id         ON sellers(seller_id);
CREATE INDEX IF NOT EXISTS ix_translation_name   ON category_translation(product_category_name);

-- Helper views that encode the cleaning decisions in ONE place.
DROP VIEW IF EXISTS delivered_orders;
DROP VIEW IF EXISTS order_totals;
DROP VIEW IF EXISTS reviews_clean;
DROP VIEW IF EXISTS products_en;

-- Only orders that really reached the customer. Everything about revenue and
-- delivery performance is based on this view.
CREATE VIEW delivered_orders AS
SELECT
    o.order_id,
    c.customer_unique_id,                      -- real person (customer_id changes per order)
    c.customer_state,
    strftime('%Y-%m', o.order_purchase_timestamp)                       AS purchase_month,
    julianday(o.order_delivered_customer_date)
        - julianday(o.order_purchase_timestamp)                         AS delivery_days,
    -- compare calendar dates: delivering on the promised day is NOT late
    julianday(date(o.order_delivered_customer_date))
        - julianday(date(o.order_estimated_delivery_date))              AS days_late,
    CASE WHEN date(o.order_delivered_customer_date)
              > date(o.order_estimated_delivery_date) THEN 1 ELSE 0 END AS is_late
FROM orders o
JOIN customers c ON c.customer_id = o.customer_id
WHERE o.order_status = 'delivered'
  AND o.order_delivered_customer_date IS NOT NULL;

-- One row per order: an order can have several items (and sellers).
CREATE VIEW order_totals AS
SELECT order_id,
       COUNT(*)           AS n_items,
       SUM(price)         AS item_revenue,    -- revenue excludes freight
       SUM(freight_value) AS freight
FROM order_items
GROUP BY order_id;

-- Some orders have more than one review: keep only the latest one.
CREATE VIEW reviews_clean AS
SELECT order_id, review_score
FROM (
    SELECT order_id, review_score,
           ROW_NUMBER() OVER (PARTITION BY order_id
                              ORDER BY review_answer_timestamp DESC, review_id) AS rn
    FROM order_reviews
)
WHERE rn = 1;

-- English category names; products with no category become 'unknown'.
CREATE VIEW products_en AS
SELECT p.product_id,
       COALESCE(t.product_category_name_english, p.product_category_name, 'unknown') AS category
FROM products p
LEFT JOIN category_translation t ON t.product_category_name = p.product_category_name;


-- name: q01_kpi_summary
-- Business question: how big is the business and how healthy is delivery?
SELECT
    COUNT(*)                                                  AS delivered_orders,
    COUNT(DISTINCT d.customer_unique_id)                      AS unique_customers,
    ROUND(SUM(t.item_revenue), 2)                             AS revenue_brl,
    ROUND(SUM(t.item_revenue) / COUNT(*), 2)                  AS avg_order_value,
    ROUND(100.0 * SUM(t.freight) / SUM(t.item_revenue), 1)    AS freight_pct_of_revenue,
    ROUND(AVG(d.delivery_days), 1)                            AS avg_delivery_days,
    ROUND(100.0 * AVG(d.is_late), 1)                          AS late_pct
FROM delivered_orders d
JOIN order_totals t ON t.order_id = d.order_id;


-- name: q02_monthly_trend
-- Business question: is the business growing? (month-over-month revenue change)
-- Only 2017-01 .. 2018-08 are used: 2016 has just a handful of orders and the
-- last months of 2018 are incomplete, so growth rates there would be misleading.
WITH m AS (
    SELECT d.purchase_month,
           COUNT(*)             AS orders,
           SUM(t.item_revenue)  AS revenue
    FROM delivered_orders d
    JOIN order_totals t ON t.order_id = d.order_id
    WHERE d.purchase_month BETWEEN '2017-01' AND '2018-08'
    GROUP BY d.purchase_month
)
SELECT purchase_month,
       orders,
       ROUND(revenue, 2)                                              AS revenue,
       ROUND(revenue / orders, 2)                                     AS avg_order_value,
       ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY purchase_month))
                   / LAG(revenue) OVER (ORDER BY purchase_month), 1)  AS revenue_mom_pct
FROM m
ORDER BY purchase_month;


-- name: q03_top_categories
-- Business question: which product categories bring the money?
SELECT p.category,
       COUNT(*)                         AS items_sold,
       ROUND(SUM(i.price), 2)           AS revenue,
       ROUND(100.0 * SUM(i.price) /
             (SELECT SUM(i2.price)
              FROM order_items i2
              JOIN delivered_orders d2 ON d2.order_id = i2.order_id), 1) AS revenue_share_pct,
       ROUND(AVG(i.price), 2)           AS avg_item_price
FROM order_items i
JOIN delivered_orders d ON d.order_id = i.order_id
JOIN products_en p      ON p.product_id = i.product_id
GROUP BY p.category
ORDER BY revenue DESC
LIMIT 10;


-- name: q04_state_summary
-- Business question: where are the customers, and is delivery worse far from the sellers?
SELECT d.customer_state,
       COUNT(*)                                                       AS orders,
       ROUND(100.0 * COUNT(*) /
             (SELECT COUNT(*) FROM delivered_orders x
              JOIN order_totals y ON y.order_id = x.order_id), 1)     AS order_share_pct,
       ROUND(SUM(t.item_revenue), 2)                                  AS revenue,
       ROUND(AVG(d.delivery_days), 1)                                 AS avg_delivery_days,
       ROUND(100.0 * AVG(d.is_late), 1)                               AS late_pct,
       ROUND(100.0 * SUM(t.freight) / SUM(t.item_revenue), 1)         AS freight_pct_of_revenue
FROM delivered_orders d
JOIN order_totals t ON t.order_id = d.order_id
GROUP BY d.customer_state
ORDER BY orders DESC;


-- name: q05_payment_mix
-- Business question: how do customers pay?
SELECT p.payment_type,
       COUNT(DISTINCT p.order_id)                                       AS orders,
       ROUND(SUM(p.payment_value), 2)                                   AS total_value,
       ROUND(100.0 * SUM(p.payment_value) /
             (SELECT SUM(p2.payment_value)
              FROM order_payments p2
              JOIN delivered_orders d2 ON d2.order_id = p2.order_id), 1) AS value_share_pct,
       ROUND(AVG(p.payment_installments), 1)                            AS avg_installments
FROM order_payments p
JOIN delivered_orders d ON d.order_id = p.order_id
GROUP BY p.payment_type
ORDER BY total_value DESC;


-- name: q06_delivery_vs_review
-- Business question: does a late delivery really hurt customer satisfaction?
SELECT CASE WHEN d.days_late <= 0 THEN '1. on time or early'
            WHEN d.days_late <= 3 THEN '2. 1-3 days late'
            WHEN d.days_late <= 7 THEN '3. 4-7 days late'
            ELSE                       '4. 8+ days late' END      AS delivery_bucket,
       COUNT(*)                                                   AS orders,
       ROUND(AVG(r.review_score), 2)                              AS avg_review_score,
       ROUND(100.0 * AVG(r.review_score = 1), 1)                  AS one_star_pct,
       ROUND(100.0 * AVG(r.review_score >= 4), 1)                 AS positive_pct
FROM delivered_orders d
JOIN reviews_clean r ON r.order_id = d.order_id
GROUP BY delivery_bucket
ORDER BY delivery_bucket;


-- name: q07_repeat_customers
-- Business question: do customers come back? (uses customer_unique_id, NOT customer_id)
WITH c AS (
    SELECT customer_unique_id, COUNT(*) AS n_orders
    FROM delivered_orders
    GROUP BY customer_unique_id
)
SELECT CASE WHEN n_orders = 1 THEN '1 order'
            WHEN n_orders = 2 THEN '2 orders'
            ELSE                   '3+ orders' END               AS segment,
       COUNT(*)                                                  AS customers,
       ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM c), 1)     AS pct_of_customers
FROM c
GROUP BY segment
ORDER BY segment;


-- name: q08_seller_pareto
-- Business question: how concentrated is revenue among sellers? (deciles, 1 = biggest)
WITH s AS (
    SELECT i.seller_id, SUM(i.price) AS revenue
    FROM order_items i
    JOIN delivered_orders d ON d.order_id = i.order_id
    GROUP BY i.seller_id
),
r AS (
    SELECT seller_id, revenue, NTILE(10) OVER (ORDER BY revenue DESC) AS decile
    FROM s
)
SELECT decile,
       COUNT(*)                                                      AS sellers,
       ROUND(SUM(revenue), 2)                                        AS revenue,
       ROUND(100.0 * SUM(revenue) / (SELECT SUM(revenue) FROM s), 1) AS revenue_share_pct
FROM r
GROUP BY decile
ORDER BY decile;


-- name: q09_top_sellers
-- Business question: who are the top sellers and are their customers happy?
SELECT i.seller_id,
       s.seller_state,
       COUNT(DISTINCT i.order_id)  AS orders,
       ROUND(SUM(i.price), 2)      AS revenue,
       ROUND(AVG(r.review_score), 2) AS avg_review_score
FROM order_items i
JOIN delivered_orders d ON d.order_id = i.order_id
JOIN sellers s          ON s.seller_id = i.seller_id
LEFT JOIN reviews_clean r ON r.order_id = i.order_id
GROUP BY i.seller_id, s.seller_state
ORDER BY revenue DESC
LIMIT 10;


-- name: q10_worst_rated_categories
-- Business question: which sizeable categories disappoint customers the most?
SELECT p.category,
       COUNT(DISTINCT i.order_id)             AS orders,
       ROUND(AVG(r.review_score), 2)          AS avg_review_score,
       ROUND(100.0 * AVG(d.is_late), 1)       AS late_pct
FROM order_items i
JOIN delivered_orders d ON d.order_id = i.order_id
JOIN products_en p      ON p.product_id = i.product_id
JOIN reviews_clean r    ON r.order_id = i.order_id
GROUP BY p.category
HAVING COUNT(DISTINCT i.order_id) >= 500
ORDER BY avg_review_score ASC
LIMIT 8;


-- name: q11_data_quality_checks
-- Evidence for the cleaning decisions documented in the README.
SELECT 'orders with status other than delivered' AS check_name, COUNT(*) AS n
FROM orders WHERE order_status <> 'delivered'
UNION ALL
SELECT 'delivered orders with no delivery date', COUNT(*)
FROM orders WHERE order_status = 'delivered' AND order_delivered_customer_date IS NULL
UNION ALL
SELECT 'orders without any item', COUNT(*)
FROM orders o WHERE NOT EXISTS (SELECT 1 FROM order_items i WHERE i.order_id = o.order_id)
UNION ALL
SELECT 'orders with more than one review', COUNT(*)
FROM (SELECT order_id FROM order_reviews GROUP BY order_id HAVING COUNT(*) > 1)
UNION ALL
SELECT 'products without a category', COUNT(*)
FROM products WHERE product_category_name IS NULL
UNION ALL
SELECT 'customer_id minus customer_unique_id (repeat buyers hidden)',
       (SELECT COUNT(DISTINCT customer_id) FROM customers)
     - (SELECT COUNT(DISTINCT customer_unique_id) FROM customers)
UNION ALL
SELECT 'orders where payments differ from items+freight by > 1 BRL', COUNT(*)
FROM order_totals t
JOIN (SELECT order_id, SUM(payment_value) AS pv FROM order_payments GROUP BY order_id) p
  ON p.order_id = t.order_id
WHERE ABS(p.pv - (t.item_revenue + t.freight)) > 1;
