-- ============================================================================
-- 04b_隐式转换验收.sql
-- 目的：验证「把原始字符串直接写进 DATETIME 列」（隐式转换，没有 CAST / STR_TO_DATE）
--       有没有静默产生错误数据。
--
-- 【为什么必须验这一项】
--   隐式转换（implicit conversion）和显式转换的行为差别很大：
--     · 显式 CAST(x AS DATETIME) / STR_TO_DATE(x, 格式) —— 严格：不合规就报错或拒收
--     · 隐式（把字符串直接塞进 DATETIME 列）        —— 宽松：不合规时【不报错】，
--         在非严格模式下会静默转成 '0000-00-00 00:00:00' 并只留一条 warning。
--   ⇒ 也就是说：INSERT 成功 ≠ 数据正确。必须回头验。
--
-- 【本脚本最核心的一招：双路径对账】
--   隐式转换 = 路径 A（MySQL 自己怎么理解这个字符串）
--   STR_TO_DATE 显式解析 = 路径 B（我们自己指定格式怎么理解）
--   两条路径必须得到【完全相同】的结果。任何一行不一致，就是隐式转换悄悄改了值。
--   这比"看看有没有 0000 年"强得多 —— 零值只是最明显的一种损坏，
--   截断、补零、错位都能被这个对账抓出来。
--
-- 【避坑提醒：不要用 '0000-00-00 00:00:00' 这个字面量去比对】
--   在当前 sql_mode 下（含 NO_ZERO_DATE），写成
--       WHERE ts = '0000-00-00 00:00:00'
--   查询会直接报 [HY000][1525] Incorrect DATETIME value，还没碰到数据就炸了。
--   正确做法是用【比较】而不是【等值】：
--       ts < '1000-01-01'          -- 零值必然小于任何合法日期
-- ============================================================================

USE olist_dw;
SET NAMES utf8mb4;


-- ============================================================================
-- 一、总览：一行看清有没有问题（先跑这个）
--     判定：三个「_零值」列和「异常早于2000」列必须全为 0；
--           「_空值」列需要和源数据里的空串数量一一对应（见第三节）
-- ============================================================================
SELECT
  COUNT(*) AS 订单总行数,

  -- 零值检测：零日期必然小于 '1000-01-01'
  SUM(purchase_ts           IS NOT NULL AND purchase_ts           < '1000-01-01') AS 下单_零值,
  SUM(approved_ts           IS NOT NULL AND approved_ts           < '1000-01-01') AS 审批_零值,
  SUM(carrier_ts            IS NOT NULL AND carrier_ts            < '1000-01-01') AS 发货_零值,
  SUM(customer_delivered_ts IS NOT NULL AND customer_delivered_ts < '1000-01-01') AS 签收_零值,
  SUM(estimated_ts          IS NOT NULL AND estimated_ts          < '1000-01-01') AS 承诺_零值,

  -- 空值检测（要和源数据的空串数对得上）
  SUM(purchase_ts           IS NULL) AS 下单_空值,
  SUM(approved_ts           IS NULL) AS 审批_空值,
  SUM(carrier_ts            IS NULL) AS 发货_空值,
  SUM(customer_delivered_ts IS NULL) AS 签收_空值,
  SUM(estimated_ts          IS NULL) AS 承诺_空值,

  -- 范围检测：Olist 数据实际只覆盖 2016-09 ~ 2018-10
  SUM(purchase_ts IS NOT NULL AND (purchase_ts < '2016-01-01' OR purchase_ts > '2018-12-31')) AS 下单时间越界,

  -- 派生列有没有被污染
  SUM(total_delivery_hours < 0)          AS 履约时长负数,
  SUM(total_delivery_hours > 24 * 365)   AS 履约超过一年
FROM dwd_orders;


