-- =====================================================
-- E-Commerce Analytics: PostgreSQL setup
-- Pehle database banao:  CREATE DATABASE ecom_analytics;
-- Phir usi database mein ye script blocks mein chalao.
-- =====================================================

-- ---------- STEP 1: staging tables (CSV yahan import hogi) ----------
DROP TABLE IF EXISTS stg_sales, stg_rfm CASCADE;

CREATE TABLE stg_sales (
    invoice_no   INT,
    stock_code   VARCHAR(20),
    description  TEXT,
    quantity     INT,
    invoice_date TIMESTAMP,
    unit_price   NUMERIC(10,2),
    customer_id  INT,
    country      VARCHAR(60),
    revenue      NUMERIC(12,2)
);

CREATE TABLE stg_rfm (
    customer_id INT,
    recency     INT,
    frequency   INT,
    monetary    NUMERIC(12,2),
    r           INT,
    f           INT,
    m           INT,
    segment     VARCHAR(30)
);

-- ---------- STEP 2: CSV import (pgAdmin GUI se, neeche guide dekho) ----------
-- Ya psql mein (apna path daalo):
-- \copy stg_sales FROM 'C:/data/clean_retail.csv' CSV HEADER
-- \copy stg_rfm   FROM 'C:/data/rfm_segments.csv' CSV HEADER

-- Import check (779425 aur 5878 aane chahiye):
-- SELECT COUNT(*) FROM stg_sales;
-- SELECT COUNT(*) FROM stg_rfm;

-- ---------- STEP 3: final tables (star schema) ----------
DROP TABLE IF EXISTS fact_sales, dim_customer, dim_product, dim_date CASCADE;

CREATE TABLE dim_customer AS
SELECT r.customer_id,
       r.recency   AS recency_days,
       r.frequency,
       r.monetary,
       r.r AS r_score, r.f AS f_score, r.m AS m_score,
       r.segment,
       c.country
FROM stg_rfm r
JOIN (SELECT customer_id,
             MODE() WITHIN GROUP (ORDER BY country) AS country
      FROM stg_sales GROUP BY customer_id) c
  ON r.customer_id = c.customer_id;
ALTER TABLE dim_customer ADD PRIMARY KEY (customer_id);

CREATE TABLE dim_product AS
SELECT stock_code,
       MODE() WITHIN GROUP (ORDER BY description) AS description
FROM stg_sales GROUP BY stock_code;
ALTER TABLE dim_product ADD PRIMARY KEY (stock_code);

CREATE TABLE dim_date AS
SELECT d::date                        AS date,
       TO_CHAR(d,'YYYYMMDD')::INT     AS date_key,
       EXTRACT(YEAR    FROM d)::INT   AS year,
       EXTRACT(QUARTER FROM d)::INT   AS quarter,
       EXTRACT(MONTH   FROM d)::INT   AS month,
       TO_CHAR(d,'Mon')               AS month_name,
       TO_CHAR(d,'YYYY-MM')           AS year_month,
       TO_CHAR(d,'Day')               AS day_name
FROM generate_series(
        (SELECT MIN(invoice_date)::date FROM stg_sales),
        (SELECT MAX(invoice_date)::date FROM stg_sales),
        interval '1 day') AS d;
ALTER TABLE dim_date ADD PRIMARY KEY (date_key);

CREATE TABLE fact_sales AS
SELECT invoice_no,
       TO_CHAR(invoice_date,'YYYYMMDD')::INT AS date_key,
       invoice_date AS order_time,
       customer_id, stock_code, quantity, unit_price, revenue, country
FROM stg_sales;
CREATE INDEX idx_fact_cust ON fact_sales(customer_id);
CREATE INDEX idx_fact_prod ON fact_sales(stock_code);
CREATE INDEX idx_fact_date ON fact_sales(date_key);

-- ---------- STEP 4: views (Power BI dashboards ke liye) ----------
-- Dashboard 1: Sales Overview
CREATE OR REPLACE VIEW vw_monthly_sales AS
SELECT d.year_month, d.year, d.month,
       ROUND(SUM(f.revenue),0) AS revenue,
       COUNT(DISTINCT f.invoice_no) AS orders,
       COUNT(DISTINCT f.customer_id) AS customers,
       ROUND(SUM(f.revenue)/COUNT(DISTINCT f.invoice_no),2) AS aov
FROM fact_sales f JOIN dim_date d ON f.date_key = d.date_key
GROUP BY d.year_month, d.year, d.month;

CREATE OR REPLACE VIEW vw_country_sales AS
SELECT country,
       ROUND(SUM(revenue),0) AS revenue,
       COUNT(DISTINCT invoice_no) AS orders,
       COUNT(DISTINCT customer_id) AS customers
FROM fact_sales GROUP BY country;

-- Dashboard 2: Customer Segments (RFM)
CREATE OR REPLACE VIEW vw_segment_summary AS
SELECT segment,
       COUNT(*) AS customers,
       ROUND(SUM(monetary),0) AS revenue,
       ROUND(AVG(monetary),0) AS avg_revenue_per_customer,
       ROUND(AVG(recency_days),0) AS avg_recency,
       ROUND(AVG(frequency),1) AS avg_frequency,
       ROUND(100.0*COUNT(*)/SUM(COUNT(*)) OVER (),1) AS customer_pct,
       ROUND(100.0*SUM(monetary)/SUM(SUM(monetary)) OVER (),1) AS revenue_pct
FROM dim_customer GROUP BY segment;

-- Dashboard 3: Product Performance
-- Note: 'Manual' aur 'PAPER CRAFT , LITTLE BIRDIE' real products nahi hain, filter kiye hain
CREATE OR REPLACE VIEW vw_product_sales AS
SELECT p.stock_code, p.description,
       SUM(f.quantity) AS units,
       ROUND(SUM(f.revenue),0) AS revenue,
       COUNT(DISTINCT f.invoice_no) AS orders,
       ROUND(100.0*SUM(f.revenue)/SUM(SUM(f.revenue)) OVER (),2) AS revenue_pct
FROM fact_sales f JOIN dim_product p ON f.stock_code = p.stock_code
WHERE p.description NOT IN ('Manual','PAPER CRAFT , LITTLE BIRDIE')
GROUP BY p.stock_code, p.description;

-- ---------- STEP 5: verify ----------
-- SELECT COUNT(*) FROM fact_sales;                 -- 779425
-- SELECT SUM(revenue) FROM fact_sales;             -- ~17374804
-- SELECT * FROM vw_segment_summary ORDER BY revenue DESC;
