-- ============================================================================
-- 01_dwd_清洗与宽表.sql
-- 作用：把 ods 的原始字符串数据清洗成可分析的 dwd 层，产出 6 张表
-- 前置：已成功执行 00_ods_建表与导入.sql
-- 要求：MySQL 8.0.19+（用到 INSERT ... WITH ... SELECT 写法）
--
-- 【表粒度设计说明 —— 这一层最容易踩的坑】
--   拆成 dwd_orders（1 行 = 1 订单）和 dwd_order_items（1 行 = 1 订单商品）两张表，
--   而不是做成一张"大宽表"。原因：payments 和 reviews 与 items 是不同粒度，
--   直接 join 会产生行数膨胀（fan-out），GMV 会被重复计算。
--   正确做法：各自先聚合到 order_id 粒度，再 join。
-- ============================================================================

USE olist_dw;
SET NAMES utf8mb4;

-- ============================================================================
-- 〇、【预处理】清掉日期列里可能混进来的行尾回车符 \r
--
-- 为什么必须做这一步（这是本机排查了十几轮才定位到的坑）：
--   · MySQL 的 TRIM(x) 默认【只去空格】，不去 \r ！要去 \r 得写 TRIM(TRAILING '\r' FROM x)
--   · 于是 '2017-10-02 10:56:33\r' 这种值会一直留在库里
--   · 而三种转换写法的行为差异，正好解释了我们看到的全部现象：
--       CAST(x AS DATETIME)      → 严格拒绝尾部多余字符，报错
--                                   （且报错信息里的类型词会错位成 "INTEGER"，极难排查）
--       原样字符串写入 DATETIME 列 → 隐式转换更宽松，忽略尾部 → 通过
--       STR_TO_DATE(x, 格式)      → 解析完指定格式就停止，忽略尾部 → 通过
--
-- 顺带说明：00 脚本的 LOAD DATA 只对【每行最后一列】做了去 \r（因为按 \n 切行时，
-- CRLF 的 \r 理论上只会落在最后一列）。但导入工具一旦不是标准按行切分，
-- 这个假设就不成立 —— 所以在这里对日期列统一兜一刀，最稳。
-- ============================================================================
SELECT
  SUM(order_purchase_timestamp      LIKE '%\r') AS 下单时间尾带回车,
  SUM(order_approved_at             LIKE '%\r') AS 审批时间尾带回车,
  SUM(order_delivered_carrier_date  LIKE '%\r') AS 发货时间尾带回车,
  SUM(order_delivered_customer_date LIKE '%\r') AS 签收时间尾带回车,
  SUM(order_estimated_delivery_date LIKE '%\r') AS 承诺送达尾带回车,
  COUNT(*) AS 订单总行数
FROM ods_orders;

UPDATE ods_orders SET
  order_purchase_timestamp      = REPLACE(order_purchase_timestamp,      '\r', ''),
  order_approved_at             = REPLACE(order_approved_at,             '\r', ''),
  order_delivered_carrier_date  = REPLACE(order_delivered_carrier_date,  '\r', ''),
  order_delivered_customer_date = REPLACE(order_delivered_customer_date, '\r', ''),
  order_estimated_delivery_date = REPLACE(order_estimated_delivery_date, '\r', '');

UPDATE ods_order_items SET shipping_limit_date = REPLACE(shipping_limit_date, '\r', '');

-- 顺手核对日期列的长度（标准应为 19 字符）。
-- 如果 MAX(LENGTH(...)) = 20 或更大，说明还有别的不可见字符，把那几行捞出来看：
SELECT MAX(LENGTH(order_purchase_timestamp)) AS 下单时间最长字符数,
       SUM(LENGTH(order_purchase_timestamp) <> 19 AND order_purchase_timestamp <> '') AS 非19字符行数
FROM ods_orders;


-- ============================================================================
-- 一、维度表
-- ============================================================================

