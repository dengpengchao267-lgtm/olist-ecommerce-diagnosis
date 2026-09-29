"""S3-02　履约瓶颈定位（品类/州延迟率 + 环节耗时 + 趋势）

回答的问题：延迟集中在哪？——哪些品类、哪些州、履约链路的哪一环？

产出：回写两张表
    ads_s3_bottleneck —— 品类/州延迟率 + Wilson CI + 两比例z + BH-FDR
    ads_s3_stage      —— 准时/延迟两组的各环节耗时对比 + 按天Bootstrap CI

用法：
    python s3_02_bottleneck.py --dry-run
    python s3_02_bottleneck.py
    python s3_02_bottleneck.py --b 1000

方法说明：
  1. 延迟率的区间用 Wilson 而不是正态近似：
     延迟率是个比例，小样本品类（n≈100）正态近似会把 CI 弄窄甚至越界，
     Wilson 区间对比例天然合适，且 n→∞ 时收敛到正态近似。
  2. 多重检验用 BH-FDR 而不是 Bonferroni：
     品类 70+ 个、州 27 个同时和总体延迟率比，Bonferroni 会把门槛抬到
     0.05/74 ≈ 0.0007，把真信号也杀掉；FDR 控制的是"报出来的显著里
     有多少是假的"，更适合探索性的瓶颈筛选。但结论仍要标注"经FDR校正"。
  3. 环节对比用按天分块 Bootstrap（同 S2/S3-01 的哲学：天是自然聚簇）。
  4. 月度延迟率趋势用 Mann-Kendall，且先剔除截断月（送达率 < 阈值），
     否则窗口末端的低估会制造一个假的"延迟率下降趋势"。
"""
from __future__ import annotations

import argparse

import numpy as np
import pandas as pd
from scipy.stats import norm, spearmanr

from common import (
    bh_fdr,
    check,
    complete_window,
    fmt_table,
    get_engine,
    mann_kendall,
    month_panel,
    read_sql,
    read_table,
    setup_logging,
    table_exists,
    two_prop_z,
    wilson_ci,
    write_table,
)
from config import ALPHA, BOOTSTRAP_B_S3, RANDOM_SEED, S3_MIN_ORDERS_DIM, S3_TRUNCATION_RATIO

DIM_CN = {"category": "品类", "state": "州"}

STAGES = [
    # code, label, dwd 列名
    ("approve", "下单→审批", "approve_hours"),
    ("carrier", "审批→交承运商", "carrier_hours"),
    ("lastmile", "交承运商→签收", "lastmile_hours"),
    ("total", "下单→签收", "total_delivery_hours"),
]

ORDER_SQL = """
SELECT DATE(o.purchase_ts)                                   AS d,
       DATE(DATE_FORMAT(o.purchase_ts, '%Y-%m-01'))           AS stat_month,
       o.is_late,
       o.approve_hours, o.carrier_hours, o.lastmile_hours, o.total_delivery_hours,
       o.avg_distance_km
FROM dwd_orders o
WHERE o.is_delivered = 1
  AND o.customer_delivered_ts IS NOT NULL
  AND o.estimated_ts IS NOT NULL
  AND o.purchase_ts IS NOT NULL
"""


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="S3-02 履约瓶颈定位")
    p.add_argument("--b", type=int, default=BOOTSTRAP_B_S3, help="Bootstrap 次数")
    p.add_argument("--seed", type=int, default=RANDOM_SEED)
    p.add_argument("--dry-run", action="store_true", help="只计算并打印，不回写")
    return p.parse_args()


def stage_table(df: pd.DataFrame, b: int, seed: int) -> pd.DataFrame:
    """准时/延迟两组 × 四个环节的耗时对比，CI 用按天分块 Bootstrap。"""
    rng = np.random.default_rng(seed)

    rows = []
    for code, label, col in STAGES:
        sub = df[["d", "is_late", col]].dropna(subset=[col])
        on = sub[sub["is_late"] == 0]
        late = sub[sub["is_late"] == 1]
        if on.empty or late.empty:
            continue

        for group, part in (("on_time", on), ("late", late)):
            per_day = part.groupby("d")[col].agg(["sum", "count"])
            agg = per_day["sum"].to_numpy(dtype=float)
            cnt = per_day["count"].to_numpy(dtype=float)
            n_d = len(per_day)

            idx = rng.integers(0, n_d, (b, n_d))
            c = cnt[idx].sum(axis=1)
            means = np.full(b, np.nan)
            ok = c > 0
            means[ok] = agg[idx].sum(axis=1)[ok] / c[ok]
            lo = np.nanpercentile(means, 100 * ALPHA / 2)
            hi = np.nanpercentile(means, 100 * (1 - ALPHA / 2))
            rows.append({
                "stage_code": code, "stage_label": label, "group_code": group,
                "n_orders": int(cnt.sum()),
                "mean_hours": round(float(agg.sum() / cnt.sum()), 1),
                "ci_low": round(float(lo), 1), "ci_high": round(float(hi), 1),
            })
    return pd.DataFrame(rows)


