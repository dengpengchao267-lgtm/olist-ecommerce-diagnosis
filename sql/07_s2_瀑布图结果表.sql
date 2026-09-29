-- ============================================================================
-- 07_s2_瀑布图结果表.sql
--
-- 作用：把 ads_gmv_decomposition（三因子 LMDI 分解，长表）摊平成
--       「瀑布图专用长表」，让 Tableau 只用一条甘特条形图（Gantt Bar）
--       就能画出三因子环比瀑布，完全不需要任何表计算。
--
-- 为什么这件事必须放 SQL 层做（而不是在 Tableau 里算）：
--   瀑布图最关键的字段是「每段柱子在纵轴上的起点」= 前面所有段的累加。
--   这是**口径**，不是画法。口径必须锁在 SQL 层（数仓四层模型的原则），
--   Tableau 只负责画。如果放到 Tableau 用 WINDOW_SUM 去算，一旦排序被打乱
--   整张图就错，而且拿到你的 .twbx 也没法复核你的数是怎么累加出来的。
--
-- 依赖：
--   ads_gmv_decomposition  ← python/s2_01_gmv_decomposition.py 回写
--   ads_gmv_trend          ← sql/05_s2_结构下钻.sql 已建
-- 执行顺序：sql/05 → python/s2_01 → 本脚本
--
-- 产出两张表：
--   ads_gmv_waterfall_base   一个月一行（中间表，可单独查，用来复核口径）
--   ads_gmv_waterfall        瀑布长表，一个月 5 行 → 19 × 5 = 95 行
-- ============================================================================


-- ============================================================================
-- 一、ads_gmv_waterfall_base：一个月一行
--
--     gmv_prev / gmv_curr 取 ads_gmv_trend 的 gmv（仅已送达，S2 主口径）。
--     ⚠️ 只保留 is_complete_month = 1 的月份：
--        - 完整月判定 order_cnt >= 500（与 sql/05、python/config.py 三处一致）
--        - LAG 在 WHERE 之后才求值，所以 gmv_prev 是「上一个完整月」的 GMV，
--          中间被剔除的残缺月不会串进来。
--
--     ⚠️ 2017-01 会被自动过滤掉：它没有完整基期（2016-12 是残缺月），
--        算不出环比。所以这张表只有 19 个月（2017-02 ~ 2018-08），
--        不是 20 个。这一点写在报告里要交代清楚，否则会问
--        「你的环比月数为什么比 GMV 趋势图少一根」。
-- ============================================================================