-- ============================================================================
-- 二、逐列体检（长表形式，哪一列出问题一眼看得出来）
-- ============================================================================
SELECT 字段, 空值行数, 零值行数, 最早, 最晚
FROM (
  SELECT 'purchase_ts'           AS 字段, SUM(purchase_ts           IS NULL) AS 空值行数,
         SUM(purchase_ts IS NOT NULL AND purchase_ts < '1000-01-01') AS 零值行数,
         CAST(MIN(purchase_ts)           AS CHAR) AS 最早, CAST(MAX(purchase_ts)           AS CHAR) AS 最晚 FROM dwd_orders
  UNION ALL
  SELECT 'approved_ts',                  SUM(approved_ts           IS NULL),
         SUM(approved_ts IS NOT NULL AND approved_ts < '1000-01-01'),
         CAST(MIN(approved_ts)           AS CHAR), CAST(MAX(approved_ts)           AS CHAR) FROM dwd_orders
  UNION ALL
  SELECT 'carrier_ts',                   SUM(carrier_ts            IS NULL),
         SUM(carrier_ts IS NOT NULL AND carrier_ts < '1000-01-01'),
         CAST(MIN(carrier_ts)            AS CHAR), CAST(MAX(carrier_ts)            AS CHAR) FROM dwd_orders
  UNION ALL
  SELECT 'customer_delivered_ts',        SUM(customer_delivered_ts IS NULL),
         SUM(customer_delivered_ts IS NOT NULL AND customer_delivered_ts < '1000-01-01'),
         CAST(MIN(customer_delivered_ts) AS CHAR), CAST(MAX(customer_delivered_ts) AS CHAR) FROM dwd_orders
  UNION ALL
  SELECT 'estimated_ts',                 SUM(estimated_ts          IS NULL),
         SUM(estimated_ts IS NOT NULL AND estimated_ts < '1000-01-01'),
         CAST(MIN(estimated_ts)          AS CHAR), CAST(MAX(estimated_ts)          AS CHAR) FROM dwd_orders
) t;

-- 年份分布（正常应只有 2016 / 2017 / 2018；出现 0000 或 1970 就是坏了）
SELECT YEAR(purchase_ts) AS 下单年份, COUNT(*) AS 订单数
FROM dwd_orders
GROUP BY YEAR(purchase_ts)
ORDER BY 下单年份;


-- ============================================================================
-- 三、与源数据对账：源里的非空串，必须一根不少地落成非空 DATETIME
--     「差」列 = 落库非空 − 源非空。只要是负数，就有值在转换时丢了。
-- ============================================================================
SELECT 字段, 源非空行数, 落库非空行数, 落库非空行数 - 源非空行数 AS 差
FROM (
  SELECT 'dwd_orders.purchase_ts' AS 字段,
         (SELECT COUNT(*) FROM ods_orders WHERE IFNULL(TRIM(order_purchase_timestamp), '') <> '')           AS 源非空行数,
         (SELECT COUNT(purchase_ts) FROM dwd_orders)                                                       AS 落库非空行数
  UNION ALL
  SELECT 'dwd_orders.approved_ts',
         (SELECT COUNT(*) FROM ods_orders WHERE IFNULL(TRIM(order_approved_at), '') <> ''),
         (SELECT COUNT(approved_ts) FROM dwd_orders)
  UNION ALL
  SELECT 'dwd_orders.carrier_ts',
         (SELECT COUNT(*) FROM ods_orders WHERE IFNULL(TRIM(order_delivered_carrier_date), '') <> ''),
         (SELECT COUNT(carrier_ts) FROM dwd_orders)
  UNION ALL
  SELECT 'dwd_orders.customer_delivered_ts',
         (SELECT COUNT(*) FROM ods_orders WHERE IFNULL(TRIM(order_delivered_customer_date), '') <> ''),
         (SELECT COUNT(customer_delivered_ts) FROM dwd_orders)
  UNION ALL
  SELECT 'dwd_orders.estimated_ts',
         (SELECT COUNT(*) FROM ods_orders WHERE IFNULL(TRIM(order_estimated_delivery_date), '') <> ''),
         (SELECT COUNT(estimated_ts) FROM dwd_orders)
  UNION ALL
  SELECT 'dwd_order_items.shipping_limit_ts',
         (SELECT COUNT(*) FROM ods_order_items WHERE IFNULL(TRIM(shipping_limit_date), '') <> ''),
         (SELECT COUNT(shipping_limit_ts) FROM dwd_order_items)
) t;

