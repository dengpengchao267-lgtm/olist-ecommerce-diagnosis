"""S3-01　延迟送达对评分的影响（假设检验 + 剂量反应）

回答的问题：延迟真的伤评分吗？伤多少？伤得越久越重吗？

产出：回写两张表
    ads_s3_score_diff  —— 准时组 vs 延迟组的整体检验（MW + 均值差 CI）
    ads_s3_delay_impact —— 延迟天数分桶的评分曲线（剂量反应）

用法：
    python s3_01_delay_impact.py --dry-run
    python s3_01_delay_impact.py
    python s3_01_delay_impact.py --b 1000

方法说明：
  1. 为什么用 Mann-Whitney U 而不是 t 检验：
     评分是 1~5 的有序变量，分布高度左偏（4、5 分占大头），
     t 检验的均值对这种分布不稳健；MW 只比较两组的秩次分布，
     这正是"延迟单的评分是否系统性更低"该用的检验。
     同时仍报告均值差（业务上好懂），CI 用按天分块 Bootstrap——
     与 S2 保持同一套重抽样哲学：天是订单的自然聚簇单位。
  2. 剂量反应（dose-response）：把 delay_hours 分成 7 个桶，
     看平均评分随延迟时长怎么走。对照组是"准时/提前≤3天"桶。
     ⚠️ 相关不等于因果：延迟晚的订单可能同时是偏远、大件、旺季单，
     报告里只能说"延迟与低评分的关联强度"，不能写"延迟导致降 x 分"。
"""
from __future__ import annotations

import argparse

import numpy as np
import pandas as pd
from scipy.stats import mannwhitneyu, norm

from common import (
    check,
    complete_window,
    fmt_table,
    get_engine,
    month_panel,
    read_sql,
    setup_logging,
    table_exists,
    write_table,
)
from config import ALPHA, BOOTSTRAP_B_S3, RANDOM_SEED

# 桶边界（小时）——与 sql/08 的 ads_s3_delay_bucket 完全一致，改必须两处同步
BUCKETS = [
    # code, order, label, lo(不含), hi(含)；lo=None 表示负无穷，hi=None 表示正无穷
    ("early_10p", 1, "提前>10天", None, -240),
    ("early_3_10", 2, "提前3~10天", -240, -72),
    ("early_0_3", 3, "准时/提前≤3天", -72, 0),
    ("late_0_3", 4, "延迟0~3天", 0, 72),
    ("late_3_7", 5, "延迟3~7天", 72, 168),
    ("late_7_14", 6, "延迟7~14天", 168, 336),
    ("late_14p", 7, "延迟>14天", 336, None),
]
CONTROL_CODE = "early_0_3"  # 对照组

ORDER_SQL = """
SELECT DATE(o.purchase_ts)                                   AS d,
       DATE(DATE_FORMAT(o.purchase_ts, '%Y-%m-01'))           AS stat_month,
       o.is_late,
       TIMESTAMPDIFF(HOUR, o.estimated_ts, o.customer_delivered_ts) AS delay_hours,
       o.review_score
FROM dwd_orders o
WHERE o.is_delivered = 1
  AND o.customer_delivered_ts IS NOT NULL
  AND o.estimated_ts IS NOT NULL
  AND o.purchase_ts IS NOT NULL
  AND o.review_score IS NOT NULL
"""


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="S3-01 延迟对评分的影响")
    p.add_argument("--b", type=int, default=BOOTSTRAP_B_S3, help="Bootstrap 次数")
    p.add_argument("--seed", type=int, default=RANDOM_SEED)
    p.add_argument("--dry-run", action="store_true", help="只计算并打印，不回写")
    return p.parse_args()


def bucket_code(h: float) -> str | None:
    """按小时边界返回桶 code（左开右闭），与 sql/08 同一套边界。"""
    for code, _, _, lo, hi in BUCKETS:
        if (lo is None or h > lo) and (hi is None or h <= hi):
            return code
    return None


