-- ============================================================================
-- 03_ads_看板结果表.sql
-- 作用：产出 Tableau 直连的 ads 层结果表。Tableau 只读这一层，不碰原始表
-- 前置：已成功执行 02_dws_主题汇总.sql
--
-- 【重要】本文件分两类表：
--   A. 由 SQL 建表并填充 —— 纯聚合类指标（GMV、履约、分层、四象限、记分卡）
--   B. 由 SQL 只建结构、Python 回写 —— 需要统计推断/模型的部分：
--        ads_gmv_decomposition   LMDI 归因分解 + 置信区间（S2）
--        ads_order_risk          差评风险预测（S4）
--        ads_experiment_result   PSM/DID 效应估计（S6）
--      这样分工的理由：SQL 算不出 p 值和置信区间，硬凑就是错的。
-- ============================================================================

USE olist_dw;
SET NAMES utf8mb4;

-- ============================================================================
-- 零、静态维度：巴西州 → 州名 + 大区（供 Tableau 地图使用）
-- ============================================================================
DROP TABLE IF EXISTS dim_brazil_state;
CREATE TABLE dim_brazil_state (
  state      CHAR(2)     NOT NULL,
  state_name VARCHAR(50) COMMENT '州全名（Tableau 地图识别用）',
  region     VARCHAR(20) COMMENT '五大区',
  PRIMARY KEY (state)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='静态维度:巴西州';

INSERT INTO dim_brazil_state (state, state_name, region) VALUES
('AC','Acre','北部'),               ('AL','Alagoas','东北部'),
('AP','Amapá','北部'),              ('AM','Amazonas','北部'),
('BA','Bahia','东北部'),            ('CE','Ceará','东北部'),
('DF','Distrito Federal','中西部'), ('ES','Espírito Santo','东南部'),
('GO','Goiás','中西部'),            ('MA','Maranhão','东北部'),
('MT','Mato Grosso','中西部'),      ('MS','Mato Grosso do Sul','中西部'),
('MG','Minas Gerais','东南部'),     ('PA','Pará','北部'),
('PB','Paraíba','东北部'),          ('PR','Paraná','南部'),
('PE','Pernambuco','东北部'),       ('PI','Piauí','东北部'),
('RJ','Rio de Janeiro','东南部'),   ('RN','Rio Grande do Norte','东北部'),
('RS','Rio Grande do Sul','南部'),  ('RO','Rondônia','北部'),
('RR','Roraima','北部'),            ('SC','Santa Catarina','南部'),
('SP','São Paulo','东南部'),        ('SE','Sergipe','东北部'),
('TO','Tocantins','北部');
-- Tableau 地图用法：把 state 设为「州/省」地理角色、国家选巴西；若识别不出来，
-- 改用 state_name 字段（Tableau 内置了巴西州名识别）。region 用于大区维度下钻。


-- ============================================================================
-- 一、ads_kpi_overview：月度经营总览（Tableau P1 顶部 KPI + 趋势）
-- ============================================================================
DROP TABLE IF EXISTS ads_kpi_overview;
CREATE TABLE ads_kpi_overview (
  stat_month          DATE NOT NULL,
  order_cnt           INT,
  buyer_cnt           INT,
  item_cnt            INT,
  delivered_cnt       INT,
  canceled_cnt        INT,
  gmv                 DECIMAL(14,2) COMMENT '仅已送达',
  gmv_all             DECIMAL(14,2) COMMENT '全部状态，口径对照',
  aov                 DECIMAL(10,2) COMMENT '客单价',
  arpu                DECIMAL(10,2) COMMENT '人均消费',
  late_rate_pct       DECIMAL(6,2),
  avg_delivery_days   DECIMAL(8,1),
  avg_review_score    DECIMAL(4,2),
  bad_review_rate_pct DECIMAL(6,2) COMMENT '差评率(评分<=2)',
  PRIMARY KEY (stat_month)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:P1 月度经营总览';

INSERT INTO ads_kpi_overview
SELECT
  DATE(DATE_FORMAT(purchase_ts, '%Y-%m-01')) AS stat_month,
  COUNT(*)                                   AS order_cnt,
  COUNT(DISTINCT customer_unique_id)         AS buyer_cnt,
  SUM(item_cnt)                              AS item_cnt,
  SUM(is_delivered)                          AS delivered_cnt,
  SUM(CASE WHEN order_status = 'canceled' THEN 1 ELSE 0 END) AS canceled_cnt,
  ROUND(SUM(CASE WHEN is_delivered = 1 THEN order_amount ELSE 0 END), 2) AS gmv,
  ROUND(SUM(order_amount), 2)                AS gmv_all,
  ROUND(SUM(CASE WHEN is_delivered = 1 THEN order_amount ELSE 0 END) / NULLIF(SUM(is_delivered), 0), 2) AS aov,
  ROUND(SUM(CASE WHEN is_delivered = 1 THEN order_amount ELSE 0 END) / NULLIF(COUNT(DISTINCT customer_unique_id), 0), 2) AS arpu,
  ROUND(AVG(is_late) * 100, 2)               AS late_rate_pct,
  ROUND(AVG(total_delivery_hours) / 24, 1)   AS avg_delivery_days,
  ROUND(AVG(review_score), 2)                AS avg_review_score,
  ROUND(AVG(CASE WHEN review_score <= 2 THEN 1 WHEN review_score IS NULL THEN NULL ELSE 0 END) * 100, 2) AS bad_review_rate_pct
FROM dwd_orders
WHERE purchase_ts IS NOT NULL
GROUP BY DATE(DATE_FORMAT(purchase_ts, '%Y-%m-01'));


-- ============================================================================
-- 二、ads_gmv_factors：GMV 三因子拆解（SQL 负责取数与聚合）
-- GMV = 下单客户数 × 人均下单次数 × 客单价 —— 三个因子相乘正好还原 GMV
-- ============================================================================
DROP TABLE IF EXISTS ads_gmv_factors;
CREATE TABLE ads_gmv_factors (
  stat_month          DATE NOT NULL,
  buyers              INT            COMMENT '因子1：下单客户数',
  delivered_orders    INT,
  gmv                 DECIMAL(14,2),
  orders_per_buyer    DECIMAL(8,4)   COMMENT '因子2：人均下单次数',
  aov                 DECIMAL(10,2)  COMMENT '因子3：客单价',
  buyers_mom_pct      DECIMAL(8,2)   COMMENT '因子1环比%',
  opb_mom_pct         DECIMAL(8,2)   COMMENT '因子2环比%',
  aov_mom_pct         DECIMAL(8,2)   COMMENT '因子3环比%',
  gmv_mom_pct         DECIMAL(8,2)   COMMENT 'GMV环比%',
  PRIMARY KEY (stat_month)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:P1 GMV三因子拆解';

INSERT INTO ads_gmv_factors
WITH m AS (
  SELECT DATE(DATE_FORMAT(purchase_ts, '%Y-%m-01'))              AS stat_month,
         COUNT(DISTINCT customer_unique_id)                      AS buyers,
         SUM(is_delivered)                                       AS delivered_orders,
         SUM(CASE WHEN is_delivered = 1 THEN order_amount ELSE 0 END) AS gmv
  FROM dwd_orders
  WHERE purchase_ts IS NOT NULL
  GROUP BY DATE(DATE_FORMAT(purchase_ts, '%Y-%m-01'))
),
f AS (
  SELECT stat_month, buyers, delivered_orders, gmv,
         ROUND(delivered_orders / NULLIF(buyers, 0), 4) AS orders_per_buyer,
         ROUND(gmv / NULLIF(delivered_orders, 0), 2)    AS aov
  FROM m
)
SELECT
  stat_month, buyers, delivered_orders, gmv, orders_per_buyer, aov,
  ROUND((buyers           / NULLIF(LAG(buyers)           OVER (ORDER BY stat_month), 0) - 1) * 100, 2),
  ROUND((orders_per_buyer / NULLIF(LAG(orders_per_buyer) OVER (ORDER BY stat_month), 0) - 1) * 100, 2),
  ROUND((aov              / NULLIF(LAG(aov)              OVER (ORDER BY stat_month), 0) - 1) * 100, 2),
  ROUND((gmv              / NULLIF(LAG(gmv)              OVER (ORDER BY stat_month), 0) - 1) * 100, 2)
FROM f;


-- ============================================================================
-- 三、ads_gmv_decomposition：【只建结构，Python 回写】
-- 用 LMDI（对数平均迪氏指数法）做加法分解：三个因子的贡献之和严格等于 GMV 变化量
-- ============================================================================
DROP TABLE IF EXISTS ads_gmv_decomposition;
CREATE TABLE ads_gmv_decomposition (
  stat_month          DATE          NOT NULL,
  factor              VARCHAR(20)   NOT NULL COMMENT 'buyers / orders_per_buyer / aov',
  factor_cn           VARCHAR(30)   COMMENT '因子中文名',
  delta_gmv           DECIMAL(14,2) COMMENT '本期 GMV 变化量',
  contribution_amount DECIMAL(14,2) COMMENT '该因子贡献的 GMV 变化额',
  contribution_pct    DECIMAL(8,4)  COMMENT '贡献占比（三因子之和=1）',
  ci_low              DECIMAL(14,2) COMMENT 'Bootstrap 置信区间下界',
  ci_high             DECIMAL(14,2) COMMENT 'Bootstrap 置信区间上界',
  method              VARCHAR(30)   COMMENT '分解方法',
  updated_at          DATETIME,
  PRIMARY KEY (stat_month, factor)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:P1 GMV归因分解(Python回写)';


-- ============================================================================
-- 四、ads_delivery_delay_impact：延迟档位 × 体验（Tableau P2 核心图）
-- 这张表是"延迟值多少钱"最直接的证据链
-- ============================================================================
DROP TABLE IF EXISTS ads_delivery_delay_impact;
CREATE TABLE ads_delivery_delay_impact (
  bucket_order        INT NOT NULL,
  delay_bucket        VARCHAR(20) NOT NULL,
  order_cnt           INT,
  order_share_pct     DECIMAL(6,2),
  avg_delay_days      DECIMAL(8,2),
  avg_delivery_days   DECIMAL(8,1),
  avg_review_score    DECIMAL(4,2),
  bad_review_rate_pct DECIMAL(6,2),
  one_star_rate_pct   DECIMAL(6,2),
  avg_order_amount    DECIMAL(10,2),
  avg_distance_km     DECIMAL(8,1),
  PRIMARY KEY (bucket_order)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:P2 延迟档位体验影响';

INSERT INTO ads_delivery_delay_impact
WITH b AS (
  SELECT
    CASE
      WHEN is_late IS NULL                                   THEN 0
      WHEN delay_hours <= 0                                  THEN 1
      WHEN delay_hours <= 24 * 3                             THEN 2
      WHEN delay_hours <= 24 * 7                             THEN 3
      WHEN delay_hours <= 24 * 14                            THEN 4
      ELSE 5
    END AS bucket_order,
    CASE
      WHEN is_late IS NULL          THEN '未送达'
      WHEN delay_hours <= 0         THEN '准时或提前'
      WHEN delay_hours <= 24 * 3    THEN '延迟1-3天'
      WHEN delay_hours <= 24 * 7    THEN '延迟4-7天'
      WHEN delay_hours <= 24 * 14   THEN '延迟8-14天'
      ELSE '延迟15天以上'
    END AS delay_bucket,
    order_amount, delay_hours, total_delivery_hours,
    review_score, avg_distance_km
  FROM dwd_orders
  WHERE purchase_ts IS NOT NULL
)
SELECT
  bucket_order,
  delay_bucket,
  COUNT(*)                                    AS order_cnt,
  ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM dwd_orders WHERE purchase_ts IS NOT NULL), 2) AS order_share_pct,
  ROUND(AVG(delay_hours) / 24, 2)             AS avg_delay_days,
  ROUND(AVG(total_delivery_hours) / 24, 1)    AS avg_delivery_days,
  ROUND(AVG(review_score), 2)                 AS avg_review_score,
  ROUND(AVG(CASE WHEN review_score <= 2 THEN 1 WHEN review_score IS NULL THEN NULL ELSE 0 END) * 100, 2) AS bad_review_rate_pct,
  ROUND(AVG(CASE WHEN review_score = 1 THEN 1 WHEN review_score IS NULL THEN NULL ELSE 0 END) * 100, 2) AS one_star_rate_pct,
  ROUND(AVG(order_amount), 2)                 AS avg_order_amount,
  ROUND(AVG(avg_distance_km), 1)              AS avg_distance_km
FROM b
GROUP BY bucket_order, delay_bucket;


-- ============================================================================
-- 五、ads_delivery_duration_impact：履约总时长档位 × 体验
-- ============================================================================
DROP TABLE IF EXISTS ads_delivery_duration_impact;
CREATE TABLE ads_delivery_duration_impact (
  bucket_order        INT NOT NULL,
  duration_bucket     VARCHAR(20) NOT NULL,
  order_cnt           INT,
  order_share_pct     DECIMAL(6,2),
  avg_delivery_days   DECIMAL(8,1),
  avg_review_score    DECIMAL(4,2),
  bad_review_rate_pct DECIMAL(6,2),
  avg_distance_km     DECIMAL(8,1),
  PRIMARY KEY (bucket_order)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:P2 履约时长档位体验影响';

INSERT INTO ads_delivery_duration_impact
WITH b AS (
  SELECT
    CASE
      WHEN total_delivery_hours IS NULL   THEN 0
      WHEN total_delivery_hours <= 24 * 7  THEN 1
      WHEN total_delivery_hours <= 24 * 14 THEN 2
      WHEN total_delivery_hours <= 24 * 21 THEN 3
      WHEN total_delivery_hours <= 24 * 30 THEN 4
      ELSE 5
    END AS bucket_order,
    CASE
      WHEN total_delivery_hours IS NULL   THEN '未送达'
      WHEN total_delivery_hours <= 24 * 7  THEN '7天内'
      WHEN total_delivery_hours <= 24 * 14 THEN '8-14天'
      WHEN total_delivery_hours <= 24 * 21 THEN '15-21天'
      WHEN total_delivery_hours <= 24 * 30 THEN '22-30天'
      ELSE '30天以上'
    END AS duration_bucket,
    total_delivery_hours, review_score, avg_distance_km
  FROM dwd_orders
  WHERE purchase_ts IS NOT NULL
)
SELECT
  bucket_order,
  duration_bucket,
  COUNT(*)                                 AS order_cnt,
  ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM dwd_orders WHERE purchase_ts IS NOT NULL), 2) AS order_share_pct,
  ROUND(AVG(total_delivery_hours) / 24, 1) AS avg_delivery_days,
  ROUND(AVG(review_score), 2)              AS avg_review_score,
  ROUND(AVG(CASE WHEN review_score <= 2 THEN 1 WHEN review_score IS NULL THEN NULL ELSE 0 END) * 100, 2) AS bad_review_rate_pct,
  ROUND(AVG(avg_distance_km), 1)           AS avg_distance_km
FROM b
GROUP BY bucket_order, duration_bucket;


-- ============================================================================
-- 六、ads_state_delivery：州级履约地图（Tableau P2 地图）
-- ============================================================================
DROP TABLE IF EXISTS ads_state_delivery;
CREATE TABLE ads_state_delivery (
  state               CHAR(2) NOT NULL,
  state_name          VARCHAR(50),
  region              VARCHAR(20),
  order_cnt           INT,
  buyer_cnt           INT,
  gmv                 DECIMAL(14,2),
  gmv_share_pct       DECIMAL(6,2),
  avg_order_amount    DECIMAL(10,2),
  avg_delivery_days   DECIMAL(8,1),
  avg_lastmile_days   DECIMAL(8,1),
  late_rate_pct       DECIMAL(6,2),
  avg_review_score    DECIMAL(4,2),
  bad_review_rate_pct DECIMAL(6,2),
  avg_distance_km     DECIMAL(8,1),
  PRIMARY KEY (state)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:P2 州级履约地图';

INSERT INTO ads_state_delivery
SELECT
  d.customer_state,
  s.state_name,
  s.region,
  COUNT(*)                                   AS order_cnt,
  COUNT(DISTINCT d.customer_unique_id)       AS buyer_cnt,
  ROUND(SUM(CASE WHEN d.is_delivered = 1 THEN d.order_amount ELSE 0 END), 2) AS gmv,
  ROUND(SUM(CASE WHEN d.is_delivered = 1 THEN d.order_amount ELSE 0 END)
        / (SELECT SUM(CASE WHEN is_delivered = 1 THEN order_amount ELSE 0 END) FROM dwd_orders WHERE purchase_ts IS NOT NULL) * 100, 2) AS gmv_share_pct,
  ROUND(AVG(d.order_amount), 2)              AS avg_order_amount,
  ROUND(AVG(d.total_delivery_hours) / 24, 1) AS avg_delivery_days,
  ROUND(AVG(d.lastmile_hours) / 24, 1)       AS avg_lastmile_days,
  ROUND(AVG(d.is_late) * 100, 2)             AS late_rate_pct,
  ROUND(AVG(d.review_score), 2)              AS avg_review_score,
  ROUND(AVG(CASE WHEN d.review_score <= 2 THEN 1 WHEN d.review_score IS NULL THEN NULL ELSE 0 END) * 100, 2) AS bad_review_rate_pct,
  ROUND(AVG(d.avg_distance_km), 1)           AS avg_distance_km
FROM dwd_orders d
LEFT JOIN dim_brazil_state s ON s.state = d.customer_state
WHERE d.purchase_ts IS NOT NULL
GROUP BY d.customer_state, s.state_name, s.region;


-- ============================================================================
-- 七、ads_rfm_segment：RFM 人群结构（Tableau P3 气泡矩阵）
-- ============================================================================
DROP TABLE IF EXISTS ads_rfm_segment;
CREATE TABLE ads_rfm_segment (
  rfm_segment         VARCHAR(20) NOT NULL,
  customers           INT,
  customers_pct       DECIMAL(6,2),
  total_monetary      DECIMAL(14,2),
  monetary_pct        DECIMAL(6,2) COMMENT 'GMV 贡献占比',
  avg_monetary        DECIMAL(10,2),
  avg_order_cnt       DECIMAL(8,2),
  avg_recency_days    DECIMAL(8,1),
  repeat_customers    INT,
  PRIMARY KEY (rfm_segment)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:P3 RFM人群结构';

INSERT INTO ads_rfm_segment
SELECT
  rfm_segment,
  COUNT(*),
  ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM dws_user_profile), 2),
  ROUND(SUM(monetary), 2),
  ROUND(SUM(monetary) / (SELECT SUM(monetary) FROM dws_user_profile) * 100, 2),
  ROUND(AVG(monetary), 2),
  ROUND(AVG(order_cnt), 2),
  ROUND(AVG(recency_days), 1),
  SUM(is_repeat)
FROM dws_user_profile
GROUP BY rfm_segment;


-- ============================================================================
-- 八、ads_retention_curve：留存曲线（Tableau P3 留存图）
-- 注意：Olist 复购率仅约 3%，第 1 月之后会断崖式下跌，这是 marketplace 的正常特征
-- ============================================================================
DROP TABLE IF EXISTS ads_retention_curve;
CREATE TABLE ads_retention_curve (
  month_index             INT NOT NULL,
  active_users            INT,
  base_users              INT COMMENT 'month_index=0 的总人数',
  weighted_retention_rate DECIMAL(8,4) COMMENT '按同期群人数加权的留存率',
  PRIMARY KEY (month_index)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:P3 留存曲线';

INSERT INTO ads_retention_curve
WITH zero AS (
  SELECT SUM(active_users) AS base_users
  FROM dws_cohort_retention WHERE month_index = 0
)
SELECT
  month_index,
  SUM(active_users)                        AS active_users,
  (SELECT base_users FROM zero)            AS base_users,
  ROUND(SUM(active_users) / NULLIF((SELECT base_users FROM zero), 0), 4) AS weighted_retention_rate
FROM dws_cohort_retention
GROUP BY month_index;


-- ============================================================================
-- 九、ads_category_matrix：品类四象限（Tableau P3 四象限散点）
-- 增长口径：近 3 个完整月 vs 前 3 个完整月（以数据最后一个月为基准）
-- ============================================================================
DROP TABLE IF EXISTS ads_category_matrix;
CREATE TABLE ads_category_matrix (
  category_en          VARCHAR(100) NOT NULL,
  gmv                  DECIMAL(14,2),
  gmv_share_pct        DECIMAL(6,2),
  order_cnt            INT,
  item_cnt             INT,
  avg_item_price       DECIMAL(10,2),
  gmv_recent3          DECIMAL(14,2),
  gmv_prev3            DECIMAL(14,2),
  growth_pct           DECIMAL(10,2) COMMENT '近3月/前3月 - 1',
  avg_review_score     DECIMAL(4,2),
  bad_review_rate_pct  DECIMAL(6,2),
  late_rate_pct        DECIMAL(6,2),
  freight_ratio_pct    DECIMAL(6,2),
  gmv_rank             INT,
  quadrant             VARCHAR(20) COMMENT '明星/现金牛/潜力/观察汰换',
  PRIMARY KEY (category_en)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:P3 品类四象限';

INSERT INTO ads_category_matrix
WITH mm AS (
  -- 用「年*12+月」把月份转成连续整数，方便取最近 N 个月
  SELECT MAX(YEAR(stat_month) * 12 + MONTH(stat_month)) AS max_mi FROM dws_category_monthly
),
agg AS (
  SELECT c.category_en,
         ROUND(SUM(c.gmv), 2)                                    AS gmv,
         SUM(c.order_cnt)                                        AS order_cnt,
         SUM(c.item_cnt)                                         AS item_cnt,
         ROUND(SUM(c.item_amount) / NULLIF(SUM(c.item_cnt), 0), 2) AS avg_item_price,
         ROUND(SUM(CASE WHEN YEAR(c.stat_month) * 12 + MONTH(c.stat_month) > (SELECT max_mi FROM mm) - 3
                        THEN c.gmv ELSE 0 END), 2)               AS gmv_recent3,
         ROUND(SUM(CASE WHEN YEAR(c.stat_month) * 12 + MONTH(c.stat_month)
                              BETWEEN (SELECT max_mi FROM mm) - 6 AND (SELECT max_mi FROM mm) - 3
                        THEN c.gmv ELSE 0 END), 2)               AS gmv_prev3,
         ROUND(AVG(c.avg_review_score), 2)                       AS avg_review_score,
         ROUND(AVG(c.bad_review_rate) * 100, 2)                  AS bad_review_rate_pct,
         ROUND(AVG(c.late_rate) * 100, 2)                        AS late_rate_pct,
         ROUND(AVG(c.freight_ratio) * 100, 2)                    AS freight_ratio_pct
  FROM dws_category_monthly c
  GROUP BY c.category_en
),
ranked AS (
  SELECT a.*,
         ROUND((a.gmv_recent3 / NULLIF(a.gmv_prev3, 0) - 1) * 100, 2) AS growth_pct,
         ROW_NUMBER() OVER (ORDER BY a.gmv DESC)                      AS gmv_rank,
         AVG(a.gmv) OVER ()                                           AS avg_gmv,
         SUM(a.gmv) OVER ()                                           AS total_gmv
  FROM agg a
)
SELECT
  category_en, gmv,
  ROUND(gmv / NULLIF(total_gmv, 0) * 100, 2) AS gmv_share_pct,
  order_cnt, item_cnt, avg_item_price,
  gmv_recent3, gmv_prev3, growth_pct,
  avg_review_score, bad_review_rate_pct, late_rate_pct, freight_ratio_pct,
  gmv_rank,
  CASE
    WHEN gmv >= avg_gmv AND IFNULL(growth_pct, 0) >= 0  THEN '明星品类'
    WHEN gmv >= avg_gmv AND IFNULL(growth_pct, 0) <  0  THEN '现金牛品类'
    WHEN gmv <  avg_gmv AND IFNULL(growth_pct, 0) >= 0  THEN '潜力品类'
    ELSE '观察汰换'
  END AS quadrant
FROM ranked;


-- ============================================================================
-- 十、ads_seller_scorecard：卖家 ABC 分级 + 质量评分（Tableau P3 卖家表）
-- ============================================================================
DROP TABLE IF EXISTS ads_seller_scorecard;
CREATE TABLE ads_seller_scorecard (
  seller_id            VARCHAR(50) NOT NULL,
  seller_state         CHAR(2),
  gmv                  DECIMAL(14,2),
  gmv_share_pct        DECIMAL(8,4),
  gmv_cum_share_pct    DECIMAL(8,4),
  abc_class            CHAR(1) COMMENT 'A:累计80%内 B:80-95% C:其余',
  order_cnt            INT,
  buyer_cnt            INT,
  product_cnt          INT,
  avg_item_price       DECIMAL(10,2),
  avg_review_score     DECIMAL(4,2),
  bad_review_rate_pct  DECIMAL(6,2),
  late_rate_pct        DECIMAL(6,2),
  cancel_rate_pct      DECIMAL(6,2),
  avg_delivery_days    DECIMAL(8,1),
  quality_flag         VARCHAR(12) COMMENT '优质/达标/待整改',
  seller_level         VARCHAR(12) COMMENT '重点扶持/稳定合作/观察/建议汰换',
  PRIMARY KEY (seller_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:P3 卖家记分卡';

INSERT INTO ads_seller_scorecard
WITH stat AS (
  SELECT AVG(bad_review_rate) AS avg_bad, AVG(late_rate) AS avg_late
  FROM dws_seller_summary
),
sh AS (
  SELECT s.*,
         ROUND(s.gmv / (SELECT SUM(gmv) FROM dws_seller_summary) * 100, 4) AS gmv_share_pct,
         ROUND(SUM(s.gmv) OVER (ORDER BY s.gmv DESC, s.seller_id)
               / (SELECT SUM(gmv) FROM dws_seller_summary) * 100, 4)      AS gmv_cum_share_pct,
         ROUND(s.bad_review_rate * 100, 2)  AS bad_pct,
         ROUND(s.late_rate * 100, 2)        AS late_pct,
         ROUND(s.cancel_rate * 100, 2)      AS cancel_pct
  FROM dws_seller_summary s
)
SELECT
  sh.seller_id, sh.seller_state, sh.gmv, sh.gmv_share_pct, sh.gmv_cum_share_pct,
  CASE WHEN sh.gmv_cum_share_pct <= 80 THEN 'A'
       WHEN sh.gmv_cum_share_pct <= 95 THEN 'B'
       ELSE 'C' END AS abc_class,
  sh.order_cnt, sh.buyer_cnt, sh.product_cnt, sh.avg_item_price,
  sh.avg_review_score, sh.bad_pct, sh.late_pct, sh.cancel_pct, sh.avg_delivery_days,
  CASE
    WHEN sh.avg_review_score >= 4.2 AND sh.late_rate <= st.avg_late     THEN '优质'
    WHEN sh.avg_review_score >= 3.6 AND sh.late_rate <= st.avg_late * 1.5 THEN '达标'
    ELSE '待整改'
  END AS quality_flag,
  CASE
    WHEN sh.gmv_cum_share_pct <= 80 AND sh.avg_review_score >= 4.0 AND sh.late_rate <= st.avg_late THEN '重点扶持'
    WHEN sh.gmv_cum_share_pct <= 95 AND sh.avg_review_score >= 3.6                                  THEN '稳定合作'
    WHEN sh.gmv_cum_share_pct >  95 AND sh.avg_review_score >= 3.6                                  THEN '观察'
    ELSE '建议汰换'
  END AS seller_level
FROM sh CROSS JOIN stat st;


-- ============================================================================
-- 十一、ads_order_risk：【只建结构，Python 回写】差评风险预警清单（S4）
-- ============================================================================
DROP TABLE IF EXISTS ads_order_risk;
CREATE TABLE ads_order_risk (
  order_id            VARCHAR(50) NOT NULL,
  customer_unique_id  VARCHAR(50),
  purchase_date       DATE,
  customer_state      CHAR(2),
  order_amount        DECIMAL(12,2),
  delivery_days       DECIMAL(8,1),
  is_late             TINYINT,
  review_score        DECIMAL(4,2) COMMENT '实际评分，用于回测',
  risk_prob           DECIMAL(6,4) COMMENT '预测差评概率',
  risk_decile         TINYINT      COMMENT '风险十分位，10=最危险',
  risk_level          VARCHAR(10)  COMMENT '高/中/低',
  top_factor_1        VARCHAR(50)  COMMENT 'SHAP 首位归因特征',
  top_factor_2        VARCHAR(50),
  top_factor_3        VARCHAR(50),
  model_name          VARCHAR(50),
  model_auc           DECIMAL(6,4),
  updated_at          DATETIME,
  PRIMARY KEY (order_id),
  KEY idx_ads_risk_level (risk_level, risk_decile)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:P4 差评风险预警(Python回写)';


-- ============================================================================
-- 十二、ads_experiment_result：【只建结构，Python 回写】策略效果评估（S6）
-- ============================================================================
DROP TABLE IF EXISTS ads_experiment_result;
CREATE TABLE ads_experiment_result (
  experiment_name     VARCHAR(50) NOT NULL,
  metric              VARCHAR(50) NOT NULL,
  method              VARCHAR(30) COMMENT 'PSM+DID / t-test+Bootstrap / power-analysis',
  group_control       VARCHAR(30),
  group_treat         VARCHAR(30),
  n_control           INT,
  n_treat             INT,
  control_value       DECIMAL(14,4),
  treat_value         DECIMAL(14,4),
  diff                DECIMAL(14,4) COMMENT '处理组 - 对照组',
  diff_pct            DECIMAL(8,4),
  ci_low              DECIMAL(14,4),
  ci_high             DECIMAL(14,4),
  p_value             DECIMAL(10,6),
  is_significant      TINYINT,
  expected_uplift_gmv DECIMAL(14,2) COMMENT '预估增量 GMV',
  note                VARCHAR(255),
  updated_at          DATETIME,
  PRIMARY KEY (experiment_name, metric)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:P4 策略效果评估(Python回写)';


-- ============================================================================
-- 十三、ads 层自检
-- ============================================================================
SELECT 'ads_kpi_overview'            AS table_name, COUNT(*) AS row_cnt FROM ads_kpi_overview
UNION ALL SELECT 'ads_gmv_factors',            COUNT(*) FROM ads_gmv_factors
UNION ALL SELECT 'ads_gmv_decomposition',      COUNT(*) FROM ads_gmv_decomposition
UNION ALL SELECT 'ads_delivery_delay_impact',  COUNT(*) FROM ads_delivery_delay_impact
UNION ALL SELECT 'ads_delivery_duration_impact', COUNT(*) FROM ads_delivery_duration_impact
UNION ALL SELECT 'ads_state_delivery',         COUNT(*) FROM ads_state_delivery
UNION ALL SELECT 'ads_rfm_segment',            COUNT(*) FROM ads_rfm_segment
UNION ALL SELECT 'ads_retention_curve',        COUNT(*) FROM ads_retention_curve
UNION ALL SELECT 'ads_category_matrix',        COUNT(*) FROM ads_category_matrix
UNION ALL SELECT 'ads_seller_scorecard',       COUNT(*) FROM ads_seller_scorecard
UNION ALL SELECT 'ads_order_risk',             COUNT(*) FROM ads_order_risk
UNION ALL SELECT 'ads_experiment_result',      COUNT(*) FROM ads_experiment_result;

-- 延迟-体验证据链（这张结果直接就是 P2 的核心结论）
SELECT delay_bucket, order_cnt, order_share_pct, avg_delivery_days,
       avg_review_score, bad_review_rate_pct, one_star_rate_pct
FROM ads_delivery_delay_impact ORDER BY bucket_order;

-- 卖家 ABC 结构（帕累托是否成立）
SELECT abc_class, COUNT(*) AS sellers,
       ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM ads_seller_scorecard), 2) AS seller_pct,
       ROUND(SUM(gmv_share_pct), 2) AS gmv_share_pct
FROM ads_seller_scorecard GROUP BY abc_class ORDER BY abc_class;
