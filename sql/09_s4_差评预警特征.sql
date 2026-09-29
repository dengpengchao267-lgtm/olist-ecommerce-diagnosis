-- ============================================================================
-- 09_s4_差评预警特征.sql
-- 作用：S4 差评预警专题——订单粒度特征宽表（含标签）
-- 前置：01_dwd_清洗与宽表.sql 已执行（依赖 dwd_orders / dwd_order_items / dwd_products）
-- 要求：MySQL 8.0.19+（WITH / 窗口日期运算 / INSERT ... SELECT）
--
-- 【S4 的业务设定 —— 先读这段再跑】
--   任务：在「签收后、评价前」的时点，预测该订单是否会收到差评（review_score ≤ 2）。
--   业务闭环：对高风险单主动干预（发关怀优惠券），把差评消灭在发生前——
--   平台侧的收益是评分体系健康度（前端展示、卖家考核、转化率）。
--
-- 【口径声明】
--   1. 样本 = 已送达且有评分的订单（无评分无法打标签，剔除；占 ~1%）
--   2. 标签 is_bad = review_score ≤ 2（1、2 星为差评；3 星是中性，不进正类）
--   3. 时间归属 = purchase_ts（继承 S2/S3）
--   4. 特征分三组，全部在「签收时点」可知，禁止任何评价后信息：
--      a. 履约特征：延迟/环节耗时/卖家违约/距离（S3 的成果直接复用）
--      b. 订单特征：金额/运费占比/件数/卖家数/分期（下单即知）
--      c. 历史特征：卖家、品类各自的「过去差评率」——见下方防泄漏设计
--
-- 【⚠️ 防泄漏设计——本脚本最核心的口径，】
--   dwd 层没有评价时间戳（评价表在建 dwd 时只保留了评分均值），
--   无法精确判断"当前订单下单时，历史订单的评价是否已经产生"。
--   处理方案（保守近似，宁可丢弃信息也不用未来信息）：
--     · 历史聚合到「品类×周」「卖家×周」粒度；
--     · 只有整周结束日（周日）距当前订单 purchase_ts ≥ 30 天的周才可用——
--       履约中位 ~12 天 + 评价滞后 ~2 周，30 天评价滞后保护基本保证评价已知；
--     · 知识窗口 = [purchase_ts − 120 天, purchase_ts − 30 天]，有效窗口 90 天。
--   代价：2017 年前几个月的历史特征覆盖低（冷启动），由 Python 侧中位数插补，
--   并在训练表里保留 seller_hist_cnt / cat_hist_cnt 让模型自己学"历史可信度"。
--
-- 【⚠️ 列名不等于类型——本脚本踩过的坑，写下来别再犯】
--   dwd_orders.pay_types 名字像"支付方式数量"，实际是 VARCHAR(100)，
--   存的是 "/" 连接的字符串（如 'boleto/credit_card'）。
--   直接插进 INT 列报 [HY000][1366] Incorrect integer value: 'credit_card'。
--   ⇒ 本脚本拆成 pay_type_cnt（种类数）+ has_credit_card（是否含信用卡）两个数值特征。
--   教训：写跨表 SQL 前先看源表 DDL 的列类型，不要凭列名猜。
--
-- 【本脚本产出的表】
--   ads_s4_order_features —— 订单 × 特征宽表（含标签），训练与预测同源
--   ads_s4_eval / ads_s4_gain / ads_s4_importance —— 空表，由 s4_01 回写
-- ============================================================================

USE olist_dw;
SET NAMES utf8mb4;

-- ============================================================================
-- 〇、跑前诊断：差评率长什么样（决定这是不是个值得做的预警问题）
-- ============================================================================
SELECT YEAR(purchase_ts) AS 年,
       COUNT(*)                                              AS 有评分已送达订单,
       SUM(review_score <= 2)                                AS 差评单,
       ROUND(AVG(review_score <= 2), 4)                      AS 差评率,
       ROUND(AVG(review_score), 2)                          AS 均分
FROM dwd_orders
WHERE is_delivered = 1 AND review_score IS NOT NULL AND purchase_ts IS NOT NULL
GROUP BY YEAR(purchase_ts)
ORDER BY 1;
-- 读法：差评率若在 8%~20% 之间，是不平衡但可建模的量级；
--       若 < 1% 则样本不足，应放宽 is_bad 阈值到 ≤3 再讨论。


