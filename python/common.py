"""S2 公共模块：连接、面板数据、统计方法、回写工具。

设计原则（沿用 S1 定的分工）：
    SQL 负责取数与聚合；Python 只做 SQL 算不出来的事——分解、检验、区间估计。
所以本模块读进来的都是已经聚合好的面板数据，不做二次清洗。

被 s2_01 / s2_02 / s2_03 / s3_02 / s5_01 / s5_02 共用。
"""
from __future__ import annotations

import logging
import math
import sys
from pathlib import Path
from typing import Sequence

import numpy as np
import pandas as pd
from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine

# 允许直接 python s2_01_xxx.py 运行（把脚本所在目录加入 import 路径）
sys.path.insert(0, str(Path(__file__).resolve().parent))

from config import (  # noqa: E402
    ALPHA,
    DB,
    DB_URL,
    MIN_ORDERS_FOR_COMPLETE_MONTH,
    RANDOM_SEED,
)


# ============================================================================
# 一、连接与日志
# ============================================================================
def setup_logging(name: str) -> logging.Logger:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s | %(levelname)-7s | %(message)s",
        datefmt="%H:%M:%S",
    )
    return logging.getLogger(name)


def get_engine() -> Engine:
    """创建引擎对象。

        engine = create_engine('mysql+pymysql://root:密码@127.0.0.1:3306/olist_dw?charset=utf8mb4')

    连接串在 config.py 里拼好（DB_URL），这里只负责交给 create_engine。
    pool_pre_ping=True：取连接前先探活，避免脚本跑久了拿到已断开的连接。
    """
    return create_engine(DB_URL, pool_pre_ping=True, future=True)


# ============================================================================
# 二、读数据
# ============================================================================
def read_table(engine: Engine, table_name: str) -> pd.DataFrame:
    """读整张表 —— 最省事的读法。

        df = pd.read_sql('ads_gmv_factors', engine)

    表名给字符串即可。表很大时别用它（整表进内存），改用下面的 read_sql 自己写条件。
    """
    return pd.read_sql(table_name, engine)


def read_sql(engine: Engine, sql: str, **params) -> pd.DataFrame:
    """按自定义 SQL 读，支持 :参数 占位。

        df = read_sql(engine, 'SELECT * FROM ads_gmv_trend WHERE stat_month >= :m', m='2017-01-01')
    """
    with engine.connect() as conn:
        return pd.read_sql(text(sql), conn, params=params or None)


def table_exists(engine: Engine, table_name: str) -> bool:
    df = read_sql(
        engine,
        "SELECT COUNT(*) AS n FROM information_schema.TABLES "
        "WHERE TABLE_SCHEMA = :db AND TABLE_NAME = :t",
        db=DB["database"],
        t=table_name,
    )
    return int(df["n"].iloc[0]) > 0


# ============================================================================
# 三、写数据
# ============================================================================
def write_df(
    engine: Engine,
    df: pd.DataFrame,
    table_name: str,
    if_exists: str = "append",
    index: bool = False,
    log: logging.Logger | None = None,
) -> int:
    """写入 MySQL —— 最省事的写法。

        df.to_sql('my_table', engine, index=False, if_exists='append')

    index=False ：不要把我自己造的 0,1,2… 行号也写进去
    if_exists   ：'append' 追加（默认）｜'replace' 删表重建｜'fail' 表存在就报错

    ⚠️ append 不会去重：同一批数据跑两遍就是两倍行数。
       所以本项目往 ads 结果表回写一律走下面的 write_table（先删后插），
       只有"往空表灌第一批数据"时才直接用 append。
    """
    payload = _clean_nan(df)
    payload.to_sql(table_name, engine, index=index, if_exists=if_exists, chunksize=1000)
    if log:
        log.info("写入 %s：%d 行（if_exists=%s）", table_name, len(payload), if_exists)
    return len(payload)


