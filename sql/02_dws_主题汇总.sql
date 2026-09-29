-- ============================================================================
-- 02_dws_主题汇总.sql
-- 作用：把 dwd 明细汇总成 5 张主题表，供 ads 层与 Python 复用
-- 前置：已成功执行 01_dwd_清洗与宽表.sql
--
-- 【统一口径 —— 全项目必须一致，】
--   GMV        = SUM(order_amount) 且仅统计 order_status = 'delivered' 的订单
--                order_amount = 商品金额 + 运费
--   延迟        = 客户签收时间 > 承诺送达时间（未送达订单的 is_late 为 NULL，不计入延迟率分母）
--   客户        = customer_unique_id（绝不是 customer_id）
--   RFM 基准日  = 数据快照日，见下方 @base_date
-- ============================================================================

USE olist_dw;
SET NAMES utf8mb4;

-- RFM / 留存 的基准日：取最后下单日 + 1 天。
-- 注意：如果要让结果可复现（推荐），把下面这行改成硬编码，例如 SET @base_date := '2018-09-01';
SET @base_date := (SELECT DATE_ADD(DATE(MAX(purchase_ts)), INTERVAL 1 DAY) FROM dwd_orders);
SELECT @base_date AS rfm_base_date;


-- ============================================================================
-- 一、dws_daily_gmv：日粒度经营指标
-- ============================================================================
DROP TABLE IF EXISTS dws_daily_gmv;
CREATE TABLE dws_daily_gmv (
  stat_date           DATE        NOT NULL,
  order_cnt           INT         COMMENT '下单数(全部状态)',
  buyer_cnt           INT         COMMENT '下单客户数',
  item_cnt            INT         COMMENT '商品件数',
  gmv                 DECIMAL(14,2) COMMENT 'GMV(仅已送达)',
  gmv_all             DECIMAL(14,2) COMMENT 'GMV(含全部状态，口径对照用)',
  freight_amount      DECIMAL(14,2) COMMENT '运费合计',
  aov                 DECIMAL(10,2) COMMENT '客单价 = GMV / 已送达订单数',
  arpu                DECIMAL(10,2) COMMENT '人均消费 = GMV / 下单客户数',
  late_order_cnt      INT         COMMENT '延迟订单数',
  late_rate           DECIMAL(6,4) COMMENT '延迟率',
  avg_review_score    DECIMAL(4,2),
  avg_delivery_days   DECIMAL(8,1),
  PRIMARY KEY (stat_date)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='dws:日粒度经营指标';

INSERT INTO dws_daily_gmv
SELECT
  DATE(purchase_ts)                                                     AS stat_date,
  COUNT(*)                                                              AS order_cnt,
  COUNT(DISTINCT customer_unique_id)                                    AS buyer_cnt,
  SUM(item_cnt)                                                         AS item_cnt,
  ROUND(SUM(CASE WHEN is_delivered = 1 THEN order_amount ELSE 0 END), 2) AS gmv,
  ROUND(SUM(order_amount), 2)                                           AS gmv_all,
  ROUND(SUM(freight_amount), 2)                                         AS freight_amount,
  ROUND(SUM(CASE WHEN is_delivered = 1 THEN order_amount ELSE 0 END)
        / NULLIF(SUM(is_delivered), 0), 2)                              AS aov,
  ROUND(SUM(CASE WHEN is_delivered = 1 THEN order_amount ELSE 0 END)
        / NULLIF(COUNT(DISTINCT customer_unique_id), 0), 2)             AS arpu,
  SUM(CASE WHEN is_late = 1 THEN 1 ELSE 0 END)                          AS late_order_cnt,
  ROUND(AVG(is_late), 4)                                                AS late_rate,
  ROUND(AVG(review_score), 2)                                           AS avg_review_score,
  ROUND(AVG(total_delivery_hours) / 24, 1)                              AS avg_delivery_days
FROM dwd_orders
WHERE purchase_ts IS NOT NULL
GROUP BY DATE(purchase_ts);


-- ============================================================================
-- 二、dws_category_monthly：品类 × 月
-- 粒度：先把明细聚合到 (订单, 品类)，再关联订单属性，避免订单级字段被重复计数
-- ============================================================================
DROP TABLE IF EXISTS dws_category_monthly;
CREATE TABLE dws_category_monthly (
  stat_month          DATE        NOT NULL,
  category_en         VARCHAR(100) NOT NULL,
  order_cnt           INT,
  item_cnt            INT,
  product_cnt         INT,
  seller_cnt          INT,
  gmv                 DECIMAL(14,2) COMMENT '仅已送达：Σ(price+freight)',
  -- 下面三个 item_amount / freight_amount / freight_delivered 的口径不统一，是有意的，
  -- 用之前务必看清字段名：
  --   item_amount      = 全部状态（含 canceled/unavailable）
  --   freight_amount   = 全部状态
  --   freight_delivered= 仅已送达  ← 算比率必须用这个，不能和 gmv（仅已送达）混用
  item_amount         DECIMAL(14,2) COMMENT '件金额：全部状态',
  freight_amount      DECIMAL(14,2) COMMENT '运费：全部状态',
  freight_delivered   DECIMAL(14,2) COMMENT '运费：仅已送达',
  avg_item_price      DECIMAL(10,2) COMMENT '件均价=item_amount/item_cnt（全部状态，口径自洽）',
  freight_ratio       DECIMAL(6,4)  COMMENT '运费占GMV比例=freight_delivered/gmv（分子分母都仅已送达）',
  avg_review_score    DECIMAL(4,2),
  bad_review_rate     DECIMAL(6,4)  COMMENT '差评率(评分<=2)',
  late_rate           DECIMAL(6,4),
  avg_delivery_days   DECIMAL(8,1),
  avg_distance_km     DECIMAL(8,1),
  PRIMARY KEY (stat_month, category_en)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='dws:品类月度指标';

INSERT INTO dws_category_monthly
WITH oi AS (
  -- 明细与订单属性拼成一张宽表，后面按 (月, 品类) 分别做「明细级」和「订单级」两种聚合
  SELECT DATE(DATE_FORMAT(o.purchase_ts, '%Y-%m-01')) AS stat_month,
         i.category_en, o.order_id, o.is_delivered,
         i.product_id, i.seller_id, i.price, i.freight_value, i.distance_km,
         o.review_score, o.is_late, o.total_delivery_hours
  FROM dwd_order_items i
  JOIN dwd_orders o ON o.order_id = i.order_id
  WHERE o.purchase_ts IS NOT NULL
),
item_lvl AS (
  SELECT stat_month, category_en,
         COUNT(DISTINCT order_id)   AS order_cnt,
         COUNT(*)                   AS item_cnt,
         COUNT(DISTINCT product_id) AS product_cnt,
         COUNT(DISTINCT seller_id)  AS seller_cnt,
         ROUND(SUM(price), 2)         AS item_amount,
         ROUND(SUM(freight_value), 2) AS freight_amount,
         ROUND(SUM(CASE WHEN is_delivered = 1 THEN freight_value ELSE 0 END), 2) AS freight_delivered,
         ROUND(SUM(CASE WHEN is_delivered = 1 THEN price + freight_value ELSE 0 END), 2) AS gmv,
         ROUND(AVG(distance_km), 1)   AS avg_distance_km
  FROM oi
  GROUP BY stat_month, category_en
),
order_lvl AS (
  -- 订单级指标必须先按 (月, 品类, 订单) 去重再求平均，否则会被"一单多件"重复加权
  SELECT stat_month, category_en,
         ROUND(AVG(review_score), 2) AS avg_review_score,
         ROUND(AVG(CASE WHEN review_score <= 2 THEN 1 WHEN review_score IS NULL THEN NULL ELSE 0 END), 4) AS bad_review_rate,
         ROUND(AVG(is_late), 4) AS late_rate,
         ROUND(AVG(total_delivery_hours) / 24, 1) AS avg_delivery_days
  FROM (SELECT DISTINCT stat_month, category_en, order_id, review_score, is_late, total_delivery_hours FROM oi) d
  GROUP BY stat_month, category_en
)
SELECT
  i.stat_month,
  i.category_en,
  i.order_cnt,
  i.item_cnt,
  i.product_cnt,
  i.seller_cnt,
  i.gmv,
  i.item_amount,
  i.freight_amount,
  i.freight_delivered,
  ROUND(i.item_amount / NULLIF(i.item_cnt, 0), 2) AS avg_item_price,
  -- 【口径修正 2026-09-23】原来写成 i.freight_amount / i.gmv：
  -- 分子是「全部状态」运费，分母是「仅已送达」GMV，两边口径不一致，会系统性低估运费率。
  -- 现在改用 freight_delivered，分子分母统一为「仅已送达」。
  ROUND(i.freight_delivered / NULLIF(i.gmv, 0), 4) AS freight_ratio,
  o.avg_review_score,
  o.bad_review_rate,
  o.late_rate,
  o.avg_delivery_days,
  i.avg_distance_km
FROM item_lvl i
JOIN order_lvl o ON o.stat_month = i.stat_month AND o.category_en = i.category_en;


-- ============================================================================
-- 三、dws_seller_summary：卖家粒度记分卡（供 ABC 分级）
-- ============================================================================
DROP TABLE IF EXISTS dws_seller_summary;
CREATE TABLE dws_seller_summary (
  seller_id           VARCHAR(50) NOT NULL,
  seller_state        CHAR(2),
  first_sale_date     DATE,
  last_sale_date      DATE,
  active_months       INT         COMMENT '有成交的自然月数',
  order_cnt           INT,
  buyer_cnt           INT,
  item_cnt            INT,
  product_cnt         INT,
  gmv                 DECIMAL(14,2) COMMENT '仅已送达',
  avg_item_price      DECIMAL(10,2),
  avg_review_score    DECIMAL(4,2),
  bad_review_rate     DECIMAL(6,4),
  late_rate           DECIMAL(6,4),
  cancel_rate         DECIMAL(6,4),
  avg_delivery_days   DECIMAL(8,1),
  avg_distance_km     DECIMAL(8,1),
  PRIMARY KEY (seller_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='dws:卖家记分卡';

INSERT INTO dws_seller_summary
WITH so AS (
  -- 1 行 = 1 个卖家 × 1 个订单
  SELECT seller_id, order_id,
         COUNT(*)                     AS item_cnt,
         ROUND(SUM(price), 2)         AS item_amount,
         ROUND(SUM(freight_value), 2) AS freight_amount,
         ROUND(AVG(distance_km), 1)   AS avg_distance_km
  FROM dwd_order_items
  GROUP BY seller_id, order_id
),
prod AS (
  SELECT seller_id, COUNT(DISTINCT product_id) AS product_cnt
  FROM dwd_order_items GROUP BY seller_id
)
SELECT
  so.seller_id,
  MIN(sl.state)                                                          AS seller_state,
  DATE(MIN(o.purchase_ts))                                               AS first_sale_date,
  DATE(MAX(o.purchase_ts))                                               AS last_sale_date,
  COUNT(DISTINCT DATE_FORMAT(o.purchase_ts, '%Y-%m'))                    AS active_months,
  COUNT(*)                                                               AS order_cnt,
  COUNT(DISTINCT o.customer_unique_id)                                   AS buyer_cnt,
  SUM(so.item_cnt)                                                       AS item_cnt,
  MAX(p.product_cnt)                                                     AS product_cnt,
  ROUND(SUM(CASE WHEN o.is_delivered = 1 THEN so.item_amount + so.freight_amount ELSE 0 END), 2) AS gmv,
  ROUND(SUM(so.item_amount) / NULLIF(SUM(so.item_cnt), 0), 2)            AS avg_item_price,
  ROUND(AVG(o.review_score), 2)                                          AS avg_review_score,
  ROUND(AVG(CASE WHEN o.review_score <= 2 THEN 1 WHEN o.review_score IS NULL THEN NULL ELSE 0 END), 4) AS bad_review_rate,
  ROUND(AVG(o.is_late), 4)                                               AS late_rate,
  ROUND(AVG(CASE WHEN o.order_status = 'canceled' THEN 1 ELSE 0 END), 4) AS cancel_rate,
  ROUND(AVG(o.total_delivery_hours) / 24, 1)                             AS avg_delivery_days,
  ROUND(AVG(so.avg_distance_km), 1)                                      AS avg_distance_km
FROM so
JOIN dwd_orders  o  ON o.order_id   = so.order_id
JOIN dwd_sellers sl ON sl.seller_id = so.seller_id
JOIN prod        p  ON p.seller_id  = so.seller_id
GROUP BY so.seller_id;


-- ============================================================================
-- 四、dws_user_profile：客户画像 + RFM 打分（粒度 = customer_unique_id）
-- 注意：monetary 只统计已送达订单，与 GMV 口径保持一致
-- ============================================================================
DROP TABLE IF EXISTS dws_user_profile;
CREATE TABLE dws_user_profile (
  customer_unique_id  VARCHAR(50) NOT NULL,
  state               CHAR(2),
  first_order_date    DATE,
  last_order_date     DATE,
  recency_days        INT         COMMENT '距基准日天数，越小越近',
  order_cnt           INT,
  delivered_cnt       INT,
  canceled_cnt        INT,
  monetary            DECIMAL(14,2) COMMENT '累计 GMV(仅已送达)',
  avg_order_value     DECIMAL(10,2),
  avg_review_score    DECIMAL(4,2),
  is_repeat           TINYINT     COMMENT '是否复购',
  r_score             TINYINT     COMMENT 'R 分 1-5',
  f_score             TINYINT     COMMENT 'F 分 1-5',
  m_score             TINYINT     COMMENT 'M 分 1-5',
  rfm_score           VARCHAR(8)  COMMENT '如 555',
  rfm_segment         VARCHAR(20) COMMENT '八类人群标签',
  PRIMARY KEY (customer_unique_id),
  KEY idx_dws_user_seg (rfm_segment),
  KEY idx_dws_user_rfm (r_score, f_score, m_score)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='dws:客户画像与RFM';

INSERT INTO dws_user_profile
WITH base AS (
  SELECT
    customer_unique_id,
    MIN(customer_state)                                        AS state,
    DATE(MIN(purchase_ts))                                     AS first_order_date,
    DATE(MAX(purchase_ts))                                     AS last_order_date,
    COUNT(DISTINCT order_id)                                   AS order_cnt,
    SUM(CASE WHEN is_delivered = 1 THEN 1 ELSE 0 END)          AS delivered_cnt,
    SUM(CASE WHEN order_status = 'canceled' THEN 1 ELSE 0 END) AS canceled_cnt,
    ROUND(SUM(CASE WHEN is_delivered = 1 THEN order_amount ELSE 0 END), 2) AS monetary,
    ROUND(AVG(review_score), 2)                                AS avg_review_score
  FROM dwd_orders
  WHERE purchase_ts IS NOT NULL AND customer_unique_id IS NOT NULL
  GROUP BY customer_unique_id
),
scored AS (
  SELECT b.*,
         DATEDIFF(@base_date, last_order_date) AS recency_days,
         -- R：天数越小分越高，所以按 recency 升序分 5 档后取反
         6 - NTILE(5) OVER (ORDER BY DATEDIFF(@base_date, last_order_date) ASC, customer_unique_id) AS r_score,
         NTILE(5)     OVER (ORDER BY order_cnt ASC, customer_unique_id) AS f_score,
         NTILE(5)     OVER (ORDER BY monetary  ASC, customer_unique_id) AS m_score
  FROM base b
)
SELECT
  customer_unique_id, state, first_order_date, last_order_date, recency_days,
  order_cnt, delivered_cnt, canceled_cnt, monetary,
  ROUND(monetary / NULLIF(delivered_cnt, 0), 2) AS avg_order_value,
  avg_review_score,
  CASE WHEN order_cnt > 1 THEN 1 ELSE 0 END     AS is_repeat,
  r_score, f_score, m_score,
  CONCAT(r_score, f_score, m_score)             AS rfm_score,
  CASE
    WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4 THEN '重要价值客户'
    WHEN r_score >= 4 AND f_score <  4 AND m_score >= 4 THEN '重要发展客户'
    WHEN r_score <  4 AND f_score >= 4 AND m_score >= 4 THEN '重要保持客户'
    WHEN r_score <  4 AND f_score <  4 AND m_score >= 4 THEN '重要挽留客户'
    WHEN r_score >= 4 AND f_score >= 4 AND m_score <  4 THEN '一般价值客户'
    WHEN r_score >= 4 AND f_score <  4 AND m_score <  4 THEN '一般发展客户'
    WHEN r_score <  4 AND f_score >= 4 AND m_score <  4 THEN '一般保持客户'
    ELSE '一般挽留客户'
  END AS rfm_segment
FROM scored;


-- ============================================================================
-- 五、dws_cohort_retention：同期群留存矩阵（首购月 × 第 N 月）
-- 预警：Olist 是 marketplace，复购率仅约 3%，第 1 月之后的留存率会非常低。
--       这不是数据错误，正是 S5 复购专题要解释的现象。
-- ============================================================================
DROP TABLE IF EXISTS dws_cohort_retention;
CREATE TABLE dws_cohort_retention (
  cohort_month    DATE    NOT NULL COMMENT '首购月',
  month_index     INT     NOT NULL COMMENT '首购后第 N 月，0=当月',
  active_users    INT     COMMENT '该月有下单的客户数',
  cohort_size     INT     COMMENT '该同期群总人数',
  retention_rate  DECIMAL(8,4),
  PRIMARY KEY (cohort_month, month_index)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='dws:同期群留存矩阵';

INSERT INTO dws_cohort_retention (cohort_month, month_index, active_users, cohort_size, retention_rate)
WITH first_buy AS (
  SELECT customer_unique_id,
         DATE(DATE_FORMAT(MIN(purchase_ts), '%Y-%m-01')) AS cohort_month
  FROM dwd_orders
  WHERE purchase_ts IS NOT NULL AND customer_unique_id IS NOT NULL
  GROUP BY customer_unique_id
),
sizes AS (
  SELECT cohort_month, COUNT(*) AS cohort_size FROM first_buy GROUP BY cohort_month
),
act AS (
  SELECT DISTINCT customer_unique_id,
         DATE(DATE_FORMAT(purchase_ts, '%Y-%m-01')) AS act_month
  FROM dwd_orders
  WHERE purchase_ts IS NOT NULL AND customer_unique_id IS NOT NULL
),
grid AS (
  SELECT f.cohort_month,
         TIMESTAMPDIFF(MONTH, f.cohort_month, a.act_month) AS month_index,
         COUNT(DISTINCT a.customer_unique_id)              AS active_users
  FROM first_buy f
  JOIN act a ON a.customer_unique_id = f.customer_unique_id
  WHERE a.act_month >= f.cohort_month
  GROUP BY f.cohort_month, TIMESTAMPDIFF(MONTH, f.cohort_month, a.act_month)
)
SELECT g.cohort_month, g.month_index, g.active_users, s.cohort_size,
       ROUND(g.active_users / s.cohort_size, 4)
FROM grid g
JOIN sizes s ON s.cohort_month = g.cohort_month;


-- ============================================================================
-- 六、dws 层自检
-- ============================================================================
SELECT 'dws_daily_gmv'        AS table_name, COUNT(*) AS row_cnt FROM dws_daily_gmv
UNION ALL SELECT 'dws_category_monthly',  COUNT(*) FROM dws_category_monthly
UNION ALL SELECT 'dws_seller_summary',    COUNT(*) FROM dws_seller_summary
UNION ALL SELECT 'dws_user_profile',      COUNT(*) FROM dws_user_profile
UNION ALL SELECT 'dws_cohort_retention',  COUNT(*) FROM dws_cohort_retention;

-- 全局 GMV 与客户结构
SELECT
  COUNT(DISTINCT customer_unique_id) AS unique_customers,
  COUNT(DISTINCT customer_id)        AS order_level_customers,
  COUNT(*)                           AS orders,
  ROUND(SUM(CASE WHEN is_delivered = 1 THEN order_amount ELSE 0 END), 2) AS total_gmv,
  ROUND(AVG(is_late) * 100, 2)       AS late_rate_pct
FROM dwd_orders;

-- 复购率（预期 3% 左右 —— 该指标决定 S5 全部分析路径）
SELECT ROUND(AVG(is_repeat) * 100, 2) AS repeat_rate_pct,
       SUM(is_repeat)                 AS repeat_customers,
       COUNT(*)                       AS total_customers
FROM dws_user_profile;

-- RFM 人群结构
SELECT rfm_segment,
       COUNT(*)                        AS customers,
       ROUND(AVG(monetary), 2)         AS avg_monetary,
       ROUND(SUM(monetary), 2)         AS total_monetary,
       ROUND(SUM(monetary) / (SELECT SUM(monetary) FROM dws_user_profile) * 100, 2) AS monetary_share_pct
FROM dws_user_profile
GROUP BY rfm_segment
ORDER BY total_monetary DESC;
