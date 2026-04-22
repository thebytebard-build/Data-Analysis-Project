-- ============================================================
--          DATA WAREHOUSE ANALYTICS - EXPLORATORY DATA ANALYSIS
--          Author  : [Roshani Singh Rathore]
--          Purpose : Structured EDA covering schema, dimensions,
--                    dates, key measures, magnitude & rankings
-- ============================================================


-- ========================= DATABASE EXPLORATION =========================

-- Explore all objects (tables/views) in the database
SELECT *
FROM INFORMATION_SCHEMA.TABLES;

-- Explore all columns across the entire database
SELECT *
FROM INFORMATION_SCHEMA.COLUMNS;

-- Explore columns of a specific table
SELECT *
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'dim_customers';


-- ========================= DATA QUALITY CHECKS =========================
-- Always validate data before analysis - catches nulls, dupes & bad values

-- Check for NULL order dates (critical field)
SELECT COUNT(*) AS null_order_dates
FROM gold.fact_sales
WHERE order_date IS NULL;

-- Check for duplicate order numbers (should be unique)
SELECT order_number, COUNT(*) AS occurrences
FROM gold.fact_sales
GROUP BY order_number
HAVING COUNT(*) > 1;

-- Check for negative or zero sales amounts (bad transactions)
SELECT COUNT(*) AS bad_sales_records
FROM gold.fact_sales
WHERE sales_amount <= 0 OR quantity <= 0;

-- Check for customers with no matching sales records (orphan dimension records)
SELECT COUNT(*) AS customers_with_no_orders
FROM gold.dim_customers C
WHERE NOT EXISTS (
    SELECT 1 FROM gold.fact_sales F WHERE F.customer_key = C.customer_key
);

-- Check for sales records with no matching product (broken FK)
SELECT COUNT(*) AS sales_with_no_product
FROM gold.fact_sales F
WHERE NOT EXISTS (
    SELECT 1 FROM gold.dim_products P WHERE P.product_key = F.product_key
);


-- ========================= DIMENSION EXPLORATION =========================

-- Unique countries from which customers originate
SELECT DISTINCT country
FROM gold.dim_customers
ORDER BY country;

-- Unique categories, subcategories, and products (full product hierarchy)
SELECT DISTINCT
    category,
    subcategory,
    product_name
FROM gold.dim_products
ORDER BY 1, 2, 3;


-- ========================= DATE EXPLORATION =========================

-- First & last order date and total data coverage span
SELECT
    MIN(order_date)                                             AS oldest_order_date,
    MAX(order_date)                                             AS latest_order_date,
    DATEDIFF(YEAR,  MIN(order_date), MAX(order_date))           AS year_duration,
    DATEDIFF(MONTH, MIN(order_date), MAX(order_date))           AS month_duration
FROM gold.fact_sales;

-- Youngest and oldest customer by birthdate
SELECT
    MAX(birthdate)                                  AS youngest_birthdate,
    DATEDIFF(YEAR, MAX(birthdate), GETDATE())        AS youngest_age,
    MIN(birthdate)                                  AS oldest_birthdate,
    DATEDIFF(YEAR, MIN(birthdate), GETDATE())        AS oldest_age
FROM gold.dim_customers;


-- ========================= MEASURE EXPLORATION =========================

-- All key business metrics in a single summary report
SELECT 'Total Sales'       AS measure_name, SUM(sales_amount)               AS measure_value FROM gold.fact_sales
UNION ALL
SELECT 'Total Quantity',                    SUM(quantity)                                    FROM gold.fact_sales
UNION ALL
SELECT 'Average Order Value',               AVG(sales_amount)                                FROM gold.fact_sales
UNION ALL
SELECT 'Average Unit Price',                AVG(price)                                       FROM gold.fact_sales
UNION ALL
SELECT 'Total Orders',                      COUNT(DISTINCT order_number)                     FROM gold.fact_sales
UNION ALL
SELECT 'Total Products (Dim)',              COUNT(DISTINCT product_key)                      FROM gold.dim_products
UNION ALL
SELECT 'Total Products (Sold)',             COUNT(DISTINCT product_key)                      FROM gold.fact_sales
UNION ALL
SELECT 'Total Customers (Dim)',             COUNT(DISTINCT customer_key)                     FROM gold.dim_customers
UNION ALL
SELECT 'Total Customers (Ordered)',         COUNT(DISTINCT customer_key)                     FROM gold.fact_sales;

-- NOTE: "Total Customers (Dim)" vs "Total Customers (Ordered)" gap = customers who never ordered


