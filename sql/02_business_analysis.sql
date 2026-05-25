-- ============================================================
-- OLIST E-COMMERCE ANALYSIS — BUSINESS QUESTIONS & INSIGHTS
-- Author  : Abhinandan Sonne
-- Tool    : SQLite via DBeaver
-- Requires: Tables created in 01_cleaning_and_tables.sql
-- ============================================================
-- SECTIONS:
--   A. Pareto Analysis — Category Revenue Concentration
--   B. State Performance vs Delivery Quality
--   C. Customer Segment Revenue Contribution
--   D. New vs Repeat Customer Analysis
--   E. High Volume but Low Value Categories (Opportunity)
--   F. State Segmentation Matrix (Volume vs Value)
-- ============================================================


-- ============================================================
-- A. PARETO ANALYSIS — CATEGORY REVENUE CONCENTRATION
-- How many categories drive 80% of total revenue?
-- Uses: SUM() OVER() cumulative window function
-- ============================================================

-- Cumulative revenue share by category
SELECT
    category_name,
    revenue,
    revenue_share_pct,
    ROUND(
        SUM(revenue_share_pct) OVER (ORDER BY revenue DESC)
    , 2) AS cumulative_share_pct
FROM category_performance
ORDER BY revenue DESC;

-- How many categories needed to reach 80% of revenue?
SELECT COUNT(*) AS categories_for_80pct_revenue
FROM (
    SELECT
        SUM(revenue_share_pct) OVER (ORDER BY revenue DESC) AS cum_share
    FROM category_performance
)
WHERE cum_share <= 80;

-- Total number of categories
SELECT COUNT(*) AS total_categories FROM category_performance;


-- ============================================================
-- B. STATE PERFORMANCE VS DELIVERY QUALITY
-- Join revenue performance with delivery late rates
-- Shows which high-revenue states also have bad delivery
-- ============================================================

SELECT
    s.customer_state,
    s.revenue,
    s.orders,
    s.avg_order_value,
    d.avg_delay_days,
    d.late_pct
FROM state_performance s
JOIN delivery_performance d
    ON s.customer_state = d.customer_state
ORDER BY s.revenue DESC;


-- ============================================================
-- C. CUSTOMER SEGMENT REVENUE CONTRIBUTION (RFM)
-- Which segments generate the most total revenue?
-- ============================================================

SELECT
    customer_segment,
    COUNT(*)                        AS customers,
    ROUND(SUM(monetary), 2)         AS revenue,
    ROUND(AVG(monetary), 2)         AS avg_customer_value
FROM rfm_segments
GROUP BY customer_segment
ORDER BY revenue DESC;


-- ============================================================
-- D. NEW VS REPEAT CUSTOMER ANALYSIS
-- Single-purchase vs multi-purchase customers
-- ============================================================

SELECT
    CASE
        WHEN frequency = 1 THEN 'New Customer'
        ELSE 'Repeat Customer'
    END                             AS customer_type,
    COUNT(*)                        AS customers,
    ROUND(SUM(monetary), 2)         AS revenue,
    ROUND(AVG(monetary), 2)         AS avg_customer_value
FROM rfm_segments
GROUP BY customer_type;


-- ============================================================
-- E. HIGH VOLUME BUT LOW VALUE CATEGORIES
-- Categories with above-average order count
-- but below-average order value — pricing opportunity
-- ============================================================

SELECT
    category_name,
    orders,
    revenue,
    avg_order_value
FROM category_performance
WHERE orders > (SELECT AVG(orders) FROM category_performance)
  AND avg_order_value < (SELECT AVG(avg_order_value) FROM category_performance)
ORDER BY orders DESC;


-- ============================================================
-- F. STATE SEGMENTATION MATRIX
-- Classify each state by order volume AND order value
-- Quadrant analysis: High/Low Volume × High/Low Value
-- ============================================================

SELECT
    customer_state,
    orders,
    avg_order_value,

    CASE
        WHEN orders > (SELECT AVG(orders) FROM state_performance)
         AND avg_order_value > (SELECT AVG(avg_order_value) FROM state_performance)
            THEN 'High Volume + High Value'

        WHEN orders > (SELECT AVG(orders) FROM state_performance)
         AND avg_order_value <= (SELECT AVG(avg_order_value) FROM state_performance)
            THEN 'High Volume + Low Value'

        WHEN orders <= (SELECT AVG(orders) FROM state_performance)
         AND avg_order_value > (SELECT AVG(avg_order_value) FROM state_performance)
            THEN 'Low Volume + High Value'

        ELSE 'Low Volume + Low Value'
    END AS state_segment

FROM state_performance
ORDER BY orders DESC;