def write_table(
    engine: Engine,
    df: pd.DataFrame,
    table_name: str,
    clear_first: bool = True,
    clear_where: str | None = None,
    clear_params: dict | None = None,
    log: logging.Logger | None = None,
) -> int:
    """幂等写入：先删后插，重复跑不会翻倍。

    为什么默认要清空：这些 ads 表的业务主键是 (stat_month, factor) 之类，
    直接 append 第二次会因主键冲突报 Duplicate entry；
    要是表上没主键，那就更糟 —— 不报错，但行数悄悄翻倍。
    两种结果都不能接受，所以默认先删。

    clear_where 给定时只删一部分（例如只删某个时间段），否则整表清空。
    """
    if df.empty:
        if log:
            log.warning("待写入 %s 的数据为空，跳过。", table_name)
        return 0

    if clear_first:
        with engine.begin() as conn:
            conn.execute(
                text(f"DELETE FROM {table_name}" if clear_where is None else clear_where),
                clear_params or {},
            )

    return write_df(engine, df, table_name, if_exists="append", index=False, log=log)


def _clean_nan(df: pd.DataFrame) -> pd.DataFrame:
    """把 NaN / NaT 转成 None。

    不转的话 DECIMAL 列会收到字符串 'nan'：轻则报 Incorrect decimal value，
    重则静默写进一堆 0 —— 而 NULL 和 0 是两件事，不能混。
    """
    return df.astype(object).where(pd.notnull(df), None)


# ============================================================================
# 四、面板数据
# ============================================================================
def month_panel(engine: Engine) -> pd.DataFrame:
    """月度面板，口径与 sql/03 的 ads_gmv_factors 完全一致。

    注意 buyers 的定义：当月有过任意状态订单的去重客户数
    （与 ads_gmv_factors 保持一行不差，否则两张表对不上）。
    """
    df = read_sql(
        engine,
        """
        SELECT DATE(DATE_FORMAT(purchase_ts, '%Y-%m-01')) AS stat_month,
               COUNT(*)                                   AS order_cnt,
               SUM(is_delivered)                          AS delivered_cnt,
               COUNT(DISTINCT customer_unique_id)         AS buyers,
               ROUND(SUM(CASE WHEN is_delivered = 1 THEN order_amount ELSE 0 END), 2) AS gmv,
               ROUND(SUM(order_amount), 2)                AS gmv_all
        FROM dwd_orders
        WHERE purchase_ts IS NOT NULL
        GROUP BY DATE(DATE_FORMAT(purchase_ts, '%Y-%m-01'))
        ORDER BY 1
        """,
    )
    df["stat_month"] = pd.to_datetime(df["stat_month"])
    for c in ("order_cnt", "delivered_cnt", "buyers"):
        df[c] = df[c].astype("int64")
    for c in ("gmv", "gmv_all"):
        df[c] = df[c].astype(float)

    df["orders_per_buyer"] = df["delivered_cnt"] / df["buyers"]
    df["aov"] = df["gmv"] / df["delivered_cnt"]
    df["is_complete_month"] = (df["order_cnt"] >= MIN_ORDERS_FOR_COMPLETE_MONTH).astype(int)
    return df


def complete_window(panel: pd.DataFrame, log: logging.Logger | None = None) -> tuple[pd.Timestamp, pd.Timestamp]:
    """返回有效分析区间 [起, 止]。

    Olist 首尾都不完整，直接拿全序列做趋势会得到"暴涨 + 断崖"两个假象。
    规则：取第一个完整月到最后一个完整月，中间无论是否达标都保留
    （中间月份量低是真实业务波动，不是数据缺失，不能剔）。
    """
    ok = panel.loc[panel["is_complete_month"] == 1, "stat_month"]
    if ok.empty:
        raise ValueError("没有任何月份满足完整月判定，请检查 MIN_ORDERS_FOR_COMPLETE_MONTH。")
    start, end = ok.min(), ok.max()
    if log:
        dropped = panel.loc[~panel["stat_month"].between(start, end), "stat_month"]
        log.info("有效分析区间：%s ~ %s", start.strftime("%Y-%m"), end.strftime("%Y-%m"))
        if len(dropped):
            log.info(
                "剔除不完整月份 %d 个：%s",
                len(dropped),
                ", ".join(m.strftime("%Y-%m") for m in dropped),
            )
    return start, end


def month_pairs(panel: pd.DataFrame, start: pd.Timestamp, end: pd.Timestamp) -> list[tuple[pd.Timestamp, pd.Timestamp]]:
    """返回区间内相邻的 (上期, 本期) 月份对。"""
    months = sorted(m for m in panel["stat_month"] if start <= m <= end)
    return list(zip(months[:-1], months[1:]))


