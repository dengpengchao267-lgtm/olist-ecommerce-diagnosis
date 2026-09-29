-- ============================================================================
-- S6 策略效果评估：把 S3/S4/S5 的结论变成可算 ROI 的策略账本
--   产出：
--     1. ads_s6_intervention_pool   可干预订单池（订单级，三条策略命中标记）
--     2. ads_s6_strategy_params     策略参数表（明确区分「数据实测」与「业务假设」）
--     3. ads_s6_roi_input           【供 Python】策略 × 月 的聚合输入
--     4. ads_s6_strategy_roi        【空表，s6_01 回写】策略 ROI 汇总
--     5. ads_s6_sensitivity         【空表，s6_01 回写】(挽回率 × 差评价值) 敏感性
--     6. ads_s6_budget_plan         【空表，s6_01 回写】预算约束下的分配方案
--
-- 依赖：dwd_orders / ads_s5_experience_effect / ads_s4_gain
-- 执行顺序：... → sql/10 → python s5_01 → python s5_02 → 本脚本 → python s6_01
--
-- ⚠️ 前置：本脚本读 ads_s5_experience_effect（s5_02 回写）与 ads_s4_gain（s4_01 回写），
--    这两张表为空时 P2/P3 的参数会退化为默认值 —— 先确认它们有数。
-- ============================================================================


-- ============================================================================
-- 〇、S6 要回答什么（以及为什么不能做真实 A/B）
-- ============================================================================
-- S2 说增长靠拉新、复购贡献仅 1.2%；S3 说瓶颈在承运环节、干预窗口 3~7 天；
-- S4 说走「物流提速」不走「卖家治理」；S5 说延迟对 365 天复购有 −1.46pp 的弱效应。
--
-- 这些都是「该做什么」，但从没回答「做了值多少钱、先做哪个、投多少」。
-- S6 就是这张账本。
--
-- ⚠️ 必须诚实声明（一定会问）：
--    Olist 是历史公开数据，**平台从未跑过延迟补偿/提速的随机试验**，
--    所以本专题做的是**反事实仿真（what-if）**，不是 A/B 实验结果。
--    仿真里有两个**数据无法确定的参数**：
--        p = 挽回率（策略执行后，问题被真正消除的比例）
--        v = 差评的单位价值（R$，属于品牌/声誉范畴，数据里没有）
--    正确做法不是「拍一个数」，而是**让它们显式进入二维敏感性分析**，
--    输出「在什么条件下这个策略才划算」—— 即盈亏平衡线。
--    ⇒ 这比给一个看起来精确的 ROI 数字专业得多，也诚实得多。
-- ----------------------------------------------------------------------------


