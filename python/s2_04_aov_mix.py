"""S2-04　客单价（AOV）五效应分解：价格效应 vs 结构效应 ★ S2 收尾的核心分析

回答的问题：
    「客单价跌了 7%」这句话无法行动。必须拆成——
        是【各品类自己变便宜了】（→ 定价问题）
        还是【低单价品类占比上升了】（→ 品类结构问题）
    这两件事对应完全不同的动作，结论含金量差一个量级。

产出（三张表，全部 Python 回写）：
    ads_aov_decomposition   月度五效应分解
    ads_aov_mix_detail      月度 × 品类：谁在拉价、谁在改结构
    ads_aov_effect_window   窗口级汇总 + 置信区间 + 符号检验

用法：
    python s2_04_aov_mix.py --dry-run
    python s2_04_aov_mix.py
    python s2_04_aov_mix.py --dry-run --top 12

分解链（每一层都是精确恒等式，无残差）：
    第 1 层   AOV = P × N + f
                 P = item_amount / item_cnt        件均价
                 N = item_cnt / delivered_orders   单均件数
                 f = freight / delivered_orders    单均运费
    第 2 层   P = Σ s_i · p_i      （s_i = 品类件数占比，Σ s_i = 1）
                 ΔP = Σ s_i0·Δp_i + Σ p_i0·Δs_i + Σ Δs_i·Δp_i

    合并后五个效应之和【严格】等于 ΔAOV —— 脚本里有断言把关。

【为什么这里不做逐月置信区间】
    月度分解是恒等式，不是估计：五项加起来必须等于 ΔAOV，这是算出来的、没有抽样误差。
    给它配置信区间是范畴错误。
    真正需要区间的是"这个效应是不是系统性的"——那是一个关于【19 个月】的推断问题，
    所以窗口级的区间用【月】做重抽样单位（顺带修正了 S2-01 里按天重抽样导致区间过宽的问题）。
"""
from __future__ import annotations

import argparse

import numpy as np
import pandas as pd
from scipy.stats import binomtest

from common import (
    check,
    complete_window,
    fmt_table,
    get_engine,
    month_pairs,
    month_panel,
    read_sql,
    setup_logging,
    table_exists,
    write_table,
)
from config import ALPHA, BOOTSTRAP_B_STRUCT, RANDOM_SEED

# 取数：品类明细（仅已送达）＋ 月度总量（仅已送达）
CATEGORY_SQL = """
SELECT DATE(DATE_FORMAT(o.purchase_ts, '%Y-%m-01')) AS stat_month,
       i.category_en                                AS category_en,
       COUNT(*)                                     AS item_cnt,
       SUM(i.price)                                 AS item_amount,
       SUM(i.freight_value)                         AS freight_amount
FROM dwd_order_items i
JOIN dwd_orders o ON o.order_id = i.order_id
WHERE o.is_delivered = 1
  AND o.purchase_ts IS NOT NULL
  AND i.category_en IS NOT NULL
GROUP BY DATE(DATE_FORMAT(o.purchase_ts, '%Y-%m-01')), i.category_en
"""

TOTAL_SQL = """
SELECT DATE(DATE_FORMAT(purchase_ts, '%Y-%m-01'))                          AS stat_month,
       SUM(is_delivered)                                                   AS delivered_orders,
       SUM(CASE WHEN is_delivered = 1 THEN item_cnt ELSE 0 END)            AS item_cnt,
       SUM(CASE WHEN is_delivered = 1 THEN item_amount ELSE 0 END)         AS item_amount,
       SUM(CASE WHEN is_delivered = 1 THEN freight_amount ELSE 0 END)      AS freight_amount,
       SUM(CASE WHEN is_delivered = 1 AND IFNULL(item_cnt, 0) = 0 THEN 1 ELSE 0 END) AS delivered_no_item
FROM dwd_orders
WHERE purchase_ts IS NOT NULL
GROUP BY DATE(DATE_FORMAT(purchase_ts, '%Y-%m-01'))
"""