def daily_order_panel(engine: Engine) -> pd.DataFrame:
    """日 × 客户 的下单明细（已由 SQL 聚合到该粒度），供按天分块 Bootstrap 使用。

    为什么要日 × 客户这一层：月度"下单客户数"是一个去重计数，
    不是各天去重数之和 —— 同一客户在两天各下一单只能算一个人。
    所以重抽样时不能简单把"日去重数"加起来，必须保留客户身份后重新去重。
    """
    df = read_sql(
        engine,
        """
        SELECT DATE(purchase_ts)                                       AS d,
               DATE(DATE_FORMAT(purchase_ts, '%Y-%m-01'))              AS stat_month,
               customer_unique_id                                      AS buyer_id,
               SUM(is_delivered)                                       AS delivered_cnt,
               SUM(CASE WHEN is_delivered = 1 THEN order_amount ELSE 0 END) AS gmv
        FROM dwd_orders
        WHERE purchase_ts IS NOT NULL
        GROUP BY DATE(purchase_ts), DATE(DATE_FORMAT(purchase_ts, '%Y-%m-01')), customer_unique_id
        """,
    )
    df["stat_month"] = pd.to_datetime(df["stat_month"])
    df["d"] = pd.to_datetime(df["d"])
    df["delivered_cnt"] = df["delivered_cnt"].astype(int)
    df["gmv"] = df["gmv"].astype(float)
    # 全局客户编码：把 32 位十六进制 ID 压成 int，后面用 np.unique 去重会快很多
    df["buyer_code"] = pd.factorize(df["buyer_id"])[0]
    return df


DIM_SQL = {
    "category": """
        SELECT DATE(o.purchase_ts)                              AS d,
               DATE(DATE_FORMAT(o.purchase_ts, '%Y-%m-01'))     AS stat_month,
               i.category_en                                    AS dim_value,
               SUM(i.price + i.freight_value)                   AS gmv
        FROM dwd_order_items i
        JOIN dwd_orders o ON o.order_id = i.order_id
        WHERE o.is_delivered = 1 AND o.purchase_ts IS NOT NULL
        GROUP BY DATE(o.purchase_ts), DATE(DATE_FORMAT(o.purchase_ts, '%Y-%m-01')), i.category_en
    """,
    "state": """
        SELECT DATE(purchase_ts)                                AS d,
               DATE(DATE_FORMAT(purchase_ts, '%Y-%m-01'))       AS stat_month,
               customer_state                                   AS dim_value,
               SUM(order_amount)                                AS gmv
        FROM dwd_orders
        WHERE is_delivered = 1 AND purchase_ts IS NOT NULL AND customer_state IS NOT NULL
        GROUP BY DATE(purchase_ts), DATE(DATE_FORMAT(purchase_ts, '%Y-%m-01')), customer_state
    """,
}


def daily_dim_panel(engine: Engine, dim_type: str) -> pd.DataFrame:
    """日 × 维度的 GMV，供结构贡献度的按天 Bootstrap 使用。"""
    df = read_sql(engine, DIM_SQL[dim_type])
    df["stat_month"] = pd.to_datetime(df["stat_month"])
    df["d"] = pd.to_datetime(df["d"])
    df["gmv"] = df["gmv"].astype(float)
    return df


# ============================================================================
# 五、LMDI 三因子分解
# ============================================================================
def _log_mean(a: float, b: float) -> float:
    """对数平均 L(a,b) = (a-b)/(ln a - ln b)，a==b 时取极限值 a。"""
    if a == b:
        return a
    return (a - b) / math.log(a / b)


def lmdi_additive(
    v0: float,
    v1: float,
    x0: Sequence[float],
    x1: Sequence[float],
) -> np.ndarray:
    """LMDI-I 加法分解。

    设 V = x1·x2·x3，则 ΔV = V1 − V0 可被完全拆成三项之和：
        ΔV_i = L(V1, V0) · ln(x_i1 / x_i0)
    性质：无残差、可加、因子对称 —— 这正是它比朴素加法分解
    （ΔV = ΔQ·P0 + Q0·ΔP + ΔQ·ΔP，还会多出一个需要人为归属的交叉项）更适合归因的原因。

    返回：各因子的贡献额，顺序与传入一致。
    """
    if v1 == v0:
        return np.zeros(len(x0))
    if v0 <= 0 or v1 <= 0:
        raise ValueError("LMDI 要求总量为正。")
    L = _log_mean(v1, v0)
    return np.array([L * math.log(a / b) for a, b in zip(x1, x0)])


