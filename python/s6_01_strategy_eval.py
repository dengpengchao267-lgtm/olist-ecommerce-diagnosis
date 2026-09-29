"""S6-01　策略效果评估：把 S3/S4/S5 的结论算成一张 ROI 账本

【这个脚本回答什么】
    前面五个专题各自给出了「该做什么」：
        S3：瓶颈在承运环节，干预窗口 = 延迟 3~7 天
        S4：走「物流提速」不走「卖家治理」，拦前 10% 性价比最高
        S5：延迟对 365 天复购有 −1.46pp 的弱效应
    但从没回答「做了值多少钱、先做哪个、投多少」。这个脚本就是那张账本。

【⚠️ 关键诚实声明：这是反事实仿真，不是 A/B 实验】
    Olist 是历史公开数据，平台**从未跑过延迟补偿/提速的随机试验**。
    所以本脚本算的是 what-if：**如果**执行某条策略，**假设**它能消除比例为 p 的问题，
    **那么**收益是多少。其中有两个参数**在数据里根本不存在**：
        p = 挽回率（策略执行后问题被真正消除的比例）
        v = 差评的单位价值（R$，属品牌/声誉范畴）
    对这两个参数的正确处理不是「拍一个数」，而是**让它们显式进入二维敏感性**，
    输出「在什么条件下这个策略才划算」——即盈亏平衡线。
    ⇒ 给出一个看起来精确的 ROI 数字是**不专业**的；给出盈亏平衡条件才是分析的价值。

【三条策略的定义（全部来自前面专题，不是拍脑袋）】
    P1 物流提速   命中：延迟 3~7 天      依据：S3 的剂量反应断崖（3 天）与饱和（7 天）
    P2 风险拦截   命中：延迟 >3 天        依据：S4 增益曲线的 10% 拐点，用延迟天数做代理
    P3 延迟补偿券 命中：全部延迟订单      依据：S5 的 −1.46pp（365 天）长期复购损失

【两个收益口径必须分开报（这是本脚本的方法论核心）】
    口径 A：只看「挽回差评」的价值         —— 三条策略都适用
    口径 B：口径 A + 「挽回复购」的价值    —— **只有 P1 适用**
      依据：S5 已证「差评 → 复购」路径不成立（log-rank p=0.4803）。
      所以「缓解差评」类策略（P2/P3）**不能**声称挽回了复购 —— 强行加进去是虚增收益。
      反过来 P1 消除了延迟本身（S5 证延迟对复购有真效应），才配得上这部分收益。

【产出】
    ads_s6_strategy_roi   策略 ROI 汇总（含盈亏平衡挽回率）
    ads_s6_sensitivity    (策略 × 挽回率 × 差评价值) 敏感性长表
    ads_s6_budget_plan    预算档位下的分配方案

【用法】python s6_01_strategy_eval.py [--dry-run]
"""
from __future__ import annotations

import argparse
import sys

import numpy as np
import pandas as pd

from common import (
    check,
    fmt_table,
    get_engine,
    read_sql,
    read_table,
    setup_logging,
    write_table,
)
from config import (
    S6_BAD_VALUES,
    S6_BASE_BAD_VALUE,
    S6_BASE_RESCUE_RATE,
    S6_BUDGET_LEVELS,
    S6_REPEAT_ELIGIBLE,
    S6_RESCUE_RATES,
)

STRATEGY_NAMES = {
    "p1_expedite": "P1 物流提速",
    "p2_intercept": "P2 风险拦截",
    "p3_voucher": "P3 延迟补偿券",
}

# 每条策略的单均成本由哪几个参数构成（乘/加关系）
COST_FORMULA = {
    "p1_expedite": "单均加急成本",
    "p2_intercept": "券面值 × 核销率 + 客服触达成本",
    "p3_voucher": "券面值 × 核销率（无额外交互）",
}


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="S6-01 策略效果评估（反事实仿真）")
    p.add_argument("--dry-run", action="store_true", help="只打印，不回写数据库")
    return p.parse_args()