def day_block_mean_diff_ci(
    df: pd.DataFrame, b: int, seed: int, alpha: float = ALPHA
) -> tuple[float, float]:
    """准时组与延迟组的评分均值之差，按天分块 Bootstrap 的 95% CI。

    为什么按天而不是按订单重抽样：同一天的订单共享旺季/天气/承运商状态，
    订单不是独立样本；按订单重抽样会低估方差、把 CI 弄窄，
    得出"差异显著"的假阳性。按天抽保留聚簇结构。
    """
    per_day = df.assign(
        n_on=np.where(df["is_late"] == 0, 1.0, 0.0),
        s_on=np.where(df["is_late"] == 0, df["review_score"].astype(float), 0.0),
        n_late=np.where(df["is_late"] == 1, 1.0, 0.0),
        s_late=np.where(df["is_late"] == 1, df["review_score"].astype(float), 0.0),
    ).groupby("d")[["n_on", "s_on", "n_late", "s_late"]].sum()
    n_on = per_day["n_on"].to_numpy(dtype=float)
    s_on = per_day["s_on"].to_numpy(dtype=float)
    n_late = per_day["n_late"].to_numpy(dtype=float)
    s_late = per_day["s_late"].to_numpy(dtype=float)

    rng = np.random.default_rng(seed)
    nd = len(per_day)
    # 一次性抽出 (b, nd) 的行索引，按轮求和——比逐轮循环快一个量级
    idx = rng.integers(0, nd, (b, nd))
    c_on, c_late = n_on[idx].sum(axis=1), n_late[idx].sum(axis=1)
    ok = (c_on > 0) & (c_late > 0)
    diffs = np.full(b, np.nan)
    diffs[ok] = s_late[idx].sum(axis=1)[ok] / c_late[ok] - s_on[idx].sum(axis=1)[ok] / c_on[ok]
    lo = np.nanpercentile(diffs, 100 * alpha / 2)
    hi = np.nanpercentile(diffs, 100 * (1 - alpha / 2))
    return float(lo), float(hi)


def mean_ci(x: np.ndarray, alpha: float = ALPHA) -> tuple[float, float]:
    """单组均值的正态近似 CI（桶内样本量大，n≥数百时足够）。"""
    x = np.asarray(x, dtype=float)
    se = x.std(ddof=1) / np.sqrt(len(x))
    z = norm.ppf(1 - alpha / 2)
    return float(x.mean() - z * se), float(x.mean() + z * se)


def diff_ci(x: np.ndarray, y: np.ndarray, alpha: float = ALPHA) -> tuple[float, float]:
    """两组均值之差 (x−y) 的正态近似 CI（Welch，不假设方差相等）。"""
    x, y = np.asarray(x, float), np.asarray(y, float)
    se = np.sqrt(x.var(ddof=1) / len(x) + y.var(ddof=1) / len(y))
    z = norm.ppf(1 - alpha / 2)
    d = x.mean() - y.mean()
    return float(d - z * se), float(d + z * se)


