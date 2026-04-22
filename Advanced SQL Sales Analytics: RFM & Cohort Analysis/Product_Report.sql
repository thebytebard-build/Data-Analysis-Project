-- ============================================================
--       DATA WAREHOUSE ANALYTICS - PRODUCT REPORT VIEW
--       Author  : [Roshani Singh Rathore]
--       Purpose : Master product-level analytical view covering
--                 performance segmentation, KPIs, and trends
-- ============================================================

/*
  Highlights:
    1. Gathers essential fields: product name, category, subcategory, cost
    2. Segments products into THREE tiers by revenue:
         HIGH PERFORMER : total sales > $50,000
         MID PERFORMER  : total sales $10,000 - $50,000
         LOW PERFORMER  : total sales < $10,000
    3. Aggregates product-level metrics:
         - total orders
         - total sales
         - total quantity sold
         - total unique customers
         - lifespan (months between first and last sale)
    4. Calculates KPIs:
         - recency        : months since last sale
         - avg order revenue (AOR) : revenue per order
         - avg monthly revenue     : revenue spread across lifespan
    5. Adds YoY revenue comparison per product
*/

CREATE VIEW gold.report_products AS

WITH base_query AS (
    -- Transaction-level data joined to product dimension
    -- No TOP here - views must return all rows; filtering belongs at query time
    SELECT
        F.order_number,
        F.order_date,
        F.customer_key,
        F.sales_amount,
        F.quantity,
        P.product_key,
        P.product_name,
        P.category,
        P.subcategory,
        P.cost
    FROM gold.fact_sales AS F
    LEFT JOIN gold.dim_products AS P ON P.product_key = F.product_key
    WHERE F.order_date IS NOT NULL
),

product_aggregation AS (
    -- One row per product with all aggregated metrics
    -- NOTE: No TOP inside CTEs - it makes results non-deterministic and incorrect
    SELECT
        product_key,
        product_name,
        category,
        subcategory,
        cost,
        MIN(order_date)                                             AS first_sale_date,
        MAX(order_date)                                             AS last_sale_date,
        DATEDIFF(MONTH, MIN(order_date), MAX(order_date))           AS lifespan_months,
        COUNT(DISTINCT order_number)                                AS total_orders,
        COUNT(DISTINCT customer_key)                                AS total_customers,
        SUM(sales_amount)                                           AS total_sales,
        SUM(quantity)                                               AS total_quantity
    FROM base_query
    GROUP BY
        product_key,
        product_name,
        category,
        subcategory,
        cost
)

SELECT
    product_key,
    product_name,
    category,
    subcategory,
    cost,

    -- THREE-TIER performance segmentation (all tiers are reachable)
    -- Previously ELSE 'LOW PERFORMER' was dead code because WHEN <= 50000 caught everything
    CASE
        WHEN total_sales > 50000    THEN 'HIGH PERFORMER'
        WHEN total_sales >= 10000   THEN 'MID PERFORMER'
        ELSE                             'LOW PERFORMER'
    END AS product_performance,

    first_sale_date,
    last_sale_date,
    lifespan_months,

    -- Recency: months since this product last sold (lower = more recently active)
    DATEDIFF(MONTH, last_sale_date, GETDATE())                      AS recency_months,

    total_orders,
    total_customers,
    total_sales,
    total_quantity,

    -- Average revenue per order (safe divide - guards against zero orders)
    CASE
        WHEN total_orders = 0 THEN 0
        ELSE total_sales / total_orders
    END AS avg_order_revenue,

    -- Average monthly revenue across the product's active lifespan (safe divide)
    -- Fixed: was incorrectly dividing by total_orders instead of lifespan_months
    CASE
        WHEN lifespan_months = 0 THEN total_sales   -- only sold in a single month
        ELSE total_sales / lifespan_months
    END AS avg_monthly_revenue,

    -- Revenue per unit sold (profitability proxy when margin data unavailable)
    CASE
        WHEN total_quantity = 0 THEN 0
        ELSE ROUND(CAST(total_sales AS FLOAT) / total_quantity, 2)
    END AS avg_revenue_per_unit,

    -- Estimated margin proxy: (avg selling price - cost) / avg selling price
    -- Useful for spotting products sold below or near cost
    CASE
        WHEN total_quantity = 0 THEN NULL
        ELSE ROUND(
            (CAST(total_sales AS FLOAT) / total_quantity - cost)
            / NULLIF(CAST(total_sales AS FLOAT) / total_quantity, 0)
            * 100
        , 2)
    END AS estimated_margin_pct

FROM product_aggregation;


-- ========================= PRODUCT YoY PERFORMANCE =========================
-- Standalone query (not part of the view) for product year-over-year analysis
-- Shows each product's yearly revenue vs. prior year with % change

WITH yearly_product_sales AS (
    SELECT
        P.product_key,
        P.product_name,
        P.category,
        YEAR(F.order_date)          AS order_year,
        SUM(F.sales_amount)         AS total_sales
    FROM gold.fact_sales AS F
    LEFT JOIN gold.dim_products AS P ON P.product_key = F.product_key
    WHERE F.order_date IS NOT NULL
    GROUP BY P.product_key, P.product_name, P.category, YEAR(F.order_date)
)
SELECT
    product_key,
    product_name,
    category,
    order_year,
    total_sales,

    LAG(total_sales, 1) OVER (PARTITION BY product_key ORDER BY order_year)         AS prior_year_sales,

    total_sales
        - LAG(total_sales, 1, 0) OVER (PARTITION BY product_key ORDER BY order_year) AS yoy_change_abs,

    -- % change vs prior year (NULL for first year - no prior year exists)
    ROUND(
        (total_sales
            - LAG(total_sales, 1, NULL) OVER (PARTITION BY product_key ORDER BY order_year))
        * 100.0
        / NULLIF(
            LAG(total_sales, 1, NULL) OVER (PARTITION BY product_key ORDER BY order_year)
        , 0)
    , 2)                                                                             AS yoy_change_pct,

    CASE
        WHEN LAG(total_sales, 1) OVER (PARTITION BY product_key ORDER BY order_year) IS NULL
                                                            THEN 'FIRST YEAR'
        WHEN total_sales > LAG(total_sales, 1, 0) OVER (PARTITION BY product_key ORDER BY order_year)
                                                            THEN 'GROWING'
        WHEN total_sales < LAG(total_sales, 1, 0) OVER (PARTITION BY product_key ORDER BY order_year)
                                                            THEN 'DECLINING'
        ELSE                                                     'FLAT'
    END AS yoy_direction

FROM yearly_product_sales
ORDER BY product_name, order_year;