-- ============================================================================
-- 一、ads_s4_order_features：订单粒度特征宽表（含标签）
-- ============================================================================
DROP TABLE IF EXISTS ads_s4_order_features;
CREATE TABLE ads_s4_order_features (
  order_id              VARCHAR(32)  NOT NULL,
  stat_month            DATE         NOT NULL COMMENT '归属月（purchase_ts，模型按它切时间）',
  is_bad                TINYINT      NOT NULL COMMENT '标签：1=review_score≤2',
  -- ── 履约特征（签收时点可知）─────────────────────────────────
  is_late               TINYINT      COMMENT '延迟（签收>承诺）',
  delay_hours           DECIMAL(8,1) COMMENT '带符号延迟小时',
  total_delivery_hours  DECIMAL(8,1),
  lastmile_hours        DECIMAL(8,1),
  carrier_hours         DECIMAL(8,1),
  approve_hours         DECIMAL(8,1),
  estimated_hours       DECIMAL(8,1) COMMENT '平台承诺时效（看承诺本身是否埋雷）',
  is_seller_late        TINYINT      COMMENT '卖家违约：交承运商晚于订单内最早发货截止',
  avg_distance_km       DECIMAL(8,1) COMMENT '买卖家平均直线距离',
  -- ── 订单特征（下单即知）─────────────────────────────────────
  order_amount          DECIMAL(10,2),
  freight_ratio         DECIMAL(6,4) COMMENT '运费 / 订单金额',
  item_cnt              INT,
  seller_cnt            INT,
  product_cnt           INT,
  pay_type_cnt          TINYINT      COMMENT '支付方式种类数（⚠️ dwd.pay_types 是"/"连接的字符串，不是计数）',
  has_credit_card       TINYINT      COMMENT '是否含信用卡支付（分期只为信用卡服务）',
  max_installments      INT,
  -- ── 商品静态特征（订单内明细行均值）─────────────────────────
  photos_qty            DECIMAL(6,1),
  description_length    DECIMAL(8,1),
  weight_g              DECIMAL(10,1),
  volume_cm3            DECIMAL(10,1),
  -- ── 历史特征（防泄漏：周粒度 + 30 天滞后保护 + 90 天窗口）────
  seller_hist_cnt       INT          COMMENT '卖家在知识窗内的历史订单数（历史可信度）',
  seller_hist_bad_rate  DECIMAL(6,4) COMMENT '卖家历史差评率（窗内池化）',
  cat_hist_cnt          INT,
  cat_hist_bad_rate     DECIMAL(6,4),
  -- ── 时间特征 ────────────────────────────────────────────────
  dow                   TINYINT      COMMENT '下单星期（1=周一）',
  PRIMARY KEY (order_id),
  KEY idx_month (stat_month)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:S4差评预警特征宽表';

INSERT INTO ads_s4_order_features (
  order_id, stat_month, is_bad,
  is_late, delay_hours, total_delivery_hours, lastmile_hours, carrier_hours,
  approve_hours, estimated_hours, is_seller_late, avg_distance_km,
  order_amount, freight_ratio, item_cnt, seller_cnt, product_cnt,
  pay_type_cnt, has_credit_card, max_installments,
  photos_qty, description_length, weight_g, volume_cm3,
  seller_hist_cnt, seller_hist_bad_rate, cat_hist_cnt, cat_hist_bad_rate,
  dow
)
WITH base AS (
  -- 样本口径：已送达 + 有评分（有标签）
  SELECT o.*
  FROM dwd_orders o
  WHERE o.is_delivered = 1
    AND o.review_score IS NOT NULL
    AND o.purchase_ts IS NOT NULL
    AND o.customer_delivered_ts IS NOT NULL
    AND o.estimated_ts IS NOT NULL
),
reviewed AS (
  -- 历史特征的知识源：所有"已送达且有评分"的订单（不限样本窗口，
  -- 只要满足知识窗约束，越早的订单也能贡献历史）
  SELECT order_id, purchase_ts, review_score
  FROM dwd_orders
  WHERE is_delivered = 1
    AND review_score IS NOT NULL
    AND purchase_ts IS NOT NULL
),
wk_seller AS (
  -- 卖家 × 周 粒度的历史差评池
  SELECT i.seller_id                                        AS seller_id,
         DATE(DATE_SUB(o.purchase_ts,
                INTERVAL WEEKDAY(o.purchase_ts) DAY))      AS wk,   -- 所在周的周一
         COUNT(DISTINCT o.order_id)                         AS cnt,
         COUNT(DISTINCT CASE WHEN o.review_score <= 2 THEN o.order_id END) AS bad
  FROM reviewed o
  JOIN (SELECT DISTINCT order_id, seller_id FROM dwd_order_items) i
    ON i.order_id = o.order_id
  GROUP BY i.seller_id, DATE(DATE_SUB(o.purchase_ts, INTERVAL WEEKDAY(o.purchase_ts) DAY))
),
wk_cat AS (
  -- 品类 × 周 粒度的历史差评池
  SELECT i.category_en                                      AS category_en,
         DATE(DATE_SUB(o.purchase_ts,
                INTERVAL WEEKDAY(o.purchase_ts) DAY))      AS wk,
         COUNT(DISTINCT o.order_id)                         AS cnt,
         COUNT(DISTINCT CASE WHEN o.review_score <= 2 THEN o.order_id END) AS bad
  FROM reviewed o
  JOIN (SELECT DISTINCT order_id, category_en FROM dwd_order_items
        WHERE category_en IS NOT NULL) i
    ON i.order_id = o.order_id
  GROUP BY i.category_en, DATE(DATE_SUB(o.purchase_ts, INTERVAL WEEKDAY(o.purchase_ts) DAY))
),
pair_seller AS (
  SELECT DISTINCT b.order_id, b.purchase_ts, i.seller_id
  FROM base b
  JOIN dwd_order_items i ON i.order_id = b.order_id
  WHERE i.seller_id IS NOT NULL
),
pair_cat AS (
  SELECT DISTINCT b.order_id, b.purchase_ts, i.category_en
  FROM base b
  JOIN dwd_order_items i ON i.order_id = b.order_id
  WHERE i.category_en IS NOT NULL
),
seller_hist AS (
  -- 周结束日（周一+6=周日）距 purchase_ts ≥30 天才可用；知识窗 90 天
  SELECT p.order_id,
         SUM(w.cnt)                AS hist_cnt,
         SUM(w.bad) / NULLIF(SUM(w.cnt), 0) AS bad_rate
  FROM pair_seller p
  JOIN wk_seller w
    ON w.seller_id = p.seller_id
   AND DATE_ADD(w.wk, INTERVAL 6 DAY) <= p.purchase_ts - INTERVAL 30 DAY
   AND DATE_ADD(w.wk, INTERVAL 6 DAY) >= p.purchase_ts - INTERVAL 120 DAY
  GROUP BY p.order_id
),
cat_hist AS (
  SELECT p.order_id,
         SUM(w.cnt)                AS hist_cnt,
         SUM(w.bad) / NULLIF(SUM(w.cnt), 0) AS bad_rate
  FROM pair_cat p
  JOIN wk_cat w
    ON w.category_en = p.category_en
   AND DATE_ADD(w.wk, INTERVAL 6 DAY) <= p.purchase_ts - INTERVAL 30 DAY
   AND DATE_ADD(w.wk, INTERVAL 6 DAY) >= p.purchase_ts - INTERVAL 120 DAY
  GROUP BY p.order_id
),
seller_limit AS (
  -- 订单内最早发货截止（判卖家违约，与 S3 口径一致）
  SELECT order_id, MIN(shipping_limit_ts) AS min_limit_ts
  FROM dwd_order_items
  WHERE shipping_limit_ts IS NOT NULL
  GROUP BY order_id
),
prod_feat AS (
  -- 商品静态特征：明细行粒度均值（多商品订单取均值，粗但稳）
  SELECT i.order_id,
         AVG(p.photos_qty)         AS photos_qty,
         AVG(p.description_length) AS description_length,
         AVG(p.weight_g)           AS weight_g,
         AVG(p.volume_cm3)         AS volume_cm3
  FROM dwd_order_items i
  JOIN dwd_products p ON p.product_id = i.product_id
  GROUP BY i.order_id
)
SELECT
  b.order_id,
  DATE(DATE_FORMAT(b.purchase_ts, '%Y-%m-01')),
  CASE WHEN b.review_score <= 2 THEN 1 ELSE 0 END,
  b.is_late,
  b.delay_hours,
  CASE WHEN b.total_delivery_hours >= 0 THEN b.total_delivery_hours END,
  CASE WHEN b.lastmile_hours      >= 0 THEN b.lastmile_hours      END,
  CASE WHEN b.carrier_hours        >= 0 THEN b.carrier_hours        END,
  CASE WHEN b.approve_hours        >= 0 THEN b.approve_hours        END,
  b.estimated_hours,
  CASE WHEN sl.min_limit_ts IS NOT NULL AND b.carrier_ts IS NOT NULL
             AND b.carrier_ts > sl.min_limit_ts THEN 1 ELSE 0 END,
  b.avg_distance_km,
  b.order_amount,
  ROUND(b.freight_amount / NULLIF(b.order_amount, 0), 4),
  b.item_cnt, b.seller_cnt, b.product_cnt,
  -- ⚠️ pay_types 是 "/" 连接的字符串（如 'boleto/credit_card'），
  --    不能直接进数值列：拆成「支付方式种类数」和「是否含信用卡」两个特征
  CASE WHEN b.pay_types IS NULL THEN NULL
       ELSE CHAR_LENGTH(b.pay_types) - CHAR_LENGTH(REPLACE(b.pay_types, '/', '')) + 1 END,
  CASE WHEN b.pay_types IS NULL THEN NULL
       WHEN b.pay_types LIKE '%credit_card%' THEN 1 ELSE 0 END,
  b.max_installments,
  ROUND(pf.photos_qty, 1), ROUND(pf.description_length, 1),
  ROUND(pf.weight_g, 1), ROUND(pf.volume_cm3, 1),
  sh.hist_cnt, ROUND(sh.bad_rate, 4),
  ch.hist_cnt, ROUND(ch.bad_rate, 4),
  WEEKDAY(b.purchase_ts) + 1
FROM base b
LEFT JOIN seller_limit sl ON sl.order_id = b.order_id
LEFT JOIN prod_feat   pf ON pf.order_id = b.order_id
LEFT JOIN seller_hist sh ON sh.order_id = b.order_id
LEFT JOIN cat_hist    ch ON ch.order_id = b.order_id;


-- ============================================================================
-- 二、统计结果空表（DDL 统一在 SQL 层，由 s4_01 回写）
-- ============================================================================
DROP TABLE IF EXISTS ads_s4_eval;
CREATE TABLE ads_s4_eval (
  model      VARCHAR(40)  NOT NULL COMMENT 'logreg / hgb',
  metric     VARCHAR(40)  NOT NULL COMMENT 'pr_auc / roc_auc / brier / threshold_f1 / ...',
  value      DOUBLE       NOT NULL COMMENT '统一转数值',
  note       VARCHAR(200),
  updated_at DATETIME,
  PRIMARY KEY (model, metric)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:S4模型评估指标(s4_01回写)';

DROP TABLE IF EXISTS ads_s4_gain;
CREATE TABLE ads_s4_gain (
  model         VARCHAR(40)  NOT NULL,
  top_pct       DECIMAL(5,2) NOT NULL COMMENT '按风险分取头部比例',
  n_orders      INT          COMMENT '干预单量',
  n_bad_total   INT          COMMENT '测试集差评总数',
  captured      INT          COMMENT '头部捕获的差评数',
  recall        DECIMAL(6,4) COMMENT '差评捕获率 = captured / n_bad_total',
  precision_    DECIMAL(6,4) COMMENT '命中精度 = captured / n_orders',
  lift          DECIMAL(6,4) COMMENT 'precision / 基准差评率',
  cost_brl      DECIMAL(12,2) COMMENT '干预成本 = n_orders × 单券成本',
  cost_per_bad  DECIMAL(10,2) COMMENT '每拦截一单差评的成本',
  updated_at    DATETIME,
  PRIMARY KEY (model, top_pct)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:S4干预增益曲线(s4_01回写)';

DROP TABLE IF EXISTS ads_s4_importance;
CREATE TABLE ads_s4_importance (
  model       VARCHAR(40)  NOT NULL,
  feature     VARCHAR(60)  NOT NULL,
  importance  DECIMAL(10,6),
  rank_no     INT          COMMENT '模型内降序排名',
  updated_at  DATETIME,
  PRIMARY KEY (model, feature)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:S4特征重要性(s4_01回写)';


-- ============================================================================
-- 三、勾稽自检（失败先排查，不许放宽容差）
-- ============================================================================
-- 3.1 行数 = 样本口径订单数
SELECT (SELECT COUNT(*) FROM ads_s4_order_features) AS 特征表行数,
       (SELECT COUNT(*) FROM dwd_orders
        WHERE is_delivered = 1 AND review_score IS NOT NULL
          AND purchase_ts IS NOT NULL
          AND customer_delivered_ts IS NOT NULL AND estimated_ts IS NOT NULL) AS 口径行数;
-- 预期：两数相等。

-- 3.2 标签取值合法
SELECT is_bad, COUNT(*) FROM ads_s4_order_features GROUP BY is_bad;
-- 预期：只有 0 / 1 两行。

-- 3.3 防泄漏检查：2017-02 之前（知识窗冷启动期）的历史特征应基本为空
SELECT DATE_FORMAT(stat_month, '%Y-%m') AS 月份,
       COUNT(*)                                          AS 订单数,
       SUM(seller_hist_cnt IS NOT NULL)                  AS 有卖家历史,
       ROUND(AVG(seller_hist_cnt), 1)                     AS 平均卖家历史单数,
       ROUND(AVG(cat_hist_cnt), 1)                        AS 平均品类历史单数
FROM ads_s4_order_features
GROUP BY DATE_FORMAT(stat_month, '%Y-%m')
ORDER BY 1;
-- 读法：2017-01/02 的"有卖家历史"应接近 0，随后逐月上升；
--       若首月就有大量历史，说明知识窗约束没生效（泄漏），必须回头查。

-- 3.4 历史差评率不得为负或 >1
SELECT COUNT(*) AS 违规行数 FROM ads_s4_order_features
WHERE seller_hist_bad_rate < 0 OR seller_hist_bad_rate > 1
   OR cat_hist_bad_rate    < 0 OR cat_hist_bad_rate    > 1;
-- 预期：0。