def main() -> None:
    args = parse_args()
    log = setup_logging("s3-01")
    engine = get_engine()

    # 分析窗口与 S2 完全一致（第一个完整月 → 最后一个完整月）
    panel = month_panel(engine)
    start, end = complete_window(panel, log)

    df = read_sql(engine, ORDER_SQL)
    df["stat_month"] = pd.to_datetime(df["stat_month"])
    df = df[(df["stat_month"] >= start) & (df["stat_month"] <= end)].copy()
    log.info("窗口内带评分的履约订单：%d 行（准时 %d / 延迟 %d）",
             len(df), int((df["is_late"] == 0).sum()), int((df["is_late"] == 1).sum()))

    on_scores = df.loc[df["is_late"] == 0, "review_score"].to_numpy(dtype=float)
    late_scores = df.loc[df["is_late"] == 1, "review_score"].to_numpy(dtype=float)

    # ---- 一、整体检验：延迟单评分是否系统性更低 ---------------------------
    mean_on, mean_late = on_scores.mean(), late_scores.mean()
    mw = mannwhitneyu(on_scores, late_scores, alternative="two-sided")
    lo, hi = day_block_mean_diff_ci(df, args.b, args.seed)
    mean_diff = float(mean_late - mean_on)

    log.info("MW U = %.1f, p = %.3e", mw.statistic, mw.pvalue)
    log.info("均值差(延迟−准时) = %.3f, 按天Bootstrap 95%%CI [%.3f, %.3f]", mean_diff, lo, hi)

    # 剂量随相关性快查：延迟天数与评分的 Spearman（打印，不入库）
    from scipy.stats import spearmanr
    rho, rho_p = spearmanr(df["delay_hours"], df["review_score"])
    log.info("Spearman(delay_hours, score) rho = %.4f, p = %.3e", rho, rho_p)

    # ---- 二、剂量反应：分桶评分曲线 ---------------------------------------
    df["bucket"] = df["delay_hours"].map(bucket_code)
    check(df["bucket"].notna().all(), "所有订单都落进了唯一的延迟桶", log)

    ctrl = df[df["bucket"] == CONTROL_CODE]["review_score"].to_numpy(dtype=float)
    ctrl_mean = float(ctrl.mean())

    rows = []
    for code, order, label, _, _ in BUCKETS:
        sub = df[df["bucket"] == code]
        if sub.empty:
            continue
        scores = sub["review_score"].to_numpy(dtype=float)
        s_lo, s_hi = mean_ci(scores)
        # 与对照组的差及其 CI（对照组方差用同一公式）
        d_lo, d_hi = diff_ci(scores, ctrl)
        rows.append({
            "bucket_code": code, "bucket_order": order, "bucket_label": label,
            "is_late": int(code.startswith("late")),
            "n_orders": len(sub),
            "n_reviewed": len(sub),  # 本脚本读入时已过滤 review 非空
            "avg_score": round(float(scores.mean()), 3),
            "score_low": round(s_lo, 3), "score_high": round(s_hi, 3),
            "diff_vs_ontime": round(float(scores.mean()) - ctrl_mean, 3),
            "diff_low": round(d_lo, 3), "diff_high": round(d_hi, 3),
            "is_significant": int(d_lo > 0 or d_hi < 0),
        })
    impact = pd.DataFrame(rows).sort_values("bucket_order").reset_index(drop=True)

    check(int(impact["n_orders"].sum()) == len(df),
          f"各桶样本数之和 = 总样本数（{impact['n_orders'].sum()} vs {len(df)}）", log)

    print("\n" + "=" * 100)
    print(f"S3-01　延迟剂量反应（窗口 {start:%Y-%m} ~ {end:%Y-%m}，对照组={CONTROL_CODE}）")
    print("=" * 100)
    print(fmt_table(impact[[
        "bucket_label", "n_orders", "avg_score", "score_low", "score_high",
        "diff_vs_ontime", "diff_low", "diff_high", "is_significant"
    ]]))
    worst = impact.sort_values("avg_score").iloc[0]
    print(f"\n最低分桶：{worst['bucket_label']}（均值 {worst['avg_score']:.2f}，"
          f"较对照组 {worst['diff_vs_ontime']:+.2f} 分，"
          f"{'显著' if worst['is_significant'] else '不显著'}）")

    # ---- 三、回写 -----------------------------------------------------------
    if args.dry_run:
        log.info("--dry-run：不写库。")
        return

    for t in ("ads_s3_delay_impact", "ads_s3_score_diff"):
        if not table_exists(engine, t):
            raise SystemExit(f"{t} 不存在，请先执行 sql/08_s3_履约链路.sql")

    impact["updated_at"] = pd.Timestamp.now().strftime("%Y-%m-%d %H:%M:%S")
    write_table(engine, impact, "ads_s3_delay_impact", log=log)

    summary = pd.DataFrame([
        {"metric": "n_on_time",      "value": str(len(on_scores)),
         "note": "准时组订单数（含提前）"},
        {"metric": "n_late",         "value": str(len(late_scores)),
         "note": "延迟组订单数"},
        {"metric": "mean_score_on_time", "value": f"{mean_on:.4f}", "note": "准时组平均评分"},
        {"metric": "mean_score_late",    "value": f"{mean_late:.4f}", "note": "延迟组平均评分"},
        {"metric": "mean_diff",      "value": f"{mean_diff:.4f}",
         "note": "延迟−准时，按天Bootstrap 95%CI 见下两行"},
        {"metric": "mean_diff_ci_low",  "value": f"{lo:.4f}", "note": f"b={args.b}，按天分块"},
        {"metric": "mean_diff_ci_high", "value": f"{hi:.4f}", "note": f"b={args.b}，按天分块"},
        {"metric": "mw_u_statistic", "value": f"{mw.statistic:.1f}", "note": "Mann-Whitney U"},
        {"metric": "mw_p_value",     "value": f"{mw.pvalue:.3e}",
         "note": "双侧；<0.05 即两组评分分布不同"},
        {"metric": "spearman_delay_score", "value": f"{rho:.4f}",
         "note": f"延迟小时 vs 评分，p={rho_p:.3e}；相关非因果"},
    ])
    summary["updated_at"] = pd.Timestamp.now().strftime("%Y-%m-%d %H:%M:%S")
    write_table(engine, summary, "ads_s3_score_diff", log=log)

    log.info("S3-01 完成。")


if __name__ == "__main__":
    main()
