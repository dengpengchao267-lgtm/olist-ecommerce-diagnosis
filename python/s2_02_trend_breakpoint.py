"""S2-02　月度趋势检验与结构断点检测

回答的问题：GMV 是从哪个月开始变的？这个变化是趋势还是噪音？

产出：回写 ads_gmv_trend 的 mk_tau / mk_p_value / mk_trend / mk_slope_log /
      breakpoint_flag / segment_id（Tableau 趋势图据此标注拐点）。

用法：
    python s2_02_trend_breakpoint.py --dry-run
    python s2_02_trend_breakpoint.py
    python s2_02_trend_breakpoint.py --max-breaks 3

两个方法为什么这么选：
  · 趋势检验用 Mann-Kendall，不用 OLS 斜率。
    MK 是非参数检验，不要求正态、对异常值稳健；只看数据的相对大小顺序。
    Olist 的 GMV 序列有 11 月黑五这种尖峰，OLS 斜率会被那几个月直接带偏。
  · 断点用「二分分割 + BIC 惩罚」，不硬套 PELT。
    月度只有二十来个观测，多断点模型的参数估计不稳定；
    二分分割每一步的判定标准都能讲清楚，且不需要额外依赖。
"""
from __future__ import annotations

import argparse

import numpy as np
import pandas as pd
from sqlalchemy import text

from common import (
    binary_segmentation,
    complete_window,
    fmt_table,
    get_engine,
    log_ols_slope,
    mann_kendall,
    month_panel,
    read_table,
    setup_logging,
    table_exists,
)
from config import ALPHA, DB

MIN_SEGMENT = 3  # 一个分段至少要有的月份数，否则"断点"就是在拟合噪音


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="S2-02 趋势检验与断点检测")
    p.add_argument("--max-breaks", type=int, default=4, help="最多检测的断点个数")
    p.add_argument("--dry-run", action="store_true", help="只计算并打印，不回写数据库")
    return p.parse_args()