DROP TABLE IF EXISTS ads_gmv_waterfall_base;
CREATE TABLE ads_gmv_waterfall_base (
  stat_month     DATE          NOT NULL COMMENT '本期月份（环比的本月）',
  gmv_prev       DECIMAL(14,2) NOT NULL COMMENT '上一个月（完整月）GMV',
  gmv_curr       DECIMAL(14,2) NOT NULL COMMENT '本月 GMV',
  delta_gmv      DECIMAL(14,2) NOT NULL COMMENT '本月 GMV 环比增量',
  c_buyers       DECIMAL(14,2) COMMENT '因子1 下单客户数 贡献额',
  c_freq         DECIMAL(14,2) COMMENT '因子2 人均下单次数 贡献额',
  c_aov          DECIMAL(14,2) COMMENT '因子3 客单价 贡献额',
  n_buyers       VARCHAR(30)   COMMENT '因子1 中文名（从源表取，避免两处命名漂移）',
  n_freq         VARCHAR(30)   COMMENT '因子2 中文名',
  n_aov          VARCHAR(30)   COMMENT '因子3 中文名',
  p_buyers       DECIMAL(8,4)  COMMENT '因子1 贡献占比',
  p_freq         DECIMAL(8,4)  COMMENT '因子2 贡献占比',
  p_aov          DECIMAL(8,4)  COMMENT '因子3 贡献占比',
  s_buyers       TINYINT       COMMENT '因子1 是否显著（Bootstrap 95%CI 不跨 0）',
  s_freq         TINYINT       COMMENT '因子2 是否显著',
  s_aov          TINYINT       COMMENT '因子3 是否显著',
  updated_at     DATETIME,
  PRIMARY KEY (stat_month)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:P1 瀑布图中间表(一个月一行)';


INSERT INTO ads_gmv_waterfall_base
  (stat_month, gmv_prev, gmv_curr, delta_gmv,
   c_buyers, c_freq, c_aov,
   n_buyers, n_freq, n_aov,
   p_buyers, p_freq, p_aov,
   s_buyers, s_freq, s_aov, updated_at)
SELECT
  f.stat_month,
  t.gmv_prev,
  t.gmv_curr,
  f.delta_gmv,
  f.c_buyers, f.c_freq, f.c_aov,
  f.n_buyers, f.n_freq, f.n_aov,
  f.p_buyers, f.p_freq, f.p_aov,
  f.s_buyers, f.s_freq, f.s_aov,
  NOW()
FROM (
  -- 把三行（三个因子）pivot 成一行
  SELECT
    stat_month,
    MAX(delta_gmv)                                                          AS delta_gmv,
    MAX(CASE WHEN factor = 'buyers'           THEN contribution_amount END) AS c_buyers,
    MAX(CASE WHEN factor = 'orders_per_buyer' THEN contribution_amount END) AS c_freq,
    MAX(CASE WHEN factor = 'aov'              THEN contribution_amount END) AS c_aov,
    MAX(CASE WHEN factor = 'buyers'           THEN factor_cn           END) AS n_buyers,
    MAX(CASE WHEN factor = 'orders_per_buyer' THEN factor_cn           END) AS n_freq,
    MAX(CASE WHEN factor = 'aov'              THEN factor_cn           END) AS n_aov,
    MAX(CASE WHEN factor = 'buyers'           THEN contribution_pct    END) AS p_buyers,
    MAX(CASE WHEN factor = 'orders_per_buyer' THEN contribution_pct    END) AS p_freq,
    MAX(CASE WHEN factor = 'aov'              THEN contribution_pct    END) AS p_aov,
    MAX(CASE WHEN factor = 'buyers'           THEN is_significant      END) AS s_buyers,
    MAX(CASE WHEN factor = 'orders_per_buyer' THEN is_significant      END) AS s_freq,
    MAX(CASE WHEN factor = 'aov'              THEN is_significant      END) AS s_aov
  FROM ads_gmv_decomposition
  GROUP BY stat_month
) f
JOIN (
  -- 完整月序列 + 上一个完整月的 GMV
  SELECT
    stat_month,
    gmv                                            AS gmv_curr,
    LAG(gmv) OVER (ORDER BY stat_month)            AS gmv_prev
  FROM ads_gmv_trend
  WHERE is_complete_month = 1
) t ON t.stat_month = f.stat_month
WHERE t.gmv_prev IS NOT NULL;


-- ============================================================================
-- 二、ads_gmv_waterfall：瀑布长表（Tableau 甘特条数据源）
--
--     一个月 5 段，seg_order 从左到右：
--       1  上月 GMV      柱子从 0 立起（基准柱）      cum_start = 0
--       2  下单客户数    浮动柱                       cum_start = gmv_prev
--       3  人均下单次数  浮动柱                       cum_start = gmv_prev + c1
--       4  客单价        浮动柱                       cum_start = gmv_prev + c1 + c2
--       5  本月 GMV      柱子从 0 立起（基准柱）      cum_start = 0
--
--     Tableau 画法：seg_name 放「详细信息」，cum_start 做基准、seg_value 做长度。
--     ⚠️ 第 4 段终点必须严格落回 gmv_curr —— 这是 LMDI-I 加法分解
--        「三项之和 ≡ ΔGMV」的可视化体现，也是这张图唯一的正确性判据。
-- ============================================================================

DROP TABLE IF EXISTS ads_gmv_waterfall;
CREATE TABLE ads_gmv_waterfall (
  stat_month     DATE          NOT NULL COMMENT '本期月份',
  seg_order      TINYINT       NOT NULL COMMENT '1..5，瀑布从左到右的顺序',
  seg_name       VARCHAR(30)   NOT NULL COMMENT '段名',
  factor         VARCHAR(20)   NULL     COMMENT '对应因子；首尾两段为 NULL',
  cum_start      DECIMAL(14,2) NOT NULL COMMENT '该段起点（甘特条的 y 位置）',
  seg_value      DECIMAL(14,2) NOT NULL COMMENT '该段高度（带符号，负值向下）',
  cum_end        DECIMAL(14,2) NOT NULL COMMENT '该段终点 = cum_start + seg_value',
  gmv_prev       DECIMAL(14,2) NULL,
  gmv_curr       DECIMAL(14,2) NULL,
  delta_gmv      DECIMAL(14,2) NULL,
  contrib_pct    DECIMAL(8,4)  NULL     COMMENT '该段占 ΔGMV 的比例',
  is_significant TINYINT       NULL     COMMENT 'Bootstrap 95%CI 是否不跨 0',
  PRIMARY KEY (stat_month, seg_order),
  KEY idx_wf_m (stat_month)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:P1 三因子环比瀑布(Tableau 甘特条)';


INSERT INTO ads_gmv_waterfall
  (stat_month, seg_order, seg_name, factor, cum_start, seg_value, cum_end,
   gmv_prev, gmv_curr, delta_gmv, contrib_pct, is_significant)
SELECT
  stat_month, seg_order, seg_name, factor,
  cum_start,
  seg_value,
  cum_start + seg_value AS cum_end,
  gmv_prev, gmv_curr, delta_gmv, contrib_pct, is_significant
FROM (
  SELECT stat_month, 1 AS seg_order, '上月 GMV' AS seg_name, NULL AS factor,
         0 AS cum_start, gmv_prev AS seg_value,
         gmv_prev, gmv_curr, delta_gmv,
         NULL AS contrib_pct, NULL AS is_significant
  FROM ads_gmv_waterfall_base

  UNION ALL

  SELECT stat_month, 2, COALESCE(n_buyers, '下单客户数'), 'buyers',
         gmv_prev, c_buyers,
         gmv_prev, gmv_curr, delta_gmv, p_buyers, s_buyers
  FROM ads_gmv_waterfall_base

  UNION ALL

  SELECT stat_month, 3, COALESCE(n_freq, '人均下单次数'), 'orders_per_buyer',
         gmv_prev + c_buyers, c_freq,
         gmv_prev, gmv_curr, delta_gmv, p_freq, s_freq
  FROM ads_gmv_waterfall_base

  UNION ALL

  SELECT stat_month, 4, COALESCE(n_aov, '客单价'), 'aov',
         gmv_prev + c_buyers + c_freq, c_aov,
         gmv_prev, gmv_curr, delta_gmv, p_aov, s_aov
  FROM ads_gmv_waterfall_base

  UNION ALL

  SELECT stat_month, 5, '本月 GMV', NULL,
         0, gmv_curr,
         gmv_prev, gmv_curr, delta_gmv, NULL, NULL
  FROM ads_gmv_waterfall_base
) x
ORDER BY stat_month, seg_order;


-- ============================================================================
-- 三、验收
-- ============================================================================

-- 校验 1：LMDI 加法恒等式落地 —— 第 4 段的终点必须等于本月 GMV。
--         若这条不为 0，说明分解有残差（那就不叫 LMDI-I 加法分解了），
--         或者 ads_gmv_trend.gmv 与 Python 用的 GMV 口径不一致。
SELECT COUNT(*) AS 恒等式不成立的月份数
FROM ads_gmv_waterfall
WHERE seg_order = 4
  AND ABS(cum_end - gmv_curr) > 0.05;

-- 校验 2：首尾基准柱必须从 0 立起、且落回各自 GMV
SELECT COUNT(*) AS 首尾柱异常月份数
FROM ads_gmv_waterfall
WHERE seg_order IN (1, 5)
  AND ABS(cum_start) > 0.05;

-- 校验 3：段数 = 月份数 × 5；月份数应为 19（2017-02 ~ 2018-08）
SELECT COUNT(DISTINCT stat_month) AS 月份数,
       COUNT(*)                   AS 总行数,
       MIN(stat_month)            AS 起点,
       MAX(stat_month)            AS 终点
FROM ads_gmv_waterfall;

-- 预览：最近 3 个月的瀑布全貌（横向看就是这张图的骨架）
SELECT stat_month, seg_order, seg_name, cum_start, seg_value, cum_end, contrib_pct
FROM ads_gmv_waterfall
WHERE stat_month >= '2018-06-01'
ORDER BY stat_month, seg_order;

-- 顺带自检：确认 2016-12 到底是不是完整月。
-- 如果它是完整月（is_complete_month = 1），那 2017-01 就有基期，
-- 瀑布应该是 20 根而不是 19 根，需要回来改报告里的月数表述。
SELECT stat_month, order_cnt, gmv, is_complete_month
FROM ads_gmv_trend
WHERE stat_month BETWEEN '2016-10-01' AND '2017-03-01'
ORDER BY stat_month;