-- 1.1 客户维表
DROP TABLE IF EXISTS dwd_customers;
CREATE TABLE dwd_customers (
  customer_id        VARCHAR(50) NOT NULL COMMENT '订单级客户ID',
  customer_unique_id VARCHAR(50) NOT NULL COMMENT '真实客户主键',
  zip_code_prefix    CHAR(5)     COMMENT '邮编前5位（已补前导0）',
  city               VARCHAR(100) COMMENT '城市',
  state              CHAR(2)     COMMENT '州',
  PRIMARY KEY (customer_id),
  KEY idx_dwd_cust_unique (customer_unique_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='dwd:客户维度';

INSERT INTO dwd_customers (customer_id, customer_unique_id, zip_code_prefix, city, state)
SELECT
  TRIM(customer_id),
  TRIM(customer_unique_id),
  LPAD(TRIM(customer_zip_code_prefix), 5, '0'),   -- 导入时前导0会丢失，这里补回来
  TRIM(customer_city),
  UPPER(TRIM(customer_state))
FROM ods_customers;


-- 1.2 商品维表（品类为空统一填 unknown，含葡英双列）
DROP TABLE IF EXISTS dwd_products;
CREATE TABLE dwd_products (
  product_id       VARCHAR(50) NOT NULL,
  category_pt      VARCHAR(100) COMMENT '品类(葡萄牙语)',
  category_en      VARCHAR(100) COMMENT '品类(英语)',
  name_length      INT,
  description_length INT,
  photos_qty       INT,
  weight_g         INT,
  length_cm        INT,
  height_cm        INT,
  width_cm         INT,
  volume_cm3       INT COMMENT '长×高×宽，立方厘米',
  PRIMARY KEY (product_id),
  KEY idx_dwd_prod_cat_en (category_en)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='dwd:商品维度';

INSERT INTO dwd_products
SELECT
  TRIM(p.product_id),
  IFNULL(NULLIF(TRIM(p.product_category_name), ''), 'unknown'),
  IFNULL(NULLIF(TRIM(t.product_category_name_english), ''), 'unknown'),
  CAST(NULLIF(TRIM(p.product_name_lenght), '')        AS UNSIGNED),
  CAST(NULLIF(TRIM(p.product_description_lenght), '') AS UNSIGNED),
  CAST(NULLIF(TRIM(p.product_photos_qty), '')         AS UNSIGNED),
  CAST(NULLIF(TRIM(p.product_weight_g), '')           AS UNSIGNED),
  CAST(NULLIF(TRIM(p.product_length_cm), '')          AS UNSIGNED),
  CAST(NULLIF(TRIM(p.product_height_cm), '')          AS UNSIGNED),
  CAST(NULLIF(TRIM(p.product_width_cm), '')           AS UNSIGNED),
  CAST(NULLIF(TRIM(p.product_length_cm), '') AS UNSIGNED)
    * CAST(NULLIF(TRIM(p.product_height_cm), '') AS UNSIGNED)
    * CAST(NULLIF(TRIM(p.product_width_cm), '')  AS UNSIGNED)
FROM ods_products p
LEFT JOIN ods_product_category_name_translation t
       ON TRIM(t.product_category_name) = TRIM(p.product_category_name);


-- 1.3 卖家维表
DROP TABLE IF EXISTS dwd_sellers;
CREATE TABLE dwd_sellers (
  seller_id       VARCHAR(50) NOT NULL,
  zip_code_prefix CHAR(5),
  city            VARCHAR(100),
  state           CHAR(2),
  PRIMARY KEY (seller_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='dwd:卖家维度';

INSERT INTO dwd_sellers (seller_id, zip_code_prefix, city, state)
SELECT TRIM(seller_id), LPAD(TRIM(seller_zip_code_prefix), 5, '0'),
       TRIM(seller_city), UPPER(TRIM(seller_state))
FROM ods_sellers;


-- 1.4 地理维表（100 万行 → 约 1.9 万行：一个邮编对应多个坐标点，取均值）
DROP TABLE IF EXISTS dwd_geolocation;
CREATE TABLE dwd_geolocation (
  zip_code_prefix CHAR(5)        NOT NULL,
  lat             DECIMAL(10,7)  COMMENT '纬度均值',
  lng             DECIMAL(10,7)  COMMENT '经度均值',
  state           CHAR(2),
  point_cnt       INT            COMMENT '原始坐标点个数',
  PRIMARY KEY (zip_code_prefix)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='dwd:地理维度(邮编级)';

INSERT INTO dwd_geolocation (zip_code_prefix, lat, lng, state, point_cnt)
SELECT
  LPAD(TRIM(geolocation_zip_code_prefix), 5, '0'),
  AVG(CAST(NULLIF(TRIM(geolocation_lat), '') AS DECIMAL(10,7))),
  AVG(CAST(NULLIF(TRIM(geolocation_lng), '') AS DECIMAL(10,7))),
  MIN(UPPER(TRIM(geolocation_state))),
  COUNT(*)
FROM ods_geolocation
GROUP BY LPAD(TRIM(geolocation_zip_code_prefix), 5, '0');


-- ============================================================================
-- 【脏数据隔离】灌 dwd 之前，先把「无法转成整数」的明细行挑出来单独存放
--
-- 设计理由：ods 层允许保留原始脏数据（只标记不删除），但 dwd 层必须保证类型可用。
--   与其让整条流水线因为几行脏数据中断，不如把坏行隔离、好行照跑，
--   并在报告里写明「剔除了多少行、依据什么规则」——这本身就是可讲的处理过程。
--
-- 这张表还兼作【诊断工具】：跑完看「被隔离的脏行数」——
--   等于 0  → 源数据是干净的，报错一定来自别的地方
--   大于 0  → 就是这些行导致 CAST 失败，而且下面会把它们原样列出来
-- ============================================================================
DROP TABLE IF EXISTS quarantine_order_items;
CREATE TABLE quarantine_order_items (
  order_id            VARCHAR(50),
  order_item_id       VARCHAR(50),
  product_id          VARCHAR(50),
  seller_id           VARCHAR(50),
  shipping_limit_date VARCHAR(30),
  price               VARCHAR(20),
  freight_value       VARCHAR(20)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='隔离区:无法转成整数的订单明细';

INSERT INTO quarantine_order_items
SELECT order_id, order_item_id, product_id, seller_id, shipping_limit_date, price, freight_value
FROM ods_order_items
WHERE NOT (TRIM(order_item_id) REGEXP '^[0-9]+$');

SELECT COUNT(*) AS 被隔离的脏行数 FROM quarantine_order_items;
SELECT MAX(LENGTH(order_item_id)) AS order_item_id最长字符数 FROM ods_order_items;
SELECT * FROM quarantine_order_items LIMIT 20;

-- 【日期格式体检】把所有 ods 日期列扫一遍，分成四类
--
-- 为什么要查「Excel 格式」：**用 Excel 打开并保存过的 CSV，时间会被写成 2017/9/19 9:45**
-- —— 秒数 09:45:35 被永久抹成 9:45。这是**数据损坏，不是格式问题**，任何代码都补不回来。
-- 判断依据：Excel 格式的年份后面跟的是【斜杠】。
--
-- 读法：只要「Excel格式」不为 0，就说明这个文件被动过，应当重新下载原始 CSV 重导。
SELECT 'ods_orders.order_purchase_timestamp' AS 字段, COUNT(*) AS 总行数,
       SUM(IFNULL(TRIM(order_purchase_timestamp),'') = '')                                       AS 空值,
       SUM(IFNULL(TRIM(order_purchase_timestamp),'') REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$') AS ISO格式,
       SUM(IFNULL(TRIM(order_purchase_timestamp),'') REGEXP '^[0-9]{4}/')                        AS Excel格式_秒数已丢,
       SUM(IFNULL(TRIM(order_purchase_timestamp),'') <> '' AND IFNULL(TRIM(order_purchase_timestamp),'') NOT REGEXP '^[0-9]{4}[-/][0-9]{1,2}[-/][0-9]{1,2} [0-9]{1,2}:[0-9]{2}') AS 其他非法
  FROM ods_orders
UNION ALL
SELECT 'ods_orders.order_approved_at', COUNT(*),
       SUM(IFNULL(TRIM(order_approved_at),'') = ''),
       SUM(IFNULL(TRIM(order_approved_at),'') REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'),
       SUM(IFNULL(TRIM(order_approved_at),'') REGEXP '^[0-9]{4}/'),
       SUM(IFNULL(TRIM(order_approved_at),'') <> '' AND IFNULL(TRIM(order_approved_at),'') NOT REGEXP '^[0-9]{4}[-/][0-9]{1,2}[-/][0-9]{1,2} [0-9]{1,2}:[0-9]{2}')
  FROM ods_orders
UNION ALL
SELECT 'ods_orders.order_delivered_customer_date', COUNT(*),
       SUM(IFNULL(TRIM(order_delivered_customer_date),'') = ''),
       SUM(IFNULL(TRIM(order_delivered_customer_date),'') REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'),
       SUM(IFNULL(TRIM(order_delivered_customer_date),'') REGEXP '^[0-9]{4}/'),
       SUM(IFNULL(TRIM(order_delivered_customer_date),'') <> '' AND IFNULL(TRIM(order_delivered_customer_date),'') NOT REGEXP '^[0-9]{4}[-/][0-9]{1,2}[-/][0-9]{1,2} [0-9]{1,2}:[0-9]{2}')
  FROM ods_orders
UNION ALL
SELECT 'ods_orders.order_estimated_delivery_date', COUNT(*),
       SUM(IFNULL(TRIM(order_estimated_delivery_date),'') = ''),
       SUM(IFNULL(TRIM(order_estimated_delivery_date),'') REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'),
       SUM(IFNULL(TRIM(order_estimated_delivery_date),'') REGEXP '^[0-9]{4}/'),
       SUM(IFNULL(TRIM(order_estimated_delivery_date),'') <> '' AND IFNULL(TRIM(order_estimated_delivery_date),'') NOT REGEXP '^[0-9]{4}[-/][0-9]{1,2}[-/][0-9]{1,2} [0-9]{1,2}:[0-9]{2}')
  FROM ods_orders
UNION ALL
SELECT 'ods_order_items.shipping_limit_date', COUNT(*),
       SUM(IFNULL(TRIM(shipping_limit_date),'') = ''),
       SUM(IFNULL(TRIM(shipping_limit_date),'') REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'),
       SUM(IFNULL(TRIM(shipping_limit_date),'') REGEXP '^[0-9]{4}/'),
       SUM(IFNULL(TRIM(shipping_limit_date),'') <> '' AND IFNULL(TRIM(shipping_limit_date),'') NOT REGEXP '^[0-9]{4}[-/][0-9]{1,2}[-/][0-9]{1,2} [0-9]{1,2}:[0-9]{2}')
  FROM ods_order_items
UNION ALL
SELECT 'ods_order_reviews.review_creation_date', COUNT(*),
       SUM(IFNULL(TRIM(review_creation_date),'') = ''),
       SUM(IFNULL(TRIM(review_creation_date),'') REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'),
       SUM(IFNULL(TRIM(review_creation_date),'') REGEXP '^[0-9]{4}/'),
       SUM(IFNULL(TRIM(review_creation_date),'') <> '' AND IFNULL(TRIM(review_creation_date),'') NOT REGEXP '^[0-9]{4}[-/][0-9]{1,2}[-/][0-9]{1,2} [0-9]{1,2}:[0-9]{2}')
  FROM ods_order_reviews;

-- 把「其他非法」的具体值列出来看看（最多 20 个不同值）
SELECT order_purchase_timestamp AS 异常值, COUNT(*) AS 出现次数
FROM ods_orders
WHERE IFNULL(TRIM(order_purchase_timestamp),'') <> ''
  AND IFNULL(TRIM(order_purchase_timestamp),'') NOT REGEXP '^[0-9]{4}[-/][0-9]{1,2}[-/][0-9]{1,2} [0-9]{1,2}:[0-9]{2}'
GROUP BY order_purchase_timestamp
ORDER BY 出现次数 DESC
LIMIT 20;


-- ============================================================================
-- 二、dwd_order_items：订单商品明细（1 行 = 1 个订单商品）
-- 含买家↔卖家直线距离（Haversine 公式），供 S3 履约分析使用
-- ============================================================================
DROP TABLE IF EXISTS dwd_order_items;
CREATE TABLE dwd_order_items (
  order_id            VARCHAR(50) NOT NULL,
  order_item_id       INT         NOT NULL COMMENT '订单内商品序号',
  product_id          VARCHAR(50),
  seller_id           VARCHAR(50),
  shipping_limit_ts   DATETIME    COMMENT '卖家发货截止时间',
  price               DECIMAL(10,2) COMMENT '商品价',
  freight_value       DECIMAL(10,2) COMMENT '运费分摊',
  category_en         VARCHAR(100),
  seller_state        CHAR(2),
  customer_state      CHAR(2),
  distance_km         DECIMAL(8,1)  COMMENT '买家-卖家直线距离(km)',
  PRIMARY KEY (order_id, order_item_id),
  KEY idx_dwd_items_order   (order_id),
  KEY idx_dwd_items_product (product_id),
  KEY idx_dwd_items_seller  (seller_id),
  KEY idx_dwd_items_cat     (category_en)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='dwd:订单商品明细';

INSERT INTO dwd_order_items
SELECT
  TRIM(i.order_id),
  CAST(NULLIF(TRIM(i.order_item_id), '') AS UNSIGNED),
  TRIM(i.product_id),
  TRIM(i.seller_id),
  -- 【日期安全转换】用 STR_TO_DATE，不用 CAST(... AS DATETIME)
  --   为什么：CAST(x AS DATETIME) 在本机 MySQL 上不支持 —— 即使喂给它一个完美的
  --   ISO 值 '2017-10-02 10:56:33'，也会报 "Truncated incorrect INTEGER value"
  --   （注意类型词是错的，极易把人带偏）。最小复现（不用碰任何表）：
  --       SELECT CAST('2017-10-02 10:56:33' AS DATETIME);
  --   STR_TO_DATE 是更传统、兼容性更好的写法，格式显式可控。
  -- 兼容两种输入：ISO 2017-09-19 09:45:35 ／ Excel 2017/9/19 09:45（秒已丢）；其余置 NULL
  CASE WHEN TRIM(i.shipping_limit_date) REGEXP '^[0-9]{4}[-/][0-9]{1,2}[-/][0-9]{1,2} [0-9]{1,2}:[0-9]{2}:[0-9]{2}$'
       THEN STR_TO_DATE(REPLACE(TRIM(i.shipping_limit_date), '/', '-'), '%Y-%m-%d %H:%i:%s')
       WHEN TRIM(i.shipping_limit_date) REGEXP '^[0-9]{4}[-/][0-9]{1,2}[-/][0-9]{1,2} [0-9]{1,2}:[0-9]{2}$'
       THEN STR_TO_DATE(CONCAT(REPLACE(TRIM(i.shipping_limit_date), '/', '-'), ':00'), '%Y-%m-%d %H:%i:%s')
       ELSE NULL END,
  CAST(NULLIF(TRIM(i.price), '')          AS DECIMAL(10,2)),
  CAST(NULLIF(TRIM(i.freight_value), '')  AS DECIMAL(10,2)),
  IFNULL(p.category_en, 'unknown') AS category_en,
  s.state,
  c.state,
  -- Haversine：用 LEAST/GREATEST 夹住取值区间，避免浮点误差导致 ACOS 报域错误
  ROUND(
    6371 * ACOS(
      LEAST(1, GREATEST(-1,
          SIN(RADIANS(gc.lat)) * SIN(RADIANS(gs.lat))
        + COS(RADIANS(gc.lat)) * COS(RADIANS(gs.lat))
          * COS(RADIANS(gs.lng) - RADIANS(gc.lng))
      ))
    )
  , 1)
FROM ods_order_items i
-- 维表一律用 LEFT JOIN：极少数明细的商品/卖家在维表中缺失，
-- 用 INNER JOIN 会静默丢行，导致 dwd 行数与 GMV 对不上
LEFT JOIN dwd_products p  ON p.product_id = TRIM(i.product_id)
LEFT JOIN dwd_sellers  s  ON s.seller_id  = TRIM(i.seller_id)
JOIN      ods_orders   o  ON o.order_id   = TRIM(i.order_id)
LEFT JOIN dwd_customers c ON c.customer_id = TRIM(o.customer_id)
LEFT JOIN dwd_geolocation gc ON gc.zip_code_prefix = c.zip_code_prefix
LEFT JOIN dwd_geolocation gs ON gs.zip_code_prefix = s.zip_code_prefix
-- 守卫条件：只放「order_item_id 是纯数字」的行。
-- 坏行已被上面的 quarantine_order_items 接住，不会丢得不明不白。
-- 如果源数据本来就是干净的，这个条件等价于恒真，没有副作用。
WHERE TRIM(i.order_item_id) REGEXP '^[0-9]+$';


-- ============================================================================
-- 三、dwd_orders：订单宽表（1 行 = 1 订单）
-- 时间字段转为 DATETIME，派生履约时长、延迟标记；金额与评价各自聚合到订单粒度后 join
-- ============================================================================
DROP TABLE IF EXISTS dwd_orders;
CREATE TABLE dwd_orders (
  order_id              VARCHAR(50) NOT NULL,
  customer_id           VARCHAR(50) NOT NULL,
  customer_unique_id    VARCHAR(50),
  order_status          VARCHAR(20),
  purchase_ts           DATETIME COMMENT '下单时间',
  approved_ts           DATETIME COMMENT '审批时间',
  carrier_ts            DATETIME COMMENT '交承运商时间',
  customer_delivered_ts DATETIME COMMENT '客户签收时间',
  estimated_ts          DATETIME COMMENT '承诺送达时间',
  approve_hours         INT COMMENT '下单→审批(小时)',
  carrier_hours         INT COMMENT '审批→交承运商(小时)',
  lastmile_hours        INT COMMENT '交承运商→签收(小时)',
  total_delivery_hours  INT COMMENT '下单→签收(小时)',
  estimated_hours       INT COMMENT '下单→承诺送达(小时)',
  delay_hours           INT COMMENT '超时小时数，正数=延迟',
  is_late               TINYINT COMMENT '是否延迟 1/0/NULL(未送达)',
  is_delivered          TINYINT COMMENT '是否已送达 1/0',
  customer_state        CHAR(2),
  customer_city         VARCHAR(100),
  customer_zip          CHAR(5),
  customer_lat          DECIMAL(10,7),
  customer_lng          DECIMAL(10,7),
  item_cnt              INT COMMENT '商品件数',
  product_cnt           INT COMMENT '商品SKU数',
  seller_cnt            INT COMMENT '涉及卖家数',
  item_amount           DECIMAL(12,2) COMMENT '商品金额小计',
  freight_amount        DECIMAL(12,2) COMMENT '运费小计',
  order_amount          DECIMAL(12,2) COMMENT '订单总额=商品+运费',
  avg_distance_km       DECIMAL(8,1),
  max_distance_km       DECIMAL(8,1),
  pay_cnt               INT,
  pay_amount            DECIMAL(12,2),
  pay_types             VARCHAR(100) COMMENT '支付方式，多值用 / 连接',
  max_installments      INT,
  review_score          DECIMAL(4,2) COMMENT '平均评分(同一订单多条评价时取均值)',
  review_cnt            INT,
  PRIMARY KEY (order_id),
  KEY idx_dwd_ord_cust_unique (customer_unique_id),
  KEY idx_dwd_ord_purchase    (purchase_ts),
  KEY idx_dwd_ord_status      (order_status),
  KEY idx_dwd_ord_late        (is_late)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='dwd:订单宽表';

INSERT INTO dwd_orders
WITH base AS (
  SELECT
    TRIM(order_id)     AS order_id,
    TRIM(customer_id)  AS customer_id,
    TRIM(order_status) AS order_status,
    -- 【日期安全转换】统一用 STR_TO_DATE，不用 CAST(... AS DATETIME)
    -- CAST(x AS DATETIME) 在本机 MySQL 上不支持：即使输入是完美的 ISO 值，也会报
    -- "Truncated incorrect INTEGER value"（类型词是错的，极易误导）。最小复现：
    --     SELECT CAST('2017-10-02 10:56:33' AS DATETIME);
    -- 兼容 ISO(2017-05-16 15:05:35) 与 Excel(2017/5/16 15:05，秒已丢)；其余置 NULL。
    CASE WHEN TRIM(order_purchase_timestamp) REGEXP '^[0-9]{4}[-/][0-9]{1,2}[-/][0-9]{1,2} [0-9]{1,2}:[0-9]{2}:[0-9]{2}$'
         THEN STR_TO_DATE(REPLACE(TRIM(order_purchase_timestamp), '/', '-'), '%Y-%m-%d %H:%i:%s')
         WHEN TRIM(order_purchase_timestamp) REGEXP '^[0-9]{4}[-/][0-9]{1,2}[-/][0-9]{1,2} [0-9]{1,2}:[0-9]{2}$'
         THEN STR_TO_DATE(CONCAT(REPLACE(TRIM(order_purchase_timestamp), '/', '-'), ':00'), '%Y-%m-%d %H:%i:%s')
         ELSE NULL END AS purchase_ts,
    CASE WHEN TRIM(order_approved_at) REGEXP '^[0-9]{4}[-/][0-9]{1,2}[-/][0-9]{1,2} [0-9]{1,2}:[0-9]{2}:[0-9]{2}$'
         THEN STR_TO_DATE(REPLACE(TRIM(order_approved_at), '/', '-'), '%Y-%m-%d %H:%i:%s')
         WHEN TRIM(order_approved_at) REGEXP '^[0-9]{4}[-/][0-9]{1,2}[-/][0-9]{1,2} [0-9]{1,2}:[0-9]{2}$'
         THEN STR_TO_DATE(CONCAT(REPLACE(TRIM(order_approved_at), '/', '-'), ':00'), '%Y-%m-%d %H:%i:%s')
         ELSE NULL END AS approved_ts,
    CASE WHEN TRIM(order_delivered_carrier_date) REGEXP '^[0-9]{4}[-/][0-9]{1,2}[-/][0-9]{1,2} [0-9]{1,2}:[0-9]{2}:[0-9]{2}$'
         THEN STR_TO_DATE(REPLACE(TRIM(order_delivered_carrier_date), '/', '-'), '%Y-%m-%d %H:%i:%s')
         WHEN TRIM(order_delivered_carrier_date) REGEXP '^[0-9]{4}[-/][0-9]{1,2}[-/][0-9]{1,2} [0-9]{1,2}:[0-9]{2}$'
         THEN STR_TO_DATE(CONCAT(REPLACE(TRIM(order_delivered_carrier_date), '/', '-'), ':00'), '%Y-%m-%d %H:%i:%s')
         ELSE NULL END AS carrier_ts,
    CASE WHEN TRIM(order_delivered_customer_date) REGEXP '^[0-9]{4}[-/][0-9]{1,2}[-/][0-9]{1,2} [0-9]{1,2}:[0-9]{2}:[0-9]{2}$'
         THEN STR_TO_DATE(REPLACE(TRIM(order_delivered_customer_date), '/', '-'), '%Y-%m-%d %H:%i:%s')
         WHEN TRIM(order_delivered_customer_date) REGEXP '^[0-9]{4}[-/][0-9]{1,2}[-/][0-9]{1,2} [0-9]{1,2}:[0-9]{2}$'
         THEN STR_TO_DATE(CONCAT(REPLACE(TRIM(order_delivered_customer_date), '/', '-'), ':00'), '%Y-%m-%d %H:%i:%s')
         ELSE NULL END AS customer_delivered_ts,
    CASE WHEN TRIM(order_estimated_delivery_date) REGEXP '^[0-9]{4}[-/][0-9]{1,2}[-/][0-9]{1,2} [0-9]{1,2}:[0-9]{2}:[0-9]{2}$'
         THEN STR_TO_DATE(REPLACE(TRIM(order_estimated_delivery_date), '/', '-'), '%Y-%m-%d %H:%i:%s')
         WHEN TRIM(order_estimated_delivery_date) REGEXP '^[0-9]{4}[-/][0-9]{1,2}[-/][0-9]{1,2} [0-9]{1,2}:[0-9]{2}$'
         THEN STR_TO_DATE(CONCAT(REPLACE(TRIM(order_estimated_delivery_date), '/', '-'), ':00'), '%Y-%m-%d %H:%i:%s')
         ELSE NULL END AS estimated_ts
  FROM ods_orders
),
items AS (
  SELECT order_id,
         COUNT(*)                   AS item_cnt,
         COUNT(DISTINCT product_id) AS product_cnt,
         COUNT(DISTINCT seller_id)  AS seller_cnt,
         ROUND(SUM(price), 2)          AS item_amount,
         ROUND(SUM(freight_value), 2)  AS freight_amount,
         ROUND(AVG(distance_km), 1)    AS avg_distance_km,
         ROUND(MAX(distance_km), 1)    AS max_distance_km
  FROM dwd_order_items
  GROUP BY order_id
),
pays AS (
  SELECT TRIM(order_id) AS order_id,
         COUNT(*) AS pay_cnt,
         ROUND(SUM(CAST(NULLIF(TRIM(payment_value), '') AS DECIMAL(12,2))), 2) AS pay_amount,
         MAX(CAST(NULLIF(TRIM(payment_installments), '') AS UNSIGNED))         AS max_installments,
         GROUP_CONCAT(DISTINCT TRIM(payment_type) ORDER BY TRIM(payment_type) SEPARATOR '/') AS pay_types
  FROM ods_order_payments
  GROUP BY TRIM(order_id)
),
revs AS (
  SELECT TRIM(order_id) AS order_id,
         COUNT(*) AS review_cnt,
         ROUND(AVG(CAST(NULLIF(TRIM(review_score), '') AS UNSIGNED)), 2) AS review_score
  FROM ods_order_reviews
  GROUP BY TRIM(order_id)
)
SELECT
  b.order_id,
  b.customer_id,
  c.customer_unique_id,
  b.order_status,
  b.purchase_ts, b.approved_ts, b.carrier_ts, b.customer_delivered_ts, b.estimated_ts,
  TIMESTAMPDIFF(HOUR, b.purchase_ts, b.approved_ts)             AS approve_hours,
  TIMESTAMPDIFF(HOUR, b.approved_ts, b.carrier_ts)              AS carrier_hours,
  TIMESTAMPDIFF(HOUR, b.carrier_ts, b.customer_delivered_ts)    AS lastmile_hours,
  TIMESTAMPDIFF(HOUR, b.purchase_ts, b.customer_delivered_ts)   AS total_delivery_hours,
  TIMESTAMPDIFF(HOUR, b.purchase_ts, b.estimated_ts)            AS estimated_hours,
  TIMESTAMPDIFF(HOUR, b.estimated_ts, b.customer_delivered_ts)  AS delay_hours,
  CASE
    WHEN b.customer_delivered_ts IS NULL OR b.estimated_ts IS NULL THEN NULL
    WHEN b.customer_delivered_ts > b.estimated_ts THEN 1
    ELSE 0
  END AS is_late,
  CASE WHEN b.order_status = 'delivered' THEN 1 ELSE 0 END AS is_delivered,
  c.state, c.city, c.zip_code_prefix,
  gc.lat, gc.lng,
  IFNULL(it.item_cnt, 0), IFNULL(it.product_cnt, 0), IFNULL(it.seller_cnt, 0),
  IFNULL(it.item_amount, 0.00), IFNULL(it.freight_amount, 0.00),
  ROUND(IFNULL(it.item_amount, 0) + IFNULL(it.freight_amount, 0), 2) AS order_amount,
  it.avg_distance_km, it.max_distance_km,
  IFNULL(p.pay_cnt, 0), IFNULL(p.pay_amount, 0.00), p.pay_types, p.max_installments,
  r.review_score, IFNULL(r.review_cnt, 0)
FROM base b
-- LEFT JOIN 保证 dwd_orders 行数严格等于 ods_orders（99,441），便于口径对账
LEFT JOIN dwd_customers c ON c.customer_id = b.customer_id
LEFT JOIN dwd_geolocation gc ON gc.zip_code_prefix = c.zip_code_prefix
LEFT JOIN items it       ON it.order_id = b.order_id
LEFT JOIN pays  p        ON p.order_id  = b.order_id
LEFT JOIN revs  r        ON r.order_id  = b.order_id;


-- ============================================================================
-- 四、dwd 层自检
-- ============================================================================
SELECT 'dwd_customers'   AS table_name, COUNT(*) AS row_cnt FROM dwd_customers
UNION ALL SELECT 'dwd_products',      COUNT(*) FROM dwd_products
UNION ALL SELECT 'dwd_sellers',       COUNT(*) FROM dwd_sellers
UNION ALL SELECT 'dwd_geolocation',   COUNT(*) FROM dwd_geolocation
UNION ALL SELECT 'dwd_order_items',   COUNT(*) FROM dwd_order_items
UNION ALL SELECT 'dwd_orders',        COUNT(*) FROM dwd_orders;

-- 订单状态分布（预期 delivered 约 97%）
SELECT order_status, COUNT(*) AS cnt,
       ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM dwd_orders), 2) AS pct
FROM dwd_orders GROUP BY order_status ORDER BY cnt DESC;

-- 延迟率（仅已送达订单）
SELECT COUNT(*)                                             AS delivered_orders,
       SUM(is_late)                                         AS late_orders,
       ROUND(AVG(is_late) * 100, 2)                         AS late_rate_pct,
       ROUND(AVG(total_delivery_hours) / 24, 1)             AS avg_delivery_days,
       ROUND(AVG(lastmile_hours) / 24, 1)                   AS avg_lastmile_days
FROM dwd_orders
WHERE is_late IS NOT NULL;
