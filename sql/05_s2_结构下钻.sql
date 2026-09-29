-- ============================================================================
-- 05_s2_结构下钻.sql
-- S2 阶段（GMV 拆解与增长归因）的 SQL 侧工作。
--
-- 【本文件的定位】
--   S2 的分工是：SQL 负责"取数 + 聚合 + 口径"，Python 负责"统计推断"。
--   所以这里只做三件事：
--     ① 补一张月×州的汇总表（结构下钻要用，S1 的 dws 层只做到了品类）
--     ② 建 ads_gmv_trend：月度趋势表，SQL 填基础列，Python 回写趋势检验/断点结果
--     ③ 建 ads_gmv_structure：结构与贡献度表，只建结构，Python 回写
--
-- 【为什么贡献度分解不在这里用 SQL 算】
--   贡献度分解本身 SQL 也能算（就是个乘法），但它必须配 Bootstrap 置信区间
--   才有决策价值 —— 而"这个变化是不是噪音"是 SQL 算不出来的。
--   分工原则（S1 已定）：需要 p 值/置信区间/模型的 → Python。
--
-- 【运行前提】先跑完 01_dwd（需要 dwd_orders / dwd_order_items / dws_category_monthly）
-- 【运行顺序】05 → s2_01 → s2_02 → s2_03
-- ============================================================================

USE olist_dw;
SET NAMES utf8mb4;


