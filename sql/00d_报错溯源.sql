-- ============================================================================
-- 00d_报错溯源.sql
-- 用途：报错反复出现、但又不像是你以为的那条语句时，用它把范围锁死。
--
-- 【核心推理：这个值物理上不可能在 order_item_id 里】
--   报错值 '2017-03-29 13:05:42' 是 19 个字符。
--   而 ods_order_items.order_item_id 是 VARCHAR(10)（见表结构）。
--   19 > 10 → 这个值根本存不进去。
--   而且 00 脚本设了 STRICT 模式，超长会直接报 "Data too long"，不会静默截断。
--   ⇒ 报错不可能来自 order_item_id 这一列。
--
-- 【再缩小范围】报错类型是 INTEGER（不是 DECIMAL / DATETIME），
--   说明是某个 `CAST(... AS UNSIGNED)` 或写入 INT 列时失败了。
--   叠加"列长度必须 ≥ 19"这个条件，全脚本只剩 4 个候选：
--       ods_products.product_weight_g    VARCHAR(20)  ✓
--       ods_products.product_length_cm   VARCHAR(20)  ✓
--       ods_products.product_height_cm   VARCHAR(20)  ✓
--       ods_products.product_width_cm    VARCHAR(20)  ✓
--   其余全部不够长，可以排除：
--       ods_order_items.order_item_id     VARCHAR(10)  ✗
--       ods_order_payments.payment_installments VARCHAR(10)  ✗
--       ods_order_reviews.review_score    VARCHAR(5)   ✗
--       ods_products.product_name_lenght  VARCHAR(10)  ✗
--   ⇒ 报错最可能来自 INSERT INTO dwd_products，而不是 dwd_order_items。
-- ============================================================================

USE olist_dw;
SET NAMES utf8mb4;


-- ============================================================================
-- 一、【最关键的一条】各 dwd 表行数 —— 直接看出脚本跑到哪一步就断了
-- 预期（全部跑通时）：customers 99441 / products 32951 / sellers 3095 /
--                     geolocation 约19015 / order_items 112650 / orders 99441
-- 读法：
--   · dwd_customers 有数、dwd_products 为 0 或不存在 → 脚本死在 dwd_products
--   · 一直到 dwd_order_items 之前都有数、之后为空  → 死在 dwd_order_items
--   · 全部有数                                     → 报错不是这几条语句
-- ============================================================================
SELECT 'dwd_customers'   AS 表名, COUNT(*) AS 行数 FROM dwd_customers
UNION ALL SELECT 'dwd_products',    COUNT(*) FROM dwd_products
UNION ALL SELECT 'dwd_sellers',     COUNT(*) FROM dwd_sellers
UNION ALL SELECT 'dwd_geolocation', COUNT(*) FROM dwd_geolocation
UNION ALL SELECT 'dwd_order_items', COUNT(*) FROM dwd_order_items
UNION ALL SELECT 'dwd_orders',      COUNT(*) FROM dwd_orders;


-- ============================================================================
-- 二、这个值到底躺在哪一列 —— 哪一行命中数 > 0，就是它的位置
-- ============================================================================
SELECT 'ods_order_items.shipping_limit_date' AS 位置, COUNT(*) AS 命中
  FROM ods_order_items WHERE shipping_limit_date = '2017-03-29 13:05:42'