# ---------------------------------------------------------------------------
# 参数与输入
# ---------------------------------------------------------------------------
def load_params(engine) -> dict[str, float]:
    """把参数表读成一个扁平字典。参数表是「实测 / 假设」的唯一事实源。"""
    df = read_table(engine, "ads_s6_strategy_params")
    params = {r["param_key"]: float(r["param_value"]) for _, r in df.iterrows()}
    for k in ("p1_expedite_cost", "p2_voucher_face", "p2_redeem_rate", "p2_contact_cost",
              "p3_voucher_face", "p3_redeem_rate", "bad_review_cost", "repeat_effect_pp",
              "aov_delayed", "aov_ontime", "baseline_bad_ontime", "baseline_bad_late"):
        if k not in params:
            raise KeyError(f"参数表缺少 {k}，请先跑 sql/11")
    return params


def cost_per_order(strategy: str, params: dict[str, float]) -> float:
    """单均成本。三条策略的成本结构不同，必须分开算 —— 这是最容易被平均掉的地方。"""
    if strategy == "p1_expedite":
        return params["p1_expedite_cost"]
    if strategy == "p2_intercept":
        return params["p2_voucher_face"] * params["p2_redeem_rate"] + params["p2_contact_cost"]
    if strategy == "p3_voucher":
        return params["p3_voucher_face"] * params["p3_redeem_rate"]
    raise ValueError(f"未知策略 {strategy}")


def load_scale(engine) -> pd.DataFrame:
    """每个策略的覆盖规模：订单数 + **全局去重**客户数。

    为什么客户数要单独查：`ads_s6_roi_input` 是「策略 × 月」粒度，
    同一客户可能在多个月各下过延迟单，逐月 sum 会重复计数。
    """
    sql = """
    SELECT 'p1_expedite' AS strategy,
           COUNT(*) AS covered_orders,
           COUNT(DISTINCT customer_unique_id) AS covered_customers,
           SUM(order_amount) AS covered_gmv,
           SUM(is_bad) AS bad_orders
    FROM ads_s6_intervention_pool WHERE hit_p1_expedite = 1
    UNION ALL
    SELECT 'p2_intercept', COUNT(*), COUNT(DISTINCT customer_unique_id),
           SUM(order_amount), SUM(is_bad)
    FROM ads_s6_intervention_pool WHERE hit_p2_intercept = 1
    UNION ALL
    SELECT 'p3_voucher', COUNT(*), COUNT(DISTINCT customer_unique_id),
           SUM(order_amount), SUM(is_bad)
    FROM ads_s6_intervention_pool WHERE hit_p3_voucher = 1
    """
    df = read_sql(engine, sql)
    for c in ("covered_orders", "covered_customers", "covered_gmv", "bad_orders"):
        df[c] = df[c].astype(float)
    return df