-- ============================================================================
-- 一、dws_state_monthly：月 × 州
-- S1 的 dws 层有「月×品类」，缺「月×州」。S2 的结构下钻两个维度都要用。
-- 粒度：1 行 = 1 个（月，州）
-- ============================================================================
DROP TABLE IF EXISTS dws_state_monthly;
CREATE TABLE dws_state_monthly (
  stat_month          DATE          NOT NULL,
  customer_state      CHAR(2)       NOT NULL,
  order_cnt           INT,
  delivered_cnt       INT,
  buyer_cnt           INT           COMMENT '当月下单客户数(customer_unique_id)',
  item_cnt            INT,
  gmv                 DECIMAL(14,2) COMMENT '仅已送达，含运费',
  aov                 DECIMAL(10,2),
  avg_delivery_days   DECIMAL(8,1),
  late_rate           DECIMAL(6,4),
  avg_review_score    DECIMAL(4,2),
  bad_review_rate     DECIMAL(6,4)  COMMENT '评分<=2 占比',
  PRIMARY KEY (stat_month, customer_state),
  KEY idx_dws_state_m (stat_month)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='dws:月×州';

INSERT INTO dws_state_monthly
SELECT
  DATE(DATE_FORMAT(purchase_ts, '%Y-%m-01'))                            AS stat_month,
  customer_state,
  COUNT(*)                                                             AS order_cnt,
  SUM(is_delivered)                                                    AS delivered_cnt,
  COUNT(DISTINCT customer_unique_id)                                   AS buyer_cnt,
  SUM(item_cnt)                                                        AS item_cnt,
  ROUND(SUM(CASE WHEN is_delivered = 1 THEN order_amount ELSE 0 END), 2) AS gmv,
  ROUND(SUM(CASE WHEN is_delivered = 1 THEN order_amount ELSE 0 END)
        / NULLIF(SUM(is_delivered), 0), 2)                             AS aov,
  ROUND(AVG(total_delivery_hours) / 24, 1)                             AS avg_delivery_days,
  ROUND(AVG(is_late), 4)                                               AS late_rate,
  ROUND(AVG(review_score), 2)                                          AS avg_review_score,
  ROUND(AVG(CASE WHEN review_score <= 2 THEN 1 WHEN review_score IS NULL THEN NULL ELSE 0 END), 4) AS bad_review_rate
FROM dwd_orders
WHERE purchase_ts IS NOT NULL
  AND customer_state IS NOT NULL
GROUP BY DATE(DATE_FORMAT(purchase_ts, '%Y-%m-01')), customer_state;


-- ============================================================================
-- 二、ads_gmv_trend：月度趋势表（Tableau P1 的趋势图直连这张）
--
-- 【完整月判定规则 —— 非常重要，这是 S2 最大的坑】
--   Olist 数据首尾都不完整：2016 年只有零星几个月、2018-09 之后订单骤降到个位数。
--   如果直接把首尾画进趋势图，会得到"暴涨"和"断崖"两个假象。
--
--   判定规则：order_cnt >= 500 的月份记为完整月。
--   有效分析区间 = [第一个完整月, 最后一个完整月] 之间的连续月份。
--   规则同时写在 python/common.py 的 MIN_ORDERS_FOR_COMPLETE_MONTH 里，两处必须一致。
--
-- 【delivered_ratio 为什么要有这一列】
--   最近月份的部分订单还没送到，用 gmv（仅已送达）会系统性低估，这叫右端截断。
--   所以每行都存 gmv/gmv_all 的比值，用来自检"最后几个月有没有被截断"。
-- ============================================================================
DROP TABLE IF EXISTS ads_gmv_trend;
CREATE TABLE ads_gmv_trend (
  stat_month          DATE          NOT NULL,
  order_cnt           INT,
  delivered_cnt       INT,
  buyer_cnt           INT,
  gmv                 DECIMAL(14,2) COMMENT '仅已送达，S2 主口径',
  gmv_all             DECIMAL(14,2) COMMENT '全部状态，口径对照',
  delivered_ratio     DECIMAL(8,4)  COMMENT 'gmv/gmv_all，用于检测右端截断',
  orders_per_buyer    DECIMAL(8,4)  COMMENT '因子2',
  aov                 DECIMAL(10,2) COMMENT '因子3',
  gmv_mom_pct         DECIMAL(10,2) COMMENT '环比%',
  gmv_ma3             DECIMAL(14,2) COMMENT '3月移动平均',
  is_complete_month   TINYINT       COMMENT '1=完整月(order_cnt>=500)',
  -- 以下 6 列由 s2_02_trend_breakpoint.py 回写，SQL 只建结构
  mk_tau              DECIMAL(8,4)  COMMENT 'Mann-Kendall 秩相关系数',
  mk_p_value          DECIMAL(12,8),
  mk_trend            VARCHAR(20)   COMMENT 'increasing/decreasing/no trend',
  mk_slope_log        DECIMAL(12,8) COMMENT '对数 GMV 的 OLS 斜率(分段)',
  breakpoint_flag     TINYINT       COMMENT '1=本行是断点(新分段起点)',
  segment_id          INT           COMMENT '断点分段编号，从 1 开始',
  updated_at          DATETIME,
  PRIMARY KEY (stat_month)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:P1 月度趋势(含Python回写)';

INSERT INTO ads_gmv_trend
  (stat_month, order_cnt, delivered_cnt, buyer_cnt, gmv, gmv_all,
   delivered_ratio, orders_per_buyer, aov, gmv_mom_pct, gmv_ma3, is_complete_month, updated_at)
WITH m AS (
  SELECT DATE(DATE_FORMAT(purchase_ts, '%Y-%m-01'))                      AS stat_month,
         COUNT(*)                                                       AS order_cnt,
         SUM(is_delivered)                                              AS delivered_cnt,
         COUNT(DISTINCT customer_unique_id)                             AS buyer_cnt,
         ROUND(SUM(CASE WHEN is_delivered = 1 THEN order_amount ELSE 0 END), 2) AS gmv,
         ROUND(SUM(order_amount), 2)                                    AS gmv_all
  FROM dwd_orders
  WHERE purchase_ts IS NOT NULL
  GROUP BY DATE(DATE_FORMAT(purchase_ts, '%Y-%m-01'))
),
f AS (
  SELECT m.*,
         ROUND(gmv           / NULLIF(gmv_all, 0), 4)   AS delivered_ratio,
         ROUND(delivered_cnt / NULLIF(buyer_cnt, 0), 4) AS orders_per_buyer,
         ROUND(gmv           / NULLIF(delivered_cnt, 0), 2) AS aov
  FROM m
)
SELECT
  stat_month, order_cnt, delivered_cnt, buyer_cnt, gmv, gmv_all,
  delivered_ratio, orders_per_buyer, aov,
  ROUND((gmv / NULLIF(LAG(gmv) OVER (ORDER BY stat_month), 0) - 1) * 100, 2)              AS gmv_mom_pct,
  ROUND(AVG(gmv) OVER (ORDER BY stat_month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2)  AS gmv_ma3,
  CASE WHEN order_cnt >= 500 THEN 1 ELSE 0 END                                            AS is_complete_month,
  NOW()
FROM f;

-- 看哪些月份被剔除、有效区间是哪一段（跑完先看这个结果再往下走）
SELECT stat_month, order_cnt, gmv, gmv_all, delivered_ratio, is_complete_month
FROM ads_gmv_trend
ORDER BY stat_month;

SELECT
  MIN(CASE WHEN is_complete_month = 1 THEN stat_month END) AS 完整月起点,
  MAX(CASE WHEN is_complete_month = 1 THEN stat_month END) AS 完整月终点,
  SUM(is_complete_month)                                   AS 完整月数,
  SUM(1 - is_complete_month)                               AS 被剔除月数
FROM ads_gmv_trend;


-- ============================================================================
-- 三、ads_gmv_decomposition：重建（在 03_ads 的基础上多一个 is_significant 列）
-- 原本只建了空结构，现在需要一列"这个贡献是否显著"，只能重建。
-- 该表在 Python 跑之前一直是空的，重建没有数据损失。
-- ============================================================================
DROP TABLE IF EXISTS ads_gmv_decomposition;
CREATE TABLE ads_gmv_decomposition (
  stat_month          DATE          NOT NULL,
  factor              VARCHAR(20)   NOT NULL COMMENT 'buyers / orders_per_buyer / aov',
  factor_cn           VARCHAR(30)   COMMENT '因子中文名',
  factor_prev         DECIMAL(16,6) COMMENT '基期因子值',
  factor_curr         DECIMAL(16,6) COMMENT '本期因子值',
  delta_gmv           DECIMAL(14,2) COMMENT '本期 GMV 变化量',
  contribution_amount DECIMAL(14,2) COMMENT '该因子贡献的 GMV 变化额',
  contribution_pct    DECIMAL(8,4)  COMMENT '贡献占比（三因子之和=1）',
  ci_low              DECIMAL(14,2) COMMENT 'Bootstrap 95%CI 下界（金额）',
  ci_high             DECIMAL(14,2) COMMENT 'Bootstrap 95%CI 上界（金额）',
  is_significant      TINYINT       COMMENT '1=CI 不跨 0',
  method              VARCHAR(40)   COMMENT '分解方法',
  updated_at          DATETIME,
  PRIMARY KEY (stat_month, factor)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:P1 GMV归因分解(Python回写)';


-- ============================================================================
-- 四、ads_gmv_structure：结构与贡献度（Python 回写）
-- 回答"是哪些品类/州造成的"。贡献度用可加分解，各项之和严格等于整体增长率：
--     contrib_pp_i = (gmv_i1 - gmv_i0) / GMV_0 × 100
--     Σ contrib_pp_i = (GMV_1 - GMV_0) / GMV_0 × 100 = 整体增长率
-- ============================================================================
DROP TABLE IF EXISTS ads_gmv_structure;
CREATE TABLE ads_gmv_structure (
  stat_month          DATE          NOT NULL,
  dim_type            VARCHAR(10)   NOT NULL COMMENT 'category / state',
  dim_value           VARCHAR(100)  NOT NULL,
  gmv                 DECIMAL(14,2) COMMENT '本期 GMV',
  gmv_prev            DECIMAL(14,2) COMMENT '上期 GMV',
  contrib_amount      DECIMAL(14,2) COMMENT 'GMV 变化额 gmv - gmv_prev',
  gmv_share           DECIMAL(8,4)  COMMENT '本期份额',
  gmv_share_prev      DECIMAL(8,4)  COMMENT '上期份额（份额变化=混比效应的来源）',
  growth_pct          DECIMAL(12,2) COMMENT '本维度自身增长率%，基期为0时NULL',
  contrib_pp          DECIMAL(12,4) COMMENT '对整体环比增长的贡献（百分点）',
  ci_low_pp           DECIMAL(12,4) COMMENT 'Bootstrap 95%CI 下界（百分点）',
  ci_high_pp          DECIMAL(12,4) COMMENT 'Bootstrap 95%CI 上界（百分点）',
  is_significant      TINYINT       COMMENT '1=CI 不跨 0',
  updated_at          DATETIME,
  PRIMARY KEY (stat_month, dim_type, dim_value),
  KEY idx_ads_struct_m (stat_month, dim_type)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:P1 结构贡献度(Python回写)';


-- ============================================================================
-- 五、截面勾稽：三个维度必须指向同一个总量
--   品类维度合计 = 州维度合计 = 总量。任何一个不等，说明维度划分有遗漏或重复。
--   这是 S2 开工前的最后一次"数据可信"确认。
-- ============================================================================
SELECT
  c.stat_month,
  ROUND(c.gmv_by_cat,   2) AS 品类合计,
  ROUND(s.gmv_by_state, 2) AS 州合计,
  ROUND(t.gmv,          2) AS 总量,
  ROUND(c.gmv_by_cat   - t.gmv, 2) AS 品类差,
  ROUND(s.gmv_by_state - t.gmv, 2) AS 州差
FROM (
  SELECT stat_month, SUM(gmv) AS gmv_by_cat FROM dws_category_monthly GROUP BY stat_month
) c
JOIN (
  SELECT stat_month, SUM(gmv) AS gmv_by_state FROM dws_state_monthly GROUP BY stat_month
) s ON s.stat_month = c.stat_month
JOIN (
  SELECT stat_month, gmv FROM ads_gmv_trend
) t ON t.stat_month = c.stat_month
ORDER BY c.stat_month;
-- 三个"差"都必须严格为 0.00。不为 0 就先别往下跑，回来查维度划分。