-- ========================= MAGNITUDE ANALYSIS =========================

-- Customers by country
SELECT
    country,
    COUNT(customer_key) AS total_customers
FROM gold.dim_customers
GROUP BY country
ORDER BY total_customers DESC;

-- Customers by gender
SELECT
    gender,
    COUNT(customer_key) AS total_customers
FROM gold.dim_customers
GROUP BY gender
ORDER BY total_customers DESC;

-- Products by category
SELECT
    category,
    COUNT(product_key) AS total_products
FROM gold.dim_products
GROUP BY category
ORDER BY total_products DESC;

-- Average cost per category
SELECT
    category,
    AVG(cost) AS avg_cost
FROM gold.dim_products
GROUP BY category
ORDER BY avg_cost DESC;

-- Total revenue by category (with % contribution)
WITH category_sales AS (
    SELECT
        P.category,
        SUM(F.sales_amount) AS cat_revenue
    FROM gold.fact_sales AS F
    LEFT JOIN gold.dim_products AS P ON P.product_key = F.product_key
    GROUP BY P.category
)
SELECT
    category,
    cat_revenue,
    ROUND(
        CAST(cat_revenue AS FLOAT) / SUM(cat_revenue) OVER () * 100
    , 2)                        AS pct_of_total_revenue
FROM category_sales
ORDER BY cat_revenue DESC;

-- Total revenue per customer (quick magnitude view)
SELECT
    C.customer_id,
    CONCAT(C.first_name, ' ', C.last_name)  AS customer_name,
    SUM(F.sales_amount)                      AS total_revenue
FROM gold.fact_sales AS F
LEFT JOIN gold.dim_customers AS C ON C.customer_key = F.customer_key
GROUP BY C.customer_id, C.first_name, C.last_name
ORDER BY total_revenue DESC;

-- Quantity sold by country (demand distribution)
SELECT
    C.country,
    SUM(F.quantity) AS total_items_sold
FROM gold.fact_sales AS F
LEFT JOIN gold.dim_customers AS C ON C.customer_key = F.customer_key
GROUP BY C.country
ORDER BY total_items_sold DESC;


-- ========================= RANKING ANALYSIS =========================

-- Top 5 products by revenue (flexible window function approach)
SELECT *
FROM (
    SELECT
        P.product_name,
        SUM(F.sales_amount)                                         AS total_revenue,
        DENSE_RANK() OVER (ORDER BY SUM(F.sales_amount) DESC)       AS product_rank
    FROM gold.fact_sales AS F
    LEFT JOIN gold.dim_products AS P ON F.product_key = P.product_key
    GROUP BY P.product_name
) ranked
WHERE product_rank <= 5;

-- Bottom 5 products by revenue (worst performers)
SELECT *
FROM (
    SELECT
        P.product_name,
        SUM(F.sales_amount)                                         AS total_revenue,
        DENSE_RANK() OVER (ORDER BY SUM(F.sales_amount) ASC)        AS product_rank
    FROM gold.fact_sales AS F
    LEFT JOIN gold.dim_products AS P ON F.product_key = P.product_key
    GROUP BY P.product_name
) ranked
WHERE product_rank <= 5;

-- Top 10 customers by revenue
SELECT *
FROM (
    SELECT
        C.customer_id,
        CONCAT(C.first_name, ' ', C.last_name)                      AS customer_name,
        SUM(F.sales_amount)                                          AS total_revenue,
        DENSE_RANK() OVER (ORDER BY SUM(F.sales_amount) DESC)        AS customer_rank
    FROM gold.fact_sales AS F
    LEFT JOIN gold.dim_customers AS C ON F.customer_key = C.customer_key
    GROUP BY C.customer_id, C.first_name, C.last_name
) ranked
WHERE customer_rank <= 10;

-- Bottom 3 customers by number of orders placed
-- NOTE: Using window function for consistency & to handle ties correctly
SELECT *
FROM (
    SELECT
        C.customer_id,
        CONCAT(C.first_name, ' ', C.last_name)                      AS customer_name,
        COUNT(DISTINCT F.order_number)                               AS total_orders,
        DENSE_RANK() OVER (ORDER BY COUNT(DISTINCT F.order_number) ASC) AS order_rank
    FROM gold.fact_sales AS F
    LEFT JOIN gold.dim_customers AS C ON C.customer_key = F.customer_key
    GROUP BY C.customer_id, C.first_name, C.last_name
) ranked
WHERE order_rank <= 3;