-- 【注意】上面刻意用 IFNULL(TRIM(col),'') <> '' 而不是 TRIM(col) <> ''。
--   原因：col 为 NULL 时，TRIM(NULL) <> '' 得到 NULL，COUNT 会【静默忽略】这一行，
--   于是"源非空行数"被少算 —— 一次假的对账通过。这个 NULL 漏检的坑本项目已经踩过一次。


-- ============================================================================
-- 四、【核心】双路径对账：隐式转换 vs STR_TO_DATE 显式解析
--     路径 A = 落库值（MySQL 隐式转换的结果）
--     路径 B = 用 STR_TO_DATE 按显式格式重新解析源字符串
--     A 必须恒等于 B。所有不等甚至为 NULL 的行，都是隐式转换动了手脚。
--     判定：「不一致_需查」必须为 0。
-- ============================================================================
SELECT 字段, 源非空行数, 落库非空行数, 双路径一致行数, 不一致_需查
FROM (
  SELECT 'purchase_ts' AS 字段,
         COUNT(*) AS 源非空行数,
         SUM(d.purchase_ts IS NOT NULL) AS 落库非空行数,
         SUM(d.purchase_ts IS NOT NULL
             AND d.purchase_ts = STR_TO_DATE(REPLACE(TRIM(o.order_purchase_timestamp), '/', '-'), '%Y-%m-%d %H:%i:%s')) AS 双路径一致行数,
         SUM(CASE WHEN d.purchase_ts IS NULL THEN 1
                  WHEN d.purchase_ts = STR_TO_DATE(REPLACE(TRIM(o.order_purchase_timestamp), '/', '-'), '%Y-%m-%d %H:%i:%s') THEN 0
                  ELSE 1 END) AS 不一致_需查
  FROM ods_orders o JOIN dwd_orders d ON d.order_id = TRIM(o.order_id)
  WHERE IFNULL(TRIM(o.order_purchase_timestamp), '') <> ''
  UNION ALL
  SELECT 'approved_ts', COUNT(*), SUM(d.approved_ts IS NOT NULL),
         SUM(d.approved_ts IS NOT NULL
             AND d.approved_ts = STR_TO_DATE(REPLACE(TRIM(o.order_approved_at), '/', '-'), '%Y-%m-%d %H:%i:%s')),
         SUM(CASE WHEN d.approved_ts IS NULL THEN 1
                  WHEN d.approved_ts = STR_TO_DATE(REPLACE(TRIM(o.order_approved_at), '/', '-'), '%Y-%m-%d %H:%i:%s') THEN 0
                  ELSE 1 END)
  FROM ods_orders o JOIN dwd_orders d ON d.order_id = TRIM(o.order_id)
  WHERE IFNULL(TRIM(o.order_approved_at), '') <> ''
  UNION ALL
  SELECT 'carrier_ts', COUNT(*), SUM(d.carrier_ts IS NOT NULL),
         SUM(d.carrier_ts IS NOT NULL
             AND d.carrier_ts = STR_TO_DATE(REPLACE(TRIM(o.order_delivered_carrier_date), '/', '-'), '%Y-%m-%d %H:%i:%s')),
         SUM(CASE WHEN d.carrier_ts IS NULL THEN 1
                  WHEN d.carrier_ts = STR_TO_DATE(REPLACE(TRIM(o.order_delivered_carrier_date), '/', '-'), '%Y-%m-%d %H:%i:%s') THEN 0
                  ELSE 1 END)
  FROM ods_orders o JOIN dwd_orders d ON d.order_id = TRIM(o.order_id)
  WHERE IFNULL(TRIM(o.order_delivered_carrier_date), '') <> ''
  UNION ALL
  SELECT 'customer_delivered_ts', COUNT(*), SUM(d.customer_delivered_ts IS NOT NULL),
         SUM(d.customer_delivered_ts IS NOT NULL
             AND d.customer_delivered_ts = STR_TO_DATE(REPLACE(TRIM(o.order_delivered_customer_date), '/', '-'), '%Y-%m-%d %H:%i:%s')),
         SUM(CASE WHEN d.customer_delivered_ts IS NULL THEN 1
                  WHEN d.customer_delivered_ts = STR_TO_DATE(REPLACE(TRIM(o.order_delivered_customer_date), '/', '-'), '%Y-%m-%d %H:%i:%s') THEN 0
                  ELSE 1 END)
  FROM ods_orders o JOIN dwd_orders d ON d.order_id = TRIM(o.order_id)
  WHERE IFNULL(TRIM(o.order_delivered_customer_date), '') <> ''
  UNION ALL
  SELECT 'estimated_ts', COUNT(*), SUM(d.estimated_ts IS NOT NULL),
         SUM(d.estimated_ts IS NOT NULL
             AND d.estimated_ts = STR_TO_DATE(REPLACE(TRIM(o.order_estimated_delivery_date), '/', '-'), '%Y-%m-%d %H:%i:%s')),
         SUM(CASE WHEN d.estimated_ts IS NULL THEN 1
                  WHEN d.estimated_ts = STR_TO_DATE(REPLACE(TRIM(o.order_estimated_delivery_date), '/', '-'), '%Y-%m-%d %H:%i:%s') THEN 0
                  ELSE 1 END)
  FROM ods_orders o JOIN dwd_orders d ON d.order_id = TRIM(o.order_id)
  WHERE IFNULL(TRIM(o.order_estimated_delivery_date), '') <> ''
) t;


