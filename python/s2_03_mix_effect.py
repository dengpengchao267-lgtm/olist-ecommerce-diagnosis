"""S2-03　结构贡献度分解（品类 / 州 维度）

回答的问题：整体 GMV 的变化，具体是哪些品类、哪些州造成的？

产出：回写 ads_gmv_structure（Tableau 双向贡献度条形图的数据源）。

用法：
    python s2_03_mix_effect.py --dry-run
    python s2_03_mix_effect.py
    python s2_03_mix_effect.py --b 1000 --dims category

方法说明：
  贡献度用可加分解，不做近似：
      contrib_pp_i = (gmv_i,本期 − gmv_i,上期) / GMV_上期 × 100
  两边对 i 求和：
      Σ contrib_pp_i = (GMV_本期 − GMV_上期) / GMV_上期 × 100 ≡ 整体增长率
  也就是说各维度的贡献加起来**恰好**是整体增长率，没有残差项。
  这比"先算各自增长率再平均"那种做法可靠得多——后者加总不等于整体。

  显著性同样用按天分块 Bootstrap：对两个月的"天"分别有放回重抽样，
  重算每个维度的贡献，得到置信区间。区间跨 0 的维度只能说"未观察到显著影响"，
  报告里不能当成结论写。
"""
from __future__ import annotations

import argparse

import numpy as np
import pandas as pd

from common import (
    check,
    ci_bounds,
    complete_window,
    daily_dim_panel,
    fmt_table,
    get_engine,
    month_pairs,
    month_panel,
    read_table,
    setup_logging,
    table_exists,
    write_table,
)
from config import ALPHA, BOOTSTRAP_B_STRUCT, RANDOM_SEED

DIM_CN = {"category": "品类", "state": "州"}


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="S2-03 结构贡献度分解")
    p.add_argument("--b", type=int, default=BOOTSTRAP_B_STRUCT, help="Bootstrap 次数")
    p.add_argument("--seed", type=int, default=RANDOM_SEED)
    p.add_argument("--dims", nargs="*", default=["category", "state"], help="要算的维度")
    p.add_argument("--dry-run", action="store_true", help="只计算并打印，不回写")
    return p.parse_args()


def month_matrix(daily_dim: pd.DataFrame, m: pd.Timestamp, all_dims: list[str]) -> np.ndarray | None:
    """把某个月转成 (天 × 维度) 的 GMV 矩阵。

    行列必须对齐：所有月份用同一套维度顺序、索引是天。
    某天某维度没有销量就是 0（这是事实，不是缺失），所以 fill_value=0。
    """
    sub = daily_dim[daily_dim["stat_month"] == m]
    if sub.empty:
        return None
    piv = sub.pivot_table(index="d", columns="dim_value", values="gmv", aggfunc="sum", fill_value=0.0)
    piv = piv.reindex(columns=all_dims, fill_value=0.0)
    return piv.to_numpy(dtype=float)


def bootstrap_contrib(
    A0: np.ndarray,
    A1: np.ndarray,
    b: int,
    seed: int,
) -> np.ndarray:
    """按天重抽样，返回形状 (b, 维度数) 的贡献百分点矩阵。"""
    rng = np.random.default_rng(seed)
    n0, n1 = A0.shape[0], A1.shape[0]
    out = np.empty((b, A0.shape[1]))
    for i in range(b):
        g0 = A0[rng.integers(0, n0, n0)].sum(axis=0)
        g1 = A1[rng.integers(0, n1, n1)].sum(axis=0)
        t0 = g0.sum()
        out[i] = (g1 - g0) / t0 * 100 if t0 > 0 else np.nan
    return out


