-- ========================= COHORT ANALYSIS =========================
-- Group customers by their first purchase month (acquisition cohort)
-- Track total revenue contribution per cohort over time
-- Reveals retention quality and which acquisition periods performed best

WITH customer_first_order AS (
    SELECT
        customer_key,
        DATETRUNC(MONTH, MIN(order_date))   AS cohort_month
    FROM gold.fact_sales
    WHERE order_date IS NOT NULL
    GROUP BY customer_key
),
cohort_data AS (
    SELECT
        CFO.cohort_month,
        DATEDIFF(MONTH, CFO.cohort_month, DATETRUNC(MONTH, F.order_date)) AS months_since_acquisition,
        COUNT(DISTINCT F.customer_key)  AS active_customers,
        SUM(F.sales_amount)             AS cohort_revenue
    FROM gold.fact_sales AS F
    INNER JOIN customer_first_order AS CFO ON F.customer_key = CFO.customer_key
    WHERE F.order_date IS NOT NULL
    GROUP BY CFO.cohort_month, DATEDIFF(MONTH, CFO.cohort_month, DATETRUNC(MONTH, F.order_date))
)
SELECT
    cohort_month,
    months_since_acquisition,
    active_customers,
    cohort_revenue,
    -- Retention rate vs. cohort's month-0 size
    ROUND(
        CAST(active_customers AS FLOAT)
        / FIRST_VALUE(active_customers) OVER (PARTITION BY cohort_month ORDER BY months_since_acquisition)
        * 100
    , 2) AS retention_rate_pct
FROM cohort_data
ORDER BY cohort_month, months_since_acquisition;




-- ========================= PRODUCT AFFINITY (CROSS-SELL PAIRS) =========================
-- Which products are frequently purchased together in the same order?
-- A basic market basket analysis - useful for bundling & recommendation strategy

SELECT TOP 20
    A.product_name      AS product_a,
    B.product_name      AS product_b,
    COUNT(*)            AS times_bought_together
FROM gold.fact_sales AS F1
INNER JOIN gold.fact_sales AS F2
    ON  F1.order_number = F2.order_number
    AND F1.product_key  < F2.product_key        -- avoids self-pairs and duplicate pairs
LEFT JOIN gold.dim_products AS A ON A.product_key = F1.product_key
LEFT JOIN gold.dim_products AS B ON B.product_key = F2.product_key
GROUP BY A.product_name, B.product_name
ORDER BY times_bought_together DESC;