UNION ALL SELECT 'ods_order_items.price',          COUNT(*) FROM ods_order_items WHERE price          = '2017-03-29 13:05:42'
UNION ALL SELECT 'ods_order_items.freight_value',  COUNT(*) FROM ods_order_items WHERE freight_value  = '2017-03-29 13:05:42'
UNION ALL SELECT 'ods_order_items.order_item_id',  COUNT(*) FROM ods_order_items WHERE order_item_id  = '2017-03-29 13:05:42'
UNION ALL SELECT 'ods_products.product_weight_g',  COUNT(*) FROM ods_products WHERE product_weight_g  = '2017-03-29 13:05:42'
UNION ALL SELECT 'ods_products.product_length_cm', COUNT(*) FROM ods_products WHERE product_length_cm = '2017-03-29 13:05:42'
UNION ALL SELECT 'ods_products.product_height_cm', COUNT(*) FROM ods_products WHERE product_height_cm = '2017-03-29 13:05:42'
UNION ALL SELECT 'ods_products.product_width_cm',  COUNT(*) FROM ods_products WHERE product_width_cm  = '2017-03-29 13:05:42'
UNION ALL SELECT 'ods_products.product_id',        COUNT(*) FROM ods_products WHERE product_id       = '2017-03-29 13:05:42'
UNION ALL SELECT 'ods_orders.order_purchase_timestamp', COUNT(*) FROM ods_orders WHERE order_purchase_timestamp = '2017-03-29 13:05:42';


-- ============================================================================
-- 三、ods_products 逐列形态体检（按上面的推理，这是头号嫌疑表）
-- ============================================================================
SELECT
  COUNT(*)                                                          AS 总行数,
  SUM(IF(product_id REGEXP '^[0-9a-f]{32}$', 0, 1))                  AS 坏_product_id,
  SUM(IF(product_category_name = '' OR product_category_name REGEXP '^[a-z0-9_]+$', 0, 1)) AS 坏_品类名,
  SUM(IF(product_name_lenght = '' OR product_name_lenght REGEXP '^[0-9]+$', 0, 1))         AS 坏_名称长度,
  SUM(IF(product_description_lenght = '' OR product_description_lenght REGEXP '^[0-9]+$', 0, 1)) AS 坏_描述长度,
  SUM(IF(product_photos_qty = '' OR product_photos_qty REGEXP '^[0-9]+$', 0, 1))           AS 坏_图片数,
  SUM(IF(product_weight_g = '' OR product_weight_g REGEXP '^[0-9]+$', 0, 1))               AS 坏_重量,
  SUM(IF(product_length_cm = '' OR product_length_cm REGEXP '^[0-9]+$', 0, 1))             AS 坏_长,
  SUM(IF(product_height_cm = '' OR product_height_cm REGEXP '^[0-9]+$', 0, 1))             AS 坏_高,
  SUM(IF(product_width_cm = '' OR product_width_cm REGEXP '^[0-9]+$', 0, 1))               AS 坏_宽
FROM ods_products;

-- 把异常行原样拉出来看
SELECT * FROM ods_products
WHERE product_weight_g NOT REGEXP '^[0-9]+$'
   OR product_length_cm NOT REGEXP '^[0-9]+$'
   OR product_height_cm NOT REGEXP '^[0-9]+$'
   OR product_width_cm  NOT REGEXP '^[0-9]+$'
LIMIT 20;


-- ============================================================================
-- 四、【执行方式排查】DBeaver 的报错栏显示的是"上一次执行"的错误，未必是你以为的那条
-- 正确做法：把 01_dwd 从头到尾【整份顺序执行】，看第一条真正失败的是哪条。
-- 也可以逐条单独执行，定位到底是哪条语句：
--   ① 单独执行 INSERT INTO dwd_customers  → 看是否通过
--   ② 单独执行 INSERT INTO dwd_products   → 重点看这条
--   ③ 单独执行 INSERT INTO dwd_sellers
--   ④ 单独执行 INSERT INTO dwd_geolocation
--   ⑤ 单独执行 INSERT INTO dwd_order_items
--   ⑥ 单独执行 INSERT INTO dwd_orders
-- 哪条报错，就是哪条 —— 不要再根据编辑器的高亮行去猜。
-- ============================================================================


