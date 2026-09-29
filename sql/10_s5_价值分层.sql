-- ============================================================================
-- S5 价值分层：客户 / 品类 / 卖家
--   产出：
--     1. ads_s5_rfm_v2              客户分层（修正版 RFM，三维二值八格）
--     2. ads_s5_repeat_compare      复购客 vs 单次客 画像对比（2 行）
--     3. ads_s5_experience_repeat_base  首购体验 × 复购率 交叉表（长表，供 s5_02 加 CI）
--     4. ads_s5_survival_input      生存分析 + 倾向得分匹配 的客户级输入
--     5. ads_s5_layer_strategy      分层运营策略表（动作 + 预算权重占比）
--     6. ads_s5_cluster_eval        【空表，s5_01 回写】K-means 评估
--     7. ads_s5_experience_repeat   【空表，s5_02 回写】体验→复购率（含 Wilson CI）
--     8. ads_s5_survival_curve      【空表，s5_02 回写】KM 生存曲线
--     9. ads_s5_experience_effect   【空表，s5_02 回写】PSM 效应估计
--
-- 依赖：dwd_orders / dws_user_profile / ads_category_matrix / ads_seller_scorecard
-- 执行顺序：sql/01 → 02 → 03 → 本脚本 → python s5_01 → python s5_02
--
-- ⚠️ 前置：dws_user_profile 依赖 sql/02 里 SET @base_date，请确认 02 已按顺序跑过。
-- ============================================================================


-- ============================================================================
-- 〇、为什么 S5 要重做 RFM（而不用 sql/02 里已经算好的 rfm_segment）
-- ============================================================================
-- 【诊断】sql/02 的 f_score 用 NTILE(5) OVER (ORDER BY order_cnt) 生成。
-- 但 Olist 复购率只有约 3%，即 96%+ 的客户 order_cnt = 1 —— 这是一个巨大的并列值。
-- NTILE 遇到并列值不会"合并档位"，而是按行位置硬切成 5 等份，于是：
--     排序键 order_cnt ASC + customer_unique_id 做 tie-break
--     → 前 4 档全部落在 order_cnt = 1 的客户里（彼此无任何频次差异）
--     → 第 5 档里混了"剩下的单次客" + "全部复购客"
-- 后果：f_score ≥ 4 的"重要价值客户"里，一半是纯靠 tie-break 随机命中的单次客。
--       也就是说 sql/02 的八类人群标签有一半是噪声。
-- 结论：F 维度的分箱数必须服从数据的区分能力。3% 复购率下，任何 ≥3 档的频次分箱
--       都只是在制造噪声，F 只能做二值（复购 / 单次）。
-- ⇒ S5 采用「三维二值 RFM」：
--     R = recency_days <= 180 天（活跃 / 沉睡）—— 业务阈值，非分位数
--     F = order_cnt >= 2（复购 / 单次）—— 数据事实，二分
--     M = monetary > 全体中位数（高值 / 低值）—— 中位数切分，保证八格规模可比
--   8 格全部有实际区分度，且每格都能落一个运营动作。
--
-- 下面 0.1 是这条诊断的证据查询，跑完请人工扫一眼：若 f_score 1~4 档的
-- min_order_cnt 与 max_order_cnt 都是 1，就证实了上述判断。
-- ----------------------------------------------------------------------------
-- 0.1 【诊断·证据】旧 f_score 各档的真实 order_cnt 分布
SELECT f_score,
       COUNT(*)                                       AS users,
       MIN(order_cnt)                                 AS min_order_cnt,
       MAX(order_cnt)                                 AS max_order_cnt,
       SUM(CASE WHEN order_cnt = 1 THEN 1 ELSE 0 END) AS single_orders_users,
       SUM(is_repeat)                                 AS repeat_users
FROM dws_user_profile
GROUP BY f_score
ORDER BY f_score;
-- 预期：f_score = 1~4 的 min=max=1、repeat_users=0（四档完全同质，分箱失效）
--       f_score = 5 集中了全部复购客