FACTORS = [
    ("price",       "价格效应"),
    ("mix",         "结构效应"),
    ("quantity",    "件数效应"),
    ("freight",     "运费效应"),
    ("interaction", "交叉项"),
]
FACTOR_CN = dict(FACTORS)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="S2-04 AOV 五效应分解")
    p.add_argument("--b", type=int, default=BOOTSTRAP_B_STRUCT, help="窗口级 Bootstrap 次数")
    p.add_argument("--seed", type=int, default=RANDOM_SEED)
    p.add_argument("--top", type=int, default=10, help="品类明细打印前 N 条")
    p.add_argument("--dry-run", action="store_true", help="只计算并打印，不回写数据库")
    return p.parse_args()


# ============================================================================
# 核心：五效应分解（抽成纯函数，便于脱库自检）
# ============================================================================
def decompose_aov(Q0, A0, F0, O0, Q1, A1, F1, O1, q0, a0, q1, a1):
    """把 ΔAOV 精确拆成五个效应。

    参数（0 = 上期，1 = 本期）：
        Q  已送达订单的商品件数（Σ q_i）
        A  已送达订单的商品金额（Σ a_i）
        F  已送达订单的运费金额
        O  已送达订单数
        q  各品类的件数向量
        a  各品类的金额向量

    返回 (effects, price_i, mix_i, aux)：
        effects  dict，五个效应的金额（单位同货币，五项之和 ≡ ΔAOV）
        price_i  各品类对价格效应的贡献
        mix_i    各品类对结构效应的贡献
        aux      中间量（P/N/f/AOV 等），便于打印核对
    """
    q0 = np.asarray(q0, dtype=float)
    q1 = np.asarray(q1, dtype=float)
    a0 = np.asarray(a0, dtype=float)
    a1 = np.asarray(a1, dtype=float)

    P0, P1 = A0 / Q0, A1 / Q1          # 件均价
    N0, N1 = Q0 / O0, Q1 / O1          # 单均件数
    f0, f1 = F0 / O0, F1 / O1          # 单均运费
    AOV0, AOV1 = P0 * N0 + f0, P1 * N1 + f1
    dAOV = AOV1 - AOV0

    s0, s1 = q0 / Q0, q1 / Q1          # 品类件数占比（各自求和为 1）

    # 件均价：该月没卖出的品类，用另一月的价格交叉填充。
    # 这不是"编数据"——它恰好让"新品类/消失品类"的全部影响归到结构效应上，
    # 从而保住 ΔP 三项分解的精确性（函数末尾的断言会验证）。
    with np.errstate(divide="ignore", invalid="ignore"):
        p0 = np.where(q0 > 0, a0 / np.where(q0 > 0, q0, 1.0), np.nan)
        p1 = np.where(q1 > 0, a1 / np.where(q1 > 0, q1, 1.0), np.nan)
    p0 = np.where(np.isnan(p0) & ~np.isnan(p1), p1, p0)
    p1 = np.where(np.isnan(p1) & ~np.isnan(p0), p0, p1)
    p0 = np.nan_to_num(p0)
    p1 = np.nan_to_num(p1)

    # 品类级贡献
    price_i = N0 * s0 * (p1 - p0)                    # 各品类自身价格变化
    mix_i = N0 * p0 * (s1 - s0)                      # 各品类占比变化（混比）

    dP, dN = P1 - P0, N1 - N0
    effects = {
        "price":       float(price_i.sum()),
        "mix":         float(mix_i.sum()),
        "quantity":    P0 * dN,
        "freight":     f1 - f0,
        "interaction": dP * dN + float(N0 * np.sum((s1 - s0) * (p1 - p0))),
    }
    aux = {"P0": P0, "P1": P1, "N0": N0, "N1": N1, "f0": f0, "f1": f1,
           "AOV0": AOV0, "AOV1": AOV1, "dAOV": dAOV}

    # 断言 1：五项之和 ≡ ΔAOV（相对容差，量级无关）
    assert abs(sum(effects.values()) - dAOV) <= 1e-9 * max(1.0, abs(dAOV)), \
        f"五效应之和 {sum(effects.values())} ≠ ΔAOV {dAOV}"
    # 断言 2：品类级贡献之和 ≡ 对应效应
    assert abs(price_i.sum() - effects["price"]) < 1e-9
    assert abs(mix_i.sum() - effects["mix"]) < 1e-9
    return effects, price_i, mix_i, aux


