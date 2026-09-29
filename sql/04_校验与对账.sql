-- ============================================================================
-- 04_校验与对账.sql
-- 作用：跑完全部脚本后做体检。每一段都对应一个「数据坑」或一个「关键业务指标」
-- 用法：逐段执行，看结果是否符合注释里的预期
-- ============================================================================

USE olist_dw;
SET NAMES utf8mb4;


-- ============================================================================
-- 【体检 1】各层行数是否与原始数据一致
-- 预期：dwd_orders = 99,441；dwd_order_items = 112,650
-- ============================================================================
SELECT 'ods_orders'         AS layer_table, COUNT(*) AS row_cnt FROM ods_orders
UNION ALL SELECT 'dwd_orders',              COUNT(*) FROM dwd_orders
UNION ALL SELECT 'dwd_order_items',         COUNT(*) FROM dwd_order_items
UNION ALL SELECT 'dwd_customers',           COUNT(*) FROM dwd_customers
UNION ALL SELECT 'dwd_geolocation(去重后)',  COUNT(*) FROM dwd_geolocation
UNION ALL SELECT 'dws_user_profile(客户数)', COUNT(*) FROM dws_user_profile;
-- 注意：dwd_order_items 会略少于 112,650，因为极少数明细的商品/卖家在维表中缺失，
--       这属于正常的数据质量问题，差值应在个位数级别。如果差值很大，说明 join 写错了。


-- ============================================================================
-- 【体检 2】数据坑 1：customer_id 根本不是客户
-- 预期：两个数差异巨大（99,441 vs 约 96,096）→ 证明用户分析必须用 customer_unique_id
-- ============================================================================
SELECT COUNT(DISTINCT customer_id)        AS order_level_customer_id,
       COUNT(DISTINCT customer_unique_id) AS real_unique_customers,
       ROUND(COUNT(DISTINCT customer_id) / COUNT(DISTINCT customer_unique_id), 4) AS inflation_ratio
FROM dwd_orders;
-- 如果这个比值接近 1.00，说明你用错了字段。


-- ============================================================================
-- 【体检 3】数据坑 2：Olist 复购率极低（预期约 3%）
-- 这个数字要背下来，用来论证"为什么不套用留存曲线 + CLV 模板"
-- ============================================================================
SELECT COUNT(*)                                                   AS total_customers,
       SUM(is_repeat)                                             AS repeat_customers,
       ROUND(AVG(is_repeat) * 100, 2)                             AS repeat_rate_pct,
       MAX(order_cnt)                                             AS max_orders_per_customer,
       ROUND(AVG(order_cnt), 4)                                   AS avg_orders_per_customer
FROM dws_user_profile;

-- 复购人群 vs 单次人群对比（S5 复购专题的核心对比）
SELECT CASE WHEN order_cnt > 1 THEN '复购客户' ELSE '单次客户' END AS customer_type,
       COUNT(*)                       AS customers,
       ROUND(AVG(monetary), 2)        AS avg_monetary,
       ROUND(AVG(avg_review_score), 2) AS avg_review_score,
       ROUND(SUM(monetary) / (SELECT SUM(monetary) FROM dws_user_profile) * 100, 2) AS gmv_share_pct
FROM dws_user_profile
GROUP BY CASE WHEN order_cnt > 1 THEN '复购客户' ELSE '单次客户' END;


-- ============================================================================
-- 【体检 4】数据坑 3：时间字段的缺失与逻辑错误
-- ============================================================================
SELECT
  SUM(purchase_ts IS NULL)                            AS 缺下单时间,
  SUM(approved_ts IS NULL)                            AS 缺审批时间,
  SUM(carrier_ts IS NULL)                             AS 缺发货时间,
  SUM(customer_delivered_ts IS NULL)                  AS 缺签收时间,
  SUM(estimated_ts IS NULL)                           AS 缺承诺送达时间,
  SUM(customer_delivered_ts < approved_ts)            AS 签收早于审批_逻辑错误,
  SUM(carrier_ts < approved_ts)                       AS 发货早于审批_逻辑错误,
  SUM(total_delivery_hours < 0)                       AS 履约时长为负