# ---------------------------------------------------------------------------
# 核心测算
# ---------------------------------------------------------------------------
def compute_roi(
    strategy: str,
    covered_orders: float,
    covered_customers: float,
    covered_gmv: float,
    params: dict[str, float],
    rescue_rate: float,
    bad_value: float,
) -> dict:
    """单条策略在 (p, v) 下的 ROI。

    收益结构（这是全脚本最需要讲清楚的地方）：
        可挽救差评上限 = 覆盖订单数 × (延迟组差评率 − 准时组差评率)
            —— 含义：如果这些延迟订单变成准时，差评率会从 53.99% 降到 9.19%
               所以每单最多能少掉 44.80pp 的差评概率。
            —— 这是**上限**：它假设「延迟是差评的唯一原因」且「准时水平可达」。
        差评收益 = 可挽救差评上限 × p × v
        复购收益 = 覆盖客户数 × |S5 效应| × p × 延迟客单价   （仅 P1）
            —— 覆盖客户数用**去重**的，因为复购是客户级行为，一个客户多单只算一次。
    """
    bad_late = params["baseline_bad_late"] / 100.0
    bad_ontime = params["baseline_bad_ontime"] / 100.0
    rescuable_pp = bad_late - bad_ontime

    bad_upper = covered_orders * rescuable_pp            # 个
    cpo = cost_per_order(strategy, params)
    total_cost = covered_orders * cpo

    # 口径 A：只看差评
    revenue_review = bad_upper * rescue_rate * bad_value

    # 口径 B：仅 P1 加复购挽回
    if strategy in S6_REPEAT_ELIGIBLE:
        rescued_repeat = covered_customers * abs(params["repeat_effect_pp"]) / 100.0 * rescue_rate
        revenue_repeat = rescued_repeat * params["aov_delayed"]
    else:
        rescued_repeat = 0.0
        revenue_repeat = 0.0

    revenue_total = revenue_review + revenue_repeat

    # 盈亏平衡挽回率：让净收益 = 0 的 p
    denom_a = bad_upper * bad_value
    breakeven_a = total_cost / denom_a if denom_a > 0 else np.nan
    denom_b = denom_a + (covered_customers * abs(params["repeat_effect_pp"]) / 100.0
                         * params["aov_delayed"] if strategy in S6_REPEAT_ELIGIBLE else 0.0)
    breakeven_b = total_cost / denom_b if denom_b > 0 else np.nan

    net_a = revenue_review - total_cost
    net_b = revenue_total - total_cost
    roi_a = revenue_review / total_cost if total_cost > 0 else np.nan
    roi_b = revenue_total / total_cost if total_cost > 0 else np.nan

    if breakeven_b > 1.0:
        verdict = "不建议：理论上限都回不了本"
    elif breakeven_b > 0.7:
        verdict = "条件投放：需要很高的挽回率"
    elif breakeven_b > 0.45:
        verdict = "条件投放：挽回率过半才划算"
    else:
        verdict = "建议投放：低挽回率即可盈利"

    # ⚠️ 这里**不做 round**：输出精度会污染下面的恒等式勾稽断言
    # （round 到 4 位后再验证 roi == 收益/成本，误差 4e-5 > 1e-6，那是"用舍入把断言弄脏"，
    #  不是"实现有错"。舍入只放在展示层与写库层。）
    return {
        "strategy": strategy,
        "strategy_name": STRATEGY_NAMES[strategy],
        "covered_orders": int(covered_orders),
        "covered_customers": int(covered_customers),
        "covered_gmv": covered_gmv,
        "cost_per_order": cpo,
        "total_cost": total_cost,
        "bad_upper": bad_upper,
        "revenue_review": revenue_review,
        "rescued_repeat": rescued_repeat,
        "revenue_repeat": revenue_repeat,
        "revenue_total": revenue_total,
        "net_benefit_a": net_a,
        "net_benefit_b": net_b,
        "roi_a": roi_a,
        "roi_b": roi_b,
        "breakeven_p_a": breakeven_a,
        "breakeven_p_b": breakeven_b,
        "rescue_rate": rescue_rate,
        "bad_value": bad_value,
        "verdict": verdict,
        "note": (f"成本口径：{COST_FORMULA[strategy]} = R${cpo:.2f}/单；"
                 f"可挽救差评 {bad_upper:,.0f} 个（延迟差评率 {bad_late*100:.2f}% "
                 f"− 准时 {bad_ontime*100:.2f}%）"
                 + ("" if strategy in S6_REPEAT_ELIGIBLE
                    else "；不含复购收益（S5 已证差评不驱动复购）")),
    }


def sensitivity(strategy: str, covered_orders: float, covered_customers: float,
                covered_gmv: float, params: dict[str, float]) -> list[dict]:
    """(p × v) 网格。用来回答「v 得有多高、p 得有多高，这条策略才划算」。"""
    rows: list[dict] = []
    for p in S6_RESCUE_RATES:
        for v in S6_BAD_VALUES:
            r = compute_roi(strategy, covered_orders, covered_customers,
                            covered_gmv, params, p, v)
            rows.append({
                "strategy": strategy,
                "rescue_rate": float(p),
                "bad_value": float(v),
                "total_cost": r["total_cost"],
                "revenue": r["revenue_total"],
                "net_benefit": r["net_benefit_b"],
                "roi": r["roi_b"],
                "is_profitable": int(r["net_benefit_b"] > 0),
            })
    return rows