-- ============================================================================
-- 五、逻辑自洽：时间必须单调递增，派生列必须能被重算出来
--     这些检查抓的是「转换没报错、但值被悄悄改了」的另一类痕迹。
--     全为 0 才是正常。
-- ============================================================================
SELECT
  SUM(approved_ts           IS NOT NULL AND approved_ts           < purchase_ts)             AS 审批早于下单,
  SUM(carrier_ts            IS NOT NULL AND approved_ts  IS NOT NULL
      AND carrier_ts        < approved_ts)                                                   AS 发货早于审批,
  SUM(customer_delivered_ts IS NOT NULL AND carrier_ts   IS NOT NULL
      AND customer_delivered_ts < carrier_ts)                                                AS 签收早于发货,
  SUM(customer_delivered_ts IS NOT NULL AND customer_delivered_ts < purchase_ts)             AS 签收早于下单,
  SUM(estimated_ts          IS NOT NULL AND estimated_ts          < purchase_ts)             AS 承诺送达早于下单,
  -- 派生时长能不能被重算出来（重算不一致 = 源时间戳被改过）
  SUM(total_delivery_hours IS NOT NULL
      AND total_delivery_hours <> TIMESTAMPDIFF(HOUR, purchase_ts, customer_delivered_ts))    AS 履约时长重算不符,
  SUM(is_late IS NOT NULL
      AND is_late <> (customer_delivered_ts > estimated_ts))                                 AS 延迟标记重算不符
FROM dwd_orders;