# ============================================================================
# 六、按天分块 Bootstrap
# ============================================================================
def bootstrap_decomposition(
    daily: pd.DataFrame,
    month0: pd.Timestamp,
    month1: pd.Timestamp,
    b: int = 1000,
    seed: int = RANDOM_SEED,
) -> tuple[np.ndarray, np.ndarray]:
    """对 (基期, 本期) 的 GMV 变化做按天分块 Bootstrap。

    返回 (contrib, delta)：
        contrib —— 形状 (b, 3) 的各因子贡献额矩阵
        delta   —— 形状 (b,)  的每轮 ΔGMV，用于逐轮验证"三项之和 = ΔGMV"
    

    【为什么按天、而不是按订单重抽样】
        月度 GMV 是"若干天之和"，天是它的自然构成单位。按订单重抽样会打散
        时间结构；按天重抽样保留"天"这个整体，更贴近数据的生成方式。

    【为什么不能简单地把各天去重客户数相加】
        "月度下单客户数"是去重计数：同一客户在两天各下一单只算 1 个人。
        所以重抽样时必须带着客户身份（buyer_code）重新去重。
        这一点如果做错，buyers 会被系统性高估，整个归因结论就废了。
    """
    rng = np.random.default_rng(seed)

    def prep(m: pd.Timestamp):
        """把一个月的日度明细整理成「每天一个块」：客户编码数组 + 已送达单数 + GMV。"""
        sub = daily[daily["stat_month"] == m]
        buyers, delivered, gmv = [], [], []
        for _, g in sub.groupby("d", sort=True):
            buyers.append(g["buyer_code"].to_numpy())
            delivered.append(float(g["delivered_cnt"].sum()))
            gmv.append(float(g["gmv"].sum()))
        return buyers, np.array(delivered), np.array(gmv)

    b0, del0, gmv0 = prep(month0)
    b1, del1, gmv1 = prep(month1)
    n0, n1 = len(b0), len(b1)
    if n0 == 0 or n1 == 0:
        raise ValueError(f"月份 {month0} 或 {month1} 没有日度数据。")

    out = np.zeros((b, 3))
    delta = np.zeros(b)
    for i in range(b):
        i0 = rng.integers(0, n0, n0)
        i1 = rng.integers(0, n1, n1)
        # 去重客户数：拼接后 unique，而不是把各天的人数加起来
        nb0 = len(np.unique(np.concatenate([b0[j] for j in i0])))
        nb1 = len(np.unique(np.concatenate([b1[j] for j in i1])))
        d0, d1 = del0[i0].sum(), del1[i1].sum()
        v0, v1 = gmv0[i0].sum(), gmv1[i1].sum()
        if min(nb0, nb1, d0, d1, v0, v1) <= 0:
            out[i] = np.nan
            delta[i] = np.nan
            continue
        x0 = (nb0, d0 / nb0, v0 / d0)
        x1 = (nb1, d1 / nb1, v1 / d1)
        out[i] = lmdi_additive(v0, v1, x0, x1)
        delta[i] = v1 - v0
    return out, delta


def ci_bounds(samples: np.ndarray, alpha: float = ALPHA) -> tuple[np.ndarray, np.ndarray]:
    """按列返回百分位置信区间。"""
    lo = np.nanpercentile(samples, 100 * alpha / 2, axis=0)
    hi = np.nanpercentile(samples, 100 * (1 - alpha / 2), axis=0)
    return lo, hi


# ============================================================================
# 七、趋势检验与断点检测（s2_02 用）
# ============================================================================
def mann_kendall_min_p(n: int) -> float:
    """序列**完全单调**时，Mann-Kendall 能达到的**最小**双侧 p 值。

    这个数不是用来做检验的，是用来判断"这个检验值不值得做"的：

        n=4  → 0.0894   ★ 大于 0.05 —— 4 个观测点的 MK 在任何情况下都不可能显著
        n=5  → 0.0275   可以
        n=6  → 0.0085   可以
        n=10 → 0.0001   可以

    所以当 n=4 时，得到 p=0.31 的正确解读是"**样本量不足以判定**"，
    而不是"没有趋势"。这两句话在报告里是完全不同分量的结论，不能混。

    用途：分段检验时，先看这一列。如果最小可达 p 已经大于显著性水平，
    那一段就别报"无趋势"，直接报"样本不足、无法判定"。
    """
    if n < 4:
        return float("nan")
    s_max = n * (n - 1) / 2.0
    var_s = n * (n - 1) * (2 * n + 5) / 18.0
    if var_s <= 0:
        return float("nan")
    from scipy.stats import norm

    z = (s_max - 1) / math.sqrt(var_s)
    return float(2 * (1 - norm.cdf(z)))


