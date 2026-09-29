-- ============================================================================
-- 00c_列错位定位.sql
-- 用途：当出现 "Truncated incorrect INTEGER value: '2017-03-29 13:05:42'" 这类
--       「下游转换才暴露」的报错时，用它定位到底是哪张表、哪一列、哪几行出了错。
--
-- 【为什么前 3 行看着对，还是会报错】
-- LOAD DATA 按【位置】灌数据。如果只有某一行的字段数多一个/少一个，或者某个字段里
-- 混进了一个落单的双引号，就只会让【那一行】后面的字段整体错位。
-- 所以「前几行正确」只能证明列是【开头对齐】的，不能证明 11 万行都对。
-- ============================================================================

USE olist_dw;
SET NAMES utf8mb4;


-- ============================================================================
-- 一、ods_order_items 逐列形态统计：先看坏行数量级
-- 读法：
--   · 只有 坏_order_item_id 非 0，且数量很小（个位/几十）→ 少数脏行
--   · 坏_order_item_id 与 坏_shipping_limit_date 差不多、且都接近总行数 → 整表错位
--   · 坏_order_id 非 0 → 连第一列都错位了，问题更靠前
-- ============================================================================
SELECT
  COUNT(*)                                                             AS 总行数,
  SUM(IF(order_id            REGEXP '^[0-9a-f]{32}$', 0, 1))            AS 坏_order_id,
  SUM(IF(order_item_id       REGEXP '^[0-9]+$', 0, 1))                 AS 坏_order_item_id,
  SUM(IF(product_id          REGEXP '^[0-9a-f]{32}$', 0, 1))           AS 坏_product_id,
  SUM(IF(seller_id           REGEXP '^[0-9a-f]{32}$', 0, 1))           AS 坏_seller_id,
  SUM(IF(shipping_limit_date REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$', 0, 1)) AS 坏_shipping_limit_date,
  SUM(IF(price               REGEXP '^[0-9]+[.]?[0-9]*$', 0, 1))       AS 坏_price,
  SUM(IF(freight_value       REGEXP '^[0-9]+[.]?[0-9]*$', 0, 1))       AS 坏_freight_value
FROM ods_order_items;


-- ============================================================================
-- 二、把坏行原样拉出来看 —— 最关键的一步
-- 它长什么样，直接告诉你错位了几列、往哪个方向错
--   例：order_item_id 是日期、product_id 是数字 → 说明该行整体后移了一列
-- ============================================================================
SELECT * FROM ods_order_items
WHERE order_item_id NOT REGEXP '^[0-9]+$'
LIMIT 20;


-- ============================================================================
-- 三、直接搜报错里那个值，确认它落在哪一列
-- ============================================================================
SELECT 'ods_order_items.order_item_id' AS 列名, COUNT(*) AS 命中数
  FROM ods_order_items   WHERE order_item_id       = '2017-03-29 13:05:42'
UNION ALL
SELECT 'ods_order_items.shipping_limit_date', COUNT(*)
  FROM ods_order_items   WHERE shipping_limit_date = '2017-03-29 13:05:42'
UNION ALL
SELECT 'ods_order_payments.payment_installments', COUNT(*)
  FROM ods_order_payments WHERE payment_installments = '2017-03-29 13:05:42'
UNION ALL
SELECT 'ods_orders.order_purchase_timestamp', COUNT(*)
  FROM ods_orders        WHERE order_purchase_timestamp = '2017-03-29 13:05:42';
-- 哪一行命中数 > 0，就是那个值实际躺着的位置。


-- ============================================================================
-- 四、【定位到 CSV 第几行】给 ods 表临时加一个自增行号
-- ods 表是按位置灌进去的，加一列自增主键后，行号 ≈ CSV 行号 - 1（扣掉表头）
-- 注意：这是「通常」按导入顺序，不保证 100% 对应；只做定位线索用。
-- 跑过一次就够了，别重复跑（列已存在会报错）。
-- ============================================================================
ALTER TABLE ods_order_items ADD COLUMN src_row_id INT AUTO_INCREMENT PRIMARY KEY FIRST;

SELECT src_row_id AS 库内行号,
       src_row_id + 1 AS 对应CSV行号,
       order_id, order_item_id, product_id, seller_id, shipping_limit_date, price, freight_value
FROM ods_order_items
WHERE order_item_id NOT REGEXP '^[0-9]+$'
ORDER BY src_row_id
LIMIT 20;

-- 拿到 CSV 行号后，直接在文件里看那一行（把 12345 换成实际行号）：
--   命令行   ：sed -n '12345p' "D:/olist_data/olist_order_items_dataset.csv"
--   PowerShell：Get-Content "D:/olist_data/olist_order_items_dataset.csv" -TotalCount 12345 | Select-Object -Last 1


-- ============================================================================
-- 五、顺带排查另一个嫌疑人：ods_order_payments
-- payment_installments 也是被转成整数的列，如果这张表错位，会报一模一样的错
-- ============================================================================
SELECT
  COUNT(*)                                                          AS 总行数,
  SUM(IF(order_id             REGEXP '^[0-9a-f]{32}$', 0, 1))        AS 坏_order_id,
  SUM(IF(payment_sequential   REGEXP '^[0-9]+$', 0, 1))             AS 坏_payment_sequential,
  SUM(IF(payment_type         REGEXP '^[a-z_]+$', 0, 1))            AS 坏_payment_type,
  SUM(IF(payment_installments REGEXP '^[0-9]+$', 0, 1))             AS 坏_payment_installments,
  SUM(IF(payment_value        REGEXP '^[0-9]+[.]?[0-9]*$', 0, 1))   AS 坏_payment_value
FROM ods_order_payments;

SELECT * FROM ods_order_payments
WHERE payment_installments NOT REGEXP '^[0-9]+$'
LIMIT 20;


-- ============================================================================
-- 六、【若 ods_order_items 已被证明干净】按这个顺序继续查
-- 结论前提：ods_order_items 的 order_item_id 全部是纯数字（坏行 = 0），
--           那么 dwd_order_items 这条 INSERT 的唯一整数转换就不可能失败。
--           → 报错一定来自另外的地方，或者数据已经被修好过。
-- ============================================================================

-- 6.1 第一步：直接重跑那条 INSERT。源表已被证明干净，很可能直接通过。
--     （在 DataGrip 里选中 INSERT INTO dwd_order_items 整条语句单独执行）

-- 6.2 第二步：如果仍然报错，先做【行数对账】—— 这是"灌错文件"最快的判据
--     任何一张表行数对不上，就是它被灌了别的 CSV
SELECT 'ods_orders'                       AS 表名, COUNT(*) AS 实际行数, 99441   AS 应为 FROM ods_orders
UNION ALL SELECT 'ods_order_items',            COUNT(*), 112650  FROM ods_order_items
UNION ALL SELECT 'ods_order_payments',         COUNT(*), 103886  FROM ods_order_payments
UNION ALL SELECT 'ods_order_reviews',          COUNT(*), 99224   FROM ods_order_reviews
UNION ALL SELECT 'ods_customers',              COUNT(*), 99441   FROM ods_customers
UNION ALL SELECT 'ods_products',               COUNT(*), 32951   FROM ods_products
UNION ALL SELECT 'ods_sellers',                COUNT(*), 3095    FROM ods_sellers
UNION ALL SELECT 'ods_geolocation',            COUNT(*), 1000163 FROM ods_geolocation
UNION ALL SELECT 'ods_product_category_name_translation', COUNT(*), 71 FROM ods_product_category_name_translation;

-- 6.3 第三步：跨表形态体检，一次把剩下所有会触发同类报错的列验完
SELECT 'ods_order_payments.payment_installments' AS 列名, COUNT(*) AS 坏行 FROM ods_order_payments WHERE payment_installments NOT REGEXP '^[0-9]+$'
UNION ALL SELECT 'ods_order_payments.payment_sequential',   COUNT(*) FROM ods_order_payments WHERE payment_sequential   NOT REGEXP '^[0-9]+$'
UNION ALL SELECT 'ods_order_payments.payment_type',         COUNT(*) FROM ods_order_payments WHERE payment_type         NOT REGEXP '^[a-z_]+$'
UNION ALL SELECT 'ods_order_payments.order_id',             COUNT(*) FROM ods_order_payments WHERE order_id             NOT REGEXP '^[0-9a-f]{32}$'
UNION ALL SELECT 'ods_order_reviews.review_score',          COUNT(*) FROM ods_order_reviews  WHERE review_score         NOT REGEXP '^[1-5]$'
UNION ALL SELECT 'ods_order_reviews.order_id',              COUNT(*) FROM ods_order_reviews  WHERE order_id             NOT REGEXP '^[0-9a-f]{32}$'
UNION ALL SELECT 'ods_orders.order_id',                     COUNT(*) FROM ods_orders         WHERE order_id             NOT REGEXP '^[0-9a-f]{32}$'
UNION ALL SELECT 'ods_orders.customer_id',                  COUNT(*) FROM ods_orders         WHERE customer_id          NOT REGEXP '^[0-9a-f]{32}$'
UNION ALL SELECT 'ods_orders.order_status',                 COUNT(*) FROM ods_orders         WHERE order_status         NOT REGEXP '^[a-z_]+$'
UNION ALL SELECT 'ods_orders.order_purchase_timestamp',     COUNT(*) FROM ods_orders         WHERE order_purchase_timestamp NOT REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'
UNION ALL SELECT 'ods_customers.customer_unique_id',        COUNT(*) FROM ods_customers      WHERE customer_unique_id    NOT REGEXP '^[0-9a-f]{32}$'
UNION ALL SELECT 'ods_products.product_id',                 COUNT(*) FROM ods_products       WHERE product_id           NOT REGEXP '^[0-9a-f]{32}$'
UNION ALL SELECT 'ods_products.product_weight_g',           COUNT(*) FROM ods_products       WHERE product_weight_g <> '' AND product_weight_g NOT REGEXP '^[0-9]+$'
UNION ALL SELECT 'ods_sellers.seller_id',                   COUNT(*) FROM ods_sellers        WHERE seller_id            NOT REGEXP '^[0-9a-f]{32}$'
UNION ALL SELECT 'ods_geolocation.geolocation_lat',         COUNT(*) FROM ods_geolocation    WHERE geolocation_lat      NOT REGEXP '^-?[0-9]+[.]?[0-9]*$';

-- 【头号嫌疑：ods_order_payments】
--   在 01_dwd 里，payment_installments 会被转成整数：
--       MAX(CAST(NULLIF(TRIM(payment_installments), '') AS UNSIGNED))
--   如果 ods_order_payments 被误灌了 olist_orders_dataset.csv，列会这样错位：
--       第1列 order_id            ← orders.order_id              ✓ 看着正常
--       第2列 payment_sequential  ← orders.customer_id
--       第3列 payment_type        ← orders.order_status
--       第4列 payment_installments← orders.order_purchase_timestamp  ← 时间戳！报错就是它
--       第5列 payment_value       ← orders.order_approved_at
--   这正好能解释 "Truncated incorrect INTEGER value: '2017-03-29 13:05:42'"。
--   判据：ods_order_payments 行数变成 99441（而不是 103886）→ 确诊。


-- ============================================================================
-- 七、修复路径
--   情况 1：坏行很少（个位/几十行）
--           → CSV 本身有脏行。用第四节的 CSV 行号去看那一行原始内容；
--             因为这几行数据本身不完整，直接从 dwd 里排除即可，并在报告里写明清除了多少行。
--   情况 2：坏行 ≈ 总行数
--           → 整表列错位。核对 CSV 表头 vs 00 脚本的 LOAD DATA 列清单，改完 TRUNCATE 重导。
--   情况 3：行数对不上
--           → 灌错文件了。TRUNCATE 那张表，重跑 00 脚本里对应的那一条 LOAD DATA。
-- ============================================================================
