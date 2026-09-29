-- ============================================================================
-- 【粘贴用副本】ads_s5_layer_strategy 建表 + 灌数（从 sql/10_s5_价值分层.sql 第五节原样切出）
-- ----------------------------------------------------------------------------
-- 用途：PyCharm 数据库控制台是"粘贴执行"的工作方式，这一个文件把第五节整段装好，
--       打开后 Ctrl+A → Ctrl+C → 粘进控制台 → 执行，一条不落。
-- ⚠️ 唯一权威来源仍是 sql/10_s5_价值分层.sql；本文件只做粘贴副本，改了那边记得重新切。
-- ⚠️ 执行前确认控制台连的是 **sql_name** 库（不是 olist_dw）。
-- 预期结果：落 15 行（用户 8 格 + 品类 3 象限 + 卖家 4 级），随后跑第七节自检 7.8 / 7.10。
-- ============================================================================

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