def mann_kendall(x: Sequence[float]) -> dict:
    """Mann-Kendall 趋势检验（含并列值修正）。

    为什么用它而不是直接看 OLS 斜率：MK 是非参数检验，不要求正态分布，
    对异常值稳健。GMV 月度序列有明显的旺季尖峰（11 月黑五），
    OLS 斜率会被那几个月带偏，MK 只看相对大小顺序，不受影响。

    返回 tau（秩相关系数）、p 值、趋势方向、观测数 n，以及两个"能不能判"的辅助量：
      · min_p     —— 本样本量下完全单调时的最小可达 p 值
      · can_detect—— min_p < ALPHA 才为 True，即"这段数据有没有可能被判定出趋势"

    `n` 和 `can_detect` 一定要带上：否则"p=0.31 → 无趋势"这种结论
    会掩盖"这段只有 4 个观测、本来就不可能显著"这个事实。
    """
    x = np.asarray(x, dtype=float)
    x = x[~np.isnan(x)]
    n = len(x)
    min_p = mann_kendall_min_p(n)
    can_detect = bool(min_p < ALPHA) if not np.isnan(min_p) else False

    if n < 4:
        return {"tau": np.nan, "p_value": np.nan, "trend": "样本过少",
                "n": n, "min_p": min_p, "can_detect": False}

    s = 0
    for i in range(n - 1):
        s += np.sign(x[i + 1:] - x[i]).sum()

    # 并列值修正
    _, counts = np.unique(x, return_counts=True)
    tie = np.sum(counts * (counts - 1) * (2 * counts + 5))
    var_s = (n * (n - 1) * (2 * n + 5) - tie) / 18.0

    if var_s <= 0:
        z = 0.0
    elif s > 0:
        z = (s - 1) / math.sqrt(var_s)
    elif s < 0:
        z = (s + 1) / math.sqrt(var_s)
    else:
        z = 0.0

    from scipy.stats import norm

    p = 2 * (1 - norm.cdf(abs(z)))
    tau = s / (0.5 * n * (n - 1))

    if p < ALPHA:
        trend = "increasing" if z > 0 else "decreasing"
    elif not can_detect:
        # 样本量不足以让检验有功效 —— 不能报"无趋势"
        trend = "样本不足"
    else:
        trend = "no trend"

    return {"tau": float(tau), "p_value": float(p), "trend": trend,
            "s": float(s), "z": float(z), "n": n,
            "min_p": min_p, "can_detect": can_detect}


def log_ols_slope(y: Sequence[float]) -> float:
    """对数序列的 OLS 斜率，可解释为"每期平均增长率"。"""
    y = np.asarray(y, dtype=float)
    mask = y > 0
    if mask.sum() < 3:
        return np.nan
    ly = np.log(y[mask])
    t = np.arange(len(ly), dtype=float)
    return float(np.polyfit(t, ly, 1)[0])


