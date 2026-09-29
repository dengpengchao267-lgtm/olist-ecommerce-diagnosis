-- ============================================================================
-- 00_ods_建表与导入.sql
-- 作用：创建数据仓库 olist_dw + ods 层 9 张原始表，批量导入 Kaggle 原始 CSV，并建索引
-- 要求：MySQL 8.0+，服务端已 SET GLOBAL local_infile = 1
-- 原则：ods 层不做任何加工，所有字段一律 VARCHAR，类型转换全部留到 dwd 层
-- 注意：本脚本会 DROP DATABASE olist_dw 后重建，已有数据请先备份
-- ============================================================================

SET NAMES utf8mb4;
SET SESSION sql_mode = 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION';

DROP DATABASE IF EXISTS olist_dw;

-- 【排序规则必须统一】库和表都用 utf8mb4_0900_ai_ci（MySQL 8.0 的 utf8mb4 字符集默认值）
-- 坑点：建表时写 `DEFAULT CHARSET=utf8mb4` 而不写 COLLATE，用的是【字符集的默认排序规则】
--       （8.0 里 = utf8mb4_0900_ai_ci），不是【数据库的默认排序规则】。
--       所以如果这里只写 general_ci，就会出现「库是 general_ci、表却是 0900_ai_ci」的不一致；
--       以后新建的表若沿用库默认，与现有表 JOIN 时会直接报 Illegal mix of collations。
CREATE DATABASE olist_dw DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE olist_dw;

-- 如果库已经建好了，不用重导数据，执行这一行即可对齐（现有表本来就是 0900_ai_ci）：
-- ALTER DATABASE olist_dw CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;

-- ============================================================================
-- 一、ods 层建表（9 张）
-- ============================================================================