-- ============================================================================
-- 五、【结论性推理】这个报错不可能由本项目脚本产生
--
-- 实测：SELECT MAX(LENGTH(order_item_id)) FROM ods_order_items;  →  2
--       （这一列里最长的值只有 2 个字符，说明它干净得不能再干净）
-- 已知：报错值是 19 个字符的日期 '2017-03-29 13:05:42'
--       ⇒ 2 < 19，这个值在 order_item_id 里【物理上不存在】，
--         不是"存在但没被检查出来"，而是根本容纳不下。
--
-- 把范围推到全项目，所有「会被转成整数」的源列都过一遍：
--
--   CAST(... AS UNSIGNED) 的源列              定义长度    能装下 19 字符日期？
--   ----------------------------------------- ---------- -------------------
--   ods_order_items.order_item_id             VARCHAR(10)  ✗ 实际最长仅 2
--   ods_order_payments.payment_installments   VARCHAR(10)  ✗
--   ods_order_reviews.review_score            VARCHAR(5)   ✗
--   ods_products.product_name_lenght          VARCHAR(10)  ✗
--   ods_products.product_description_lenght   VARCHAR(10)  ✗
--   ods_products.product_photos_qty           VARCHAR(10)  ✗
--   ods_products.product_weight_g             VARCHAR(20)  ✗ 源文件里没有日期
--   ods_products.product_length_cm            VARCHAR(20)  ✗
--   ods_products.product_height_cm            VARCHAR(20)  ✗
--   ods_products.product_width_cm             VARCHAR(20)  ✗
--
-- 真正能装下 19 字符日期的列只有下面这几类，但它们【永远不会被转成整数】：
--   ods_orders.*                              → 只转 DATETIME
--   ods_order_items.shipping_limit_date       → 只转 DATETIME
--   ods_order_reviews.review_creation_date / review_answer_timestamp
--                                             → 脚本里根本没用到
--   ods_geolocation.geolocation_lat / lng     → 只转 DECIMAL
--
-- ⇒ 结论：本项目脚本里没有任何一处能产生这个报错。
--   它极可能是下面三种情况之一：
--     ① DBeaver 底部错误栏里【上一次执行】残留的旧报错（最常见，会一直挂着）
--     ② 你手写或改动过的某条语句
--     ③ 另一个连接 / 另一个工具上产生的
--
-- 【处置】关掉当前 console，新开一个，从头逐条执行 —— 别让残留报错继续误导。
-- ============================================================================


-- ============================================================================
-- 六、全量整数转换体检（用 REGEXP 而不是 CAST，保证查询本身不会中断）
-- 哪一行的数字不是 0，就是它出了问题
-- ============================================================================
SELECT 'ods_order_items.order_item_id'                       AS 源列, SUM(NOT (TRIM(order_item_id) REGEXP '^[0-9]+$'))                        AS 不可转整数
  FROM ods_order_items