-- ============================================================================
-- 一、ads_s6_intervention_pool：可干预订单池（订单级）
-- ============================================================================
-- 口径：仅「已送达 + 有评分」的订单 —— 因为「差评」既是策略的目标变量，
--       也是唯一能回测的标签。未送达/未评价订单没有可观测结果，无法回测。
--
-- 三条策略的定义（全部来自前面专题的结论，不是拍脑袋）：
--   P1 物流提速 expedite   —— 命中：延迟 3~7 天
--       依据：S3 剂量反应显示 3 天是断崖起点、7 天后饱和，故 3~7 天是「抢救窗口」
--   P2 风险拦截 intercept  —— 命中：延迟 >3 天
--       依据：S4 的增益曲线显示拦截范围越大边际成本越高，前 10% 是性价比拐点；
--             这里用「延迟 >3 天」作可执行代理（S4 第一特征 is_late/delay_hours）
--   P3 延迟补偿券 voucher  —— 命中：全部延迟订单
--       依据：S5 的 PSM 显示延迟对 365 天复购有 −1.46pp 效应，用券挽回长期价值
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS ads_s6_intervention_pool;
CREATE TABLE ads_s6_intervention_pool (
  order_id            VARCHAR(50)  NOT NULL,
  customer_unique_id  VARCHAR(50),
  stat_month          DATE         COMMENT '归属月（purchase_ts）',
  customer_state      CHAR(2),
  is_late             TINYINT      COMMENT '1=延迟（签收>承诺）',
  delay_hours         INT          COMMENT '带符号延迟小时（负=提前）',
  delay_days          DECIMAL(7,2) COMMENT '延迟天数（保留 2 位，便于分桶核对）',
  delay_bucket        VARCHAR(20)  COMMENT '准时 / 延迟0-3天 / 延迟3-7天 / 延迟7-14天 / 延迟>14天',
  order_amount        DECIMAL(12,2),
  item_cnt            INT,
  review_score        DECIMAL(4,2),
  is_bad              TINYINT      COMMENT '1=差评（review_score<=2）—— 策略要拦的目标',
  hit_p1_expedite     TINYINT      COMMENT 'P1 物流提速：延迟 3~7 天',
  hit_p2_intercept    TINYINT      COMMENT 'P2 风险拦截：延迟 >3 天',
  hit_p3_voucher      TINYINT      COMMENT 'P3 延迟补偿券：全部延迟订单',
  PRIMARY KEY (order_id),
  KEY idx_month (stat_month),
  KEY idx_bucket (delay_bucket)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:S6可干预订单池（订单级，三条策略命中标记）';

INSERT INTO ads_s6_intervention_pool (
  order_id, customer_unique_id, stat_month, customer_state,
  is_late, delay_hours, delay_days, delay_bucket,
  order_amount, item_cnt, review_score, is_bad,
  hit_p1_expedite, hit_p2_intercept, hit_p3_voucher
)
SELECT
  order_id,
  customer_unique_id,
  DATE_FORMAT(purchase_ts, '%Y-%m-01')                        AS stat_month,
  customer_state,
  is_late,
  delay_hours,
  ROUND(delay_hours / 24, 2)                                  AS delay_days,
  CASE
    WHEN is_late IS NULL                            THEN '未知'
    WHEN is_late = 0                                 THEN '准时'
    WHEN delay_hours <= 72                           THEN '延迟0-3天'
    WHEN delay_hours <= 168                          THEN '延迟3-7天'
    WHEN delay_hours <= 336                          THEN '延迟7-14天'
    ELSE                                                  '延迟>14天'
  END                                                          AS delay_bucket,
  order_amount,
  item_cnt,
  review_score,
  CASE WHEN review_score <= 2 THEN 1 ELSE 0 END                AS is_bad,
  -- P1：只打「延迟 3~7 天」这一档（S3 的抢救窗口）
  CASE WHEN is_late = 1 AND delay_hours > 72 AND delay_hours <= 168
       THEN 1 ELSE 0 END                                       AS hit_p1_expedite,
  -- P2：延迟 >3 天（含 P1 那一档，因为拦截的时点在签收后，比提速更晚、更宽）
  CASE WHEN is_late = 1 AND delay_hours > 72
       THEN 1 ELSE 0 END                                       AS hit_p2_intercept,
  -- P3：全部延迟订单
  CASE WHEN is_late = 1 THEN 1 ELSE 0 END                      AS hit_p3_voucher
FROM dwd_orders
WHERE is_delivered = 1
  AND review_score IS NOT NULL;
-- 预期约 95,832 行（与 S4 的建模样本同口径）


-- ============================================================================
-- 二、ads_s6_strategy_params：策略参数表
-- ============================================================================
-- ⚠️ 这张表的核心价值是**把「数据实测」和「业务假设」分开**。
--    实测值可追溯到具体专题；假设值必须由业务方确认，否则一律做敏感性。
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS ads_s6_strategy_params;
CREATE TABLE ads_s6_strategy_params (
  param_key     VARCHAR(40)   NOT NULL,
  param_value   DECIMAL(14,4) NOT NULL,
  unit          VARCHAR(20),
  source_type   VARCHAR(10)   COMMENT 'measured=数据实测 / assumed=业务假设',
  source_detail VARCHAR(160)  COMMENT '可追溯的口径来源',
  PRIMARY KEY (param_key)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:S6策略参数（实测 vs 假设）';

INSERT INTO ads_s6_strategy_params (param_key, param_value, unit, source_type, source_detail) VALUES
  ('p1_expedite_cost',   8.0000,  'R$/单',  'assumed',  '加急/换承运商的单均增量成本；Olist 数据无物流成本字段，需业务确认'),
  ('p2_voucher_face',   15.0000,  'R$',     'assumed',  '签收后触达券的面值（约客单价 158.54 的 9.5%）'),
  ('p2_redeem_rate',     0.6000,  '比例',   'assumed',  '券核销率（行业经验值）'),
  ('p2_contact_cost',    2.0000,  'R$/单',  'assumed',  '客服触达的运营成本'),
  ('p3_voucher_face',   10.0000,  'R$',     'assumed',  '延迟补偿券面值（低于 P2，因为不额外投客服）'),
  ('p3_redeem_rate',     0.6500,  '比例',   'assumed',  '券核销率'),
  ('bad_review_cost',   40.7500,  'R$',     'measured', 'S4 实测：拦前 10% 的单位干预成本（可理解为处理一个差评的运营成本）'),
  ('repeat_effect_pp',  -1.4600,  'pp',     'measured', 'S5 实测：PSM 365 天窗口，延迟对复购率的影响（绝对值 1.46pp）'),
  ('aov_delayed',      171.2900,  'R$',     'measured', '实测：延迟订单的客单价'),
  ('aov_ontime',       158.5400,  'R$',     'measured', '实测：准时订单的客单价'),
  ('baseline_bad_ontime', 9.1900, '%',      'measured', '实测：准时订单差评率（P1 提速后的目标水平）'),
  ('baseline_bad_late',  53.9900, '%',      'measured', '实测：延迟订单差评率（干预前的现状）');


-- ============================================================================
-- 三、ads_s6_roi_input：策略 × 月 的聚合输入（供 Python 折算）
-- ============================================================================
-- Python 层不重复做 SQL 能做的事：这里把「每个策略每月覆盖多少单、
-- 这些单里有多少差评、GMV 多少」算好，Python 只负责乘参数、算 ROI。
-- 分工理由：口径一律锁在 SQL 层，Python 只做推断与敏感性。
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS ads_s6_roi_input;
CREATE TABLE ads_s6_roi_input (
  strategy          VARCHAR(20) NOT NULL COMMENT 'p1_expedite / p2_intercept / p3_voucher',
  stat_month        DATE        NOT NULL,
  covered_orders    INT         COMMENT '命中的订单数',
  covered_customers INT         COMMENT '命中的去重客户数（同月内去重；复购收益按客户算，不按订单）',
  bad_orders        INT         COMMENT '命中订单里的差评数',
  bad_rate_pct      DECIMAL(7,3) COMMENT '命中订单的差评率(%)',
  covered_gmv       DECIMAL(16,2) COMMENT '命中订单的总 GMV',
  avg_order_amount  DECIMAL(12,2) COMMENT '命中订单均值',
  avg_delay_hours   DECIMAL(10,2) COMMENT '命中订单的平均延迟小时',
  PRIMARY KEY (strategy, stat_month)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:S6策略×月聚合输入（供 s6_01）';

INSERT INTO ads_s6_roi_input (
  strategy, stat_month, covered_orders, covered_customers, bad_orders, bad_rate_pct,
  covered_gmv, avg_order_amount, avg_delay_hours
)
SELECT 'p1_expedite', stat_month,
       COUNT(*), COUNT(DISTINCT customer_unique_id),
       SUM(is_bad), ROUND(AVG(is_bad) * 100, 3),
       SUM(order_amount), ROUND(AVG(order_amount), 2), ROUND(AVG(delay_hours), 2)
FROM ads_s6_intervention_pool
WHERE hit_p1_expedite = 1
GROUP BY stat_month
UNION ALL
SELECT 'p2_intercept', stat_month,
       COUNT(*), COUNT(DISTINCT customer_unique_id),
       SUM(is_bad), ROUND(AVG(is_bad) * 100, 3),
       SUM(order_amount), ROUND(AVG(order_amount), 2), ROUND(AVG(delay_hours), 2)
FROM ads_s6_intervention_pool
WHERE hit_p2_intercept = 1
GROUP BY stat_month
UNION ALL
SELECT 'p3_voucher', stat_month,
       COUNT(*), COUNT(DISTINCT customer_unique_id),
       SUM(is_bad), ROUND(AVG(is_bad) * 100, 3),
       SUM(order_amount), ROUND(AVG(order_amount), 2), ROUND(AVG(delay_hours), 2)
FROM ads_s6_intervention_pool
WHERE hit_p3_voucher = 1
GROUP BY stat_month;


-- ============================================================================
-- 四、Python 回写的三张表（建空表，由 s6_01 填充）
-- ============================================================================
DROP TABLE IF EXISTS ads_s6_strategy_roi;
CREATE TABLE ads_s6_strategy_roi (
  strategy          VARCHAR(20)  NOT NULL,
  strategy_name     VARCHAR(40)  COMMENT '中文名，给看板用',
  covered_orders    INT          COMMENT '覆盖订单数',
  covered_customers INT          COMMENT '覆盖去重客户数（复购收益按客户算）',
  covered_gmv       DECIMAL(16,2),
  -- 成本侧
  cost_per_order    DECIMAL(10,4) COMMENT '单均成本（券面值×核销率 + 触达等）',
  total_cost        DECIMAL(16,2),
  -- 收益侧（两条口径：口径A 只看差评挽回；口径B 再加复购挽回）
  bad_upper         DECIMAL(12,2) COMMENT '可挽回差评的上限（按实测差评率差 × 覆盖单数）',
  revenue_review    DECIMAL(16,2) COMMENT '口径A 收益：挽回差评 × 差评单位价值 × 挽回率',
  rescued_repeat    DECIMAL(12,2) COMMENT '口径B 额外：挽回的复购订单数',
  revenue_repeat    DECIMAL(16,2) COMMENT '口径B 额外收益：挽回复购 × 客单价',
  revenue_total     DECIMAL(16,2) COMMENT '口径B 总收益',
  -- 决策指标
  net_benefit_a     DECIMAL(16,2) COMMENT '口径A 净收益',
  net_benefit_b     DECIMAL(16,2) COMMENT '口径B 净收益',
  roi_a             DECIMAL(10,4) COMMENT '口径A ROI = 收益/成本',
  roi_b             DECIMAL(10,4) COMMENT '口径B ROI',
  breakeven_p_a     DECIMAL(8,4)  COMMENT '口径A 的盈亏平衡挽回率',
  breakeven_p_b     DECIMAL(8,4)  COMMENT '口径B 的盈亏平衡挽回率',
  rescue_rate       DECIMAL(8,4)  COMMENT '本次测算采用的挽回率基准值',
  bad_value         DECIMAL(10,2) COMMENT '本次测算采用的差评单位价值',
  verdict           VARCHAR(60)   COMMENT '结论：建议投放 / 条件投放 / 不建议',
  note              VARCHAR(240),
  updated_at        DATETIME,
  PRIMARY KEY (strategy)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:S6策略ROI汇总（s6_01回写）';

DROP TABLE IF EXISTS ads_s6_sensitivity;
CREATE TABLE ads_s6_sensitivity (
  strategy      VARCHAR(20) NOT NULL,
  rescue_rate   DECIMAL(8,4) NOT NULL COMMENT '挽回率 p（策略执行后问题真正被消除的比例）',
  bad_value     DECIMAL(10,2) NOT NULL COMMENT '差评单位价值 v（R$）',
  total_cost    DECIMAL(16,2),
  revenue       DECIMAL(16,2),
  net_benefit   DECIMAL(16,2),
  roi           DECIMAL(10,4),
  is_profitable TINYINT      COMMENT '1=净收益>0',
  PRIMARY KEY (strategy, rescue_rate, bad_value)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:S6敏感性（挽回率×差评价值，s6_01回写）';

DROP TABLE IF EXISTS ads_s6_budget_plan;
CREATE TABLE ads_s6_budget_plan (
  budget_level      DECIMAL(14,2) NOT NULL COMMENT '预算档位（R$）',
  strategy          VARCHAR(20)   NOT NULL,
  allocated         DECIMAL(16,2) COMMENT '分配金额',
  alloc_pct         DECIMAL(8,2)  COMMENT '占总预算比例(%)',
  covered_orders    INT           COMMENT '该预算能覆盖的订单数',
  expected_net      DECIMAL(16,2) COMMENT '预期净收益',
  expected_roi      DECIMAL(10,4),
  rationale         VARCHAR(200),
  updated_at        DATETIME,
  PRIMARY KEY (budget_level, strategy)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:S6预算分配方案（s6_01回写）';


-- ============================================================================
-- 五、勾稽自检（失败先排查，不许放宽容差）
-- ============================================================================
-- 5.1 订单池规模 = 已送达且有评分的订单数（不重不漏）
SELECT (SELECT COUNT(*) FROM ads_s6_intervention_pool)                          AS 订单池,
       (SELECT COUNT(*) FROM dwd_orders
         WHERE is_delivered = 1 AND review_score IS NOT NULL)                   AS 应等于,
       (SELECT COUNT(*) FROM ads_s6_intervention_pool
         WHERE is_bad != (review_score <= 2))                                   AS is_bad口径错位;
-- 预期：前两列相等，第三列为 0。

-- 5.2 三策略的命中数应满足包含关系：P1 ⊂ P2 ⊂ P3
SELECT SUM(hit_p1_expedite) AS P1_延迟3_7天,
       SUM(hit_p2_intercept) AS P2_延迟超3天,
       SUM(hit_p3_voucher)   AS P3_全部延迟
FROM ads_s6_intervention_pool;
-- 预期：P1 < P2 < P3（严格递增，因为 P1 只打 3~7 天那一档）。
--       若 P1 = P2，说明 3~7 天之外没有延迟订单 —— 与 S3 的分桶矛盾，要查。

-- 5.3 分桶互斥且完备：各桶之和 = 订单池总数
SELECT delay_bucket, COUNT(*) AS 订单数
FROM ads_s6_intervention_pool
GROUP BY delay_bucket
ORDER BY FIELD(delay_bucket, '未知', '准时', '延迟0-3天', '延迟3-7天', '延迟7-14天', '延迟>14天');
-- 预期：六桶之和 = 95,832；「准时」桶 is_late 全为 0、四个延迟桶全为 1。
--       「未知」桶应只有个位数（is_late IS NULL 的脏数据），若很大说明 DWD 出问题。
--       ⚠️ 「未知」桶不参与任何策略命中（三条策略都要求 is_late = 1），
--          它的存在是「宁可少算也不误算」的选择。

-- 5.4 「准时」桶里不允许出现 hit_p3_voucher = 1
SELECT COUNT(*) AS 准时桶误标延迟 FROM ads_s6_intervention_pool
WHERE delay_bucket = '准时' AND hit_p3_voucher = 1;
-- 预期：0。这条防的是 CASE 分支写错（把 is_late 判断漏掉）。

-- 5.5 差评率应与 S3/S4 的口径对得上
SELECT is_late, COUNT(*) AS n, ROUND(AVG(is_bad) * 100, 2) AS 差评率pct,
       ROUND(AVG(order_amount), 2) AS 客单价
FROM ads_s6_intervention_pool
GROUP BY is_late;
-- 预期：准时 ≈ 9.19%、延迟 ≈ 53.99% —— 与参数表 baseline_bad_* 一致。

-- 5.6 参数表：实测值与假设值必须都在，且实测值可追溯
SELECT source_type, COUNT(*) AS 参数个数 FROM ads_s6_strategy_params GROUP BY source_type;
-- 预期：assumed 6 个、measured 6 个。若 measured 少了，说明某个结论没同步进来。

-- 5.7 参数表内部一致性：延迟差评率必须显著高于准时
SELECT MAX(CASE WHEN param_key = 'baseline_bad_late'   THEN param_value END) AS 延迟差评率,
       MAX(CASE WHEN param_key = 'baseline_bad_ontime' THEN param_value END) AS 准时差评率
FROM ads_s6_strategy_params;
-- 预期：延迟 ≈ 53.99 > 准时 ≈ 9.19。若反了，说明匹配的对象写错了。

-- 5.8 roi_input 三策略的行数应一致（都是 20 个完整月）
SELECT strategy, COUNT(*) AS 月数, SUM(covered_orders) AS 覆盖单数
FROM ads_s6_roi_input
GROUP BY strategy
ORDER BY strategy;
-- 预期：三个策略月数相同；覆盖单数 P1 < P2 < P3。

-- 5.9 回写表的幂等前提：空表就绪
SELECT (SELECT COUNT(*) FROM ads_s6_strategy_roi) AS roi表,
       (SELECT COUNT(*) FROM ads_s6_sensitivity)  AS 敏感性表,
       (SELECT COUNT(*) FROM ads_s6_budget_plan)  AS 预算表;
-- 预期：全为 0（本脚本刚 DROP 重建）。非 0 说明 s6_01 已跑过，本脚本重跑会清掉。