def main() -> None:
    args = parse_args()
    log = setup_logging("s3-02")
    engine = get_engine()

    if not table_exists(engine, "ads_s3_bottleneck_base"):
        raise SystemExit("ads_s3_bottleneck_base 不存在，请先执行 sql/08_s3_履约链路.sql")

    panel = month_panel(engine)
    start, end = complete_window(panel, log)

    # ---- 一、月度延迟率趋势（先剔截断月） --------------------------------
    monthly = read_table(engine, "ads_s3_fulfillment_monthly")
    monthly["stat_month"] = pd.to_datetime(monthly["stat_month"])
    monthly = monthly[(monthly["stat_month"] >= start) & (monthly["stat_month"] <= end)]
    monthly = monthly.sort_values("stat_month")
    truncated = monthly[monthly["delivered_ratio"] < S3_TRUNCATION_RATIO]
    if not truncated.empty:
        log.warning("截断月剔除（送达率 < %.2f）：%s",
                    S3_TRUNCATION_RATIO,
                    ", ".join(m.strftime("%Y-%m") for m in truncated["stat_month"]))
    trend_df = monthly[monthly["delivered_ratio"] >= S3_TRUNCATION_RATIO]
    mk = mann_kendall(trend_df["late_rate"].astype(float).to_numpy())
    log.info("月度延迟率 MK：tau=%.3f, p=%.4f, trend=%s (n=%d, min_p=%.4f)",
             mk["tau"], mk["p_value"], mk["trend"], mk["n"], mk["min_p"])
    log.info("延迟率首尾：%.4f → %.4f，均值 %.4f",
             trend_df["late_rate"].iloc[0], trend_df["late_rate"].iloc[-1],
             trend_df["late_rate"].mean())

    # ---- 二、品类/州瓶颈（窗口内汇总 → Wilson + z + FDR） ------------------
    base = read_table(engine, "ads_s3_bottleneck_base")
    base["stat_month"] = pd.to_datetime(base["stat_month"])
    base = base[(base["stat_month"] >= start) & (base["stat_month"] <= end)]

    out_rows = []
    for dim_type in ("category", "state"):
        sub = base[base["dim_type"] == dim_type]
        g = sub.groupby("dim_value", as_index=False).agg(
            delivered_cnt=("delivered_cnt", "sum"),
            late_cnt=("late_cnt", "sum"),
            gmv=("gmv", "sum"),
        )
        # 月度均值 → 窗口加总：按各月订单数加权，避免"平均的均值"丢权重
        for col in ("avg_lastmile_hours", "avg_distance_km", "avg_review_score"):
            ok = sub.dropna(subset=[col])
            w = ok.assign(_w=ok[col] * ok["delivered_cnt"]).groupby("dim_value")["_w"].sum()
            n = ok.groupby("dim_value")["delivered_cnt"].sum()
            g[col] = (w / n).reindex(g["dim_value"]).round(1).to_numpy()

        p_overall = g["late_cnt"].sum() / g["delivered_cnt"].sum()

        g["late_rate"] = (g["late_cnt"] / g["delivered_cnt"]).round(4)
        cis = g.apply(lambda r: wilson_ci(int(r["late_cnt"]), int(r["delivered_cnt"])), axis=1)
        g["rate_low"] = [c[0] for c in cis]
        g["rate_high"] = [c[1] for c in cis]
        g["diff_vs_overall_pp"] = ((g["late_rate"] - p_overall) * 100).round(2)

        # 检验只对样本量足够的维度做（小样本 z 检验没有功效，报点估计即可）
        tested = (g["delivered_cnt"] >= S3_MIN_ORDERS_DIM).to_numpy()
        zvals = np.full(len(g), np.nan)
        praw = np.full(len(g), np.nan)
        for i in np.where(tested)[0]:
            r = g.iloc[i]
            zvals[i] = two_prop_z(int(r["late_cnt"]), int(r["delivered_cnt"]), p_overall)
            if not np.isnan(zvals[i]):
                praw[i] = 2 * (1 - norm.cdf(abs(zvals[i])))
        g["z_stat"] = np.round(zvals, 3)
        g["p_value_raw"] = praw
        g["p_value_fdr"] = np.nan
        if tested.any():
            g.loc[tested, "p_value_fdr"] = bh_fdr(g.loc[tested, "p_value_raw"].astype(float).to_numpy())
        g["is_significant"] = np.where(tested,
                                       (g["p_value_fdr"] < ALPHA).astype(float),
                                       np.nan)

        g["dim_type"] = dim_type
        out_rows.append(g)

    bott = pd.concat(out_rows, ignore_index=True)
    check(bool((bott["late_cnt"] <= bott["delivered_cnt"]).all()),
          "所有维度 late_cnt ≤ delivered_cnt", log)
    state_sum = int(bott.loc[bott["dim_type"] == "state", "delivered_cnt"].sum())
    valid_sum = int(monthly["valid_cnt"].sum())
    check(state_sum <= valid_sum,
          f"州维度订单数之和({state_sum}) ≤ 履约总量({valid_sum})；"
          f"差额 {valid_sum - state_sum} = 州为空的订单（应为 0 或极小）", log)

    print("\n" + "=" * 100)
    print("S3-02　瓶颈定位（窗口内汇总，按延迟率降序，仅列 n≥%d 且经 FDR 显著的前 8）" % S3_MIN_ORDERS_DIM)
    print("=" * 100)
    for dim_type in ("category", "state"):
        sub = bott[(bott["dim_type"] == dim_type) & (bott["delivered_cnt"] >= S3_MIN_ORDERS_DIM)]
        worst = sub.sort_values("late_rate", ascending=False).head(8)
        sig = sub[sub["is_significant"] == 1].sort_values("late_rate", ascending=False)
        print(f"\n[{DIM_CN[dim_type]}] 最差 8 个（n≥{S3_MIN_ORDERS_DIM}）：")
        print(fmt_table(worst[["dim_value", "delivered_cnt", "late_rate",
                               "rate_low", "rate_high", "diff_vs_overall_pp", "p_value_fdr"]]))
        print(f"经 FDR 校正后显著高于/低于总体的：{len(sig)} 个"
              + (f"，最差 = {sig.iloc[0]['dim_value']}（{sig.iloc[0]['late_rate']:.2%}）" if not sig.empty else ""))

    # ---- 三、环节耗时对比 + 距离效应 --------------------------------------
    odf = read_sql(engine, ORDER_SQL)
    odf["stat_month"] = pd.to_datetime(odf["stat_month"])
    odf = odf[(odf["stat_month"] >= start) & (odf["stat_month"] <= end)]
    log.info("环节分析样本：%d 行（准时 %d / 延迟 %d）",
             len(odf), int((odf["is_late"] == 0).sum()), int((odf["is_late"] == 1).sum()))

    stage = stage_table(odf, args.b, args.seed)
    print("\n" + "=" * 100)
    print("S3-02　准时 vs 延迟的各环节耗时（小时，按天分块 Bootstrap 95%CI）")
    print("=" * 100)
    print(fmt_table(stage.pivot_table(index=["stage_code", "stage_label"],
                                       columns="group_code",
                                       values=["mean_hours", "ci_low", "ci_high"],
                                       aggfunc="first").round(1)))

    # 距离效应：末端时长 vs 买家-卖家直线距离（打印，报告用）
    dist = odf.dropna(subset=["avg_distance_km", "lastmile_hours"])
    rho, p = spearmanr(dist["avg_distance_km"], dist["lastmile_hours"])
    log.info("Spearman(distance, lastmile) rho = %.4f, p = %.3e, n = %d", rho, p, len(dist))

    # ---- 四、回写 -----------------------------------------------------------
    if args.dry_run:
        log.info("--dry-run：不写库。")
        return

    for t in ("ads_s3_bottleneck", "ads_s3_stage"):
        if not table_exists(engine, t):
            raise SystemExit(f"{t} 不存在，请先执行 sql/08_s3_履约链路.sql")

    keep = ["dim_type", "dim_value", "delivered_cnt", "late_cnt", "late_rate",
            "rate_low", "rate_high", "diff_vs_overall_pp", "z_stat",
            "p_value_raw", "p_value_fdr", "is_significant",
            "avg_lastmile_hours", "avg_distance_km", "avg_review_score", "gmv"]
    bott_out = bott[keep].copy()
    bott_out["updated_at"] = pd.Timestamp.now().strftime("%Y-%m-%d %H:%M:%S")
    write_table(engine, bott_out, "ads_s3_bottleneck", log=log)

    stage_out = stage.copy()
    stage_out["updated_at"] = pd.Timestamp.now().strftime("%Y-%m-%d %H:%M:%S")
    write_table(engine, stage_out, "ads_s3_stage", log=log)

    log.info("S3-02 完成。")


if __name__ == "__main__":
    main()