-- ============================================================================
-- 六、dwd_order_items.shipping_limit_ts 同样验一遍
-- ============================================================================
SELECT
  COUNT(*)                                                                   AS 明细总行数,
  SUM(shipping_limit_ts IS NULL)                                             AS 空值行数,
  SUM(shipping_limit_ts IS NOT NULL AND shipping_limit_ts < '1000-01-01')     AS 零值行数,
  SUM(shipping_limit_ts IS NOT NULL
      AND (shipping_limit_ts < '2016-01-01' OR shipping_limit_ts > '2019-12-31')) AS 时间越界,
  CAST(MIN(shipping_limit_ts) AS CHAR) AS 最早,
  CAST(MAX(shipping_limit_ts) AS CHAR) AS 最晚
FROM dwd_order_items;

-- 双路径对账（明细表）
SELECT
  COUNT(*) AS 源非空行数,
  SUM(d.shipping_limit_ts IS NOT NULL) AS 落库非空行数,
  SUM(d.shipping_limit_ts IS NOT NULL
      AND d.shipping_limit_ts = STR_TO_DATE(REPLACE(TRIM(i.shipping_limit_date), '/', '-'), '%Y-%m-%d %H:%i:%s')) AS 双路径一致行数,
  SUM(CASE WHEN d.shipping_limit_ts IS NULL THEN 1
           WHEN d.shipping_limit_ts = STR_TO_DATE(REPLACE(TRIM(i.shipping_limit_date), '/', '-'), '%Y-%m-%d %H:%i:%s') THEN 0
           ELSE 1 END) AS 不一致_需查
FROM ods_order_items i
JOIN dwd_order_items d ON d.order_id = TRIM(i.order_id)
                      AND d.order_item_id = CAST(NULLIF(TRIM(i.order_item_id), '') AS UNSIGNED)
WHERE IFNULL(TRIM(i.shipping_limit_date), '') <> '';


-- ============================================================================
-- 七、可疑行并排打印：源字符串 ↔ 落库值，肉眼看一眼就定案
-- ============================================================================
SELECT
  o.order_id,
  o.order_purchase_timestamp           AS 源_下单,          d.purchase_ts           AS dwd_下单,
  o.order_approved_at                  AS 源_审批,          d.approved_ts           AS dwd_审批,
  o.order_delivered_carrier_date       AS 源_发货,          d.carrier_ts            AS dwd_发货,
  o.order_delivered_customer_date      AS 源_签收,          d.customer_delivered_ts AS dwd_签收,
  o.order_estimated_delivery_date      AS 源_承诺,          d.estimated_ts          AS dwd_承诺
FROM ods_orders o
JOIN dwd_orders d ON d.order_id = TRIM(o.order_id)
WHERE
     (IFNULL(TRIM(o.order_purchase_timestamp), '')           <> '' AND d.purchase_ts           IS NULL)
  OR (IFNULL(TRIM(o.order_approved_at), '')                  <> '' AND d.approved_ts           IS NULL)
  OR (IFNULL(TRIM(o.order_delivered_carrier_date), '')       <> '' AND d.carrier_ts            IS NULL)
  OR (IFNULL(TRIM(o.order_delivered_customer_date), '')      <> '' AND d.customer_delivered_ts IS NULL)
  OR (IFNULL(TRIM(o.order_estimated_delivery_date), '')      <> '' AND d.estimated_ts          IS NULL)
LIMIT 50;

-- 反向：源里本来就是空的，落库却有了值（说明列映射错位过）
SELECT o.order_id,
       o.order_purchase_timestamp AS 源_下单, d.purchase_ts AS dwd_下单,
       o.order_approved_at        AS 源_审批, d.approved_ts AS dwd_审批
FROM ods_orders o
JOIN dwd_orders d ON d.order_id = TRIM(o.order_id)
WHERE (IFNULL(TRIM(o.order_purchase_timestamp), '') = '' AND d.purchase_ts IS NOT NULL)
   OR (IFNULL(TRIM(o.order_approved_at), '')        = '' AND d.approved_ts IS NOT NULL)
LIMIT 50;


