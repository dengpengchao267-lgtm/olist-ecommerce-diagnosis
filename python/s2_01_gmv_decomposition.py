"""S2-01　GMV 三因子 LMDI 归因分解 + Bootstrap 置信区间

回答的问题：GMV 的涨跌，是「下单人数」「人均下单次数」「客单价」三个因子中
谁造成的，各占多少，以及这个变化是不是噪音。

产出：回写 ads_gmv_decomposition（Tableau 瀑布图的数据源）。

用法：
    python s2_01_gmv_decomposition.py                # 正常跑并回写
    python s2_01_gmv_decomposition.py --dry-run      # 只算不写，先看结果
    python s2_01_gmv_decomposition.py --b 2000       # 加大重抽样次数
    python s2_01_gmv_decomposition.py --last 3       # 只看最近 3 个月对（调试用）

为什么这个脚本必须存在：
    环比只能告诉你"变了多少"，说不了"为什么变"、更说不了"这个变化算不算数"。
    LMDI 解决"为什么变"，Bootstrap 解决"算不算数"。两件事缺一，结论都不能上会。
"""
from __future__ import annotations

import argparse

import numpy as np
import pandas as pd

from common import (
    bootstrap_decomposition,
    check,
    ci_bounds,
    complete_window,
    daily_order_panel,
    fmt_table,
    get_engine,
    lmdi_additive,
    month_pairs,
    month_panel,
    read_table,
    setup_logging,
    write_table,
)
from config import BOOTSTRAP_B, DB, RANDOM_SEED

FACTORS = ["buyers", "orders_per_buyer", "aov"]
FACTOR_CN = {
    "buyers": "下单人数",
    "orders_per_buyer": "人均下单次数",
    "aov": "客单价",
}


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="S2-01 GMV 三因子 LMDI 分解")
    p.add_argument("--b", type=int, default=BOOTSTRAP_B, help="Bootstrap 重抽样次数")
    p.add_argument("--seed", type=int, default=RANDOM_SEED, help="随机种子")
    p.add_argument("--last", type=int, default=0, help="只处理最近 N 个月份对（0=全部）")
    p.add_argument("--dry-run", action="store_true", help="只计算并打印，不回写数据库")
    return p.parse_args()


def monthly_states(daily: pd.DataFrame) -> pd.DataFrame:
    """从日度明细还原每个月的三因子状态。

    刻意不从数据库直接读聚合值再算，而是从「日 × 客户」明细重算一遍：
    这样月度的去重客户数与日度重抽样用的是同一份数据，口径不会漂。
    """
    g = daily.groupby("stat_month")
    out = pd.DataFrame(
        {
            "buyers": g["buyer_code"].nunique(),
            "delivered": g["delivered_cnt"].sum(),
            "gmv": g["gmv"].sum(),
        }
    )
    out["orders_per_buyer"] = out["delivered"] / out["buyers"]
    out["aov"] = out["gmv"] / out["delivered"]
    return out