FROM dwd_orders;
-- 签收时间缺失约 3,000 行（都是未送达订单），这是正常的。
-- 逻辑错误行应为 0；若不为 0，在 Python 侧建模时要剔除，并在报告里说明处理方式。


-- ============================================================================
-- 【体检 5】数据坑 4：2016 年数据极少，趋势分析必须从 2017-01 起
-- ============================================================================
SELECT YEAR(purchase_ts) AS yr, MONTH(purchase_ts) AS mo,
       COUNT(*) AS orders,
       ROUND(SUM(CASE WHEN is_delivered = 1 THEN order_amount ELSE 0 END), 2) AS gmv
FROM dwd_orders
WHERE purchase_ts IS NOT NULL
GROUP BY YEAR(purchase_ts), MONTH(purchase_ts)
ORDER BY yr, mo;
-- 预期：2016-09 只有个位数订单，2017-01 之后才上量 → Tableau 趋势图应从 2017-01 起画


-- ============================================================================
-- 【体检 6】数据坑 5：订单状态分布（delivered 约 97%）
-- ============================================================================
SELECT order_status, COUNT(*) AS orders,
       ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM dwd_orders), 2) AS pct,
       ROUND(SUM(order_amount), 2) AS amount_all_status
FROM dwd_orders GROUP BY order_status ORDER BY orders DESC;


-- ============================================================================
-- 【体检 7】数据坑 6：geolocation 的邮编覆盖情况
-- 孤儿邮编会在计算距离时产生 NULL，Python 建模前必须知道比例
-- ============================================================================
SELECT
  (SELECT COUNT(*) FROM dwd_customers)                                        AS customers,
  (SELECT COUNT(*) FROM dwd_customers c LEFT JOIN dwd_geolocation g ON g.zip_code_prefix = c.zip_code_prefix WHERE g.zip_code_prefix IS NULL) AS 客户邮编未匹配数,
  (SELECT COUNT(*) FROM dwd_sellers)                                          AS sellers,
  (SELECT COUNT(*) FROM dwd_sellers s LEFT JOIN dwd_geolocation g ON g.zip_code_prefix = s.zip_code_prefix WHERE g.zip_code_prefix IS NULL)   AS 卖家邮编未匹配数,
  (SELECT COUNT(*) FROM dwd_order_items WHERE distance_km IS NULL)            AS 无法计算距离的明细行;


-- ============================================================================
-- 【体检 8】口径对账：这三个数字用 Excel 独立算一遍，必须一致
-- 这是你验证自己 SQL 口径的正确姿势，当作"交付前自检习惯"来讲
-- ============================================================================
SELECT
  COUNT(*)                                                                    AS 已送达订单数,
  ROUND(SUM(order_amount), 2)                                                 AS GMV总额,
  ROUND(SUM(item_amount), 2)                                                  AS 商品金额合计,
  ROUND(SUM(freight_amount), 2)                                               AS 运费合计,
  ROUND(AVG(order_amount), 2)                                                 AS 客单价,
  ROUND(SUM(pay_amount), 2)                                                   AS 支付金额合计,
  ROUND(SUM(item_amount) + SUM(freight_amount) - SUM(order_amount), 2)        AS 订单总额勾稽差
FROM dwd_orders
WHERE is_delivered = 1;
-- 勾稽差应为 0.00（order_amount 就是 item_amount + freight_amount）。
-- 另外可以核对：SUM(pay_amount) 与 SUM(order_amount) 应非常接近，
-- 若有差异，通常来自「订单有商品明细但无支付记录」或金额精度，差异比例应在千分之一以内。