-- ============================================================================
-- 一、ads_s5_rfm_v2：修正版客户分层（三维二值八格）
-- ============================================================================
DROP TABLE IF EXISTS ads_s5_rfm_v2;
CREATE TABLE ads_s5_rfm_v2 (
  rfm_code          CHAR(3)       NOT NULL COMMENT '编码，位序 R|F|M，1=活跃/复购/高值',
  segment_name      VARCHAR(20)   NOT NULL,
  segment_desc      VARCHAR(80),
  r_flag            TINYINT       COMMENT '1=活跃(recency<=180天)',
  f_flag            TINYINT       COMMENT '1=复购(order_cnt>=2)',
  m_flag            TINYINT       COMMENT '1=高值(monetary>中位数)',
  customers         INT,
  customers_pct     DECIMAL(6,2),
  total_monetary    DECIMAL(16,2),
  monetary_pct      DECIMAL(6,2)  COMMENT 'GMV 贡献占比',
  avg_monetary      DECIMAL(12,2),
  avg_order_cnt     DECIMAL(8,2),
  avg_recency_days  DECIMAL(8,1),
  repeat_customers  INT,
  repeat_rate       DECIMAL(6,4),
  thr_recency_days  INT           COMMENT '本表所用的 R 切点（天数）',
  thr_monetary      DECIMAL(12,2) COMMENT '本表所用的 M 切点（金额）',
  PRIMARY KEY (rfm_code)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:S5修正版RFM分层(三维二值八格)';

INSERT INTO ads_s5_rfm_v2
WITH med AS (
  -- MySQL 8.0 没有 PERCENTILE_CONT，用行号取中位数（偶数个取中间两个的均值）
  SELECT AVG(monetary) AS med_monetary
  FROM (
    SELECT monetary,
           ROW_NUMBER() OVER (ORDER BY monetary) AS rn,
           COUNT(*)     OVER ()                  AS n
    FROM dws_user_profile
  ) t
  WHERE rn IN (FLOOR((n + 1) / 2), CEIL((n + 1) / 2))
),
flagged AS (
  SELECT u.customer_unique_id,
         u.monetary,
         u.order_cnt,
         u.recency_days,
         CASE WHEN u.recency_days <= 180 THEN 1 ELSE 0 END AS r_flag,
         CASE WHEN u.order_cnt   >= 2   THEN 1 ELSE 0 END AS f_flag,
         CASE WHEN u.monetary > (SELECT med_monetary FROM med) THEN 1 ELSE 0 END AS m_flag
  FROM dws_user_profile u
),
agg AS (
  SELECT CONCAT(r_flag, f_flag, m_flag) AS rfm_code,
         COUNT(*)                                          AS customers,
         ROUND(SUM(monetary), 2)                           AS total_monetary,
         ROUND(AVG(monetary), 2)                           AS avg_monetary,
         ROUND(AVG(order_cnt), 2)                          AS avg_order_cnt,
         ROUND(AVG(recency_days), 1)                       AS avg_recency_days,
         SUM(f_flag)                                       AS repeat_customers
  FROM flagged
  GROUP BY CONCAT(r_flag, f_flag, m_flag)
),
tot AS (
  SELECT SUM(customers) AS all_customers, SUM(total_monetary) AS all_monetary FROM agg
)
SELECT a.rfm_code,
       CASE a.rfm_code
         WHEN '111' THEN '核心活跃客'
         WHEN '110' THEN '活跃复购客'
         WHEN '101' THEN '活跃高值单客'
         WHEN '100' THEN '活跃低值单客'
         WHEN '011' THEN '沉睡高值复购客'
         WHEN '010' THEN '沉睡低值复购客'
         WHEN '001' THEN '沉睡高值单客'
         ELSE            '沉睡低值单客'
       END AS segment_name,
       CASE a.rfm_code
         WHEN '111' THEN '近180天有单 + 复购 + 消费高值：平台最核心资产'
         WHEN '110' THEN '近180天有单 + 复购 + 消费低值：买得勤但客单低'
         WHEN '101' THEN '近180天有单 + 单次 + 消费高值：最强复购潜力池'
         WHEN '100' THEN '近180天有单 + 单次 + 消费低值：首购客主体'
         WHEN '011' THEN '超180天未下单 + 复购 + 消费高值：高价值流失预警'
         WHEN '010' THEN '超180天未下单 + 复购 + 消费低值：自然流失'
         WHEN '001' THEN '超180天未下单 + 单次 + 消费高值：一次性大额客户'
         ELSE            '超180天未下单 + 单次 + 消费低值：低价值流失'
       END AS segment_desc,
       CAST(SUBSTRING(a.rfm_code, 1, 1) AS UNSIGNED) AS r_flag,
       CAST(SUBSTRING(a.rfm_code, 2, 1) AS UNSIGNED) AS f_flag,
       CAST(SUBSTRING(a.rfm_code, 3, 1) AS UNSIGNED) AS m_flag,
       a.customers,
       ROUND(a.customers / NULLIF(t.all_customers, 0) * 100, 2)  AS customers_pct,
       a.total_monetary,
       ROUND(a.total_monetary / NULLIF(t.all_monetary, 0) * 100, 2) AS monetary_pct,
       a.avg_monetary, a.avg_order_cnt, a.avg_recency_days, a.repeat_customers,
       ROUND(a.repeat_customers / NULLIF(a.customers, 0), 4)     AS repeat_rate,
       180                                                       AS thr_recency_days,
       (SELECT ROUND(med_monetary, 2) FROM med)                  AS thr_monetary
FROM agg a
CROSS JOIN tot t;


-- ============================================================================
-- 二、ads_s5_survival_input：生存分析 + 倾向得分匹配 的客户级输入
-- ----------------------------------------------------------------------------
-- 【口径声明 · 三条都要写进报告】
-- 1) 窗口左截断：只看 purchase_ts >= 2017-01-01 的订单，"首购"= 窗口内首单。
--    2016 年就下过单的老客会被重新认定为窗口内首购（数量很小），必须声明。
-- 2) 复购定义：窗口内第二单 → event = 1；否则 event = 0（右删失）。
-- 3) 只存"原始事实"（days_to_repeat / tenure_days），不在这里做截尾。
--    KM 的最大观察天数（S5_KM_MAX_DAYS）属于分析参数，锁在 config.py，
--    避免 SQL 与 Python 两处常量漂移。
-- ============================================================================
DROP TABLE IF EXISTS ads_s5_survival_input;
CREATE TABLE ads_s5_survival_input (
  customer_unique_id  VARCHAR(50) NOT NULL,
  first_order_id      VARCHAR(50),
  first_order_date    DATE        COMMENT '窗口内首购日',
  second_order_date   DATE        COMMENT '窗口内第二单日，NULL=未复购',
  days_to_repeat      INT         COMMENT '首购→复购间隔天数，NULL=未复购',
  tenure_days         INT         COMMENT '观察期长度 = 快照日 - 首购日',
  event               TINYINT     COMMENT '1=观察期内复购',
  first_cohort_month  DATE        COMMENT '首购月（同期群）',
  first_amount        DECIMAL(12,2) COMMENT '首单金额（PSM 协变量）',
  first_item_cnt      INT,
  first_seller_cnt    INT,
  first_dist_km       DECIMAL(8,1),
  first_state         CHAR(2),
  first_installments  INT,
  first_pay_type_cnt  INT,
  first_freight_ratio DECIMAL(8,4),
  first_is_late       TINYINT     COMMENT '首单是否延迟（PSM 处理变量）',
  first_review_score  DECIMAL(4,2) COMMENT '首单评分（PSM 结果变量之一）',
  PRIMARY KEY (customer_unique_id),
  KEY idx_s5_surv_event (event),
  KEY idx_s5_surv_late  (first_is_late)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:S5生存分析/PSM客户级输入';

INSERT INTO ads_s5_survival_input
WITH snap AS (
  SELECT DATE_ADD(DATE(MAX(purchase_ts)), INTERVAL 1 DAY) AS snap_date
  FROM dwd_orders
),
win AS (
  SELECT o.*
  FROM dwd_orders o
  WHERE o.purchase_ts >= '2017-01-01'
    AND o.purchase_ts IS NOT NULL
    AND o.customer_unique_id IS NOT NULL
),
rk AS (
  SELECT w.customer_unique_id, w.order_id, w.purchase_ts,
         ROW_NUMBER() OVER (PARTITION BY w.customer_unique_id
                            ORDER BY w.purchase_ts, w.order_id) AS rn
  FROM win w
),
f1 AS (SELECT * FROM rk WHERE rn = 1),
f2 AS (
  SELECT customer_unique_id, MIN(purchase_ts) AS second_ts
  FROM rk WHERE rn >= 2
  GROUP BY customer_unique_id
),
detail AS (
  SELECT w.customer_unique_id, w.order_id, w.purchase_ts, w.order_amount, w.item_cnt,
         w.seller_cnt, w.avg_distance_km, w.customer_state, w.max_installments,
         w.freight_amount, w.pay_types, w.is_late, w.review_score
  FROM win w
)
SELECT
  f1.customer_unique_id,
  f1.order_id                                                      AS first_order_id,
  DATE(f1.purchase_ts)                                             AS first_order_date,
  DATE(f2.second_ts)                                               AS second_order_date,
  DATEDIFF(f2.second_ts, f1.purchase_ts)                           AS days_to_repeat,
  DATEDIFF(s.snap_date, f1.purchase_ts)                            AS tenure_days,
  CASE WHEN f2.second_ts IS NOT NULL THEN 1 ELSE 0 END             AS event,
  DATE(DATE_FORMAT(f1.purchase_ts, '%Y-%m-01'))                    AS first_cohort_month,
  d.order_amount                                                   AS first_amount,
  d.item_cnt                                                       AS first_item_cnt,
  d.seller_cnt                                                     AS first_seller_cnt,
  d.avg_distance_km                                                AS first_dist_km,
  d.customer_state                                                 AS first_state,
  d.max_installments                                               AS first_installments,
  CASE WHEN d.pay_types IS NULL THEN NULL
       ELSE CHAR_LENGTH(d.pay_types) - CHAR_LENGTH(REPLACE(d.pay_types, '/', '')) + 1
  END                                                              AS first_pay_type_cnt,
  ROUND(d.freight_amount / NULLIF(d.order_amount, 0), 4)            AS first_freight_ratio,
  d.is_late                                                        AS first_is_late,
  d.review_score                                                   AS first_review_score
FROM f1
CROSS JOIN snap s
JOIN detail d ON d.order_id = f1.order_id
LEFT JOIN f2 ON f2.customer_unique_id = f1.customer_unique_id;


-- ============================================================================
-- 三、ads_s5_repeat_compare：复购客 vs 单次客 画像对比（2 行）
-- ============================================================================
DROP TABLE IF EXISTS ads_s5_repeat_compare;
CREATE TABLE ads_s5_repeat_compare (
  group_code          VARCHAR(12) NOT NULL COMMENT 'repeat / single',
  group_name          VARCHAR(12),
  customers           INT,
  customers_pct       DECIMAL(6,2),
  avg_first_amount    DECIMAL(12,2),
  avg_item_cnt        DECIMAL(8,2),
  avg_seller_cnt      DECIMAL(8,2),
  avg_dist_km         DECIMAL(10,1),
  avg_installments    DECIMAL(8,2),
  avg_freight_ratio   DECIMAL(8,4),
  late_rate           DECIMAL(6,4) COMMENT '首单延迟率',
  bad_review_rate     DECIMAL(6,4) COMMENT '首单差评率(<=2分)',
  avg_review_score    DECIMAL(4,2),
  delivered_ratio     DECIMAL(6,4) COMMENT '首单已送达占比（延迟率的分母口径提示）',
  PRIMARY KEY (group_code)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:S5复购vs单次画像';

INSERT INTO ads_s5_repeat_compare
WITH base AS (
  SELECT event, first_amount, first_item_cnt, first_seller_cnt, first_dist_km,
         first_installments, first_freight_ratio, first_is_late, first_review_score
  FROM ads_s5_survival_input
),
tot AS (SELECT COUNT(*) AS n FROM base)
SELECT
  CASE b.event WHEN 1 THEN 'repeat' ELSE 'single' END AS group_code,
  CASE b.event WHEN 1 THEN '复购客'  ELSE '单次客'  END AS group_name,
  COUNT(*)                                                     AS customers,
  ROUND(COUNT(*) / NULLIF((SELECT n FROM tot), 0) * 100, 2)     AS customers_pct,
  ROUND(AVG(b.first_amount), 2)                                 AS avg_first_amount,
  ROUND(AVG(b.first_item_cnt), 2)                               AS avg_item_cnt,
  ROUND(AVG(b.first_seller_cnt), 2)                             AS avg_seller_cnt,
  ROUND(AVG(b.first_dist_km), 1)                                AS avg_dist_km,
  ROUND(AVG(b.first_installments), 2)                           AS avg_installments,
  ROUND(AVG(b.first_freight_ratio), 4)                          AS avg_freight_ratio,
  ROUND(AVG(b.first_is_late), 4)                                AS late_rate,
  ROUND(AVG(CASE WHEN b.first_review_score <= 2 THEN 1
                 WHEN b.first_review_score IS NULL THEN NULL
                 ELSE 0 END), 4)                                 AS bad_review_rate,
  ROUND(AVG(b.first_review_score), 2)                           AS avg_review_score,
  ROUND(AVG(CASE WHEN b.first_is_late IS NULL THEN 0 ELSE 1 END), 4) AS delivered_ratio
FROM base b
GROUP BY b.event;


-- ============================================================================
-- 四、ads_s5_experience_repeat_base：首购体验 × 复购率 交叉表（长表）
-- ----------------------------------------------------------------------------
-- 设计说明：SQL 只输出"事实"（人数、复购人数），
--           Wilson 置信区间与 FDR 校正属于统计推断 → 交给 s5_02。
--           产出表名带 _base 后缀，与 S3 的 ads_s3_bottleneck_base 同一约定。
-- ============================================================================
DROP TABLE IF EXISTS ads_s5_experience_repeat_base;
CREATE TABLE ads_s5_experience_repeat_base (
  dim_type          VARCHAR(30) NOT NULL,
  dim_value         VARCHAR(40) NOT NULL,
  customers         INT,
  repeat_customers  INT,
  PRIMARY KEY (dim_type, dim_value)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:S5首购体验×复购率(事实层)';

INSERT INTO ads_s5_experience_repeat_base
WITH base AS (
  SELECT s.customer_unique_id, s.event, s.first_is_late, s.first_review_score,
         s.first_amount, s.first_item_cnt, s.first_dist_km, s.first_state,
         s.first_cohort_month,
         NTILE(4) OVER (ORDER BY s.first_amount, s.customer_unique_id) AS amount_q
  FROM ads_s5_survival_input s
),
d1 AS (
  SELECT 'first_is_late' AS dim_type,
         CASE first_is_late WHEN 1 THEN '延迟' WHEN 0 THEN '准时' ELSE '未送达' END AS dim_value,
         COUNT(*) AS customers, SUM(event) AS repeat_customers
  FROM base GROUP BY 1, 2
),
d2 AS (
  SELECT 'first_score' AS dim_type,
         CASE WHEN first_review_score IS NULL THEN '无评价'
              WHEN first_review_score <= 2    THEN '差评(1-2)'
              WHEN first_review_score <  4    THEN '中评(3)'
              ELSE                                 '好评(4-5)' END AS dim_value,
         COUNT(*) AS customers, SUM(event) AS repeat_customers
  FROM base GROUP BY 1, 2
),
d3 AS (
  SELECT 'first_amount_q' AS dim_type,
         CONCAT('Q', amount_q) AS dim_value,
         COUNT(*) AS customers, SUM(event) AS repeat_customers
  FROM base GROUP BY 1, 2
),
d4 AS (
  SELECT 'first_dist_km' AS dim_type,
         CASE WHEN first_dist_km IS NULL  THEN '未知'
              WHEN first_dist_km <  100   THEN '0-100'
              WHEN first_dist_km <  300   THEN '100-300'
              WHEN first_dist_km <  700   THEN '300-700'
              WHEN first_dist_km < 1500   THEN '700-1500'
              ELSE                             '1500+' END AS dim_value,
         COUNT(*) AS customers, SUM(event) AS repeat_customers
  FROM base GROUP BY 1, 2
),
d5 AS (
  SELECT 'first_item_cnt' AS dim_type,
         CASE WHEN first_item_cnt = 1 THEN '1件'
              WHEN first_item_cnt = 2 THEN '2件'
              ELSE                         '3件+' END AS dim_value,
         COUNT(*) AS customers, SUM(event) AS repeat_customers
  FROM base GROUP BY 1, 2
),
d6 AS (
  SELECT 'first_state' AS dim_type,
         IFNULL(first_state, '未知') AS dim_value,
         COUNT(*) AS customers, SUM(event) AS repeat_customers
  FROM base GROUP BY 1, 2
),
d7 AS (
  SELECT 'first_cohort_month' AS dim_type,
         DATE_FORMAT(first_cohort_month, '%Y-%m') AS dim_value,
         COUNT(*) AS customers, SUM(event) AS repeat_customers
  FROM base GROUP BY 1, 2
)
SELECT * FROM d1
UNION ALL SELECT * FROM d2
UNION ALL SELECT * FROM d3
UNION ALL SELECT * FROM d4
UNION ALL SELECT * FROM d5
UNION ALL SELECT * FROM d6
UNION ALL SELECT * FROM d7;


-- ============================================================================
-- 五、ads_s5_layer_strategy：分层运营策略表（用户 8 格 + 品类象限 + 卖家 4 级 = 15 行）
-- ----------------------------------------------------------------------------
-- 粒度说明：品类层按"象限"汇总（3 行），不按品类铺开（72 行）。
--   ads_category_matrix 里没有"明星品类"，只有 现金牛 18 / 潜力 7 / 观察汰换 47。
-- 预算权重公式（可追溯，不是拍脑袋）：
--     weight        = 该层 GMV 占比（%） × 策略系数
--     budget_share  = weight / Σweight × 100
-- 策略系数（数值越小 = 越不需要补贴，因为客户/品类本身就会贡献）：
--     促复购（高值单客）        ×1.5   首购已证明支付力，复购是最便宜的增量
--     召回（沉睡复购客）        ×1.2   有购买习惯，唤醒成本低
--     高价值流失预警            ×1.1   金额大、值得一次定向挽回
--     维护（核心活跃客）        ×0.8   本来就会买，补贴是浪费
--     低值单客                  ×0.6   先验证转化率再放量
--     低价值流失                ×0.3   只做低成本触达
-- ⚠️ 这些系数是"建议初值"，必须用 S6 的实验去校准，不能当成既定结论。
-- ============================================================================
DROP TABLE IF EXISTS ads_s5_layer_strategy;
CREATE TABLE ads_s5_layer_strategy (
  layer_type       VARCHAR(12) NOT NULL COMMENT 'user / category / seller',
  layer_value      VARCHAR(60) NOT NULL,
  layer_name       VARCHAR(40),
  base_cnt         INT          COMMENT '用户数 / 品类数 / 卖家数',
  gmv              DECIMAL(16,2),
  gmv_share_pct    DECIMAL(6,2),
  action           VARCHAR(80)  COMMENT '运营动作',
  priority         VARCHAR(8)   COMMENT 'P0/P1/P2',
  strategy_coef    DECIMAL(6,2) COMMENT '策略系数（见脚本注释）',
  budget_weight    DECIMAL(12,4) COMMENT 'gmv_share_pct × strategy_coef',
  budget_share_pct DECIMAL(6,2) COMMENT '归一化后的预算占比建议',
  rationale        VARCHAR(120),
  PRIMARY KEY (layer_type, layer_value)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:S5分层运营策略表（用户8格 + 品类象限 + 卖家4级 = 15行）';

INSERT INTO ads_s5_layer_strategy
WITH u AS (
  SELECT 'user' AS layer_type, rfm_code AS layer_value, segment_name AS layer_name,
         customers AS base_cnt, total_monetary AS gmv,
         CASE rfm_code
           WHEN '101' THEN '高值单客复购激励：首单后 30 天定向券 + 品类交叉推荐'
           WHEN '111' THEN '核心客维护：会员权益 + 新品优先购（不做现金补贴）'
           WHEN '011' THEN '高价值流失召回：专属客服电话回访 + 大额召回券'
           WHEN '001' THEN '一次性大额客户唤醒：同类目新品推荐 + 免运费'
           WHEN '110' THEN '活跃复购客提客单：满减／搭售组合包'
           WHEN '010' THEN '低值复购客低成本触达：邮件／站内信自动召回'
           WHEN '100' THEN '活跃单次客首复购：首单后 14 天首复购券'
           ELSE            '低价值流失：仅保留低成本自动化触达'
         END AS action,
         CASE rfm_code
           WHEN '101' THEN 'P0' WHEN '111' THEN 'P1' WHEN '011' THEN 'P0' WHEN '001' THEN 'P1'
           ELSE 'P2'
         END AS priority,
         CASE rfm_code
           WHEN '101' THEN 1.5 WHEN '111' THEN 0.8 WHEN '011' THEN 1.2 WHEN '001' THEN 1.1
           WHEN '110' THEN 1.0 WHEN '010' THEN 0.6 WHEN '100' THEN 0.6 ELSE 0.3
         END AS strategy_coef,
         CASE rfm_code
           WHEN '101' THEN '近180天有单且消费高值，但未复购——复购潜力最大的一格'
           WHEN '111' THEN '近180天有单、已复购、消费高值，粘性已建立'
           WHEN '011' THEN '消费高值且曾复购，但已超180天未回——流失代价最高'
           WHEN '001' THEN '单次即达高消费，说明支付力强，只是没被留住'
           WHEN '110' THEN '复购已验证，但客单偏低'
           WHEN '010' THEN '复购但金额低，唤醒 ROI 有限'
           WHEN '100' THEN '首购客主体，用低成本券试转化'
           ELSE            '既无金额也无频次，不值得投入现金'
         END AS rationale
  FROM ads_s5_rfm_v2
),
u_w AS (
  SELECT u.*, ROUND(u.gmv / NULLIF(SUM(u.gmv) OVER (), 0) * 100, 2) AS gmv_share_pct
  FROM u
),
u_f AS (
  SELECT layer_type, layer_value, layer_name, base_cnt, gmv, gmv_share_pct,
         action, priority, strategy_coef,
         ROUND(gmv_share_pct * strategy_coef, 4) AS budget_weight,
         rationale
  FROM u_w
),
u_n AS (
  SELECT layer_type, layer_value, layer_name, base_cnt, gmv, gmv_share_pct,
         action, priority, strategy_coef, budget_weight,
         ROUND(budget_weight / NULLIF(SUM(budget_weight) OVER (), 0) * 100, 2) AS budget_share_pct,
         rationale
  FROM u_f
),
c AS (
  -- ★ 品类层按「象限」汇总成 4 行，而不是按品类铺开 70+ 行：
  --   ① 象限才是策略粒度（系数、优先级都挂在象限上），铺开到品类后每行预算占比只有 0.0X%，没有决策意义；
  --   ② Tableau 上一眼能看懂"预算给哪一类品类"。
  --   品类级的明细（用来看具体是哪个品类拖后腿）留在 ads_category_matrix，不在本表重复。
  SELECT 'category' AS layer_type, quadrant AS layer_value, quadrant AS layer_name,
         COUNT(*)  AS base_cnt,
         SUM(gmv)  AS gmv,
         ROUND(SUM(gmv) / NULLIF(SUM(SUM(gmv)) OVER (), 0) * 100, 2) AS gmv_share_pct,
         CASE quadrant
           WHEN '明星品类'   THEN '加投放扩规模：搜索加权 + 联合营销'
           WHEN '现金牛品类' THEN '守份额不涨价：维持流量，严控延迟与差评'
           WHEN '潜力品类'   THEN '小步试投：A/B 测流量倾斜的边际效果'
           ELSE                  '观察汰换：降流量位，治理无果则下架'
         END AS action,
         CASE quadrant WHEN '明星品类' THEN 'P0' WHEN '现金牛品类' THEN 'P1'
                       WHEN '潜力品类' THEN 'P1' ELSE 'P2' END AS priority,
         CASE quadrant WHEN '明星品类' THEN 1.6 WHEN '现金牛品类' THEN 1.0
                       WHEN '潜力品类' THEN 1.0 ELSE 0.4 END AS strategy_coef,
         CONCAT('象限=', quadrant, '，含 ', COUNT(*), ' 个品类（近3月 ',
                ROUND(SUM(gmv_recent3), 0), ' vs 前3月 ', ROUND(SUM(gmv_prev3), 0), '）') AS rationale
  FROM ads_category_matrix
  GROUP BY quadrant
),
c_f AS (
  SELECT layer_type, layer_value, layer_name, base_cnt, gmv, gmv_share_pct,
         action, priority, strategy_coef,
         ROUND(gmv_share_pct * strategy_coef, 4) AS budget_weight,
         rationale
  FROM c
),
c_n AS (
  SELECT layer_type, layer_value, layer_name, base_cnt, gmv, gmv_share_pct,
         action, priority, strategy_coef, budget_weight,
         ROUND(budget_weight / NULLIF(SUM(budget_weight) OVER (), 0) * 100, 2) AS budget_share_pct,
         rationale
  FROM c_f
),
s AS (
  -- 卖家维度先聚合成 4 行（等价于用户分支里的 ads_s5_rfm_v2，只是它已聚合好）
  SELECT seller_level,
         COUNT(*)              AS base_cnt,
         SUM(gmv)              AS gmv,
         ROUND(AVG(bad_review_rate_pct), 2) AS avg_bad,
         ROUND(AVG(late_rate_pct), 2)       AS avg_late
  FROM ads_seller_scorecard
  GROUP BY seller_level
),
s_a AS (
  -- 与用户分支的 u 同层：补动作 / 优先级 / 策略系数 / 理由（全部基于 s 的列，不同层引用合法）
  SELECT 'seller' AS layer_type, seller_level AS layer_value, seller_level AS layer_name,
         base_cnt, gmv,
         CASE seller_level
           WHEN '重点扶持' THEN '资源倾斜：流量加权 + 优先履约通道'
           WHEN '稳定合作' THEN '维持：常规流量 + 季度复盘'
           WHEN '观察'     THEN '限期整改：连续两月差评率超标则降权'
           ELSE               '建议汰换：停止流量分配，清退低质卖家'
         END AS action,
         CASE seller_level WHEN '重点扶持' THEN 'P0' WHEN '稳定合作' THEN 'P1'
                           WHEN '观察' THEN 'P0' ELSE 'P1' END AS priority,
         CASE seller_level WHEN '重点扶持' THEN 1.5 WHEN '稳定合作' THEN 1.0
                           WHEN '观察' THEN 1.0 ELSE 0.3 END AS strategy_coef,
         CONCAT('平均差评率 ', avg_bad, '%，平均延迟率 ', avg_late, '%') AS rationale
  FROM s
),
s_w AS (
  -- 与用户分支的 u_w 同层：GMV 占比（窗口只作用于朴素列，不套窗口）
  SELECT s_a.*, ROUND(gmv / NULLIF(SUM(gmv) OVER (), 0) * 100, 2) AS gmv_share_pct
  FROM s_a
),
s_f AS (
  -- 与用户分支的 u_f 同层：预算权重 = GMV 占比 × 策略系数，列序对齐 u_n
  SELECT layer_type, layer_value, layer_name, base_cnt, gmv, gmv_share_pct,
         action, priority, strategy_coef,
         ROUND(gmv_share_pct * strategy_coef, 4) AS budget_weight,
         rationale
  FROM s_w
),
s_n AS (
  -- 与用户分支的 u_n 同层：归一化成预算占比
  SELECT layer_type, layer_value, layer_name, base_cnt, gmv, gmv_share_pct,
         action, priority, strategy_coef, budget_weight,
         ROUND(budget_weight / NULLIF(SUM(budget_weight) OVER (), 0) * 100, 2) AS budget_share_pct,
         rationale
  FROM s_f
)
SELECT * FROM u_n
UNION ALL SELECT * FROM c_n
UNION ALL SELECT * FROM s_n;


-- ============================================================================
-- 六、统计结果空表（DDL 统一在 SQL 层，由 s5_01 / s5_02 回写）
-- ============================================================================
-- 6.1 K-means 聚类评估（s5_01 回写）
DROP TABLE IF EXISTS ads_s5_cluster_eval;
CREATE TABLE ads_s5_cluster_eval (
  method     VARCHAR(30) NOT NULL COMMENT 'kmeans / cross_tab 等',
  metric     VARCHAR(40) NOT NULL COMMENT 'silhouette / ari / cluster_size / ...',
  label      VARCHAR(60) NOT NULL COMMENT '如 k=3 / cluster=0×segment',
  value      DOUBLE      COMMENT '统一转数值',
  note       VARCHAR(200),
  updated_at DATETIME,
  PRIMARY KEY (method, metric, label)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:S5聚类评估(s5_01回写)';

-- 6.2 首购体验 → 复购率（含 Wilson CI，s5_02 回写）
DROP TABLE IF EXISTS ads_s5_experience_repeat;
CREATE TABLE ads_s5_experience_repeat (
  dim_type            VARCHAR(30) NOT NULL,
  dim_value           VARCHAR(40) NOT NULL,
  customers           INT,
  repeat_customers    INT,
  repeat_rate         DECIMAL(8,4),
  rate_low            DECIMAL(8,4) COMMENT 'Wilson 95%CI 下限',
  rate_high           DECIMAL(8,4) COMMENT 'Wilson 95%CI 上限',
  diff_vs_overall_pp  DECIMAL(8,2) COMMENT '与总体复购率之差（百分点）',
  p_value_raw         DOUBLE,
  p_value_fdr         DOUBLE,
  is_significant      TINYINT      COMMENT '仅对 n>=阈值 的维度做检验，否则 NULL',
  updated_at          DATETIME,
  PRIMARY KEY (dim_type, dim_value)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:S5体验→复购率(s5_02回写)';

-- 6.3 KM 生存曲线（s5_02 回写）
DROP TABLE IF EXISTS ads_s5_survival_curve;
CREATE TABLE ads_s5_survival_curve (
  group_code  VARCHAR(30) NOT NULL COMMENT 'all / first_late / first_ontime / ...',
  t_days      INT         NOT NULL COMMENT '首购后第 t 天',
  at_risk     INT         COMMENT '风险集人数',
  events      INT         COMMENT '该时点事件数（复购）',
  surv        DECIMAL(8,6) COMMENT 'KM 生存率 = 仍未复购的比例',
  cum_ret     DECIMAL(8,6) COMMENT '累计复购率 = 1 - surv',
  ci_low      DECIMAL(8,6) COMMENT 'Greenwood 对数-log 95%CI 下限',
  ci_high     DECIMAL(8,6),
  median_days DECIMAL(10,2) COMMENT '组内中位复购时间（未达则 NULL）',
  n_total     INT,
  n_event     INT,
  logrank_p   DOUBLE      COMMENT '该组 vs all 的 log-rank p 值',
  updated_at  DATETIME,
  PRIMARY KEY (group_code, t_days)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:S5 KM生存曲线(s5_02回写)';

-- 6.4 首购体验 → 复购的效应估计（PSM，s5_02 回写）
DROP TABLE IF EXISTS ads_s5_experience_effect;
CREATE TABLE ads_s5_experience_effect (
  outcome       VARCHAR(40) NOT NULL COMMENT 'repeat_180 / repeat_any',
  method        VARCHAR(30) COMMENT 'naive / psm_1to1',
  n_treat       INT,
  n_control     INT,
  treat_value   DECIMAL(10,4) COMMENT '处理组复购率',
  control_value DECIMAL(10,4) COMMENT '对照组复购率',
  diff          DECIMAL(10,4) COMMENT '处理组 - 对照组',
  diff_pp       DECIMAL(8,2)  COMMENT '百分点',
  ci_low        DECIMAL(10,4),
  ci_high       DECIMAL(10,4),
  p_value       DOUBLE,
  is_significant TINYINT,
  smd_max_after DECIMAL(8,4)  COMMENT '匹配后最大标准化均值差',
  n_unmatched   INT           COMMENT '处理组未匹配上的单数',
  note          VARCHAR(200),
  updated_at    DATETIME,
  PRIMARY KEY (outcome, method)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:S5体验→复购效应(s5_02回写)';


-- ============================================================================
-- 七、勾稽自检（失败先排查，不许放宽容差）
-- ============================================================================
-- 7.1 rfm_v2 客户数之和 = dws_user_profile 行数
SELECT (SELECT SUM(customers) FROM ads_s5_rfm_v2)        AS rfm_v2_总人数,
       (SELECT COUNT(*)      FROM dws_user_profile)       AS 客户画像行数;
-- 预期：两数相等（八格必须覆盖全部客户，不重不漏）。

-- 7.2 rfm_v2 八格齐全
SELECT COUNT(*) AS 格数 FROM ads_s5_rfm_v2;
-- 预期：8。若少于 8，说明某一格无客户，需检查切点是否合理。

-- 7.3 survival_input 行数 = 窗口内去重客户数
SELECT (SELECT COUNT(*) FROM ads_s5_survival_input) AS 生存表行数,
       (SELECT COUNT(DISTINCT customer_unique_id) FROM dwd_orders
        WHERE purchase_ts >= '2017-01-01' AND purchase_ts IS NOT NULL
          AND customer_unique_id IS NOT NULL)        AS 窗口内客户数;
-- 预期：两数相等。

-- 7.4 生存表勾稽：event=1 的人数 = 有 second_order_date 的人数；且 days_to_repeat > 0
SELECT SUM(event)                                                        AS 复购人数,
       SUM(CASE WHEN second_order_date IS NOT NULL THEN 1 ELSE 0 END)     AS 有二单日人数,
       SUM(CASE WHEN days_to_repeat IS NOT NULL AND days_to_repeat <= 0
                THEN 1 ELSE 0 END)                                        AS 间隔非正人数
FROM ads_s5_survival_input;
-- 预期：复购人数 = 有二单日人数；间隔非正人数 = 0
--       （首购与二单同日下单极少但可能存在，出现即需人工确认口径）。

-- 7.5 生存表勾稽：tenure_days 必须 >= days_to_repeat（复购不可能晚于观察期结束）
SELECT COUNT(*) AS 违反行数
FROM ads_s5_survival_input
WHERE days_to_repeat IS NOT NULL AND days_to_repeat > tenure_days;
-- 预期：0。

-- 7.6 体验交叉表勾稽：各 dim_type 内 customers 之和 = 生存表行数
SELECT dim_type, SUM(customers) AS 人数合计 FROM ads_s5_experience_repeat_base GROUP BY dim_type;
-- 预期：每个 dim_type 都是生存表行数（每个客户在每个维度上恰好落入一个桶）。

-- 7.7 复购人数只在 'first_is_late' 维度上做一次总和校验（其余维度重复计数）
SELECT (SELECT SUM(repeat_customers) FROM ads_s5_experience_repeat_base
        WHERE dim_type = 'first_is_late')                       AS 复购人数_按延迟桶,
       (SELECT COUNT(*) FROM ads_s5_survival_input WHERE event = 1) AS 复购人数_总;
-- 预期：两数相等。

-- 7.8 策略表预算占比：每一类 layer_type 内部合计应 = 100%
SELECT layer_type, ROUND(SUM(budget_share_pct), 2) AS 预算占比合计
FROM ads_s5_layer_strategy GROUP BY layer_type;
-- 预期：user / category / seller 三行均为 100.00（舍入误差 ±0.1 内）。

-- 7.9 策略表覆盖度：用户层策略表人数 = rfm_v2 总人数
SELECT (SELECT SUM(base_cnt) FROM ads_s5_layer_strategy WHERE layer_type = 'user') AS 策略表用户数,
       (SELECT SUM(customers) FROM ads_s5_rfm_v2)                                  AS rfm_v2人数;
-- 预期：两数相等。

-- 7.10 策略表粒度：三类的行数必须是 8 / 4 / 3（共 15 行）
SELECT layer_type, COUNT(*) AS 行数 FROM ads_s5_layer_strategy GROUP BY layer_type;
-- 预期：user=8（RFM 八格）、seller=4（等级）、category=3（象限）。
--   category 是 3 而不是 4 是数据事实：ads_category_matrix 里**没有"明星品类"**
--   （18 个现金牛 + 7 个潜力 + 47 个观察汰换 = 72 个品类，没有一个同时满足高份额+正增长）。
--   若 category 出现几十行，说明品类层误按"品类"铺开了，预算占比会碎到 0.0X%，失去决策意义。
