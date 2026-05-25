-- ============================================================
-- OLIST E-COMMERCE ANALYSIS — DATA CLEANING & TABLE CREATION
-- Author  : Abhinandan Sonne
-- Tool    : SQLite via DBeaver
-- Dataset : Brazilian E-Commerce Public Dataset (Olist / Kaggle)
-- ============================================================
-- TABLES CREATED:
--   1. orders_clean_full     → Master cleaned fact table
--   2. monthly_trends        → Monthly GMV + MoM growth (window fn)
--   3. state_performance     → Revenue & delivery KPIs by state
--   4. payment_analysis      → Payment type breakdown
--   5. delivery_performance  → Late delivery rate by state
--   6. category_performance  → Revenue by product category
--   7. rfm_segments (VIEW)   → RFM customer segmentation
-- ============================================================


-- ============================================================
-- TABLE 1: orders_clean_full
-- Master analytical table joining all 5 raw Olist tables
-- ============================================================

CREATE TABLE orders_clean_full AS
SELECT
    o.order_id,
    o.customer_id,
    c.customer_unique_id,

    -- Date fields
    DATE(o.order_purchase_timestamp)        AS order_date,
    DATE(o.order_delivered_customer_date)   AS delivered_date,

    -- Delivery delay: days from purchase to delivery
    CAST(
        JULIANDAY(o.order_delivered_customer_date)
        - JULIANDAY(o.order_purchase_timestamp)
    AS INTEGER)                             AS delivery_delay_days,

    -- Time dimensions for aggregation
    STRFTIME('%Y',    o.order_purchase_timestamp)   AS order_year,
    STRFTIME('%m',    o.order_purchase_timestamp)   AS order_month,
    STRFTIME('%Y-%m', o.order_purchase_timestamp)   AS order_year_month,

    -- Customer location
    c.customer_city,
    c.customer_state,

    -- Order metrics (aggregated from items subquery)
    i.item_count,
    i.items_subtotal,
    i.freight_total,
    i.gmv,

    -- Payment metrics (aggregated from payments subquery)
    p.total_payment,
    p.payment_types,
    p.max_installments,

    -- Product category
    i.category_name

FROM olist_orders_dataset o

LEFT JOIN olist_customers_dataset c
    ON o.customer_id = c.customer_id

-- Aggregate order items: count, subtotal, freight, GMV, category
LEFT JOIN (
    SELECT
        order_id,
        COUNT(DISTINCT order_item_id)               AS item_count,
        SUM(price)                                  AS items_subtotal,
        SUM(freight_value)                          AS freight_total,
        SUM(price) + SUM(freight_value)             AS gmv,
        GROUP_CONCAT(DISTINCT pr.product_category_name) AS category_name
    FROM olist_order_items_dataset oi
    LEFT JOIN olist_products_dataset pr
        ON oi.product_id = pr.product_id
    GROUP BY order_id
) i ON o.order_id = i.order_id

-- Aggregate payments: total value, types, max installments
LEFT JOIN (
    SELECT
        order_id,
        SUM(payment_value)                          AS total_payment,
        GROUP_CONCAT(DISTINCT payment_type)         AS payment_types,
        MAX(payment_installments)                   AS max_installments
    FROM olist_order_payments_dataset
    GROUP BY order_id
) p ON o.order_id = p.order_id;


-- ── Validation queries ────────────────────────────────────────
-- Total row count
SELECT COUNT(*) FROM orders_clean_full;

-- Check for duplicate order_ids
SELECT order_id, COUNT(*)
FROM orders_clean_full
GROUP BY order_id
HAVING COUNT(*) > 1;

-- GMV vs payment reconciliation
SELECT
    ROUND(SUM(gmv), 2)           AS total_gmv,
    ROUND(SUM(total_payment), 2) AS total_payment
FROM orders_clean_full;

-- Top 10 orders with largest GMV vs payment discrepancy
SELECT
    order_id,
    item_count,
    gmv,
    total_payment
FROM orders_clean_full
ORDER BY ABS(total_payment - gmv) DESC
LIMIT 10;


-- ============================================================
-- TABLE 2: monthly_trends
-- Monthly GMV with MoM growth % and cumulative GMV
-- Uses: LAG() window function, SUM() OVER()
-- ============================================================

CREATE TABLE monthly_trends AS
WITH base AS (
    SELECT
        order_year_month,
        COUNT(order_id)     AS orders,
        ROUND(SUM(gmv), 2)  AS gmv
    FROM orders_clean_full
    GROUP BY order_year_month
)
SELECT
    order_year_month,
    orders,
    gmv,

    -- Previous month GMV for MoM calculation
    LAG(gmv) OVER (ORDER BY order_year_month) AS prev_gmv,

    -- Month-over-Month growth percentage
    ROUND(
        (gmv - LAG(gmv) OVER (ORDER BY order_year_month))
        * 100.0
        / LAG(gmv) OVER (ORDER BY order_year_month)
    , 2) AS mom_pct,

    -- Cumulative GMV running total
    ROUND(
        SUM(gmv) OVER (ORDER BY order_year_month)
    , 2) AS cum_gmv

FROM base;