-- 1. 订单主表（99,441 行 × 8 列）
DROP TABLE IF EXISTS ods_orders;
CREATE TABLE ods_orders (
  order_id                       VARCHAR(50)  COMMENT '订单ID',
  customer_id                    VARCHAR(50)  COMMENT '订单级客户ID（每单新建，注意不是客户主键）',
  order_status                   VARCHAR(20)  COMMENT '订单状态，共8种',
  order_purchase_timestamp       VARCHAR(30)  COMMENT '下单时间',
  order_approved_at              VARCHAR(30)  COMMENT '支付审批时间',
  order_delivered_carrier_date   VARCHAR(30)  COMMENT '交付承运商时间',
  order_delivered_customer_date  VARCHAR(30)  COMMENT '客户签收时间',
  order_estimated_delivery_date  VARCHAR(30)  COMMENT '承诺送达时间'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ods:订单主表(原始)';

-- 2. 订单商品明细（112,650 行 × 7 列）
DROP TABLE IF EXISTS ods_order_items;
CREATE TABLE ods_order_items (
  order_id           VARCHAR(50) COMMENT '订单ID',
  order_item_id      VARCHAR(10) COMMENT '订单内商品序号',
  product_id         VARCHAR(50) COMMENT '商品ID',
  seller_id          VARCHAR(50) COMMENT '卖家ID',
  shipping_limit_date VARCHAR(30) COMMENT '卖家发货截止时间',
  price              VARCHAR(20) COMMENT '商品单价',
  freight_value      VARCHAR(20) COMMENT '运费分摊'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ods:订单商品明细(原始)';

-- 3. 支付记录（103,886 行 × 5 列）
DROP TABLE IF EXISTS ods_order_payments;
CREATE TABLE ods_order_payments (
  order_id             VARCHAR(50) COMMENT '订单ID',
  payment_sequential   VARCHAR(10) COMMENT '同一订单的支付序号',
  payment_type         VARCHAR(30) COMMENT '支付方式',
  payment_installments VARCHAR(10) COMMENT '分期期数',
  payment_value        VARCHAR(20) COMMENT '支付金额'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ods:支付记录(原始)';

-- 4. 订单评价（99,224 行 × 7 列）注意：一个订单可能有多条评价
DROP TABLE IF EXISTS ods_order_reviews;
CREATE TABLE ods_order_reviews (
  review_id               VARCHAR(50) COMMENT '评价ID（不唯一，勿做唯一键）',
  order_id                VARCHAR(50) COMMENT '订单ID',
  review_score            VARCHAR(5)  COMMENT '评分 1-5',
  review_comment_title    VARCHAR(255) COMMENT '评价标题',
  review_comment_message  TEXT        COMMENT '评价内容（葡萄牙语）',
  review_creation_date    VARCHAR(30) COMMENT '满意度问卷发出时间',
  review_answer_timestamp VARCHAR(30) COMMENT '问卷回答时间'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ods:订单评价(原始)';

-- 5. 客户表（99,441 行 × 5 列）
DROP TABLE IF EXISTS ods_customers;
CREATE TABLE ods_customers (
  customer_id            VARCHAR(50) COMMENT '订单级客户ID',
  customer_unique_id     VARCHAR(50) COMMENT '真实客户主键（用户级分析必须用这个）',
  customer_zip_code_prefix VARCHAR(10) COMMENT '邮编前5位（导入后会丢前导0）',
  customer_city          VARCHAR(100) COMMENT '客户城市',
  customer_state         VARCHAR(10) COMMENT '客户州（2位缩写）'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ods:客户(原始)';

-- 6. 商品表（32,951 行 × 9 列）注意：列名 lenght 是源数据的拼写错误，保持原样
DROP TABLE IF EXISTS ods_products;
CREATE TABLE ods_products (
  product_id                 VARCHAR(50)  COMMENT '商品ID',
  product_category_name      VARCHAR(100) COMMENT '品类名（葡萄牙语）',
  product_name_lenght        VARCHAR(10)  COMMENT '商品名字符数',
  product_description_lenght VARCHAR(10)  COMMENT '商品描述字符数',
  product_photos_qty         VARCHAR(10)  COMMENT '商品图片数',
  product_weight_g           VARCHAR(20)  COMMENT '重量(g)',
  product_length_cm          VARCHAR(20)  COMMENT '长(cm)',
  product_height_cm          VARCHAR(20)  COMMENT '高(cm)',
  product_width_cm           VARCHAR(20)  COMMENT '宽(cm)'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ods:商品(原始)';

-- 7. 卖家表（3,095 行 × 4 列）
DROP TABLE IF EXISTS ods_sellers;
CREATE TABLE ods_sellers (
  seller_id              VARCHAR(50)  COMMENT '卖家ID',
  seller_zip_code_prefix VARCHAR(10)  COMMENT '邮编前5位',
  seller_city            VARCHAR(100) COMMENT '卖家城市',
  seller_state           VARCHAR(10)  COMMENT '卖家州'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ods:卖家(原始)';

-- 8. 地理坐标（1,000,163 行 × 5 列）注意：一个邮编对应多个坐标点
DROP TABLE IF EXISTS ods_geolocation;
CREATE TABLE ods_geolocation (
  geolocation_zip_code_prefix VARCHAR(10) COMMENT '邮编前5位',
  geolocation_lat             VARCHAR(30) COMMENT '纬度',
  geolocation_lng             VARCHAR(30) COMMENT '经度',
  geolocation_city            VARCHAR(100) COMMENT '城市',
  geolocation_state           VARCHAR(10) COMMENT '州'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ods:地理坐标(原始)';

-- 9. 品类翻译字典（71 行 × 2 列）
DROP TABLE IF EXISTS ods_product_category_name_translation;
CREATE TABLE ods_product_category_name_translation (
  product_category_name         VARCHAR(100) COMMENT '品类名（葡萄牙语）',
  product_category_name_english VARCHAR(100) COMMENT '品类名（英语）'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ods:品类翻译字典';

-- ============================================================================
-- 二、导入 CSV
-- 把 'D:/olist_data/ 换成你自己的目录，必须用正斜杠
-- 三个关键参数说明：
--   OPTIONALLY ENCLOSED BY '"' + ESCAPED BY '"'  → 正确处理带逗号/换行的引号字段
--   IGNORE 1 LINES                               → 跳过表头
--   SET 最后一列 = TRIM(TRAILING '\r' ...)        → 若 CSV 是 CRLF，行尾的 \r 只会落在最后一列
-- ============================================================================

-- 1. orders（99,441 行）
LOAD DATA LOCAL INFILE 'D:/olist_data/olist_orders_dataset.csv'
INTO TABLE ods_orders
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(order_id, customer_id, order_status, order_purchase_timestamp, order_approved_at,
 order_delivered_carrier_date, order_delivered_customer_date, order_estimated_delivery_date)
SET order_estimated_delivery_date = TRIM(TRAILING '\r' FROM order_estimated_delivery_date);

-- 2. order_items（112,650 行）
LOAD DATA LOCAL INFILE 'D:/olist_data/olist_order_items_dataset.csv'
INTO TABLE ods_order_items
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(order_id, order_item_id, product_id, seller_id, shipping_limit_date, price, freight_value)
SET freight_value = TRIM(TRAILING '\r' FROM freight_value);

-- 3. order_payments（103,886 行）
LOAD DATA LOCAL INFILE 'D:/olist_data/olist_order_payments_dataset.csv'
INTO TABLE ods_order_payments
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(order_id, payment_sequential, payment_type, payment_installments, payment_value)
SET payment_value = TRIM(TRAILING '\r' FROM payment_value);

-- 4. order_reviews（99,224 行）
LOAD DATA LOCAL INFILE 'D:/olist_data/olist_order_reviews_dataset.csv'
INTO TABLE ods_order_reviews
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(review_id, order_id, review_score, review_comment_title, review_comment_message,
 review_creation_date, review_answer_timestamp)
SET review_answer_timestamp = TRIM(TRAILING '\r' FROM review_answer_timestamp);

-- 5. customers（99,441 行）
LOAD DATA LOCAL INFILE 'D:/olist_data/olist_customers_dataset.csv'
INTO TABLE ods_customers
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(customer_id, customer_unique_id, customer_zip_code_prefix, customer_city, customer_state)
SET customer_state = TRIM(TRAILING '\r' FROM customer_state);

-- 6. products（32,951 行）
LOAD DATA LOCAL INFILE 'D:/olist_data/olist_products_dataset.csv'
INTO TABLE ods_products
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(product_id, product_category_name, product_name_lenght, product_description_lenght,
 product_photos_qty, product_weight_g, product_length_cm, product_height_cm, product_width_cm)
SET product_width_cm = TRIM(TRAILING '\r' FROM product_width_cm);

-- 7. sellers（3,095 行）
LOAD DATA LOCAL INFILE 'D:/olist_data/olist_sellers_dataset.csv'
INTO TABLE ods_sellers
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(seller_id, seller_zip_code_prefix, seller_city, seller_state)
SET seller_state = TRIM(TRAILING '\r' FROM seller_state);

-- 8. geolocation（1,000,163 行，最慢的一张，耐心等）
LOAD DATA LOCAL INFILE 'D:/olist_data/olist_geolocation_dataset.csv'
INTO TABLE ods_geolocation
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(geolocation_zip_code_prefix, geolocation_lat, geolocation_lng, geolocation_city, geolocation_state)
SET geolocation_state = TRIM(TRAILING '\r' FROM geolocation_state);

-- 9. product_category_name_translation（71 行）
LOAD DATA LOCAL INFILE 'D:/olist_data/product_category_name_translation.csv'
INTO TABLE ods_product_category_name_translation
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(product_category_name, product_category_name_english)
SET product_category_name_english = TRIM(TRAILING '\r' FROM product_category_name_english);

-- ============================================================================
-- 三、建索引（ods 层不加主键约束，导入完成后再建索引：导入更快，也不会因脏数据失败）
-- ============================================================================

CREATE INDEX idx_ods_orders_order    ON ods_orders (order_id);
CREATE INDEX idx_ods_orders_customer ON ods_orders (customer_id);

CREATE INDEX idx_ods_items_order     ON ods_order_items (order_id);
CREATE INDEX idx_ods_items_product   ON ods_order_items (product_id);
CREATE INDEX idx_ods_items_seller    ON ods_order_items (seller_id);

CREATE INDEX idx_ods_pay_order       ON ods_order_payments (order_id);
CREATE INDEX idx_ods_rev_order       ON ods_order_reviews (order_id);

CREATE INDEX idx_ods_cust_id         ON ods_customers (customer_id);
CREATE INDEX idx_ods_cust_unique     ON ods_customers (customer_unique_id);

CREATE INDEX idx_ods_prod_id         ON ods_products (product_id);
CREATE INDEX idx_ods_seller_id       ON ods_sellers (seller_id);
CREATE INDEX idx_ods_geo_zip         ON ods_geolocation (geolocation_zip_code_prefix);
CREATE INDEX idx_ods_cat_name        ON ods_product_category_name_translation (product_category_name);

-- ============================================================================
-- 四、导入结果自检
-- expected 列来自公开资料，不同来源之间略有出入，以实际导入为准。
-- 真正要警惕的是「整齐地少 1 行」—— 那通常意味着 CSV 的【最后一行没有行尾换行符】，
-- LOAD DATA 会跳过它。判定依据：看 LOAD DATA 执行后的结果消息里有没有 Skipped: 1
--   Query OK, 112649 rows affected
--   Records: 112649  Deleted: 0  Skipped: 1  Warnings: 1     ← Skipped: 1 就是证据
-- 修复：给对应的 CSV 补上末尾换行，然后重新导入那一张表。
-- ============================================================================
SELECT table_name, row_cnt, expected,
       row_cnt - expected AS diff,
       CASE
         WHEN row_cnt = expected     THEN 'OK'
         WHEN expected - row_cnt = 1 THEN '少1行：检查 CSV 末行是否有换行符'
         WHEN row_cnt > expected     THEN '多行：检查是否重复导入过'
         ELSE '差异需核查'
       END AS 判定
FROM (
  SELECT 'ods_orders'                          AS table_name, COUNT(*) AS row_cnt, 99441    AS expected FROM ods_orders
  UNION ALL SELECT 'ods_order_items',                          COUNT(*), 112650  FROM ods_order_items
  UNION ALL SELECT 'ods_order_payments',                       COUNT(*), 103886  FROM ods_order_payments
  UNION ALL SELECT 'ods_order_reviews',                        COUNT(*), 99224   FROM ods_order_reviews
  UNION ALL SELECT 'ods_customers',                            COUNT(*), 99441   FROM ods_customers
  UNION ALL SELECT 'ods_products',                             COUNT(*), 32951   FROM ods_products
  UNION ALL SELECT 'ods_sellers',                              COUNT(*), 3095    FROM ods_sellers
  UNION ALL SELECT 'ods_geolocation',                          COUNT(*), 1000163 FROM ods_geolocation
  UNION ALL SELECT 'ods_product_category_name_translation',     COUNT(*), 71     FROM ods_product_category_name_translation
) t;