def budget_plan(roi_df: pd.DataFrame, params: dict[str, float]) -> list[dict]:
    """预算约束下的分配：按「每元投入的净收益」从高到低贪心塞满。

    为什么不按 ROI 排序而按「净收益/成本」排序：ROI 是比率，在预算有限时
    应该优先把钱投给**边际效率最高**的策略 —— 这正是 S4 增益曲线同一个思路。
    """
    df = roi_df.copy()
    # 每条策略的「单位覆盖率」：一轮（覆盖全部命中订单）要花多少钱
    df["cycle_cost"] = df["covered_orders"] * df["cost_per_order"]
    df["net_per_cycle"] = df["net_benefit_b"]
    # 每元净收益 = 一轮净收益 / 一轮成本
    df["net_per_brl"] = np.where(df["cycle_cost"] > 0,
                                 df["net_per_cycle"] / df["cycle_cost"], 0.0)
    order = df.sort_values("net_per_brl", ascending=False)

    rows: list[dict] = []
    for budget in S6_BUDGET_LEVELS:
        remain = float(budget)
        for _, r in order.iterrows():
            if remain <= 0 or r["net_per_brl"] <= 0:
                continue
            alloc = min(remain, r["cycle_cost"])
            # 部分覆盖时按比例折算覆盖单数与净收益
            frac = alloc / r["cycle_cost"] if r["cycle_cost"] > 0 else 0.0
            covered = int(round(r["covered_orders"] * frac))
            net = r["net_per_cycle"] * frac
            remain -= alloc
            rows.append({
                "budget_level": float(budget),
                "strategy": r["strategy"],
                "allocated": round(alloc, 2),
                "alloc_pct": round(alloc / budget * 100, 2),
                "covered_orders": covered,
                "expected_net": round(net, 2),
                # 口径：expected_roi = 净收益/投入 + 1 = 总回报倍数（1.0 = 刚好回本）
                "expected_roi": round(net / alloc + 1, 4) if alloc > 0 else np.nan,
                "rationale": (f"每元净收益 R${r['net_per_brl']:.2f}，按效率优先排序；"
                              f"{'全额覆盖一轮' if frac >= 0.999 else f'部分覆盖 {frac:.0%}'}"),
            })
        # 亏损策略不参与分配，但必须在表里留痕 —— 否则看板读者会以为漏算了
        for _, r in order.iterrows():
            if r["net_per_brl"] <= 0:
                rows.append({
                    "budget_level": float(budget),
                    "strategy": r["strategy"],
                    "allocated": 0.0,
                    "alloc_pct": 0.0,
                    "covered_orders": 0,
                    "expected_net": 0.0,
                    "expected_roi": np.nan,
                    "rationale": (f"每元净收益 R${r['net_per_brl']:.2f} ≤ 0，"
                                  f"在 (p={r['rescue_rate']}, v=R${r['bad_value']:.2f}) 下不投放"),
                })
        # 预算花不完时也留痕：说明「这个问题自身的盘子」就这么大
        if remain > 1:
            rows.append({
                "budget_level": float(budget),
                "strategy": "unallocated",
                "allocated": round(remain, 2),
                "alloc_pct": round(remain / budget * 100, 2),
                "covered_orders": 0,
                "expected_net": 0.0,
                "expected_roi": np.nan,
                "rationale": ("全部盈利策略已被完整覆盖，剩余预算无有效投放对象 ⇒ "
                              "瓶颈不是钱，是可干预订单池的规模"),
            })
    return rows


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
def main() -> None:
    args = parse_args()
    log = setup_logging("s6_01")
    engine = get_engine()

    params = load_params(engine)
    scale = load_scale(engine)
    log.info("读入参数 %d 个；策略规模 %d 条", len(params), len(scale))

    # ---- 勾稽：策略规模必须满足包含关系 ----
    smap = {r["strategy"]: r for _, r in scale.iterrows()}
    check(set(smap) == set(STRATEGY_NAMES), "三个策略都在规模表里", log)
    check(smap["p1_expedite"]["covered_orders"] < smap["p2_intercept"]["covered_orders"]
          < smap["p3_voucher"]["covered_orders"],
          "覆盖规模满足 P1 < P2 < P3（与 sql/11 自检 5.2 一致）", log)
    check(params["baseline_bad_late"] > params["baseline_bad_ontime"],
          "延迟差评率 > 准时差评率（否则可挽救量会是负数）", log)
    check(all(cost_per_order(s, params) > 0 for s in STRATEGY_NAMES),
          "三条策略的单均成本均为正", log)

    p0 = S6_BASE_RESCUE_RATE
    v0 = S6_BASE_BAD_VALUE
    log.info("主测算口径：挽回率 p=%.2f，差评单位价值 v=R$%.2f", p0, v0)

    # ---- 主测算 ----
    roi_rows: list[dict] = []
    sens_rows: list[dict] = []
    for s in STRATEGY_NAMES:
        r = smap[s]
        roi_rows.append(compute_roi(s, r["covered_orders"], r["covered_customers"],
                                    r["covered_gmv"], params, p0, v0))
        sens_rows.extend(sensitivity(s, r["covered_orders"], r["covered_customers"],
                                     r["covered_gmv"], params))
    roi_df = pd.DataFrame(roi_rows)
    sens_df = pd.DataFrame(sens_rows)

    log.info("ROI 算完：%s", {r["strategy"]: r["roi_b"] for r in roi_rows})

    # ---- 勾稽：内部恒等式 ----
    for r in roi_rows:
        check(abs(r["roi_b"] - r["revenue_total"] / r["total_cost"]) < 1e-9,
              f"{r['strategy']} ROI = 收益/成本", log)
        check(abs(r["net_benefit_b"] - (r["revenue_total"] - r["total_cost"])) < 1e-9,
              f"{r['strategy']} 净收益 = 收益 − 成本", log)
        check(r["rescued_repeat"] > 0 if r["strategy"] in S6_REPEAT_ELIGIBLE
              else r["rescued_repeat"] == 0,
              f"{r['strategy']} 复购收益的适用性与 S6_REPEAT_ELIGIBLE 一致", log)
        # 盈亏平衡点的定义验算：把 p* 代回，净收益应 ≈ 0（相对容差，浮点除法必然有尾差）
        p_star = r["breakeven_p_b"]
        if 0 < p_star <= 1:
            rr = compute_roi(r["strategy"], r["covered_orders"], r["covered_customers"],
                             r["covered_gmv"], params, p_star, v0)
            check(abs(rr["net_benefit_b"]) < 1e-6 * abs(r["total_cost"]),
                  f"{r['strategy']} 盈亏平衡点的定义自洽（代回后净收益≈0）", log)
        else:
            check(p_star > 1.0 or np.isnan(p_star),
                  f"{r['strategy']} p*>1 表示理论上限都回不了本（已如实标注）", log)
    check(not sens_df.duplicated(["strategy", "rescue_rate", "bad_value"]).any(),
          "敏感性表无重复主键", log)
    check(int(sens_df["is_profitable"].sum()) > 0, "敏感性网格里至少有一个盈利点（否则 v 上限太低）", log)

    # ---- 预算分配 ----
    plan_df = pd.DataFrame(budget_plan(roi_df, params))
    log.info("预算分配方案：%d 行", len(plan_df))

    # ---- 回写（写库时才做舍入，DECIMAL 列会自行截断，这里显式 round 便于控制台核对）----
    roi_out = roi_df.copy()
    for c in ("covered_gmv", "cost_per_order", "total_cost", "bad_upper", "revenue_review",
              "rescued_repeat", "revenue_repeat", "revenue_total", "net_benefit_a",
              "net_benefit_b", "roi_a", "roi_b", "breakeven_p_a", "breakeven_p_b"):
        roi_out[c] = roi_out[c].astype(float).round(4)
    roi_out["updated_at"] = pd.Timestamp.now()

    sens_out = sens_df.copy()
    for c in ("total_cost", "revenue", "net_benefit", "roi"):
        sens_out[c] = sens_out[c].astype(float).round(4)

    plan_out = plan_df.copy()
    plan_out["updated_at"] = pd.Timestamp.now()

    if args.dry_run:
        log.info("--dry-run：不回写数据库")
    else:
        write_table(engine, roi_out, "ads_s6_strategy_roi", log=log)
        write_table(engine, sens_out, "ads_s6_sensitivity", log=log)
        write_table(engine, plan_out, "ads_s6_budget_plan", log=log)

    # ---- 控制台汇报 ----
    print("\n" + "=" * 92)
    print(f"S6-01　策略效果评估（反事实仿真，p={p0}，v=R${v0:.2f}）")
    print("=" * 92)

    show = roi_df[["strategy_name", "covered_orders", "cost_per_order", "total_cost",
                   "bad_upper", "revenue_total", "net_benefit_b", "roi_b",
                   "breakeven_p_b", "verdict"]].round({
                       "cost_per_order": 2, "total_cost": 2, "bad_upper": 0,
                       "revenue_total": 0, "net_benefit_b": 0, "roi_b": 3,
                       "breakeven_p_b": 3,
                   })
    print("\n【主测算】")
    print(fmt_table(show))

    print("\n【读法】")
    print(f"  延迟差评率 {params['baseline_bad_late']:.2f}% vs 准时 {params['baseline_bad_ontime']:.2f}%"
          f" ⇒ 每单最多可挽救 {params['baseline_bad_late']-params['baseline_bad_ontime']:.2f}pp 的差评概率")
    print(f"  盈亏平衡挽回率 p* < {p0} 的策略，说明按当前假设就是赚的；")
    print(f"  p* > 1.0 的策略，说明连理论上限都回不了本 —— 应当直接砍掉。")

    print("\n【敏感性摘要：各策略在不同 p 下的 ROI（v=R$40.75）】")
    sub = sens_df[np.isclose(sens_df["bad_value"], 40.75)]
    pivot = sub.pivot(index="strategy", columns="rescue_rate", values="roi").round(2)
    print(pivot.to_string())

    print("\n【盈亏平衡（v 固定 R$40.75）】")
    for _, r in roi_df.iterrows():
        print(f"  {r['strategy_name']}：p* = {r['breakeven_p_b']:.3f}"
              f"  {'✓ 可达' if r['breakeven_p_b'] <= 1 else '✗ 理论不可达'}")

    print("\n【预算分配（按每元净收益排序，效率优先）】")
    print("   expected_roi = 净收益/投入 + 1（总回报倍数，1.0 表示刚好回本）")
    print(fmt_table(plan_df[["budget_level", "strategy", "allocated", "alloc_pct",
                             "covered_orders", "expected_net", "expected_roi"]]))

    unalloc = plan_df[plan_df["strategy"] == "unallocated"]
    if len(unalloc) and (unalloc["alloc_pct"] > 50).any():
        print("\n  ⚠️ 注意：高预算档位下超过一半的钱没处投 ——")
        print("     这不是分配算法的问题，而是「这个问题本身的盘子就这么大」：")
        print(f"     全部盈利策略完整覆盖一轮只需 "
              f"R${roi_df[roi_df['net_benefit_b'] > 0]['total_cost'].sum():,.0f}。")
        print("     若目标是花掉更多预算，必须扩大可干预池（例如把干预点前移到『发货前』），")
        print("     而不是提高单均投入 —— 后者只会稀释 ROI。")

    print("\n⚠️ 声明：本表是 what-if 仿真，不是实验结果。")
    print("   p（挽回率）与 v（差评价值）在 Olist 数据里不存在，必须由真实 A/B 实验测定")
    print("   或由业务方确认。在上生产前，请把 p* 当作「需要验证的假设」而非「已知的事实」。")
    print("\nS6-01 完成。")


if __name__ == "__main__":
    sys.exit(main())