-- ============================================================================
-- 八、环境侧的两个旁证（不是数据检查，是帮我们判断"理论上会不会坏"）
-- ============================================================================
SELECT
  @@SESSION.sql_mode                                    AS 当前会话sql_mode,
  @@SESSION.sql_mode LIKE '%STRICT_TRANS_TABLES%'       AS 是否严格模式,
  @@SESSION.sql_mode LIKE '%NO_ZERO_DATE%'              AS 是否禁止零日期,
  @@SESSION.sql_mode LIKE '%NO_ZERO_IN_DATE%'           AS 是否禁止零月日;
-- 读法：严格模式开着 + 上面 0 零值 ⇒ 双保险，可以放心。
--       严格模式没开 + 零值为 0 ⇒ 结果可信，但要靠数据本身保证，不能靠数据库兜底。
--
-- 补充：INSERT 执行完立刻跑 SHOW WARNINGS; 如果返回 > 0 条，
--       说明隐式转换当时是靠 warning 糊过去的（不是干净通过），务必对照本脚本逐条查。


-- ============================================================================
-- 九、通用模板：换表名 / 换列名就能套到任何「隐式转换过的列」上
-- ----------------------------------------------------------------------------
-- 把 3 个占位符换掉即可：
--   <库>.<目标表>      转换后的表
--   <日期列>           目标表里的 DATETIME 列
--   <源表> / <源列>    对应的 ods 源表与源列
--   <连接键>           两表关联字段
-- ----------------------------------------------------------------------------
-- SELECT
--   COUNT(*)                                                    AS 源非空行数,
--   SUM(d.<日期列> IS NOT NULL)                                  AS 落库非空,
--   SUM(d.<日期列> IS NOT NULL AND d.<日期列> < '1000-01-01')     AS 零值,
--   SUM(d.<日期列> IS NOT NULL
--       AND d.<日期列> = STR_TO_DATE(REPLACE(TRIM(o.<源列>), '/', '-'), '%Y-%m-%d %H:%i:%s')) AS 双路径一致,
--   SUM(CASE WHEN d.<日期列> IS NULL THEN 1
--            WHEN d.<日期列> = STR_TO_DATE(REPLACE(TRIM(o.<源列>), '/', '-'), '%Y-%m-%d %H:%i:%s') THEN 0
--            ELSE 1 END)                                       AS 不一致_需查,
--   SUM(d.<日期列> IS NOT NULL
--       AND (d.<日期列> < '1900-01-01' OR d.<日期列> > '2100-01-01')) AS 越界
-- FROM <源表> o JOIN <目标表> d ON d.<连接键> = TRIM(o.<连接键>)
-- WHERE IFNULL(TRIM(o.<源列>), '') <> '';
-- ----------------------------------------------------------------------------
-- 判定口径：不一致_需查 = 0 且 零值 = 0 ⇒ 隐式转换干净可用。
--           只要有一个不为 0，就把第七节的并排查询结果发出来，我们按行处理。
-- ============================================================================


-- ============================================================================
-- 十、如果查出问题，怎么修
--   ① 单表修复（不用重导数据）：把出问题的表换成显式转换版重跑即可 ——
--      DELETE FROM dwd_orders;  然后执行 01_dwd 里 STR_TO_DATE 版本的 INSERT；
--      （01_dwd 的 dwd_orders/dwd_order_items 已经是 STR_TO_DATE 版，直接复用）
--   ② 治本：不要依赖隐式转换。转换一律写明格式：
--      CASE WHEN TRIM(x) REGEXP '^[0-9]{4}[-/][0-9]{1,2}[-/][0-9]{1,2} [0-9]{1,2}:[0-9]{2}(:[0-9]{2})?$'
--           THEN STR_TO_DATE(REPLACE(TRIM(x), '/', '-'), '%Y-%m-%d %H:%i:%s')
--           ELSE NULL END
--   ③ 把本节第五节（逻辑自洽）与第四节（双路径对账）纳入固定验收流程 ——
--      "转换不报错"和"转换正确"是两件事。
-- ============================================================================