def main() -> None:
    args = parse_args()
    log = setup_logging("s2-03")
    engine = get_engine()

    panel = month_panel(engine)
    start, end = complete_window(panel, log)
    pairs = month_pairs(panel, start, end)
    log.info("待分解月份对：%d 个；维度：%s", len(pairs), args.dims)

    all_rows: list[pd.DataFrame] = []

    for dim_type in args.dims:
        daily_dim = daily_dim_panel(engine, dim_type)
        daily_dim = daily_dim[(daily_dim["stat_month"] >= start) & (daily_dim["stat_month"] <= end)]
        all_dims = sorted(daily_dim["dim_value"].dropna().unique().tolist())
        log.info("[%s] 维度值 %d 个，日度明细 %d 行", DIM_CN[dim_type], len(all_dims), len(daily_dim))

        for m0, m1 in pairs:
            A0 = month_matrix(daily_dim, m0, all_dims)
            A1 = month_matrix(daily_dim, m1, all_dims)
            if A0 is None or A1 is None:
                log.warning("%s 或 %s 无数据，跳过", m0, m1)
                continue

            G0, G1 = A0.sum(axis=0), A1.sum(axis=0)
            T0, T1 = G0.sum(), G1.sum()
            if T0 <= 0 or T1 <= 0:
                continue

            contrib_pp = (G1 - G0) / T0 * 100

            # 勾稽：各维度贡献之和 ≡ 整体增长率
            total_growth = (T1 - T0) / T0 * 100
            check(
                abs(contrib_pp.sum() - total_growth) < 0.01,
                f"[{DIM_CN[dim_type]}] {m1:%Y-%m} 各维度贡献之和 = 整体增长率 "
                f"（{contrib_pp.sum():.4f} vs {total_growth:.4f}）",
                log,
            )

            boot = bootstrap_contrib(A0, A1, args.b, args.seed)
            lo, hi = ci_bounds(boot, ALPHA)

            df = pd.DataFrame(
                {
                    "stat_month": m1.date(),
                    "dim_type": dim_type,
                    "dim_value": all_dims,
                    "gmv": np.round(G1, 2),
                    "gmv_prev": np.round(G0, 2),
                    "contrib_amount": np.round(G1 - G0, 2),
                    "gmv_share": np.round(G1 / T1, 4),
                    "gmv_share_prev": np.round(G0 / T0, 4),
                    "growth_pct": np.where(G0 > 0, np.round((G1 / np.where(G0 > 0, G0, 1) - 1) * 100, 2), None),
                    "contrib_pp": np.round(contrib_pp, 4),
                    "ci_low_pp": np.round(lo, 4),
                    "ci_high_pp": np.round(hi, 4),
                    "is_significant": ((lo > 0) | (hi < 0)).astype(int),
                    "updated_at": pd.Timestamp.now().strftime("%Y-%m-%d %H:%M:%S"),
                }
            )
            # 两个月都是 0 的维度没有信息量，不入库
            df = df[(df["gmv"] != 0) | (df["gmv_prev"] != 0)]
            all_rows.append(df)

    result = pd.concat(all_rows, ignore_index=True)
    log.info("共生成 %d 行结构贡献度记录", len(result))

    # ---- 打印结论 ---------------------------------------------------------
    latest_month = result["stat_month"].max()
    for dim_type in args.dims:
        sub = result[(result["stat_month"] == latest_month) & (result["dim_type"] == dim_type)]
        if sub.empty:
            continue
        sub = sub.sort_values("contrib_pp")
        print("\n" + "=" * 96)
        print(f"S2-03　{latest_month} {DIM_CN[dim_type]}贡献度（按贡献百分点升序）")
        print("=" * 96)
        show = pd.concat([sub.head(8), sub.tail(8)])
        print(
            fmt_table(
                show[["dim_value", "gmv", "gmv_prev", "growth_pct", "contrib_pp", "ci_low_pp", "ci_high_pp", "is_significant"]]
            )
        )
        neg = sub.head(1).iloc[0]
        pos = sub.tail(1).iloc[0]
        print(
            f"最大拖累：{neg['dim_value']}（{neg['contrib_pp']:.2f}pp，"
            f"CI [{neg['ci_low_pp']:.2f}, {neg['ci_high_pp']:.2f}]，"
            f"{'显著' if neg['is_significant'] else '不显著'}）"
        )
        print(
            f"最大拉动：{pos['dim_value']}（{pos['contrib_pp']:.2f}pp，"
            f"CI [{pos['ci_low_pp']:.2f}, {pos['ci_high_pp']:.2f}]，"
            f"{'显著' if pos['is_significant'] else '不显著'}）"
        )

    # 累计视角：整个区间里谁在长期失血、谁在长期贡献
    print("\n" + "=" * 96)
    print("整个分析区间的累计贡献额（Top 拖累 / Top 拉动）")
    print("=" * 96)
    for dim_type in args.dims:
        sub = (
            result[result["dim_type"] == dim_type]
            .groupby("dim_value", as_index=False)
            .agg(累计贡献额=("contrib_amount", "sum"), 累计GMV=("gmv", "sum"), 显著月数=("is_significant", "sum"))
            .sort_values("累计贡献额")
        )
        print(f"\n[{DIM_CN[dim_type]}]")
        print(fmt_table(pd.concat([sub.head(6), sub.tail(6)])))

    # ---- 回写 -------------------------------------------------------------
    if args.dry_run:
        log.info("--dry-run：不写库。")
        return

    if not table_exists(engine, "ads_gmv_structure"):
        raise SystemExit("ads_gmv_structure 不存在，请先执行 sql/05_s2_结构下钻.sql")

    # 等价于 df.to_sql('ads_gmv_structure', engine, index=False, if_exists='append')，
    # 多的一次"先清空"是为了避免重复跑时主键 (stat_month, dim_type, dim_value) 冲突
    write_table(engine, result, "ads_gmv_structure", log=log)

    back = read_table(engine, "ads_gmv_structure")
    log.info("读回核对：ads_gmv_structure 现有 %d 行", len(back))


if __name__ == "__main__":
    main()
