-- ============================================================================
-- 06_s2_AOV结构拆解.sql
-- S2 收尾分析：把「客单价（AOV）变化」拆成可归因的几股力量。
--
-- 【要回答的问题】
--   S2-01 已经证明：2018-08 GMV 环比 −4.12% 中，客单价贡献了 173%（显著）。
--   但"客单价跌了 7%"本身没法行动。必须回答：
--       这 7% 里，多少来自「各品类自己变便宜了」，多少来自「低单价品类占比上升」？
--   前者要动定价，后者要动品类结构 —— 是完全不同的两个动作。
--
-- 【分解链（每一层都是精确恒等式，无残差）】
--   第 1 层：AOV = P × N + f
--       P = item_amount / item_cnt      件均价
--       N = item_cnt / delivered_orders 单均件数
--       f = freight / delivered_orders  单均运费
--   第 2 层：件均价 P 再按品类拆
--       P = Σ s_i · p_i    s_i = 品类件数占比（Σ s_i = 1），p_i = 品类件均价
--       ΔP = Σ s_i0·Δp_i  +  Σ p_i0·Δs_i  +  Σ Δs_i·Δp_i
--            └─ 价格效应 ─┘  └─ 结构效应 ─┘   └─ 二阶交叉 ─┘
--
--   合起来得到五个效应，五项之和严格等于 ΔAOV：
--       价格效应 = N0 · Σ s_i0·Δp_i
--       结构效应 = N0 · Σ p_i0·Δs_i
--       件数效应 = P0 · ΔN
--       运费效应 = Δf
--       交叉项   = ΔP·ΔN + N0 · Σ Δs_i·Δp_i
--
-- 【口径提醒 —— 为什么脚本不直接从 dws_category_monthly 取数】
--   该表的 item_amount / freight_amount 是【全部状态】订单的合计，
--   只有 gmv 是【仅已送达】。而 AOV 必须只在已送达订单上算，
--   所以脚本改从 dwd_order_items + dwd_orders 现算，显式加 is_delivered = 1。
--   （顺带发现：该表的 freight_ratio = 全状态运费 / 已送达GMV，分子分母口径不一致，
--     已在 02_dws 修正 —— 见该文件注释。S2 不受影响。）
--
-- 【运行顺序】06 → python/s2_04_aov_mix.py
-- ============================================================================

USE olist_dw;
SET NAMES utf8mb4;