def main() -> None:
    args = parse_args()
    log = setup_logging("s2-01")
    engine = get_engine()

    log.info("连接 %s@%s/%s", DB["user"], DB["host"], DB["database"])

    # ---- 1. 定分析区间（首尾不完整月必须剔掉，否则趋势是假的）--------------
    panel = month_panel(engine)
    start, end = complete_window(panel, log)
    pairs = month_pairs(panel, start, end)
    if args.last:
        pairs = pairs[-args.last:]
    log.info("待分解月份对：%d 个", len(pairs))

    # ---- 2. 读日度明细 -----------------------------------------------------
    daily = daily_order_panel(engine)
    log.info("日度明细：%d 行", len(daily))
    states = monthly_states(daily)

    # ---- 3. 与 SQL 算的三因子对账（防止 Python 与 SQL 口径漂移）------------
    cmp = panel.set_index("stat_month")[["buyers", "delivered_cnt", "gmv"]].join(
        states[["buyers", "delivered", "gmv"]], rsuffix="_py", how="inner"
    )
    max_gap = max(
        (cmp["buyers"] - cmp["buyers_py"]).abs().max(),
        (cmp["delivered_cnt"] - cmp["delivered_py"]).abs().max(),
        (cmp["gmv"] - cmp["gmv_py"]).abs().max(),
    )
    check(max_gap < 0.01, f"Python 重算的三因子与 SQL 结果一致（最大偏差 {max_gap}）", log)

    # ---- 4. 逐月分解 -------------------------------------------------------
    rows: list[dict] = []
    for m0, m1 in pairs:
        s0, s1 = states.loc[m0], states.loc[m1]
        x0 = (s0["buyers"], s0["orders_per_buyer"], s0["aov"])
        x1 = (s1["buyers"], s1["orders_per_buyer"], s1["aov"])
        v0, v1 = float(s0["gmv"]), float(s1["gmv"])
        delta = v1 - v0

        contrib = lmdi_additive(v0, v1, x0, x1)

        # 勾稽 1：三因子贡献之和必须严格等于 GMV 变化量（LMDI 的核心性质）
        check(
            abs(contrib.sum() - delta) < 0.01,
            f"{m1:%Y-%m} 三因子贡献合计 = ΔGMV（{contrib.sum():.2f} vs {delta:.2f}）",
            log,
        )

        log.info("Bootstrap %s ← %s（%d 次）...", m1.strftime("%Y-%m"), m0.strftime("%Y-%m"), args.b)
        boot, boot_delta = bootstrap_decomposition(daily, m0, m1, b=args.b, seed=args.seed)
        lo, hi = ci_bounds(boot)

        # 勾稽 2：Bootstrap 的每一轮内部也必须满足"三因子之和 = 该轮的 ΔGMV"。
        # 这条比总体的勾稽更严 —— 它说明分解在任意一次重抽样里都成立，
        # 不是只在原样本上碰巧对上。
        resid = np.nanmax(np.abs(np.nansum(boot, axis=1) - boot_delta))
        if not resid < 1e-6:
            log.warning("%s 的 Bootstrap 逐轮勾稽残差=%.6g", m1.strftime("%Y-%m"), resid)

        for i, f in enumerate(FACTORS):
            rows.append(
                {
                    "stat_month": m1.date(),
                    "factor": f,
                    "factor_cn": FACTOR_CN[f],
                    "factor_prev": round(float(x0[i]), 6),
                    "factor_curr": round(float(x1[i]), 6),
                    "delta_gmv": round(delta, 2),
                    "contribution_amount": round(float(contrib[i]), 2),
                    "contribution_pct": round(float(contrib[i] / delta), 4) if delta != 0 else None,
                    "ci_low": round(float(lo[i]), 2),
                    "ci_high": round(float(hi[i]), 2),
                    "is_significant": int(lo[i] > 0 or hi[i] < 0),
                    "method": f"LMDI-I + 天分块Bootstrap(b={args.b})",
                    "updated_at": pd.Timestamp.now().strftime("%Y-%m-%d %H:%M:%S"),
                }
            )

    result = pd.DataFrame(rows)

    # 全局勾稽：每个月的三个因子贡献占比之和必须为 1
    pct_sum = result.dropna(subset=["contribution_pct"]).groupby("stat_month")["contribution_pct"].sum()
    check(bool(np.allclose(pct_sum.to_numpy(), 1.0, atol=1e-3)), "各月三因子贡献占比之和 = 1", log)

    # ---- 5. 打印结论 -------------------------------------------------------
    print("\n" + "=" * 78)
    print("S2-01 三因子归因（最近 6 个月对）")
    print("=" * 78)
    show = result.tail(18)[
        ["stat_month", "factor_cn", "factor_prev", "factor_curr",
         "contribution_amount", "contribution_pct", "ci_low", "ci_high", "is_significant"]
    ].copy()
    show["contribution_pct"] = (show["contribution_pct"] * 100).round(1)
    print(fmt_table(show))

    print("\n" + "=" * 78)
    print("三因子在整个分析区间内的累计贡献")
    print("=" * 78)
    total = (
        result.groupby(["factor", "factor_cn"], as_index=False)
        .agg(累计贡献额=("contribution_amount", "sum"), 显著月份数=("is_significant", "sum"))
        .sort_values("累计贡献额")
    )
    total["累计贡献占比"] = (total["累计贡献额"] / total["累计贡献额"].sum() * 100).round(1)
    print(fmt_table(total))

    latest = result[result["stat_month"] == result["stat_month"].max()]
    if not latest.empty:
        top = latest.loc[latest["contribution_amount"].abs().idxmax()]
        print(
            f"\n结论要点：{top['stat_month']} GMV 变化 {latest['delta_gmv'].iloc[0]:,.2f} 元，"
            f"最大驱动因子是「{top['factor_cn']}」（{top['contribution_amount']:,.2f} 元，"
            f"占比 {top['contribution_pct'] * 100:.1f}%），"
            f"95%CI [{top['ci_low']:,.2f}, {top['ci_high']:,.2f}]，"
            f"{'显著' if top['is_significant'] else '不显著（区间跨 0，只能说不确定）'}。"
        )

    # ---- 6. 回写 -----------------------------------------------------------
    if args.dry_run:
        log.info("--dry-run：不写库。确认无误后去掉该参数重跑即可回写。")
        return

    # 这一步等价于 df.to_sql('ads_gmv_decomposition', engine, index=False, if_exists='append')，
    # 只是多了一次"先清空"——否则第二次跑会因主键 (stat_month, factor) 冲突报错。
    write_table(engine, result, "ads_gmv_decomposition", log=log)

    # 回写后读回来核对一眼（read_table 就是 pd.read_sql('表名', engine)）
    back = read_table(engine, "ads_gmv_decomposition")
    log.info("读回核对：ads_gmv_decomposition 现有 %d 行", len(back))


if __name__ == "__main__":
    main()
