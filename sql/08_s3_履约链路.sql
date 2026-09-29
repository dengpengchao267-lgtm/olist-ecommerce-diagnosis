-- ============================================================================
-- 08_s3_履约链路.sql
-- 作用：S3 履约体验专题的 dws/ads 层建表与汇总
-- 前置：01_dwd_清洗与宽表.sql 已执行（依赖 dwd_orders / dwd_order_items）
--       05_s2_结构下钻.sql 已执行（Python 侧要复用完整月窗口）
-- 要求：MySQL 8.0.19+（用到 INSERT ... WITH ... SELECT 写法）
--
-- 【S3 的分析对象与口径 —— 先读这段再跑】
--   1. 履约对象 = is_delivered = 1 且签收时间、承诺送达时间都非空的订单
--      （即 is_late IS NOT NULL，与 dwd_orders 的延迟标记口径一致）
--   2. 时间归属 = purchase_ts（下单时间），与 S2 完全一致，不例外
--   3. 延迟 = 签收时间 > 承诺送达时间（严格大于），delay_hours 为带符号小时数
--   4. 评分 = review_score（订单级均值，同一订单多条评价已取均值）
--   5. 卖家违约 = carrier_ts > 订单内最早的 shipping_limit_ts
--      （交承运商时间晚于任一商品的发货截止，即视为该订单卖家侧违约）
--   6. ⚠️ 右端截断：最近月份有订单"已下单未签收"，它们不进履约口径，
--      会导致近期延迟率被低估。本脚本产出 delivered_ratio 供 Python 侧
--      做截断月剔除（阈值在 config.py，不写死在 SQL 里）
--
-- 【本脚本产出的表】
--   ads_s3_fulfillment_monthly —— 月度履约画像（趋势 / 环节耗时的主数据源）
--   ads_s3_delay_bucket        —— 月 × 延迟分桶 × 评分（剂量反应的口径层）
--   ads_s3_bottleneck_base     —— 月 × 品类/州 × 履约汇总（瓶颈定位的口径层）
--   ads_s3_delay_impact        —— 空表，由 s3_01 回写（桶级评分 + 置信区间）
--   ads_s3_score_diff          —— 空表，由 s3_01 回写（准时 vs 延迟的检验结果）
--   ads_s3_bottleneck          —— 空表，由 s3_02 回写（Wilson CI + FDR）
--   ads_s3_stage               —— 空表，由 s3_02 回写（环节耗时对比 + CI）
--   统计结果表的 DDL 也统一放这里：表结构是口径的一部分，不留散在 Python 里
-- ============================================================================

USE olist_dw;
SET NAMES utf8mb4;

-- ============================================================================
-- 〇、跑前诊断：右端截断有多严重（先看这个数再解读后面的表）
-- ============================================================================
SELECT DATE_FORMAT(purchase_ts, '%Y-%m') AS 月份,
       COUNT(*)                                                AS 下单数,
       SUM(is_delivered)                                       AS 已送达数,
       ROUND(AVG(is_delivered), 4)                             AS 送达率,
       SUM(customer_delivered_ts IS NULL AND order_status = 'delivered') AS 状态送达但无签收时间
FROM dwd_orders
WHERE purchase_ts IS NOT NULL
GROUP BY DATE_FORMAT(purchase_ts, '%Y-%m')
ORDER BY 1;
-- 读法：窗口末端（2018-08 之后）送达率明显 < 1 的月份，其履约指标系统性偏好，
--       因为"还没送到"（更可能是慢单）的订单根本不在统计里。