UNION ALL SELECT 'ods_order_items.price',                     SUM(NOT (TRIM(price) REGEXP '^[0-9]+[.]?[0-9]*$'))                          FROM ods_order_items
UNION ALL SELECT 'ods_order_items.freight_value',             SUM(NOT (TRIM(freight_value) REGEXP '^[0-9]+[.]?[0-9]*$'))                  FROM ods_order_items
UNION ALL SELECT 'ods_order_items.shipping_limit_date',       SUM(NOT (TRIM(shipping_limit_date) REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$')) FROM ods_order_items
UNION ALL SELECT 'ods_order_payments.payment_sequential',     SUM(NOT (TRIM(payment_sequential) REGEXP '^[0-9]+$'))                      FROM ods_order_payments
UNION ALL SELECT 'ods_order_payments.payment_installments',   SUM(NOT (TRIM(payment_installments) REGEXP '^[0-9]+$'))                    FROM ods_order_payments
UNION ALL SELECT 'ods_order_payments.payment_value',          SUM(NOT (TRIM(payment_value) REGEXP '^[0-9]+[.]?[0-9]*$'))                  FROM ods_order_payments
UNION ALL SELECT 'ods_order_reviews.review_score',            SUM(NOT (TRIM(review_score) REGEXP '^[1-5]$'))                             FROM ods_order_reviews
UNION ALL SELECT 'ods_products.product_name_lenght',          SUM(NOT (TRIM(product_name_lenght) REGEXP '^[0-9]*$'))                     FROM ods_products
UNION ALL SELECT 'ods_products.product_description_lenght',   SUM(NOT (TRIM(product_description_lenght) REGEXP '^[0-9]*$'))              FROM ods_products
UNION ALL SELECT 'ods_products.product_photos_qty',           SUM(NOT (TRIM(product_photos_qty) REGEXP '^[0-9]*$'))                      FROM ods_products
UNION ALL SELECT 'ods_products.product_weight_g',             SUM(NOT (TRIM(product_weight_g) REGEXP '^[0-9]*$'))                        FROM ods_products
UNION ALL SELECT 'ods_products.product_length_cm',            SUM(NOT (TRIM(product_length_cm) REGEXP '^[0-9]*$'))                       FROM ods_products
UNION ALL SELECT 'ods_products.product_height_cm',            SUM(NOT (TRIM(product_height_cm) REGEXP '^[0-9]*$'))                       FROM ods_products
UNION ALL SELECT 'ods_products.product_width_cm',             SUM(NOT (TRIM(product_width_cm) REGEXP '^[0-9]*$'))                        FROM ods_products
UNION ALL SELECT 'ods_geolocation.geolocation_lat',           SUM(NOT (TRIM(geolocation_lat) REGEXP '^-?[0-9]+[.]?[0-9]*$'))             FROM ods_geolocation
UNION ALL SELECT 'ods_geolocation.geolocation_lng',           SUM(NOT (TRIM(geolocation_lng) REGEXP '^-?[0-9]+[.]?[0-9]*$'))             FROM ods_geolocation;
-- 全部为 0 → 源数据无懈可击，报错与数据无关
-- 某行 > 0 → 找到真凶，按归属去修对应的那张 ods 表


-- ============================================================================
-- 七、纯净 SELECT 复现测试：只跑 JOIN，不带 INSERT、不带 CAST
-- 目的：确认 dwd_order_items 的 SELECT 到底能不能出数
-- 预期：约 112,650
--   · 出得来 → JOIN 没问题，那条 INSERT 应该能成功（那它就是没被执行过）
--   · 出不来 / 报错 → 问题在 JOIN 上，把这句的报错原文发我
-- ============================================================================
SELECT COUNT(*) AS 应得行数
FROM ods_order_items i
LEFT JOIN dwd_products p  ON p.product_id = TRIM(i.product_id)
LEFT JOIN dwd_sellers  s  ON s.seller_id  = TRIM(i.seller_id)
JOIN      ods_orders   o  ON o.order_id   = TRIM(i.order_id)
LEFT JOIN dwd_customers c ON c.customer_id = TRIM(o.customer_id)
LEFT JOIN dwd_geolocation gc ON gc.zip_code_prefix = c.zip_code_prefix
LEFT JOIN dwd_geolocation gs ON gs.zip_code_prefix = s.zip_code_prefix;

-- 加上全部 CAST，但只 COUNT，不写表 —— 隔离出是不是类型转换的问题
SELECT COUNT(*) AS 转换后可插入行数
FROM ods_order_items i
LEFT JOIN dwd_products p  ON p.product_id = TRIM(i.product_id)
LEFT JOIN dwd_sellers  s  ON s.seller_id  = TRIM(i.seller_id)
JOIN      ods_orders   o  ON o.order_id   = TRIM(i.order_id)
LEFT JOIN dwd_customers c ON c.customer_id = TRIM(o.customer_id)
LEFT JOIN dwd_geolocation gc ON gc.zip_code_prefix = c.zip_code_prefix
LEFT JOIN dwd_geolocation gs ON gs.zip_code_prefix = s.zip_code_prefix
WHERE CAST(NULLIF(TRIM(i.order_item_id), '') AS UNSIGNED) IS NOT NULL
  AND STR_TO_DATE(REPLACE(TRIM(i.shipping_limit_date), '/', '-'), '%Y-%m-%d %H:%i:%s') IS NOT NULL;


-- ============================================================================
-- 八、【最可能的真凶】同一台 MySQL 上存在两份同名表
--
-- 症状特征（与实际情况完全吻合）：
--   · 你查的那份数据是干净的，执行时报错的值却是另一个
--   · 报错的值每次还不一样（上次 '2017-03-29 13:05:42'，这次 '2017-05-03 11:05:13'）
--     → 说明是在逐行扫描，撞到第一个坏行就停下
--   · 报错值是一个 shipping_limit_date，却被当成整数转换
--     → 像是整表列错位（日期落进了数字列的位置）
--   · 对象树里出现了两个 schema，各自都有 14 张表
--
-- 原因：控制台默认库 ≠ 表真正所在的库。
--   跑整份脚本时，脚本开头的 USE olist_dw; 会纠正；
--   但单独执行一段 SQL（不带动 USE）时，未限定库名的表名会解析到【当前默认库】。
--   于是「查 A 库、改 B 库」——数据永远看着是对的，执行永远报错。
--
-- 【根治办法】所有对象名都写全限定名，彻底杜绝歧义。
-- ============================================================================

-- 8.1 这台 MySQL 上到底有几份同名表 —— 同一个表名出现在两个库里，就是它
SELECT TABLE_SCHEMA    AS 所在库,
       TABLE_NAME      AS 表名,
       TABLE_ROWS      AS 约行数,
       TABLE_COLLATION AS 排序规则,
       CREATE_TIME     AS 建表时间
FROM information_schema.TABLES
WHERE TABLE_NAME IN ('ods_order_items','dwd_order_items','ods_orders','dwd_orders')
ORDER BY TABLE_NAME, TABLE_SCHEMA;

-- 8.2 当前控制台默认连的是哪个库（必须在执行 INSERT 的那个控制台里跑）
SELECT DATABASE() AS 当前库, @@collation_database AS 当前排序规则;

-- 8.3 把两份 ods_order_items 摆到一起对比（把 sql_name / olist_dw 换成 8.1 查出来的真实库名）
--     哪一份的「最长 order_item_id」是 19、或者合格行数明显偏少，哪一份就是脏的
SELECT 'olist_dw' AS 库名, COUNT(*) AS 行数,
       MAX(LENGTH(order_item_id))                       AS 最长order_item_id,
       SUM(TRIM(order_item_id) REGEXP '^[0-9]+$')       AS 合格行数
  FROM olist_dw.ods_order_items
UNION ALL
SELECT 'sql_name', COUNT(*),
       MAX(LENGTH(order_item_id)),
       SUM(TRIM(order_item_id) REGEXP '^[0-9]+$')
  FROM sql_name.ods_order_items;

-- 8.4 脏的那一份长什么样（把库名换成脏的那一个）
SELECT * FROM sql_name.ods_order_items LIMIT 5;


-- ============================================================================
-- 九、【全限定名版】dwd_order_items 的 INSERT —— 可直接替换原来的语句
-- 把库名 olist_dw 换成你实际的库名即可。这样写之后，无论控制台默认库是什么，
-- 都只会读到正确的那一份数据。
-- ============================================================================
INSERT INTO olist_dw.dwd_order_items
SELECT
  TRIM(i.order_id),
  CAST(NULLIF(TRIM(i.order_item_id), '')       AS UNSIGNED),
  TRIM(i.product_id),
  TRIM(i.seller_id),
  STR_TO_DATE(REPLACE(TRIM(i.shipping_limit_date), '/', '-'), '%Y-%m-%d %H:%i:%s'),
  CAST(NULLIF(TRIM(i.price), '')               AS DECIMAL(10,2)),
  CAST(NULLIF(TRIM(i.freight_value), '')       AS DECIMAL(10,2)),
  IFNULL(p.category_en, 'unknown') AS category_en,
  s.state,
  c.state,
  ROUND(6371 * ACOS(LEAST(1, GREATEST(-1,
      SIN(RADIANS(gc.lat)) * SIN(RADIANS(gs.lat))
    + COS(RADIANS(gc.lat)) * COS(RADIANS(gs.lat))
      * COS(RADIANS(gs.lng) - RADIANS(gc.lng))
  ))), 1)
FROM olist_dw.ods_order_items i
LEFT JOIN olist_dw.dwd_products p  ON p.product_id = TRIM(i.product_id)
LEFT JOIN olist_dw.dwd_sellers  s  ON s.seller_id  = TRIM(i.seller_id)
JOIN      olist_dw.ods_orders   o  ON o.order_id   = TRIM(i.order_id)
LEFT JOIN olist_dw.dwd_customers c ON c.customer_id = TRIM(o.customer_id)
LEFT JOIN olist_dw.dwd_geolocation gc ON gc.zip_code_prefix = c.zip_code_prefix
LEFT JOIN olist_dw.dwd_geolocation gs ON gs.zip_code_prefix = s.zip_code_prefix
WHERE TRIM(i.order_item_id) REGEXP '^[0-9]+$';


-- ============================================================================
-- 十、【终极二分】把问题一刀切开
--
-- 逻辑前提：
--   `CAST(NULLIF(TRIM(i.order_item_id), '') AS UNSIGNED)` 是这条 INSERT 里
--   【唯一】的整数转换；而它的源列已经被两次证明"最长只有 2 个字符、无非数字值"。
--   ⇒「源数据里有非数字值」和「这条语句报错」在逻辑上无法同时成立。
--   所以只剩两个出口：要么检查漏了行，要么报错的根本不是这条语句。
--   下面四步把这两种可能彻底分开。
-- ============================================================================

-- 10.1 【先补一个检查漏洞】单独把 NULL 行数数出来
--      为什么必须单独数：`WHERE NOT (col REGEXP '^[0-9]+$')` 在 col 为 NULL 时
--      结果是 NULL，而 WHERE 只接受 TRUE —— **NULL 行会被直接漏掉**。
--      所以隔离表返回 0 行，并不能证明"没有 NULL"。
SELECT
  COUNT(*)                                        AS 总行数,
  SUM(order_item_id IS NULL)                      AS 空值行数,
  MAX(LENGTH(order_item_id))                      AS 最长字符数,
  SUM(order_item_id NOT REGEXP '^[0-9]+$')        AS 非数字行数
FROM ods_order_items;
-- 若「空值行数」> 0 → 找到了：CAST(NULLIF(TRIM(NULL),'')) 得到 NULL，
--   写入 order_item_id INT NOT NULL 就会失败（这类问题会被上面的 WHERE 漏掉）。


-- 10.2 【决定性二分】只跑 SELECT，不写表 —— 报错就说明问题在"读"，不报错就说明在"写"
--      预期返回约 112,650。把整段单独选中执行。
SELECT COUNT(*) AS 应得行数 FROM (
  SELECT
    TRIM(i.order_id)                                                AS c_order_id,
    CAST(NULLIF(TRIM(i.order_item_id), '')       AS UNSIGNED)       AS c_order_item_id,
    TRIM(i.product_id)                                              AS c_product_id,
    TRIM(i.seller_id)                                               AS c_seller_id,
    STR_TO_DATE(REPLACE(TRIM(i.shipping_limit_date), '/', '-'), '%Y-%m-%d %H:%i:%s')       AS c_shipping_limit_ts,
    CAST(NULLIF(TRIM(i.price), '')               AS DECIMAL(10,2))  AS c_price,
    CAST(NULLIF(TRIM(i.freight_value), '')       AS DECIMAL(10,2))  AS c_freight_value,
    IFNULL(p.category_en, 'unknown')                                AS c_category_en,
    s.state                                                         AS c_seller_state,
    c.state                                                         AS c_customer_state,
    ROUND(6371 * ACOS(LEAST(1, GREATEST(-1,
        SIN(RADIANS(gc.lat)) * SIN(RADIANS(gs.lat))
      + COS(RADIANS(gc.lat)) * COS(RADIANS(gs.lat))
        * COS(RADIANS(gs.lng) - RADIANS(gc.lng))
    ))), 1)                                                         AS c_distance_km
  FROM ods_order_items i
  LEFT JOIN dwd_products p  ON p.product_id = TRIM(i.product_id)
  LEFT JOIN dwd_sellers  s  ON s.seller_id  = TRIM(i.seller_id)
  JOIN      ods_orders   o  ON o.order_id   = TRIM(i.order_id)
  LEFT JOIN dwd_customers c ON c.customer_id = TRIM(o.customer_id)
  LEFT JOIN dwd_geolocation gc ON gc.zip_code_prefix = c.zip_code_prefix
  LEFT JOIN dwd_geolocation gs ON gs.zip_code_prefix = s.zip_code_prefix
) t;
-- ① 报同样的错 → 问题在"读"，继续看 10.3
-- ② 正常返回行数 → 问题在"写"，去看 10.4


-- 10.3 若 10.2 报错：把 11 个表达式逐个换掉，找出到底哪一个是元凶
--      方法：先只保留第 1 列，再逐步加列，看加到第几列出错。
--      下面给出"只留前 2 列"的写法，按此模式往下加：
SELECT COUNT(*) FROM (
  SELECT
    TRIM(i.order_id)                                          AS c1,
    CAST(NULLIF(TRIM(i.order_item_id), '') AS UNSIGNED)       AS c2
  FROM ods_order_items i
) t;
-- 再逐步加入 c3…c11（把 10.2 的 SELECT 列表逐行往后放开），出错那一列就是元凶。


-- 10.4 若 10.2 通过：问题在目标表上 —— 必须看真实建表语句
SHOW CREATE TABLE dwd_order_items;
SHOW CREATE TABLE ods_order_items;
-- 重点核对三件事：
--   ① dwd_order_items 的列顺序是否与 SELECT 一一对应（数量必须都是 11）
--   ② order_item_id 的实际类型是否真的是 INT
--   ③ 是否存在意料之外的触发器、生成列或主键定义


-- 10.5 顺手一招：报错后立刻看警告明细，MySQL 往往会给出更具体的一句
SHOW WARNINGS;


-- ============================================================================
-- 十一、结案记录 + 验收
--
-- 【已确定】真正的触发点是这一行：
--     CAST(NULLIF(TRIM(i.shipping_limit_date), '') AS DATETIME),   ← 这个写法报错（原样保留作记录）
--   换成原样字符串就通过：
--     i.shipping_limit_date,                                       ← 通过
--   ⇒ 与 order_item_id 无关。报错信息写的 "Truncated incorrect INTEGER value"
--     是误导性的，别拿错误信息里的类型词当定位依据。
--
-- 【最终根因（见第十二节）】不是数据的问题，是 CAST(x AS DATETIME) 这个写法
--   在本机 MySQL 上根本不可用 —— 即使输入是完美的 ISO 值也一样报错。
--
-- 【已确定】ods_order_items.shipping_limit_date 里没有非法日期（实测 0 行）。
--   所以"数据里有坏日期"这个解释也不成立，具体机制未查明 —— 但触发点确定，不影响推进。
--
-- 【必须做的验收】原样字符串写进 DATETIME 列走的是 MySQL 的隐式转换，比显式 CAST 宽松，
--   非法值可能被静默转成 '0000-00-00 00:00:00'。所以必须回头确认放进来的是什么。
-- ============================================================================

-- 11.1 验收 dwd_order_items 的时间列
--      注意：不要写 shipping_limit_ts = '0000-00-00 00:00:00' ——
--      如果你的 sql_mode 带 NO_ZERO_DATE，这个【字面量】本身就非法，查询会报
--      [HY000][1525] Incorrect DATETIME value，那是 SQL 的问题，不是数据的问题。
--      正确做法：先转成字符串再比。
SELECT
  COUNT(*)                                                     AS 总行数,
  SUM(shipping_limit_ts IS NULL)                               AS NULL行数,
  SUM(LEFT(CAST(shipping_limit_ts AS CHAR), 4) = '0000')       AS 零值行数,
  MIN(CAST(shipping_limit_ts AS CHAR))                         AS 最早,
  MAX(CAST(shipping_limit_ts AS CHAR))                         AS 最晚
FROM dwd_order_items;

-- 11.2 顺手确认会话的 sql_mode —— 脚本里的 SET SESSION 只对【那一个会话】有效，
--      在 IDE 控制台分段执行时用的是服务器默认值，两者可能不一样。
SELECT @@SESSION.sql_mode AS 当前会话, @@GLOBAL.sql_mode AS 服务器默认;
-- MySQL 8.0 默认含 NO_ZERO_DATE / NO_ZERO_IN_DATE / ONLY_FULL_GROUP_BY；
-- 而 00 脚本里 SET 的是 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION'（不含前三个）。
-- 两边不一致时，同一段 SQL 在不同会话里可能表现不同 —— 这是很隐蔽的一类坑。


-- ============================================================================
-- 十二、【根因修正】不是 CAST 不支持 —— 是列值末尾有不可见的 \r
--
-- 先纠正一个错误结论：曾判断"本机 MySQL 不支持 CAST(x AS DATETIME)"。
-- 实测：SELECT CAST('2017-10-02 10:56:33' AS DATETIME);  →  正常返回 2017-10-02 10:56:33
-- （MySQL 8.0.46）。该结论不成立。
--
-- 真正的解释：**列值末尾带着不可见的回车符**，即实际值是 '2017-10-02 10:56:33\r'。
-- 三种写法对"尾部垃圾字符"的容忍度不同，正好解释了全部现象：
--   CAST(x AS DATETIME)          严格拒绝尾部多余字符   → 报错（类型词还错位成 INTEGER）
--   原样字符串写进 DATETIME 列    隐式转换宽松，忽略尾部  → 通过
--   STR_TO_DATE(x, '%Y-%m-%d ...') 解析完格式即停止，忽略尾部 → 通过
--
-- 而 MySQL 的 TRIM(x) 默认【只去空格】，去不掉 \r（要写 TRIM(TRAILING '\r' FROM x)），
-- 所以这个 \r 一路留到了 dwd 层。
--
-- 【上次为什么没复现出来 —— 这是本轮最该记住的方法论】
--   我给的复现语句是 CAST('2017-10-02 10:56:33' AS DATETIME)，用的是【干净字面量】，
--   里面没有 \r，当然跑得通。
--   ⇒ **最小复现必须用表里的真实值，不能用干净字面量。**
-- ============================================================================
SELECT VERSION() AS MySQL版本;

-- 用【真实数据】做最小复现 —— 这一条才有诊断价值
SELECT CAST((SELECT order_purchase_timestamp FROM ods_orders
             WHERE order_purchase_timestamp <> '' LIMIT 1) AS DATETIME) AS 真实值转DATETIME;

-- 对照：干净字面量一定通过，所以它复现不出问题
SELECT CAST('2017-10-02 10:56:33' AS DATETIME) AS 干净字面量;

-- 【照妖镜】标准 ISO 是 19 个字符，若带 \r 就会是 20
SELECT MAX(LENGTH(order_purchase_timestamp)) AS 最长字符数,
       SUM(LENGTH(order_purchase_timestamp) <> 19 AND order_purchase_timestamp <> '') AS 非19字符行数,
       SUM(order_purchase_timestamp LIKE '%\r') AS 尾带回车行数
FROM ods_orders;

-- 【修复】已在 01_dwd 开头加入「预处理」：先 REPLACE(x, '\r', '') 清干净再转换。
-- 记忆点：TRIM(x) 去不掉 \r，必须写 TRIM(TRAILING '\r' FROM x) 或 REPLACE(x, '\r', '')。
