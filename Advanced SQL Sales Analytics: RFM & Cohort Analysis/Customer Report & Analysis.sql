-- ============================================================
--       DATA WAREHOUSE ANALYTICS - TIME SERIES & SEGMENTATION
--       Author  : [Roshani Singh Rathore]
--       Purpose : Sales trends over time, product performance
--                 comparisons, customer segmentation, and
--                 final customer report view
-- ============================================================


-- ========================= SALES PERFORMANCE OVER TIME =========================

-- Monthly sales trend: revenue, unique customers, and items sold
-- Ordered correctly by year then calendar month (not alphabetical month name)
SELECT
    DATEPART(YEAR,  order_date)     AS year_name,
    DATENAME(MONTH, order_date)     AS month_name,
    SUM(sales_amount)               AS total_sales,
    COUNT(DISTINCT customer_key)    AS total_customers,
    SUM(quantity)                   AS total_items
FROM gold.fact_sales
WHERE order_date IS NOT NULL
GROUP BY
    DATEPART(YEAR,  order_date),
    DATENAME(MONTH, order_date),
    DATEPART(MONTH, order_date)
ORDER BY
    year_name,
    DATEPART(MONTH, order_date);


-- ========================= RUNNING TOTAL & MOVING AVERAGE =========================

-- Cumulative (running) total sales and 3-month moving average over time
-- Useful to spot growth trends and seasonal smoothing
SELECT
    [date],
    total_sales,
    SUM(total_sales)  OVER (ORDER BY [date] ROWS UNBOUNDED PRECEDING)   AS running_total_sales,
    AVG(total_sales)  OVER (ORDER BY [date] ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS moving_avg_3m
FROM (
    SELECT
        DATETRUNC(MONTH, order_date)    AS [date],
        SUM(sales_amount)               AS total_sales
    FROM gold.fact_sales
    WHERE order_date IS NOT NULL
    GROUP BY DATETRUNC(MONTH, order_date)
) monthly
ORDER BY [date];


-- ========================= YEAR-OVER-YEAR PRODUCT PERFORMANCE =========================

-- For each product and year:
--   - Compare sales to that product's all-time average (above/below avg)
--   - Compare sales to prior year (YoY absolute change + % change + direction)
WITH yearly_sales AS (
    SELECT
        YEAR(FS.order_date)     AS order_year,
        P.product_name,
        SUM(FS.sales_amount)    AS total_sales
    FROM gold.fact_sales AS FS
    LEFT JOIN gold.dim_products AS P ON P.product_key = FS.product_key
    WHERE FS.order_date IS NOT NULL
    GROUP BY YEAR(FS.order_date), P.product_name
)
SELECT
    product_name,
    order_year,
    total_sales,

    -- vs. product's own historical average
    AVG(total_sales) OVER (PARTITION BY product_name)                                               AS avg_sales,
    total_sales - AVG(total_sales) OVER (PARTITION BY product_name)                                 AS diff_vs_avg,
    CASE
        WHEN total_sales > AVG(total_sales) OVER (PARTITION BY product_name) THEN 'ABOVE AVG'
        WHEN total_sales < AVG(total_sales) OVER (PARTITION BY product_name) THEN 'BELOW AVG'
        ELSE 'AT AVG'
    END AS avg_performance_flag,

    -- vs. prior year
    LAG(total_sales, 1, 0) OVER (PARTITION BY product_name ORDER BY order_year)                     AS prior_year_sales,
    total_sales - LAG(total_sales, 1, 0) OVER (PARTITION BY product_name ORDER BY order_year)       AS yoy_change_abs,

    -- YoY % change (NULLIF prevents divide-by-zero on first year where PY = 0)
    ROUND(
        (total_sales - LAG(total_sales, 1, NULL) OVER (PARTITION BY product_name ORDER BY order_year))
        * 100.0
        / NULLIF(LAG(total_sales, 1, NULL) OVER (PARTITION BY product_name ORDER BY order_year), 0)
    , 2)                                                                                             AS yoy_change_pct,

    CASE
        WHEN total_sales > LAG(total_sales, 1, 0) OVER (PARTITION BY product_name ORDER BY order_year) THEN 'INCREASING'
        WHEN total_sales < LAG(total_sales, 1, 0) OVER (PARTITION BY product_name ORDER BY order_year) THEN 'DECREASING'
        ELSE 'NO CHANGE'
    END AS yoy_direction
FROM yearly_sales
ORDER BY product_name, order_year;


-- ========================= CATEGORY CONTRIBUTION TO TOTAL SALES =========================

-- What % of total revenue does each category contribute?
-- Using window function instead of correlated subquery - cleaner & faster
WITH category_sales AS (
    SELECT
        P.category,
        SUM(F.sales_amount) AS cat_sales
    FROM gold.fact_sales AS F
    LEFT JOIN gold.dim_products AS P ON P.product_key = F.product_key
    GROUP BY P.category
)
SELECT
    category,
    cat_sales,
    ROUND(
        CAST(cat_sales AS FLOAT) / SUM(cat_sales) OVER () * 100
    , 2)                            AS pct_of_total,
    CONCAT(
        ROUND(CAST(cat_sales AS FLOAT) / SUM(cat_sales) OVER () * 100, 2),
        '%'
    )                               AS pct_of_total_formatted
FROM category_sales
ORDER BY cat_sales DESC;


-- ========================= PRODUCT COST SEGMENTATION =========================

-- How many products fall into each price/cost tier?
SELECT
    cost_range,
    COUNT(product_id) AS total_products
FROM (
    SELECT
        product_id,
        product_name,
        CASE
            WHEN cost < 100              THEN 'BELOW $100'
            WHEN cost BETWEEN 100 AND 499 THEN '$100 - $499'
            WHEN cost BETWEEN 500 AND 999 THEN '$500 - $999'
            ELSE                              'ABOVE $1000'
        END AS cost_range
    FROM gold.dim_products
) segmented
GROUP BY cost_range
ORDER BY total_products DESC;


-- ========================= CUSTOMER SEGMENTATION =========================

-- Segment customers based on spending behaviour and tenure:
--   VIP      : 12+ months history AND total spend > $5,000
--   REGULAR  : 12+ months history AND total spend <= $5,000
--   NEW      : Less than 12 months of history (regardless of spend)
-- Then count customers per segment

WITH customer_summary AS (
    SELECT
        customer_key,
        MIN(order_date)                                             AS first_order,
        MAX(order_date)                                             AS last_order,
        SUM(sales_amount)                                           AS total_spend,
        DATEDIFF(MONTH, MIN(order_date), MAX(order_date))           AS lifespan_months
    FROM gold.fact_sales
    GROUP BY customer_key
),
customer_segments AS (
    SELECT
        customer_key,
        total_spend,
        lifespan_months,
        CASE
            WHEN lifespan_months >= 12 AND total_spend > 5000   THEN 'VIP'
            WHEN lifespan_months >= 12 AND total_spend <= 5000  THEN 'REGULAR'
            ELSE                                                     'NEW'
        END AS customer_segment
    FROM customer_summary
)
SELECT
    customer_segment,
    COUNT(customer_key)     AS total_customers,
    ROUND(AVG(total_spend), 2)  AS avg_spend_per_customer,
    ROUND(AVG(lifespan_months), 1) AS avg_tenure_months
FROM customer_segments
GROUP BY customer_segment
ORDER BY total_customers DESC;


-- ========================= RFM SCORING =========================
-- Recency-Frequency-Monetary scoring: ranks each customer 1-4 on each dimension
-- High score = more valuable customer. Used for targeting & retention strategy.

WITH rfm_base AS (
    SELECT
        customer_key,
        DATEDIFF(MONTH, MAX(order_date), GETDATE())     AS recency_months,   -- lower = better
        COUNT(DISTINCT order_number)                    AS frequency,         -- higher = better
        SUM(sales_amount)                               AS monetary           -- higher = better
    FROM gold.fact_sales
    WHERE order_date IS NOT NULL
    GROUP BY customer_key
),
rfm_scored AS (
    SELECT
        customer_key,
        recency_months,
        frequency,
        monetary,
        -- Recency: lower recency months = better = higher score
        NTILE(4) OVER (ORDER BY recency_months DESC)    AS r_score,
        NTILE(4) OVER (ORDER BY frequency ASC)          AS f_score,
        NTILE(4) OVER (ORDER BY monetary ASC)           AS m_score
    FROM rfm_base
)
SELECT
    customer_key,
    recency_months,
    frequency,
    monetary,
    r_score,
    f_score,
    m_score,
    r_score + f_score + m_score                         AS rfm_total_score,
    CASE
        WHEN r_score + f_score + m_score >= 10 THEN 'CHAMPION'
        WHEN r_score + f_score + m_score >= 7  THEN 'LOYAL'
        WHEN r_score + f_score + m_score >= 5  THEN 'AT RISK'
        ELSE                                        'LOST'
    END                                                 AS rfm_segment
FROM rfm_scored
ORDER BY rfm_total_score DESC;



-- ========================= CUSTOMER REPORT VIEW =========================
/*
  Purpose  : Master customer-level analytical view
  Highlights:
    1. Retrieves core fields: names, age, transaction details
    2. Segments customers by spending behaviour (VIP / Regular / New)
       and by age group (properly gapless ranges)
    3. Aggregates customer-level metrics:
       - total orders, sales, quantity, distinct products, lifespan
    4. Calculates KPIs:
       - recency (months since last order)
       - average order value (AOV)
       - average monthly spend
*/

CREATE VIEW gold.report_customers AS

WITH base_query AS (
    -- Pull all transaction-level data joined to customer dimension
    SELECT
        F.order_number,
        F.product_key,
        F.order_date,
        F.quantity,
        F.sales_amount,
        C.customer_key,
        C.customer_number,
        CONCAT(C.first_name, ' ', C.last_name)          AS customer_name,
        DATEDIFF(YEAR, C.birthdate, GETDATE())           AS age
    FROM gold.fact_sales AS F
    LEFT JOIN gold.dim_customers AS C ON F.customer_key = C.customer_key
    WHERE F.order_date IS NOT NULL
),

customer_aggregation AS (
    -- Roll up to one row per customer with all key metrics
    SELECT
        customer_key,
        customer_number,
        customer_name,
        age,
        COUNT(DISTINCT order_number)        AS total_orders,
        SUM(sales_amount)                   AS total_sales,
        SUM(quantity)                       AS total_quantity,
        COUNT(DISTINCT product_key)         AS total_products,
        MAX(order_date)                     AS last_order_date,
        MIN(order_date)                     AS first_order_date,
        DATEDIFF(MONTH, MIN(order_date), MAX(order_date)) AS lifespan_months
    FROM base_query
    GROUP BY customer_key, customer_number, customer_name, age
)

SELECT
    customer_key,
    customer_number,
    customer_name,
    age,

    -- Gapless age groups (every integer age is covered exactly once)
    CASE
        WHEN age < 20                   THEN 'UNDER 20'
        WHEN age BETWEEN 20 AND 29      THEN '20-29'
        WHEN age BETWEEN 30 AND 39      THEN '30-39'
        WHEN age BETWEEN 40 AND 49      THEN '40-49'
        ELSE                                 '50+'
    END AS age_group,

    -- Customer value segment
    CASE
        WHEN lifespan_months >= 12 AND total_sales > 5000   THEN 'VIP'
        WHEN lifespan_months >= 12 AND total_sales <= 5000  THEN 'REGULAR'
        ELSE                                                     'NEW'
    END AS customer_segment,

    total_orders,
    total_sales,
    total_quantity,
    total_products,
    first_order_date,
    last_order_date,
    lifespan_months,

    -- Recency: months since last purchase (lower = more recently active)
    DATEDIFF(MONTH, last_order_date, GETDATE())             AS recency_months,

    -- Average order value: revenue per order (safe divide)
    CASE
        WHEN total_orders = 0 THEN 0
        ELSE total_sales / total_orders
    END AS avg_order_value,

    -- Average monthly spend: revenue spread across active tenure (safe divide)
    CASE
        WHEN lifespan_months = 0 THEN total_sales   -- single-month customer: all spend in month 0
        ELSE total_sales / lifespan_months
    END AS avg_monthly_spend

FROM customer_aggregation;