-- ============================================================================
-- 一、ads_s3_fulfillment_monthly：月度履约画像（1 行 = 1 个月）
-- ============================================================================
DROP TABLE IF EXISTS ads_s3_fulfillment_monthly;
CREATE TABLE ads_s3_fulfillment_monthly (
  stat_month        DATE         NOT NULL COMMENT '归属月（按 purchase_ts）',
  order_cnt_all     INT                   COMMENT '当月全部订单（含未送达，截断诊断用）',
  delivered_cnt    INT                   COMMENT '已送达订单数',
  delivered_ratio  DECIMAL(6,4)         COMMENT '送达率（截断诊断：低于阈值剔除出趋势）',
  valid_cnt        INT                   COMMENT '履约口径订单数（已送达且时效字段齐全）',
  late_cnt         INT                   COMMENT '延迟订单数',
  late_rate        DECIMAL(6,4)         COMMENT '延迟率 = late_cnt / valid_cnt',
  avg_delay_hours  DECIMAL(8,1)         COMMENT '平均超时小时（仅延迟单，看严重度）',
  avg_approve_hours DECIMAL(8,1)        COMMENT '下单→审批 平均小时',
  avg_carrier_hours DECIMAL(8,1)        COMMENT '审批→交承运商 平均小时',
  avg_lastmile_hours DECIMAL(8,1)       COMMENT '交承运商→签收 平均小时',
  avg_total_days   DECIMAL(6,1)         COMMENT '下单→签收 平均天',
  seller_base_cnt  INT                   COMMENT '可判卖家违约的订单数',
  seller_late_cnt  INT                   COMMENT '卖家违约订单数',
  seller_late_rate DECIMAL(6,4)         COMMENT '卖家违约率',
  n_reviewed       INT                   COMMENT '有评分的订单数',
  avg_review_score DECIMAL(5,2)         COMMENT '平均评分',
  gmv              DECIMAL(14,2)        COMMENT '已送达 GMV（口径同 S2）',
  PRIMARY KEY (stat_month)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:S3月度履约画像';

INSERT INTO ads_s3_fulfillment_monthly (
  stat_month, order_cnt_all, delivered_cnt, delivered_ratio, valid_cnt,
  late_cnt, late_rate, avg_delay_hours,
  avg_approve_hours, avg_carrier_hours, avg_lastmile_hours, avg_total_days,
  seller_base_cnt, seller_late_cnt, seller_late_rate,
  n_reviewed, avg_review_score, gmv
)
WITH valid AS (
  -- 履约口径订单：已送达 + 签收/承诺时间齐全 + 时长非负（负数是脏时间戳，见 dwd 自检）
  SELECT
    DATE(DATE_FORMAT(purchase_ts, '%Y-%m-01'))                    AS stat_month,
    order_id, customer_id,
    is_late,
    CASE WHEN is_late = 1 THEN delay_hours END                     AS late_hours,
    CASE WHEN approve_hours   >= 0 THEN approve_hours   END        AS approve_h,
    CASE WHEN carrier_hours   >= 0 THEN carrier_hours   END        AS carrier_h,
    CASE WHEN lastmile_hours  >= 0 THEN lastmile_hours  END        AS lastmile_h,
    CASE WHEN total_delivery_hours >= 0
         THEN total_delivery_hours END                             AS total_h,
    CASE WHEN review_score IS NOT NULL THEN review_score END       AS score,
    order_amount
  FROM dwd_orders
  WHERE is_delivered = 1
    AND customer_delivered_ts IS NOT NULL
    AND estimated_ts IS NOT NULL
    AND purchase_ts IS NOT NULL
),
seller AS (
  -- 订单内最早的发货截止时间：交承运商晚于它，即卖家侧违约
  SELECT order_id, MIN(shipping_limit_ts) AS min_limit_ts
  FROM dwd_order_items
  WHERE shipping_limit_ts IS NOT NULL
  GROUP BY order_id
),
seller_flag AS (
  SELECT v.stat_month, v.order_id,
         CASE WHEN o.carrier_ts IS NOT NULL AND s.min_limit_ts IS NOT NULL THEN 1 ELSE 0 END AS can_judge,
         CASE WHEN o.carrier_ts IS NOT NULL AND s.min_limit_ts IS NOT NULL
                   AND o.carrier_ts > s.min_limit_ts THEN 1 ELSE 0 END                    AS is_seller_late
  FROM valid v
  JOIN dwd_orders o      ON o.order_id = v.order_id
  LEFT JOIN seller s     ON s.order_id = v.order_id
)
SELECT
  v.stat_month,
  a.order_cnt_all,
  a.delivered_cnt,
  ROUND(a.delivered_cnt / a.order_cnt_all, 4),
  COUNT(*),
  SUM(v.is_late),
  ROUND(AVG(v.is_late), 4),
  ROUND(AVG(v.late_hours), 1),
  ROUND(AVG(v.approve_h), 1),
  ROUND(AVG(v.carrier_h), 1),
  ROUND(AVG(v.lastmile_h), 1),
  ROUND(AVG(v.total_h) / 24, 1),
  SUM(sf.can_judge),
  SUM(sf.is_seller_late),
  ROUND(SUM(sf.is_seller_late) / NULLIF(SUM(sf.can_judge), 0), 4),
  COUNT(v.score),
  ROUND(AVG(v.score), 2),
  ROUND(SUM(v.order_amount), 2)
FROM valid v
JOIN seller_flag sf ON sf.order_id = v.order_id
JOIN (
  SELECT DATE(DATE_FORMAT(purchase_ts, '%Y-%m-01')) AS stat_month,
         COUNT(*)                                   AS order_cnt_all,
         SUM(is_delivered)                          AS delivered_cnt
  FROM dwd_orders
  WHERE purchase_ts IS NOT NULL
  GROUP BY DATE(DATE_FORMAT(purchase_ts, '%Y-%m-01'))
) a ON a.stat_month = v.stat_month
GROUP BY v.stat_month, a.order_cnt_all, a.delivered_cnt
ORDER BY v.stat_month;


-- ============================================================================
-- 二、ads_s3_delay_bucket：月 × 延迟分桶 × 评分
--
-- 分桶边界用小时（72h = 3 天，168h = 7 天，336h = 14 天），左开右闭：
--   early_10p  h ≤ -240   提前 10 天以上
--   early_3_10 -240 < h ≤ -72
--   early_0_3  -72 < h ≤ 0      准时或提前 3 天内（对照组）
--   late_0_3   0 < h ≤ 72
--   late_3_7   72 < h ≤ 168
--   late_7_14  168 < h ≤ 336
--   late_14p   h > 336
-- 边界与桶名同时出现在 SQL（口径）与 s3_01（计算）——改一处必须同步另一处。
-- ============================================================================
DROP TABLE IF EXISTS ads_s3_delay_bucket;
CREATE TABLE ads_s3_delay_bucket (
  stat_month   DATE          NOT NULL,
  bucket_code  VARCHAR(12)   NOT NULL,
  bucket_order INT           NOT NULL COMMENT '桶排序键（时间从早到晚）',
  bucket_label VARCHAR(30)   NOT NULL,
  is_late      TINYINT       NOT NULL COMMENT '0=准时侧（含提前） 1=延迟侧',
  n_orders     INT           COMMENT '该桶订单数',
  n_reviewed   INT           COMMENT '其中有评分的订单数',
  sum_score    DECIMAL(12,2) COMMENT '评分合计（均值口径用 n_reviewed）',
  PRIMARY KEY (stat_month, bucket_code)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:S3延迟分桶月度口径表';

INSERT INTO ads_s3_delay_bucket
  (stat_month, bucket_code, bucket_order, bucket_label, is_late, n_orders, n_reviewed, sum_score)
WITH valid AS (
  SELECT
    DATE(DATE_FORMAT(purchase_ts, '%Y-%m-01')) AS stat_month,
    TIMESTAMPDIFF(HOUR, estimated_ts, customer_delivered_ts) AS h,
    review_score
  FROM dwd_orders
  WHERE is_delivered = 1
    AND customer_delivered_ts IS NOT NULL
    AND estimated_ts IS NOT NULL
    AND purchase_ts IS NOT NULL
)
SELECT
  stat_month,
  CASE WHEN h <= -240 THEN 'early_10p'
       WHEN h <= -72  THEN 'early_3_10'
       WHEN h <= 0    THEN 'early_0_3'
       WHEN h <= 72   THEN 'late_0_3'
       WHEN h <= 168  THEN 'late_3_7'
       WHEN h <= 336  THEN 'late_7_14'
       ELSE 'late_14p' END                                   AS bucket_code,
  CASE WHEN h <= -240 THEN 1 WHEN h <= -72 THEN 2 WHEN h <= 0 THEN 3
       WHEN h <= 72 THEN 4 WHEN h <= 168 THEN 5 WHEN h <= 336 THEN 6
       ELSE 7 END                                            AS bucket_order,
  CASE WHEN h <= -240 THEN '提前>10天'
       WHEN h <= -72  THEN '提前3~10天'
       WHEN h <= 0    THEN '准时/提前≤3天'
       WHEN h <= 72   THEN '延迟0~3天'
       WHEN h <= 168  THEN '延迟3~7天'
       WHEN h <= 336  THEN '延迟7~14天'
       ELSE '延迟>14天' END                                  AS bucket_label,
  CASE WHEN h > 0 THEN 1 ELSE 0 END                          AS is_late,
  COUNT(*),
  COUNT(review_score),
  ROUND(SUM(review_score), 2)
FROM valid
GROUP BY stat_month,
  CASE WHEN h <= -240 THEN 'early_10p' WHEN h <= -72 THEN 'early_3_10' WHEN h <= 0 THEN 'early_0_3'
       WHEN h <= 72 THEN 'late_0_3' WHEN h <= 168 THEN 'late_3_7' WHEN h <= 336 THEN 'late_7_14'
       ELSE 'late_14p' END,
  CASE WHEN h <= -240 THEN 1 WHEN h <= -72 THEN 2 WHEN h <= 0 THEN 3
       WHEN h <= 72 THEN 4 WHEN h <= 168 THEN 5 WHEN h <= 336 THEN 6 ELSE 7 END,
  CASE WHEN h <= -240 THEN '提前>10天' WHEN h <= -72 THEN '提前3~10天' WHEN h <= 0 THEN '准时/提前≤3天'
       WHEN h <= 72 THEN '延迟0~3天' WHEN h <= 168 THEN '延迟3~7天' WHEN h <= 336 THEN '延迟7~14天'
       ELSE '延迟>14天' END,
  CASE WHEN h > 0 THEN 1 ELSE 0 END
ORDER BY stat_month, bucket_order;


-- ============================================================================
-- 三、ads_s3_bottleneck_base：月 × 品类/州 × 履约汇总（瓶颈定位的口径层）
--
-- 【品类粒度的口径声明 —— 】
--   一个订单可含多个品类：本表在「订单 × 品类」去重粒度上计数，
--   即该订单在每个所含品类下各计 1 次；GMV 按明细行拆到品类，跨品类加总不重复。
--   后果：分母(订单数)在品类间会有重叠，各品类订单数之和 > 总订单数，
--   这是维度归因的常规处理，报告里要写明，不能假装没看见。
--   时长/评分/距离取的是「明细行加权均值」（item 粒度），与订单粒度略有差异。
-- ============================================================================
DROP TABLE IF EXISTS ads_s3_bottleneck_base;
CREATE TABLE ads_s3_bottleneck_base (
  stat_month         DATE          NOT NULL,
  dim_type           VARCHAR(20)   NOT NULL COMMENT 'category=品类 state=客户州',
  dim_value          VARCHAR(100)  NOT NULL,
  delivered_cnt      INT           COMMENT '履约口径订单数（品类粒度=订单×品类去重）',
  late_cnt           INT,
  avg_lastmile_hours DECIMAL(8,1),
  avg_distance_km    DECIMAL(8,1),
  n_reviewed         INT,
  avg_review_score   DECIMAL(5,2),
  gmv                DECIMAL(14,2) COMMENT '该维度已送达 GMV',
  PRIMARY KEY (stat_month, dim_type, dim_value)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:S3瓶颈定位口径表(月×维度)';

-- 3.1 品类维度（订单 × 品类 粒度）
INSERT INTO ads_s3_bottleneck_base
  (stat_month, dim_type, dim_value, delivered_cnt, late_cnt,
   avg_lastmile_hours, avg_distance_km, n_reviewed, avg_review_score, gmv)
SELECT
  DATE(DATE_FORMAT(o.purchase_ts, '%Y-%m-01'))                AS stat_month,
  'category'                                                  AS dim_type,
  i.category_en                                               AS dim_value,
  COUNT(DISTINCT o.order_id)                                  AS delivered_cnt,
  COUNT(DISTINCT CASE WHEN o.is_late = 1 THEN o.order_id END) AS late_cnt,
  ROUND(AVG(CASE WHEN o.lastmile_hours >= 0 THEN o.lastmile_hours END), 1),
  ROUND(AVG(i.distance_km), 1),
  COUNT(DISTINCT CASE WHEN o.review_score IS NOT NULL THEN o.order_id END),
  ROUND(AVG(o.review_score), 2),
  ROUND(SUM(i.price + i.freight_value), 2)
FROM dwd_order_items i
JOIN dwd_orders o ON o.order_id = i.order_id
WHERE o.is_delivered = 1
  AND o.customer_delivered_ts IS NOT NULL
  AND o.estimated_ts IS NOT NULL
  AND o.purchase_ts IS NOT NULL
GROUP BY DATE(DATE_FORMAT(o.purchase_ts, '%Y-%m-01')), i.category_en;

-- 3.2 州维度（订单粒度，无膨胀）
INSERT INTO ads_s3_bottleneck_base
  (stat_month, dim_type, dim_value, delivered_cnt, late_cnt,
   avg_lastmile_hours, avg_distance_km, n_reviewed, avg_review_score, gmv)
SELECT
  DATE(DATE_FORMAT(purchase_ts, '%Y-%m-01'))                  AS stat_month,
  'state'                                                     AS dim_type,
  customer_state                                              AS dim_value,
  COUNT(*)                                                    AS delivered_cnt,
  SUM(is_late)                                                AS late_cnt,
  ROUND(AVG(CASE WHEN lastmile_hours >= 0 THEN lastmile_hours END), 1),
  ROUND(AVG(avg_distance_km), 1),
  COUNT(review_score),
  ROUND(AVG(review_score), 2),
  ROUND(SUM(order_amount), 2)
FROM dwd_orders
WHERE is_delivered = 1
  AND customer_delivered_ts IS NOT NULL
  AND estimated_ts IS NOT NULL
  AND purchase_ts IS NOT NULL
  AND customer_state IS NOT NULL
GROUP BY DATE(DATE_FORMAT(purchase_ts, '%Y-%m-01')), customer_state;


-- ============================================================================
-- 四、统计结果空表（DDL 统一在 SQL 层，由 s3_01 / s3_02 回写）
-- ============================================================================
DROP TABLE IF EXISTS ads_s3_delay_impact;
CREATE TABLE ads_s3_delay_impact (
  bucket_code   VARCHAR(12)  NOT NULL COMMENT '与 ads_s3_delay_bucket 同名同边界',
  bucket_order  INT          NOT NULL,
  bucket_label  VARCHAR(30)  NOT NULL,
  is_late       TINYINT      NOT NULL,
  n_orders      INT,
  n_reviewed    INT,
  avg_score     DECIMAL(6,3) COMMENT '桶内平均评分',
  score_low     DECIMAL(6,3) COMMENT '均值的95%CI下界',
  score_high    DECIMAL(6,3) COMMENT '均值的95%CI上界',
  diff_vs_ontime DECIMAL(6,3) COMMENT '与对照组(准时/提前≤3天)均值之差',
  diff_low      DECIMAL(6,3) COMMENT '差值的95%CI下界',
  diff_high     DECIMAL(6,3) COMMENT '差值的95%CI上界',
  is_significant TINYINT     COMMENT '差值CI不含0=1',
  updated_at    DATETIME,
  PRIMARY KEY (bucket_code)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:S3延迟剂量反应(整窗汇总, s3_01回写)';

DROP TABLE IF EXISTS ads_s3_score_diff;
CREATE TABLE ads_s3_score_diff (
  metric        VARCHAR(60)  NOT NULL COMMENT '指标名',
  value         VARCHAR(80)  NOT NULL COMMENT '取值（统一转字符串便于打印）',
  note          VARCHAR(200) COMMENT '解读口径',
  updated_at    DATETIME,
  PRIMARY KEY (metric)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:S3准时vs延迟检验结果(单行宽表, s3_01回写)';

DROP TABLE IF EXISTS ads_s3_bottleneck;
CREATE TABLE ads_s3_bottleneck (
  dim_type          VARCHAR(20)  NOT NULL,
  dim_value         VARCHAR(100) NOT NULL,
  delivered_cnt     INT,
  late_cnt          INT,
  late_rate         DECIMAL(6,4),
  rate_low          DECIMAL(6,4) COMMENT 'Wilson 95%CI下界',
  rate_high         DECIMAL(6,4) COMMENT 'Wilson 95%CI上界',
  diff_vs_overall_pp DECIMAL(7,2) COMMENT '与维度总体延迟率之差(pp)',
  z_stat            DOUBLE      COMMENT '两比例z统计量(n<阈值时为NULL)',
  p_value_raw       DOUBLE      COMMENT '原始p值',
  p_value_fdr       DOUBLE      COMMENT 'BH-FDR校正p值',
  is_significant    TINYINT     COMMENT 'FDR后仍显著=1',
  avg_lastmile_hours DECIMAL(8,1),
  avg_distance_km   DECIMAL(8,1),
  avg_review_score  DECIMAL(5,2),
  gmv               DECIMAL(14,2),
  updated_at        DATETIME,
  PRIMARY KEY (dim_type, dim_value)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:S3品类/州延迟瓶颈(整窗汇总, s3_02回写)';

DROP TABLE IF EXISTS ads_s3_stage;
CREATE TABLE ads_s3_stage (
  stage_code  VARCHAR(30)  NOT NULL COMMENT 'approve/carrier/lastmile/total',
  stage_label VARCHAR(30)  NOT NULL,
  group_code  VARCHAR(10)  NOT NULL COMMENT 'on_time=准时组 late=延迟组',
  n_orders   INT,
  mean_hours DECIMAL(8,1),
  ci_low     DECIMAL(8,1)  COMMENT '按天分块Bootstrap 95%CI',
  ci_high    DECIMAL(8,1),
  updated_at DATETIME,
  PRIMARY KEY (stage_code, group_code)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ads:S3履约环节耗时对比(s3_02回写)';


-- ============================================================================
-- 五、勾稽自检（失败说明口径断了，先排查再往下走）
-- ============================================================================
-- 5.1 分桶完整性：每月各桶订单数之和 = 月度表的 valid_cnt
SELECT b.stat_month, SUM(b.n_orders) AS bucket_sum,
       m.valid_cnt, SUM(b.n_orders) - m.valid_cnt AS diff
FROM ads_s3_delay_bucket b
JOIN ads_s3_fulfillment_monthly m ON m.stat_month = b.stat_month
GROUP BY b.stat_month, m.valid_cnt
HAVING diff <> 0;
-- 预期：0 行。注意 review 不影响 n_orders（桶按全部履约订单计，评分只影响 n_reviewed）。

-- 5.2 延迟侧桶的 is_late 标记一致性：late_* 桶的 late_cnt 必须与月度表一致
SELECT b.stat_month, SUM(CASE WHEN b.is_late = 1 THEN b.n_orders ELSE 0 END) AS late_from_bucket,
       m.late_cnt
FROM ads_s3_delay_bucket b
JOIN ads_s3_fulfillment_monthly m ON m.stat_month = b.stat_month
GROUP BY b.stat_month, m.late_cnt
HAVING late_from_bucket <> m.late_cnt;
-- 预期：0 行。is_late 的判定（h>0）在两张表里是同一套 CASE，这里防止日后改漂。

-- 5.3 州维度的履约订单数之和 = 总履约订单数（state 无 NULL 时严格相等；差值=州缺失的订单）
SELECT SUM(delivered_cnt) AS state_dim_sum
FROM ads_s3_bottleneck_base WHERE dim_type = 'state';

SELECT COUNT(*) AS valid_total
FROM dwd_orders
WHERE is_delivered = 1 AND customer_delivered_ts IS NOT NULL
  AND estimated_ts IS NOT NULL AND purchase_ts IS NOT NULL;

-- 5.4 截断月预警：送达率低于 config 阈值(默认0.9)的月份，趋势检验前要剔除
SELECT stat_month, order_cnt_all, delivered_cnt, delivered_ratio
FROM ads_s3_fulfillment_monthly
WHERE delivered_ratio < 0.9
ORDER BY stat_month;