-- ============================================================================
-- 一、ads_aov_decomposition：月度五效应分解（Python 回写）
--    月度分解是【恒等式】不是估计，所以不需要置信区间；
--    需要 CI 的是窗口级累计（见第三张表）。
-- ============================================================================
DROP TABLE IF EXISTS ads_aov_decomposition;
CREATE TABLE ads_aov_decomposition (
  stat_month          DATE          NOT NULL,
  factor              VARCHAR(20)   NOT NULL COMMENT 'price/mix/quantity/freight/interaction',
  factor_cn           VARCHAR(20)   COMMENT '中文名',
  aov_prev            DECIMAL(12,4) COMMENT '上期客单价',
  aov_curr            DECIMAL(12,4) COMMENT '本期客单价',
  delta_aov           DECIMAL(12,4) COMMENT '客单价变化额',
  contribution_amount DECIMAL(12,4) COMMENT '该效应贡献的客单价变化额',
  contribution_pct    DECIMAL(10,6) COMMENT '占比（五项之和=1）',
  method              VARCHAR(60),
  updated_at          DATETIME,
  PRIMARY KEY (stat_month, factor)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:S2 AOV五效应分解(Python回写)';


-- ============================================================================
-- 二、ads_aov_mix_detail：月度 × 品类 —— 谁在拉价、谁在改结构
--    这是整张分析里最可执行的一张表：
--      price_contrib 为负 → 这个品类自己降价了（定价问题）
--      mix_contrib   为负 → 这个品类卖得少了（结构问题，权重被低价品类顶替）
-- ============================================================================
DROP TABLE IF EXISTS ads_aov_mix_detail;
CREATE TABLE ads_aov_mix_detail (
  stat_month          DATE          NOT NULL,
  category_en         VARCHAR(100)  NOT NULL,
  item_cnt_prev       INT,
  item_cnt_curr       INT,
  share_prev          DECIMAL(10,6) COMMENT '上期件数占比',
  share_curr          DECIMAL(10,6) COMMENT '本期件数占比',
  price_prev          DECIMAL(12,4) COMMENT '上期件均价',
  price_curr          DECIMAL(12,4) COMMENT '本期件均价',
  price_contrib       DECIMAL(12,6) COMMENT '对价格效应的贡献（客单价格数）',
  mix_contrib         DECIMAL(12,6) COMMENT '对结构效应的贡献（客单价格数）',
  updated_at          DATETIME,
  PRIMARY KEY (stat_month, category_en),
  KEY idx_ads_aov_mix_m (stat_month)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:S2 AOV品类价格/结构贡献(Python回写)';


-- ============================================================================
-- 三、ads_aov_effect_window：窗口级汇总 + 显著性
--    单位是「月」，不是「天」—— 这是对 S2-01 那个"置信区间过宽"的修正：
--      · 月度分解是恒等式，逐月报区间没有意义
--      · 决策者真正要问的是"这个效应是不是系统性的"，那是一个关于
--        【19 个月份】的推断问题，样本单位就该是月
--    两种判据一起给：
--      · Bootstrap 百分位区间（对月份重抽样）
--      · 符号检验（p 值）—— 只问"有多少个月的效应是负的"，不做分布假设
-- ============================================================================
DROP TABLE IF EXISTS ads_aov_effect_window;
CREATE TABLE ads_aov_effect_window (
  factor            VARCHAR(20)   NOT NULL,
  factor_cn         VARCHAR(20),
  total_amount      DECIMAL(12,4) COMMENT '全区间累计（元）',
  mean_per_month    DECIMAL(12,4) COMMENT '月均',
  ci_low            DECIMAL(12,4) COMMENT 'Bootstrap 95%CI 下界',
  ci_high           DECIMAL(12,4) COMMENT 'Bootstrap 95%CI 上界',
  negative_months   INT           COMMENT '效应为负的月份数',
  positive_months   INT,
  sign_test_p       DECIMAL(10,6) COMMENT '符号检验双侧 p 值',
  months            INT,
  method            VARCHAR(60),
  updated_at        DATETIME,
  PRIMARY KEY (factor)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:S2 AOV效应窗口汇总(Python回写)';


-- ============================================================================
-- 四、取数口径自检：三个层级必须一致（跑脚本前先看这个）
--     ① 品类明细的件数/金额合计 = 订单层的合计
--     ② 已送达订单数 = ads_gmv_factors.delivered_orders
--     ③ 有没有"已送达但查不到任何明细"的订单（会只进分母不进分子，压低 AOV）
-- ============================================================================
SELECT
  c.stat_month,
  c.cat_item_cnt,
  t.total_item_cnt,
  c.cat_item_cnt - t.total_item_cnt   AS 件数差,
  c.cat_item_amount,
  t.total_item_amount,
  c.cat_item_amount - t.total_item_amount AS 金额差,
  t.delivered_orders,
  t.delivered_no_item                 AS 已送达但无明细
FROM (
  SELECT DATE(DATE_FORMAT(o.purchase_ts, '%Y-%m-01')) AS stat_month,
         COUNT(*)                 AS cat_item_cnt,
         ROUND(SUM(i.price), 2)   AS cat_item_amount
  FROM dwd_order_items i
  JOIN dwd_orders o ON o.order_id = i.order_id
  WHERE o.is_delivered = 1 AND o.purchase_ts IS NOT NULL
  GROUP BY 1
) c
JOIN (
  SELECT DATE(DATE_FORMAT(purchase_ts, '%Y-%m-01')) AS stat_month,
         SUM(CASE WHEN is_delivered = 1 THEN item_cnt ELSE 0 END)      AS total_item_cnt,
         ROUND(SUM(CASE WHEN is_delivered = 1 THEN item_amount ELSE 0 END), 2) AS total_item_amount,
         SUM(is_delivered)                                             AS delivered_orders,
         SUM(CASE WHEN is_delivered = 1 AND IFNULL(item_cnt, 0) = 0 THEN 1 ELSE 0 END) AS delivered_no_item
  FROM dwd_orders
  WHERE purchase_ts IS NOT NULL
  GROUP BY 1
) t ON t.stat_month = c.stat_month
ORDER BY c.stat_month;
-- 两个"差"都必须严格为 0.00；「已送达但无明细」若不为 0，脚本会打印警告。
