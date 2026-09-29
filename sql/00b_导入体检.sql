-- ============================================================================
-- 00b_导入体检.sql
-- 作用：导完 CSV 立刻跑一遍，校验「每个字段的内容是否符合该列应有的形态」
--
-- 【为什么需要这个文件】
-- LOAD DATA 是按【位置】把 CSV 的列灌进表里的。如果 CSV 的实际列序和脚本里的
-- 列清单不一致，MySQL 不会报错——它照样导完，只是数据整体错位了。
-- 这类错误在导入阶段完全静默，直到你写 dwd 转换时才会以各种诡异的方式爆出来：
--   例如 "Truncated incorrect INTEGER value: '2017-03-29 13:05:42'"
--   意思就是「本该是数字的那一列里，存着一个日期」
--
-- 判定依据：Olist 的 ID 都是 32 位十六进制字符串，日期都是 'YYYY-MM-DD HH:MM:SS'
-- 跑完如果每张表的「异常行数」都接近 0，说明列没有错位。
-- ============================================================================

USE olist_dw;
SET NAMES utf8mb4;


-- ============================================================================
-- 一、一键总览：一眼看出哪张表错位了
-- 每张表挑一个「形态最鲜明」的列来验，异常行数非 0 就是出问题了
-- ============================================================================
SELECT 'ods_orders' AS 表名, 'order_status 应为纯小写字母' AS 检查列,
       (SELECT COUNT(*) FROM ods_orders) AS 总行数,
       (SELECT COUNT(*) FROM ods_orders WHERE order_status NOT REGEXP '^[a-z_]+$') AS 异常行数
UNION ALL
SELECT 'ods_order_items', 'order_item_id 应为纯数字（本次报错的就是它）',
       (SELECT COUNT(*) FROM ods_order_items),
       (SELECT COUNT(*) FROM ods_order_items WHERE order_item_id NOT REGEXP '^[0-9]+$')
UNION ALL
SELECT 'ods_order_payments', 'payment_sequential 应为纯数字',
       (SELECT COUNT(*) FROM ods_order_payments),
       (SELECT COUNT(*) FROM ods_order_payments WHERE payment_sequential NOT REGEXP '^[0-9]+$')
UNION ALL
SELECT 'ods_order_reviews', 'review_score 应为 1-5',
       (SELECT COUNT(*) FROM ods_order_reviews),
       (SELECT COUNT(*) FROM ods_order_reviews WHERE review_score NOT REGEXP '^[1-5]$')
UNION ALL
SELECT 'ods_customers', 'customer_unique_id 应为32位十六进制',
       (SELECT COUNT(*) FROM ods_customers),
       (SELECT COUNT(*) FROM ods_customers WHERE customer_unique_id NOT REGEXP '^[0-9a-f]{32}$')
UNION ALL
SELECT 'ods_products', 'product_id 应为32位十六进制',
       (SELECT COUNT(*) FROM ods_products),
       (SELECT COUNT(*) FROM ods_products WHERE product_id NOT REGEXP '^[0-9a-f]{32}$')
UNION ALL
SELECT 'ods_sellers', 'seller_id 应为32位十六进制',
       (SELECT COUNT(*) FROM ods_sellers),
       (SELECT COUNT(*) FROM ods_sellers WHERE seller_id NOT REGEXP '^[0-9a-f]{32}$')
UNION ALL
SELECT 'ods_geolocation', 'geolocation_lat 应为纬度数字',
       (SELECT COUNT(*) FROM ods_geolocation),
       (SELECT COUNT(*) FROM ods_geolocation WHERE geolocation_lat NOT REGEXP '^-?[0-9]+[.]?[0-9]*$')
UNION ALL
SELECT 'ods_product_category_name_translation', '英语品类名应为小写字母数字下划线',
       (SELECT COUNT(*) FROM ods_product_category_name_translation),
       (SELECT COUNT(*) FROM ods_product_category_name_translation
        WHERE product_category_name_english NOT REGEXP '^[a-z0-9_]+$');