-- Preview
SELECT * FROM monthly_trends LIMIT 12;


-- ============================================================
-- TABLE 3: state_performance
-- Revenue, order volume, and delivery KPIs by state
-- ============================================================

CREATE TABLE state_performance AS
SELECT
    customer_state,
    COUNT(order_id)                     AS orders,
    COUNT(DISTINCT customer_unique_id)  AS unique_customers,
    ROUND(SUM(gmv), 2)                  AS revenue,
    ROUND(AVG(gmv), 2)                  AS avg_order_value,
    ROUND(AVG(delivery_delay_days), 2)  AS avg_delay_days
FROM orders_clean_full
GROUP BY customer_state
ORDER BY revenue DESC;

SELECT * FROM state_performance;


-- ============================================================
-- TABLE 4: payment_analysis
-- Order count, revenue, and installments by payment type
-- ============================================================

CREATE TABLE payment_analysis AS
SELECT
    payment_types,
    COUNT(order_id)                     AS orders,
    ROUND(SUM(total_payment), 2)        AS revenue,
    ROUND(AVG(total_payment), 2)        AS avg_order_value,
    ROUND(AVG(max_installments), 2)     AS avg_installments
FROM orders_clean_full
WHERE payment_types IS NOT NULL
  AND payment_types <> ''
  AND payment_types <> 'not_defined'
GROUP BY payment_types
ORDER BY revenue DESC;

SELECT * FROM payment_analysis;


-- ============================================================
-- TABLE 5: delivery_performance
-- Late delivery rate by state (threshold: >15 days)
-- ============================================================

CREATE TABLE delivery_performance AS
SELECT
    customer_state,
    ROUND(AVG(delivery_delay_days), 2)  AS avg_delay_days,
    COUNT(order_id)                     AS total_orders,

    -- Orders exceeding 15-day delivery threshold
    SUM(CASE WHEN delivery_delay_days > 15 THEN 1 ELSE 0 END) AS late_orders,

    ROUND(
        SUM(CASE WHEN delivery_delay_days > 15 THEN 1 ELSE 0 END)
        * 100.0 / COUNT(order_id)
    , 2) AS late_pct

FROM orders_clean_full
GROUP BY customer_state
ORDER BY late_pct DESC;

SELECT * FROM delivery_performance LIMIT 15;


-- ============================================================
-- TABLE 6: category_performance
-- Revenue, order volume, and revenue share by product category
-- ============================================================

CREATE TABLE category_performance AS
SELECT
    category_name,
    COUNT(order_id)                     AS orders,
    ROUND(SUM(gmv), 2)                  AS revenue,
    ROUND(AVG(gmv), 2)                  AS avg_order_value,

    -- Revenue share as % of total GMV
    ROUND(
        SUM(gmv) * 100.0
        / (SELECT SUM(gmv) FROM orders_clean_full)
    , 2) AS revenue_share_pct

FROM orders_clean_full
GROUP BY category_name
ORDER BY revenue DESC;

SELECT * FROM category_performance LIMIT 15;


-- ============================================================
-- VIEW 7: rfm_segments
-- RFM (Recency, Frequency, Monetary) customer segmentation
-- Uses: NTILE(4) window function, CASE WHEN segmentation
-- ============================================================

CREATE VIEW rfm_segments AS
WITH rfm_base AS (
    SELECT
        customer_unique_id,
        COUNT(*)                                    AS frequency,
        ROUND(SUM(COALESCE(gmv, 0)), 2)             AS monetary,

        -- Recency: days since last order (relative to dataset max date)
        CAST(
            JULIANDAY((SELECT MAX(order_date) FROM orders_clean_full))
            - JULIANDAY(MAX(order_date))
        AS INTEGER)                                 AS recency_days
    FROM orders_clean_full
    GROUP BY customer_unique_id
),

rfm_scored AS (
    SELECT
        *,
        NTILE(4) OVER (ORDER BY recency_days DESC)  AS r_score,
        NTILE(4) OVER (ORDER BY frequency DESC)     AS f_score,
        NTILE(4) OVER (ORDER BY monetary DESC)      AS m_score
    FROM rfm_base
)

SELECT
    customer_unique_id,
    recency_days,
    frequency,
    monetary,
    r_score,
    f_score,
    m_score,
    (r_score + f_score + m_score)   AS rfm_total,

    CASE
        WHEN r_score = 4 AND f_score >= 3              THEN 'Champion'
        WHEN r_score >= 3 AND f_score >= 2             THEN 'Loyal'
        WHEN r_score >= 3 AND f_score = 1              THEN 'Potential Loyalist'
        WHEN r_score = 2 AND f_score >= 2              THEN 'At Risk'
        WHEN r_score <= 2 AND f_score >= 3             THEN 'Cannot Lose Them'
        WHEN r_score = 1                               THEN 'Lost'
        ELSE                                                'Others'
    END AS customer_segment

FROM rfm_scored;

-- Preview
SELECT * FROM rfm_segments LIMIT 15;

-- Segment distribution
SELECT
    customer_segment,
    COUNT(*) AS customers
FROM rfm_segments
GROUP BY customer_segment
ORDER BY customers DESC;