def binary_segmentation(
    y: Sequence[float],
    min_size: int = 3,
    max_breaks: int = 4,
) -> list[int]:
    """均值变点检测（二分分割 + BIC 惩罚），返回断点所在的索引位置。

    为什么不用 ruptures 库：这是一个只有二十来个月度观测的小样本，
    带 BIC 惩罚的二分分割足够、且每一步都可解释、无额外依赖。
    需要更复杂的多断点模型时再换 PELT 即可。

    判定标准：某处切分带来的残差平方和下降，是否超过 BIC 惩罚项。
        惩罚 = sigma^2 * ln(n)   （每新增一个变点算一个参数）
    sigma^2 用整段的残差方差估计，避免"切得越多越划算"。

    y 建议传 log(GMV)：取对数后更接近同方差，且变点对应"增长率变化"。
    """
    y = np.asarray(y, dtype=float)
    n = len(y)
    if n < 2 * min_size:
        return []

    def sse(seg: np.ndarray) -> float:
        if len(seg) == 0:
            return 0.0
        return float(((seg - seg.mean()) ** 2).sum())

    # 退化保护：序列本身没有变化时不存在断点。
    # 这一条不能省 —— 常数序列的残差平方和在浮点下是 1e-30 量级的"噪声"，
    # 而惩罚项同样是 1e-31 量级，噪声会随机超过惩罚，凭空造出一个断点。
    # 断点检测最怕的就是"无中生有"，这种误报比漏报危险得多。
    if np.ptp(y) <= 1e-12 * max(1.0, abs(y.mean())):
        return []

    sigma2 = sse(y) / n
    if sigma2 <= 0:
        return []
    penalty = sigma2 * math.log(n)

    breaks: list[int] = []
    segments = [(0, n)]
    for _ in range(max_breaks):
        best = None
        for k, (a, b) in enumerate(segments):
            if b - a < 2 * min_size:
                continue
            base = sse(y[a:b])
            for cut in range(a + min_size, b - min_size + 1):
                gain = base - sse(y[a:cut]) - sse(y[cut:b])
                if best is None or gain > best[0]:
                    best = (gain, k, cut)
        # 收益必须为正、且超过 BIC 惩罚，才认可这个断点
        if best is None or best[0] <= 0 or best[0] <= penalty:
            break
        _, k, cut = best
        a, b = segments.pop(k)
        segments.extend([(a, cut), (cut, b)])
        breaks.append(cut)

    return sorted(breaks)


# ============================================================================
# 八、小工具
# ============================================================================
def fmt_table(df: pd.DataFrame, floatfmt: str = ",.2f") -> str:
    """把 DataFrame 打成好读的纯文本表（控制台汇报用）。"""
    with pd.option_context("display.width", 200, "display.max_columns", 50):
        return df.to_string(index=False, float_format=lambda v: format(v, floatfmt))


def check(cond: bool, msg: str, log: logging.Logger) -> None:
    """勾稽断言。失败即中止 —— 宁可跑不完，也不能跑出错的数。"""
    if cond:
        log.info("勾稽通过：%s", msg)
    else:
        raise AssertionError(f"勾稽失败：{msg}")


# ============================================================================
# 九、比例推断（S3 起共用：延迟率、差评率、复购率本质都是"比例"）
# ----------------------------------------------------------------------------
# 为什么不用正态近似的 Wald 区间：
#   小 n 或 p 接近 0/1 时 Wald 区间会越界（下界为负、上界超过 1），
#   而品类 / 州 / 分层的细胞里恰恰经常出现小样本。
#   Wilson 得分区间在同样条件下的覆盖率更接近名义水平，且永远落在 [0,1] 内。
# ============================================================================
def wilson_ci(k: int, n: int, alpha: float = ALPHA) -> tuple[float, float]:
    """比例的 Wilson 得分区间。k 成功数，n 样本数。"""
    from scipy.stats import norm

    if n == 0:
        return (np.nan, np.nan)
    z = norm.ppf(1 - alpha / 2)
    p = k / n
    denom = 1 + z * z / n
    center = (p + z * z / (2 * n)) / denom
    half = z * np.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denom
    return (float(center - half), float(center + half))


def two_prop_z(k: int, n: int, p0: float) -> float:
    """与已知总体比例 p0 比较的 z 统计量（单组对总体，无重叠方差项）。"""
    if n == 0 or p0 in (0.0, 1.0):
        return np.nan
    return (k / n - p0) / np.sqrt(p0 * (1 - p0) / n)


def bh_fdr(pvals: np.ndarray) -> np.ndarray:
    """Benjamini-Hochberg 校正，返回与输入同序的 q 值。

    为什么用 BH 而不是 Bonferroni：Bonferroni 控 FWER（一个都不能错），
    在"筛出值得关注的品类 / 州 / 分层"这种探索性场景下过于保守，
    会把真信号一起否掉；BH 控 FDR（错误发现占全部发现的比例），更适合筛选场景。
    """
    p = np.asarray(pvals, dtype=float)
    n = len(p)
    if n == 0:
        return p
    order = np.argsort(p)
    q = p[order] * n / np.arange(1, n + 1)
    q = np.minimum.accumulate(q[::-1])[::-1]
    out = np.empty(n)
    out[order] = np.clip(q, 0, 1)
    return out