-- ============================================================================
-- 二、细查 ods_order_items（本次报错的源头）
-- 七个列逐一验形态，能精确定位到底错位了几列
-- 说明：IF(col = '' OR col REGEXP '...', 0, 1) —— 空值或形态正确都算通过
-- ============================================================================
SELECT
  COUNT(*)                                                                   AS 总行数,
  SUM(IF(order_id            REGEXP '^[0-9a-f]{32}$', 0, 1))                  AS 坏_order_id,
  SUM(IF(order_item_id       REGEXP '^[0-9]+$', 0, 1))                       AS 坏_order_item_id,
  SUM(IF(product_id          REGEXP '^[0-9a-f]{32}$', 0, 1))                 AS 坏_product_id,
  SUM(IF(seller_id           REGEXP '^[0-9a-f]{32}$', 0, 1))                 AS 坏_seller_id,
  SUM(IF(shipping_limit_date REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$', 0, 1)) AS 坏_shipping_limit_date,
  SUM(IF(price               REGEXP '^[0-9]+[.]?[0-9]*$', 0, 1))             AS 坏_price,
  SUM(IF(freight_value       REGEXP '^[0-9]+[.]?[0-9]*$', 0, 1))             AS 坏_freight_value
FROM ods_order_items;

-- 直接看前 3 行原始内容，一眼就能看出错位了几列
SELECT * FROM ods_order_items LIMIT 3;

-- 结论判定
SELECT
  CASE
    WHEN (SELECT COUNT(*) FROM ods_order_items WHERE order_item_id NOT REGEXP '^[0-9]+$') = 0
      THEN '通过：ods_order_items 列没有错位，问题在别处'
    ELSE '不通过：ods_order_items 列错位 → 核对 CSV 表头，改 LOAD DATA 的列清单后重跑 00 脚本'
  END AS 结论;


-- ============================================================================
-- 三、细查 ods_orders（第二关键，时间列错位会毁掉全部履约分析）
-- ============================================================================
SELECT
  COUNT(*)                                                                   AS 总行数,
  SUM(IF(order_id       REGEXP '^[0-9a-f]{32}$', 0, 1))                      AS 坏_order_id,
  SUM(IF(customer_id    REGEXP '^[0-9a-f]{32}$', 0, 1))                      AS 坏_customer_id,
  SUM(IF(order_status   REGEXP '^[a-z_]+$', 0, 1))                           AS 坏_order_status,
  SUM(IF(order_purchase_timestamp REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$', 0, 1)) AS 坏_下单时间,
  SUM(IF(order_estimated_delivery_date REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$', 0, 1)) AS 坏_承诺送达时间
FROM ods_orders;


-- ============================================================================
-- 四、细查 ods_order_reviews（这条最容易被 CSV 里的引号/换行搞串行）
-- ============================================================================
SELECT
  COUNT(*)                                                       AS 总行数,
  SUM(IF(review_id  REGEXP '^[0-9a-f]{32}$', 0, 1))              AS 坏_review_id,
  SUM(IF(order_id   REGEXP '^[0-9a-f]{32}$', 0, 1))              AS 坏_order_id,
  SUM(IF(review_score REGEXP '^[1-5]$', 0, 1))                   AS 坏_review_score
FROM ods_order_reviews;

-- ============================================================================
-- 五、邮编前导 0 体检 —— 用 GUI 工具（DataGrip / Navicat / Excel）导入时最常见的静默错误
--
-- 把 '01037' 当成数字处理时会变成 1037，前导 0 就悄悄丢了。
-- 后果很严重：dwd_customers.zip_code_prefix 与 dwd_geolocation.zip_code_prefix
-- （都是 CHAR(5)）对不上 → distance_km 全部为 NULL → S3 的距离分析直接废掉。
-- 这就是 01_dwd 里对邮编做 LPAD(...,5,'0') 的原因，千万别去掉。
-- ============================================================================
SELECT
  MIN(LENGTH(customer_zip_code_prefix))        AS 客户邮编最短长度,
  MAX(LENGTH(customer_zip_code_prefix))        AS 客户邮编最长长度,
  SUM(LEFT(customer_zip_code_prefix, 1) = '0') AS 以0开头的客户邮编数
FROM ods_customers;

SELECT
  MIN(LENGTH(seller_zip_code_prefix))        AS 卖家邮编最短长度,
  MAX(LENGTH(seller_zip_code_prefix))        AS 卖家邮编最长长度,
  SUM(LEFT(seller_zip_code_prefix, 1) = '0') AS 以0开头的卖家邮编数
FROM ods_sellers;
-- 最长长度 = 5 且"以0开头"数量可观 → 前导 0 没丢
-- 最长长度 = 4，或最长 5 但"以0开头"为 0 → 前导 0 丢了，必须靠 dwd 层的 LPAD 补回来


-- ============================================================================
-- 六、NULL 体检 —— GUI 导入的列映射完整度 + 修补一个检查漏洞
--
-- 两个作用：
-- ① GUI 导入（DataGrip / Navicat 拖拽）是按【列名】匹配的。如果某列没映射上，
--    整列都是 NULL —— 这里一看就知道。
-- ② 修补体检脚本自身的漏洞：用 REGEXP 数"坏行"时会【静默跳过 NULL】，
--    因为 NOT (NULL REGEXP '...') = NULL，而 SUM() 忽略 NULL。
--    所以要单独把 NULL 行数数出来，否则脏数据会漏网。
-- ============================================================================
SELECT 'ods_order_items' AS 表名, COUNT(*) AS 总行数,
       SUM(order_id            IS NULL) AS 空_order_id,
       SUM(order_item_id       IS NULL) AS 空_order_item_id,
       SUM(product_id          IS NULL) AS 空_product_id,
       SUM(seller_id           IS NULL) AS 空_seller_id,
       SUM(shipping_limit_date IS NULL) AS 空_shipping_limit_date,
       SUM(price               IS NULL) AS 空_price,
       SUM(freight_value       IS NULL) AS 空_freight_value
FROM ods_order_items
UNION ALL
SELECT 'ods_orders', COUNT(*),
       SUM(order_id IS NULL), SUM(customer_id IS NULL), SUM(order_status IS NULL),
       SUM(order_purchase_timestamp IS NULL), SUM(order_approved_at IS NULL),
       SUM(order_delivered_customer_date IS NULL), SUM(order_estimated_delivery_date IS NULL)
FROM ods_orders;
-- 正常情况：只有「未送达订单的签收/审批时间」会有 NULL，其余列应为 0。
-- 如果某个「本不该为空」的列出现大量 NULL，就是导入时那列没映射上。


-- ============================================================================
-- 【修复指引】
-- 1) 先看 CSV 的第一行（表头），确认列顺序：
--      命令行：head -1 "D:/olist_data/olist_order_items_dataset.csv"
--      PowerShell：Get-Content "D:/olist_data/olist_order_items_dataset.csv" -TotalCount 1
-- 2) 如果表头顺序 ≠ 00 脚本里 LOAD DATA 的列清单，就按表头顺序重写列清单，
--    然后重跑 00 脚本里对应的那一条 LOAD DATA（表要先 TRUNCATE）。
-- 3) 如果是最坏情况——CSV 列名和官方完全不一样（比如下载了别人重排过的版本），
--    把表头发给我，我按实际列序重写整段导入脚本。
--
-- 【更推荐的做法：用脚本导入，不要用 GUI 拖拽】
--   GUI 导入有三个问题：① 不可复现（换台机器要重新手工点一遍，也没法写进 GitHub）
--   ② 前导 0 会被静默吞掉 ③ 列映射靠手工，容易漏。
--   00 脚本里的 LOAD DATA 一条命令搞定，可复现、可追溯 —— 这正是会看的「工程化」。
-- ============================================================================