def main() -> None:
    args = parse_args()
    log = setup_logging("s2-02")
    engine = get_engine()

    panel = month_panel(engine)
    start, end = complete_window(panel, log)

    s = panel[(panel["stat_month"] >= start) & (panel["stat_month"] <= end)].sort_values("stat_month")
    s = s.reset_index(drop=True)
    log.info("参与趋势分析的月份：%d 个", len(s))

    y = s["gmv"].to_numpy(dtype=float)
    ly = np.log(y)

    # ---- 1. 断点检测 -------------------------------------------------------
    breaks = binary_segmentation(ly, min_size=MIN_SEGMENT, max_breaks=args.max_breaks)
    log.info("检测到断点：%s", [s.loc[b, "stat_month"].strftime("%Y-%m") for b in breaks] or "无")

    segment_id = np.zeros(len(s), dtype=int)
    for i, b in enumerate(breaks):
        segment_id[b:] = i + 1
    s["segment_id"] = segment_id
    s["breakpoint_flag"] = [1 if i in breaks else 0 for i in range(len(s))]

    # 先把要回写的列建好，避免逐分段赋值时因列不存在而出错
    s["mk_tau"] = np.nan
    s["mk_p_value"] = np.nan
    s["mk_trend"] = None
    s["mk_slope_log"] = np.nan

    # ---- 2. 全序列 + 分段趋势检验 -----------------------------------------
    full = mann_kendall(y)
    log.info(
        "全序列 Mann-Kendall：tau=%.3f, p=%.4f, 结论=%s",
        full["tau"], full["p_value"], full["trend"],
    )

    seg_rows = []
    for seg, g in s.groupby("segment_id"):
        seg_y = g["gmv"].to_numpy(dtype=float)
        mk = mann_kendall(seg_y)
        slope = log_ols_slope(seg_y)
        # 功效自检：如果这一段的最小可达 p 值就已经大于显著性水平，
        # 那它无论如何都判不出趋势。此时报"无趋势"是错的，应报"样本不足、无法判定"。
        if not mk["can_detect"] and len(seg_y) >= 4:
            log.warning(
                "分段 #%s 只有 %d 个观测，MK 最小可达 p=%.4f > %.2f —— "
                "该段无法判定趋势，报告里要写'样本不足'而不是'无趋势'。",
                seg, len(seg_y), mk["min_p"], ALPHA,
            )
        s.loc[g.index, "mk_tau"] = mk["tau"]
        s.loc[g.index, "mk_p_value"] = mk["p_value"]
        s.loc[g.index, "mk_trend"] = mk["trend"]
        s.loc[g.index, "mk_slope_log"] = slope
        seg_rows.append(
            {
                "分段": f"#{seg}",
                "起": g["stat_month"].min().strftime("%Y-%m"),
                "止": g["stat_month"].max().strftime("%Y-%m"),
                "月数": len(g),
                "MK参与n": mk.get("n"),
                "期初GMV": seg_y[0],
                "期末GMV": seg_y[-1],
                "平均月增长率%": (np.exp(slope) - 1) * 100 if not np.isnan(slope) else np.nan,
                "MK_tau": mk["tau"],
                "MK_p值": mk["p_value"],
                "MK最小可达p": mk["min_p"],
                "能否判定": "可以" if mk["can_detect"] else "★样本不足",
                "趋势": mk["trend"],
            }
        )

    print("\n" + "=" * 92)
    print("S2-02 分段趋势（断点由 log(GMV) 上的二分分割检测）")
    print("=" * 92)
    print(fmt_table(pd.DataFrame(seg_rows), floatfmt=",.2f"))
    print(
        "读法：『MK最小可达p』是这一段在【完全单调】时能达到的最小 p 值。\n"
        "      它若已大于 0.05，这一段无论怎么涨跌都判不出显著趋势 —— \n"
        "      结论要写'样本不足、无法判定'，不能写'无趋势'。"
    )

    print("\n" + "=" * 92)
    print("全序列检验")
    print("=" * 92)
    print(f"tau = {full['tau']:.4f}    p = {full['p_value']:.4f}    n = {full['n']}    结论 = {full['trend']}")
    print(
        "读法：p < 0.05 才敢说'存在趋势'；p >= 0.05 只能说'未观察到显著单调趋势'，\n"
        "      不能说'没有变化'—— 不显著 ≠ 无影响。\n"
        "注意：全序列显著上升，不等于'现在还在涨'。趋势检验是对整段历史的平均判断，\n"
        "      它会把早期的高增长和近期的停滞揉在一起 —— 这正是必须分段看的原因。"
    )

    # ---- 3. 右端截断诊断（这是最容易忽略、后果最严重的一条）---------------
    s["delivered_ratio"] = s["gmv"] / s["gmv_all"]
    med = s["delivered_ratio"].median()
    tail = s.tail(3)[["stat_month", "gmv", "gmv_all", "delivered_ratio", "order_cnt"]]
    print("\n" + "=" * 92)
    print("右端截断诊断：最近 3 个月的 gmv / gmv_all")
    print("=" * 92)
    print(fmt_table(tail, floatfmt=",.4f"))
    print(f"全区间 delivered_ratio 中位数 = {med:.4f}")
    if (s["delivered_ratio"].tail(3) < med * 0.98).any():
        print(
            "⚠️  警告：最近月份的已送达占比低于中位数 —— 部分订单尚未送达，\n"
            "    '仅已送达'口径会系统性低估最近月份的 GMV。趋势图的右端要么截断，\n"
            "    要么改用 gmv_all，并在报告里写明。"
        )
    else:
        print("✔ 最近月份的送达占比正常，右端没有明显截断，趋势图可以直接用。")

    # ---- 4. 回写 -----------------------------------------------------------
    if args.dry_run:
        log.info("--dry-run：不写库。")
        return

    if not table_exists(engine, "ads_gmv_trend"):
        raise SystemExit("ads_gmv_trend 不存在，请先执行 sql/05_s2_结构下钻.sql")

    payload = s[
        ["stat_month", "mk_tau", "mk_p_value", "mk_trend", "mk_slope_log", "breakpoint_flag", "segment_id"]
    ].copy()
    payload["stat_month"] = payload["stat_month"].dt.date
    payload["updated_at"] = pd.Timestamp.now().strftime("%Y-%m-%d %H:%M:%S")
    payload = payload.astype(object).where(pd.notnull(payload), None)

    with engine.begin() as conn:
        conn.execute(
            text(
                """
                UPDATE ads_gmv_trend
                   SET mk_tau = :mk_tau,
                       mk_p_value = :mk_p_value,
                       mk_trend = :mk_trend,
                       mk_slope_log = :mk_slope_log,
                       breakpoint_flag = :breakpoint_flag,
                       segment_id = :segment_id,
                       updated_at = :updated_at
                 WHERE stat_month = :stat_month
                """
            ),
            payload.to_dict("records"),
        )
    log.info("回写 ads_gmv_trend：%d 行", len(payload))

    check_df = read_table(engine, "ads_gmv_trend")[
        ["stat_month", "segment_id", "breakpoint_flag", "mk_trend"]
    ].sort_values("stat_month")
    print("\n回写结果核对（读回整表再挑列）：")
    print(fmt_table(check_df))


if __name__ == "__main__":
    main()