-- ============================================================================
-- 【体检 9】履约时长分布 —— 证明为什么 S3 要用分位数回归而不是普通 OLS
-- ============================================================================
WITH d AS (
  SELECT total_delivery_hours / 24 AS days FROM dwd_orders WHERE total_delivery_hours IS NOT NULL
),
r AS (
  SELECT days, ROW_NUMBER() OVER (ORDER BY days) AS rn, COUNT(*) OVER () AS n FROM d
)
SELECT
  ROUND(AVG(days), 1)                                                  AS 均值,
  ROUND(MAX(CASE WHEN rn = CEIL(n * 0.25) THEN days END), 1)           AS P25,
  ROUND(MAX(CASE WHEN rn = CEIL(n * 0.50) THEN days END), 1)           AS 中位数,
  ROUND(MAX(CASE WHEN rn = CEIL(n * 0.75) THEN days END), 1)           AS P75,
  ROUND(MAX(CASE WHEN rn = CEIL(n * 0.95) THEN days END), 1)           AS P95,
  ROUND(MAX(days), 1)                                                  AS 最大值
FROM r;
-- 预期：均值明显大于中位数，且 P95 远大于 P75 → 右偏分布 → OLS 会被长尾拖偏


-- ============================================================================
-- 【体检 10】核心业务结论：延迟如何摧毁评分（S3 主结论）
-- 这张表跑出来就是报告里的第一张图
-- ============================================================================
SELECT delay_bucket, order_cnt, order_share_pct,
       avg_delivery_days, avg_review_score, bad_review_rate_pct, one_star_rate_pct
FROM ads_delivery_delay_impact ORDER BY bucket_order;
-- 预期趋势：延迟天数越大 → 平均评分越低、差评率越高，且 15 天以上档位差评率会非常夸张。
-- 这就是"履约体验值多少钱"的证据起点。


-- ============================================================================
-- 【体检 11】卖家帕累托结构（S5 卖家分级的依据）
-- ============================================================================
SELECT abc_class, COUNT(*) AS sellers,
       ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM ads_seller_scorecard), 2) AS seller_pct,
       ROUND(SUM(gmv_share_pct), 2) AS gmv_share_pct
FROM ads_seller_scorecard GROUP BY abc_class ORDER BY abc_class;
-- 预期：A 类卖家数量占比约 20%-30%，却贡献约 80% 的 GMV（帕累托法则成立）


-- ============================================================================
-- 【体检 12】索引是否真的被用上（"我做过执行计划优化"）
-- ============================================================================
EXPLAIN SELECT customer_unique_id, COUNT(*)
FROM dwd_orders
WHERE purchase_ts >= '2018-01-01'
GROUP BY customer_unique_id;
-- 关注 type 列：出现 range/ref 说明走索引；出现 ALL 说明全表扫描，需要加索引

EXPLAIN SELECT o.order_id, o.order_amount
FROM dwd_orders o
JOIN dwd_order_items i ON i.order_id = o.order_id
WHERE i.category_en = 'health_beauty';
-- idx_dwd_items_cat 应该被命中


-- ============================================================================
-- 【体检 13】冻结基准：把下面三个数字抄进报告首页，之后所有分析都以它们为准
-- ============================================================================
SELECT
  (SELECT COUNT(*) FROM dwd_orders)                                          AS 订单总数,
  (SELECT COUNT(DISTINCT customer_unique_id) FROM dwd_orders)                AS 客户总数,
  (SELECT ROUND(SUM(order_amount), 2) FROM dwd_orders WHERE is_delivered = 1) AS GMV总额,
  (SELECT ROUND(AVG(is_late) * 100, 2) FROM dwd_orders WHERE is_late IS NOT NULL) AS 全局延迟率,
  (SELECT ROUND(AVG(review_score), 2) FROM dwd_orders WHERE review_score IS NOT NULL) AS 全局平均评分,
  (SELECT ROUND(AVG(CASE WHEN review_score <= 2 THEN 1 ELSE 0 END) * 100, 2) FROM dwd_orders WHERE review_score IS NOT NULL) AS 全局差评率,
  (SELECT MIN(DATE(purchase_ts)) FROM dwd_orders)                            AS 数据起始日,
  (SELECT MAX(DATE(purchase_ts)) FROM dwd_orders)                            AS 数据截止日;