def load_data(engine):
    """读品类明细与月度总量。"""
    cat = read_sql(engine, CATEGORY_SQL)
    tot = read_sql(engine, TOTAL_SQL)
    for df in (cat, tot):
        df["stat_month"] = pd.to_datetime(df["stat_month"])
    for c in ("item_cnt", "item_amount", "freight_amount"):
        cat[c] = cat[c].astype(float)
    for c in ("delivered_orders", "item_cnt", "item_amount", "freight_amount", "delivered_no_item"):
        tot[c] = tot[c].astype(float)
    return cat, tot


def monthly_matrix(cat: pd.DataFrame, month: pd.Timestamp, col: str, cats: list[str]) -> np.ndarray:
    """取出某个月的品类向量，缺失品类补 0（补 0 是对的：表示该月这个品类没卖出）。"""
    sub = cat[cat["stat_month"] == month]
    return sub.set_index("category_en")[col].reindex(cats).fillna(0.0).to_numpy(dtype=float)


def main() -> None:
    args = parse_args()
    log = setup_logging("s2-04")
    engine = get_engine()

    # ---- 1. 定区间（与其他脚本同一套规则）----------------------------------
    panel = month_panel(engine)
    start, end = complete_window(panel, log)

    cat, tot = load_data(engine)
    tot_idx = tot.set_index("stat_month")
    cats = sorted(cat["category_en"].unique().tolist())
    log.info("品类数：%d", len(cats))

    # ---- 2. 跨层级对账（三个层级必须指向同一个总量）------------------------
    gap_cnt = gap_amt = 0.0
    for m in tot_idx.index:
        gap_cnt = max(gap_cnt, abs(monthly_matrix(cat, m, "item_cnt", cats).sum() - float(tot_idx.loc[m, "item_cnt"])))
        gap_amt = max(gap_amt, abs(monthly_matrix(cat, m, "item_amount", cats).sum() - float(tot_idx.loc[m, "item_amount"])))
    check(gap_cnt < 0.01, f"品类件数合计 = 订单层件数（最大偏差 {gap_cnt:.4f}）", log)
    check(gap_amt < 0.01, f"品类金额合计 = 订单层金额（最大偏差 {gap_amt:.4f}）", log)

    cmp = panel.set_index("stat_month")["delivered_cnt"] - tot_idx["delivered_orders"]
    check(float(cmp.abs().max()) < 0.01,
          f"已送达订单数 = ads_gmv_factors 口径（最大偏差 {cmp.abs().max():.4f}）", log)

    no_item = int(tot_idx["delivered_no_item"].sum())
    if no_item > 0:
        log.warning(
            "有 %d 笔「已送达但查不到任何明细」的订单 —— 它们只进 AOV 的分母不进分子，"
            "会系统性压低客单价，报告里要注明。", no_item,
        )

    # ---- 3. 逐月分解 -------------------------------------------------------
    pairs = month_pairs(panel, start, end)
    log.info("待分解月份对：%d 个", len(pairs))

    decomp_rows, detail_rows = [], []
    window_series = {k: [] for k, _ in FACTORS}
    aov_by_month: dict[pd.Timestamp, float] = {}

    for m0, m1 in pairs:
        t0, t1 = tot_idx.loc[m0], tot_idx.loc[m1]
        O0, O1 = float(t0["delivered_orders"]), float(t1["delivered_orders"])
        Q0, Q1 = float(t0["item_cnt"]), float(t1["item_cnt"])
        A0, A1 = float(t0["item_amount"]), float(t1["item_amount"])
        F0, F1 = float(t0["freight_amount"]), float(t1["freight_amount"])
        if min(O0, O1, Q0, Q1) <= 0:
            log.warning("%s 缺数据，跳过", m1.strftime("%Y-%m"))
            continue

        q0 = monthly_matrix(cat, m0, "item_cnt", cats)
        q1 = monthly_matrix(cat, m1, "item_cnt", cats)
        a0 = monthly_matrix(cat, m0, "item_amount", cats)
        a1 = monthly_matrix(cat, m1, "item_amount", cats)

        effects, price_i, mix_i, aux = decompose_aov(
            Q0, A0, F0, O0, Q1, A1, F1, O1, q0, a0, q1, a1
        )
        aov_by_month[m1] = aux["AOV1"]
        aov_by_month.setdefault(m0, aux["AOV0"])
        dAOV = aux["dAOV"]

        for k, cn in FACTORS:
            window_series[k].append(effects[k])
            decomp_rows.append({
                "stat_month": m1.date(),
                "factor": k,
                "factor_cn": cn,
                "aov_prev": round(aux["AOV0"], 4),
                "aov_curr": round(aux["AOV1"], 4),
                "delta_aov": round(dAOV, 4),
                "contribution_amount": round(effects[k], 4),
                "contribution_pct": round(effects[k] / dAOV, 6) if dAOV != 0 else None,
                "method": "AOV=P×N+f 五效应精确分解",
                "updated_at": pd.Timestamp.now().strftime("%Y-%m-%d %H:%M:%S"),
            })

        s0, s1 = q0 / Q0, q1 / Q1
        for i, cname in enumerate(cats):
            if q0[i] == 0 and q1[i] == 0:
                continue
            detail_rows.append({
                "stat_month": m1.date(),
                "category_en": cname,
                "item_cnt_prev": int(q0[i]),
                "item_cnt_curr": int(q1[i]),
                "share_prev": round(float(s0[i]), 6),
                "share_curr": round(float(s1[i]), 6),
                "price_prev": round(float(a0[i] / q0[i] if q0[i] > 0 else 0.0), 4),
                "price_curr": round(float(a1[i] / q1[i] if q1[i] > 0 else 0.0), 4),
                "price_contrib": round(float(price_i[i]), 6),
                "mix_contrib": round(float(mix_i[i]), 6),
                "updated_at": pd.Timestamp.now().strftime("%Y-%m-%d %H:%M:%S"),
            })

    decomp = pd.DataFrame(decomp_rows)
    detail = pd.DataFrame(detail_rows)
    check(len(decomp) > 0, "至少分解出一个月份对", log)

    # ---- 4. 窗口级汇总 + 区间 + 符号检验 ----------------------------------
    rng = np.random.default_rng(args.seed)
    win_rows = []
    for k, cn in FACTORS:
        vals = np.array(window_series[k], dtype=float)
        n = len(vals)
        idx = rng.integers(0, n, (args.b, n))
        means = vals[idx].mean(axis=1)
        lo, hi = np.percentile(means, [100 * ALPHA / 2, 100 * (1 - ALPHA / 2)])
        neg, pos = int((vals < 0).sum()), int((vals > 0).sum())
        p_sign = float(binomtest(min(neg, pos), neg + pos, 0.5).pvalue) if (neg + pos) > 0 else None
        win_rows.append({
            "factor": k,
            "factor_cn": cn,
            "total_amount": round(float(vals.sum()), 4),
            "mean_per_month": round(float(vals.mean()), 4),
            "ci_low": round(float(lo), 4),
            "ci_high": round(float(hi), 4),
            "negative_months": neg,
            "positive_months": pos,
            "sign_test_p": round(p_sign, 6) if p_sign is not None else None,
            "months": n,
            "method": f"月度精确分解 + 月级Bootstrap(b={args.b}) + 符号检验",
            "updated_at": pd.Timestamp.now().strftime("%Y-%m-%d %H:%M:%S"),
        })
    window = pd.DataFrame(win_rows)

    # 望远镜求和：各效应累计之和必须等于首末期客单价之差
    months_sorted = sorted(aov_by_month)
    aov_first, aov_last = aov_by_month[months_sorted[0]], aov_by_month[months_sorted[-1]]
    check(abs(window["total_amount"].sum() - (aov_last - aov_first)) < 0.01,
          f"各效应累计之和 = 期末AOV − 期初AOV（{window['total_amount'].sum():.4f} vs {aov_last - aov_first:.4f}）", log)

    # ---- 5. 打印 -----------------------------------------------------------
    latest = decomp["stat_month"].max()
    print("\n" + "=" * 96)
    print(f"S2-04　{latest} 客单价五效应分解（单位：元）")
    print("=" * 96)
    cur = decomp[decomp["stat_month"] == latest].copy()
    cur["占比%"] = (cur["contribution_pct"] * 100).round(1)
    cur = cur.rename(columns={"factor_cn": "效应", "aov_prev": "上期AOV", "aov_curr": "本期AOV",
                              "delta_aov": "AOV变化", "contribution_amount": "贡献额"})
    print(fmt_table(cur[["效应", "上期AOV", "本期AOV", "AOV变化", "贡献额", "占比%"]]))

    print("\n" + "=" * 96)
    print(f"S2-04　全区间窗口汇总（{int(window['months'].iloc[0])} 个月）")
    print("=" * 96)
    w = window.copy()
    w["显著?"] = np.where((w["ci_low"] > 0) | (w["ci_high"] < 0), "是", "否")
    w = w.rename(columns={"factor_cn": "效应", "total_amount": "累计", "mean_per_month": "月均",
                          "ci_low": "CI下界", "ci_high": "CI上界", "negative_months": "负月数",
                          "positive_months": "正月数", "sign_test_p": "符号检验p"})
    print(fmt_table(w[["效应", "累计", "月均", "CI下界", "CI上界", "负月数", "正月数", "符号检验p", "显著?"]]))
    print(
        "\n读法：\n"
        "  · 累计 = 该效应在整个区间贡献的客单价变化总额（各效应累计之和 ≡ 期末AOV − 期初AOV）\n"
        "  · 符号检验 p 只问『有多少个月的效应是负的』，不做任何分布假设，比 t 检验更稳\n"
        "  · CI 用【月】做重抽样单位 —— 月度分解是恒等式，逐月配区间没有意义；\n"
        "    要推断的是『这个效应是不是系统性的』，样本单位就该是月"
    )

    print("\n" + "=" * 96)
    print("S2-04　品类明细：谁在拉价、谁在改结构（全区间累计，单位：元）")
    print("=" * 96)
    agg = (
        detail.groupby("category_en", as_index=False)
        .agg(价格贡献=("price_contrib", "sum"), 结构贡献=("mix_contrib", "sum"),
             件数期初=("item_cnt_prev", "first"), 件数期末=("item_cnt_curr", "last"))
    )
    agg["合计"] = agg["价格贡献"] + agg["结构贡献"]
    for tag, col in (("价格效应", "价格贡献"), ("结构效应", "结构贡献")):
        s = agg.sort_values(col)
        print(f"\n【{tag}】拖累 Top{args.top} / 拉动 Top{args.top}")
        print(fmt_table(pd.concat([s.head(args.top), s.tail(args.top)])))

    # ---- 6. 一句话结论 -----------------------------------------------------
    price_total = float(window.loc[window["factor"] == "price", "total_amount"].iloc[0])
    mix_total = float(window.loc[window["factor"] == "mix", "total_amount"].iloc[0])
    aov_delta = aov_last - aov_first
    print("\n" + "=" * 96)
    print("一句话结论")
    print("=" * 96)
    print(
        f"整个区间客单价从 {aov_first:,.2f} 变到 {aov_last:,.2f}（{aov_delta:+,.2f} 元）。\n"
        f"其中价格效应 {price_total:+,.2f} 元、结构效应 {mix_total:+,.2f} 元。"
    )
    print(
        "⇒ 结构效应是主要驱动：问题出在【卖了什么】，不是【卖多少钱】—— 动作应落在品类结构运营。"
        if abs(mix_total) > abs(price_total) else
        "⇒ 价格效应是主要驱动：问题出在【各品类自身价格】—— 动作应落在定价与折扣策略。"
    )

    # ---- 7. 回写 -----------------------------------------------------------
    if args.dry_run:
        log.info("--dry-run：不写库。")
        return

    for tbl in ("ads_aov_decomposition", "ads_aov_mix_detail", "ads_aov_effect_window"):
        if not table_exists(engine, tbl):
            raise SystemExit(f"{tbl} 不存在，请先执行 sql/06_s2_AOV结构拆解.sql")

    write_table(engine, decomp, "ads_aov_decomposition", log=log)
    write_table(engine, detail, "ads_aov_mix_detail", log=log)
    write_table(engine, window, "ads_aov_effect_window", log=log)


if __name__ == "__main__":
    main()
