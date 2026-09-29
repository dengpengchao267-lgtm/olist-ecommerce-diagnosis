"""S5-02　复购专题：生存分析 + 首购体验的准因果效应

【这个脚本回答什么】
    复购率只有约 3%，传统"留存曲线 + CLV"模板根本撑不起结论。
    所以这里换三个能站住的问题：
      1) 复购率在不同首购体验/品类/州/月份之间差多少？（描述层，带 Wilson CI + FDR）
      2) 首购到复购要多久？按时长看（不是二元的"复购/未复购"）是什么形状？（KM 生存分析）
      3) 首单延迟**导致**复购率下降多少？（倾向得分匹配，把相关性往因果推一步）

【为什么要用 KM 生存分析，不能直接算"复购率"】
    每个客户被观察的时长不一样：2017-01 首购的客户被跟了 20 个月，
    2018-08 首购的客户只被跟了 1 个月。直接算"复购率"等于把"观察期短"当成了"不复购"，
    这是典型的**右删失**。KM 让每个客户在"自己被观察到的最后一天"才退出风险集，
    所以不同首购月的客户可以放进同一张图比较。
    ⚠️ 已知局限：KM 假设删失与事件时间独立。本数据里删失来自"入组时间不同"（行政删失），
       这个假设基本成立；但仍要在报告里声明。

【为什么要用 PSM，不能直接比"延迟组 vs 准时组"的复购率】
    延迟不是随机分配的：远距离、大额、多件、特定州的订单更可能延迟，
    而这些特征本身也会影响复购。直接相减会把"距离远"的效应算到"延迟"头上。
    PSM 先用这些特征算一个"延迟倾向"，再只在倾向相近的样本之间比 —— 让两组在
    协变量上可比，剩下的差异才能更干净地归给延迟。
    ⚠️ PSM 的强假设是"没有未观测混杂"。本脚本做了匹配后均衡性检验（SMD），
       但那只验证了**已观测**协变量，这一点必须在报告里写死。

【一个关键的变量选择：不要把首单评分放进协变量】
    首单评分是"延迟 → 不复购"这条链上的**中介变量**（延迟会先拉低评分，再影响复购）。
    控制中介变量会挡住一部分真实效应，估计出来的就不是总效应了。
    所以协变量只用"下单时就已知"的变量（金额、件数、距离、州、月份、分期数）。

【产出】ads_s5_experience_repeat / ads_s5_survival_curve / ads_s5_experience_effect
【用法】python s5_02_repeat_survival.py [--dry-run]
"""
from __future__ import annotations

import argparse
import sys

import numpy as np
import pandas as pd
from scipy.stats import chi2 as chi2_dist
from scipy.stats import norm
from sklearn.linear_model import LogisticRegression
from sklearn.neighbors import NearestNeighbors

from common import (
    bh_fdr,
    check,
    fmt_table,
    get_engine,
    read_table,
    setup_logging,
    two_prop_z,
    wilson_ci,
    write_table,
)
from config import (
    ALPHA,
    BOOTSTRAP_B_S5,
    RANDOM_SEED,
    S5_KM_MAX_DAYS,
    S5_MIN_CUSTOMERS_DIM,
    S5_PSM_CALIPER,
    S5_PSM_MIN_TREAT,
    S5_REPEAT_HORIZON_DAYS,
)

DIM_CN = {
    "first_is_late": "首单履约",
    "first_score": "首单评分",
    "first_amount_q": "首单金额四分位",
    "first_dist_km": "首单运距(km)",
    "first_item_cnt": "首单件数",
    "first_state": "首单收货州",
    "first_cohort_month": "首购月份",
}

DATETIME_NOW = pd.Timestamp.now().normalize()


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="S5-02 复购专题：生存分析 + PSM")
    p.add_argument("--dry-run", action="store_true", help="只打印，不回写数据库")
    return p.parse_args()


# ===========================================================================
# 一、生存分析（KM + log-rank）——自己实现，理由见文件头
# ===========================================================================
def km_fit(obs: np.ndarray, ev: np.ndarray, alpha: float = ALPHA):
    """Kaplan-Meier 估计。

    返回 DataFrame：t_days / at_risk / events / surv / ci_low / ci_high。
    CI 用 Greenwood 方差 + log-log 变换：
        Var(log(-log S)) = Σ d_i / (n_i (n_i - d_i)) / (log S)^2
        CI = S ** exp(±z·sqrt(Var))
    为什么不用普通的 S ± z·SE：普通区间在 S 接近 0 或 1 时会越界（出负值或 >1），
    log-log 变换把区间约束在 (0,1) 内，覆盖率也更好。
    """
    obs = np.asarray(obs, dtype=float)
    ev = np.asarray(ev, dtype=int)
    order = np.argsort(obs, kind="mergesort")
    obs, ev = obs[order], ev[order]
    n_total = len(obs)

    uniq_t = np.unique(obs[ev == 1])
    if len(uniq_t) == 0:
        return pd.DataFrame(
            columns=["t_days", "at_risk", "events", "surv", "ci_low", "ci_high"]
        )

    # 用 searchsorted 一次算出风险集人数，避免逐时点做 bool 扫描（O(Σ n) 太慢）
    lo = np.searchsorted(obs, uniq_t, side="left")
    hi = np.searchsorted(obs, uniq_t, side="right")
    at_risk = n_total - lo
    d = np.array([int(ev[i:j].sum()) for i, j in zip(lo, hi)], dtype=float)

    ok = (at_risk > 0) & (d > 0)
    uniq_t, at_risk, d = uniq_t[ok], at_risk[ok], d[ok]
    if len(uniq_t) == 0:
        return pd.DataFrame(
            columns=["t_days", "at_risk", "events", "surv", "ci_low", "ci_high"]
        )

    surv = np.cumprod(1.0 - d / at_risk)

    denom = at_risk - d
    green_term = np.where(denom > 0, d / np.where(denom > 0, at_risk * denom, 1.0), 0.0)
    green = np.cumsum(green_term)

    z = norm.ppf(1 - alpha / 2)
    with np.errstate(divide="ignore", invalid="ignore"):
        log_s = np.log(surv)
        se = np.sqrt(green) / np.abs(log_s)          # Var(log(-log S)) 的平方根
        ci_low = surv ** np.exp(z * se)              # S<1 时指数越大值越小 → 下界
        ci_high = surv ** np.exp(-z * se)

    ci_low = np.clip(np.nan_to_num(ci_low, nan=0.0), 0.0, 1.0)
    ci_high = np.clip(np.nan_to_num(ci_high, nan=1.0), 0.0, 1.0)

    return pd.DataFrame({
        "t_days": uniq_t.astype(int),
        "at_risk": at_risk.astype(int),
        "events": d.astype(int),
        "surv": np.round(surv, 6),
        "ci_low": np.round(ci_low, 6),
        "ci_high": np.round(ci_high, 6),
    })


def logrank_2group(obs: np.ndarray, ev: np.ndarray, grp: np.ndarray) -> tuple[float, float]:
    """两组 log-rank 检验（Mantel-Cox）。返回 (chi2, p)。

    做法：在每个事件时点比较"处理组实际事件数"与"按风险集比例应发生的事件数"，
    把差值累积起来做卡方检验。不假设比例风险的具体形状，比 Cox 更宽松。
    """
    obs = np.asarray(obs, dtype=float)
    ev = np.asarray(ev, dtype=int)
    g0 = grp == 0
    g1 = grp == 1
    o0, e0, o1, e1 = obs[g0], ev[g0], obs[g1], ev[g1]

    s0 = np.sort(o0)
    s1 = np.sort(o1)
    e0s = e0[np.argsort(o0, kind="mergesort")]
    e1s = e1[np.argsort(o1, kind="mergesort")]

    all_times = np.unique(np.concatenate([o0[e0 == 1], o1[e1 == 1]]))
    O1 = E1 = V = 0.0
    for t in all_times:
        n1 = len(s1) - np.searchsorted(s1, t, side="left")
        n0 = len(s0) - np.searchsorted(s0, t, side="left")
        n = n0 + n1
        if n <= 1:
            continue
        d1 = int(e1s[np.searchsorted(s1, t, "left"):np.searchsorted(s1, t, "right")].sum())
        d0 = int(e0s[np.searchsorted(s0, t, "left"):np.searchsorted(s0, t, "right")].sum())
        dd = d0 + d1
        if dd == 0:
            continue
        E1 += dd * n1 / n
        O1 += d1
        V += n1 * n0 * dd * (n - dd) / (n * n * (n - 1))
    if V <= 0:
        return (np.nan, np.nan)
    chi2 = (O1 - E1) ** 2 / V
    return (float(chi2), float(1 - chi2_dist.cdf(chi2, 1)))


def km_interval(df: pd.DataFrame, max_days: int) -> tuple[np.ndarray, np.ndarray]:
    """把客户级数据转成 KM 需要的 (观察时长, 事件标记)，观察时长封顶到 max_days。"""
    d2r = df["days_to_repeat"].to_numpy(dtype=float)
    ten = df["tenure_days"].to_numpy(dtype=float)
    is_ev = df["event"].to_numpy(dtype=int)

    rep = np.nan_to_num(d2r, nan=np.inf)
    ev = ((is_ev == 1) & (rep <= max_days)).astype(int)
    obs = np.where(is_ev == 1, np.minimum(rep, max_days), np.minimum(ten, max_days))
    obs = np.maximum(obs, 1.0)  # 首购当日即快照日的极端样本，至少给 1 天，避免 t=0
    return obs, ev


def median_surv_time(curve: pd.DataFrame) -> float | None:
    """中位复购时间：生存率首次跌到 0.5 及以下的那一天。未达到则 NULL。"""
    hit = curve[curve["surv"] <= 0.5]
    return float(hit["t_days"].iloc[0]) if len(hit) else None


# ===========================================================================
# 二、倾向得分匹配
# ===========================================================================
def smd(x_t: np.ndarray, x_c: np.ndarray) -> float:
    """标准化均值差（Standardized Mean Difference）。

    匹配后一般要求 |SMD| < 0.1 才算"均衡"。用合并标准差做分母，
    这样不同量纲的协变量可以直接比大小。
    """
    if len(x_t) == 0 or len(x_c) == 0:
        return np.nan
    denom = np.sqrt((x_t.var(ddof=1) + x_c.var(ddof=1)) / 2)
    if denom == 0:
        return 0.0
    return float((x_t.mean() - x_c.mean()) / denom)


def build_covariates(df: pd.DataFrame, state_cols: list[str]) -> tuple[np.ndarray, list[str]]:
    """构造 PSM 协变量矩阵（只用下单时已知的变量，不含评分这个中介变量）。"""
    parts: list[np.ndarray] = []
    names: list[str] = []

    def add(name: str, values: np.ndarray) -> None:
        parts.append(np.asarray(values, dtype=float))
        names.append(name)

    add("log_amount", np.log1p(df["first_amount"].fillna(0).to_numpy(dtype=float)))
    add("item_cnt", df["first_item_cnt"].fillna(1).to_numpy(dtype=float))
    add("seller_cnt", df["first_seller_cnt"].fillna(1).to_numpy(dtype=float))
    add("log_dist", np.log1p(df["first_dist_km"].fillna(0).to_numpy(dtype=float)))
    add("dist_missing", df["first_dist_km"].isna().to_numpy(dtype=float))
    add("installments", df["first_installments"].fillna(1).to_numpy(dtype=float))
    add("pay_type_cnt", df["first_pay_type_cnt"].fillna(1).to_numpy(dtype=float))
    add("freight_ratio", df["first_freight_ratio"].fillna(0).to_numpy(dtype=float))

    # 首购月份转成连续序号，控制时间趋势（增长期与物流改善期重叠，必须控住）
    cm = pd.to_datetime(df["first_cohort_month"])
    add("cohort_index", ((cm.dt.year - 2017) * 12 + cm.dt.month).to_numpy(dtype=float))

    for c in state_cols:
        add(f"state_{c}", (df["first_state"] == c).to_numpy(dtype=float))

    X = np.column_stack(parts)
    # 标准化：LogisticRegression 收敛更快，倾向得分的量纲也更干净
    X = (X - X.mean(axis=0)) / np.where(X.std(axis=0) == 0, 1.0, X.std(axis=0))
    return X, names


def psm_1to1(
    X: np.ndarray, treat: np.ndarray, y: np.ndarray, seed: int
) -> dict:
    """倾向得分 + 1:1 最近邻匹配（卡尺、无放回），返回 ATT 与诊断量。"""
    rng = np.random.default_rng(seed)

    ps_model = LogisticRegression(max_iter=2000, solver="lbfgs")
    ps_model.fit(X, treat)
    ps = ps_model.predict_proba(X)[:, 1]
    logit = np.log(np.clip(ps, 1e-9, 1 - 1e-9) / (1 - np.clip(ps, 1e-9, 1 - 1e-9)))

    ti = np.flatnonzero(treat == 1)
    ci_ = np.flatnonzero(treat == 0)
    tree = NearestNeighbors(n_neighbors=min(64, len(ci_))).fit(logit[ci_][:, None])

    # 随机化处理样本顺序：否则"先来的处理样本先挑邻居"会引入顺序偏倚
    avail = np.ones(len(ci_), dtype=bool)
    pairs: list[tuple[int, int]] = []
    for i in rng.permutation(ti):
        # ⚠️ query 必须是 2D `(1, 1)`，否则 sklearn 1.0+ 会报
        #   "Expected 2D array, got 1D array instead: array=[-2.0300234]"。
        #   logit 本身就是 1D（N,），logit[i:i+1] 是 shape (1,)，必须显式升维。
        query = logit[i : i + 1, None]
        dist, idx = tree.kneighbors(query, n_neighbors=min(64, len(ci_)))
        for dd, jj in zip(dist[0], idx[0]):
            if not avail[jj]:
                continue
            if dd <= S5_PSM_CALIPER:
                pairs.append((i, ci_[jj]))
                avail[jj] = False
            break  # 最近的那个可用邻居超卡尺 → 该处理样本放弃匹配

    if not pairs:
        return {"n_pairs": 0}

    mt = np.array([p[0] for p in pairs])
    mc = np.array([p[1] for p in pairs])

    def att(idx_t: np.ndarray, idx_c: np.ndarray) -> float:
        return float(y[idx_t].mean() - y[idx_c].mean())

    point = att(mt, mc)

    # Bootstrap：按"匹配对"整体重抽，保住配对结构（拆开重抽会低估方差）
    reps = np.empty(BOOTSTRAP_B_S5)
    for b in range(BOOTSTRAP_B_S5):
        pick = rng.integers(0, len(mt), len(mt))
        reps[b] = att(mt[pick], mc[pick])
    lo = float(np.percentile(reps, 100 * ALPHA / 2))
    hi = float(np.percentile(reps, 100 * (1 - ALPHA / 2)))

    # 双侧 p：Bootstrap 分布的标准误 + 正态近似
    se = float(reps.std(ddof=1))
    p_val = float(2 * (1 - norm.cdf(abs(point / se)))) if se > 0 else np.nan

    return {
        "n_pairs": len(pairs),
        "point": point,
        "ci_low": lo,
        "ci_high": hi,
        "p_value": p_val,
        "treat_value": float(y[mt].mean()),
        "control_value": float(y[mc].mean()),
        "n_treat": len(ti),
        "n_control": len(ci_),
        "n_unmatched": len(ti) - len(pairs),
        "ps": ps,
        "matched_treat": mt,
        "matched_control": mc,
        "logit": logit,
    }


# ===========================================================================
# 主流程
# ===========================================================================
def main() -> None:
    args = parse_args()
    log = setup_logging("s5_02")
    engine = get_engine()

    df = read_table(engine, "ads_s5_survival_input")
    base = read_table(engine, "ads_s5_experience_repeat_base")
    log.info("读取生存分析输入：%d 行；体验交叉表：%d 行", len(df), len(base))

    check(len(df) == df["customer_unique_id"].nunique(), "客户唯一（无重复）", log)
    check(bool(((df["event"] == 0) | (df["days_to_repeat"].notna())).all()),
          "event=1 的客户都有复购间隔天数", log)
    check(bool((df["tenure_days"] >= 0).all()), "观察期长度非负", log)

    # -----------------------------------------------------------------
    # 第一部分：描述层 —— 各维度复购率 + Wilson CI + FDR
    # -----------------------------------------------------------------
    total_n = int(base[base["dim_type"] == "first_is_late"]["customers"].sum())
    total_k = int(base[base["dim_type"] == "first_is_late"]["repeat_customers"].sum())
    p_overall = total_k / total_n if total_n else np.nan
    log.info("总体复购率 = %d / %d = %.4f", total_k, total_n, p_overall)

    # 跨表勾稽：交叉表里的复购人数必须等于生存表里 event=1 的人数
    check(total_k == int(df["event"].sum()),
          f"复购人数一致：交叉表 {total_k} = 生存表 {int(df['event'].sum())}", log)

    rows: list[dict] = []
    for dim_type, sub in base.groupby("dim_type", sort=False):
        sub = sub.reset_index(drop=True)
        tested = (sub["customers"] >= S5_MIN_CUSTOMERS_DIM).to_numpy()

        # 检验：每个取值 vs 总体复购率（两比例 z 检验），再做 BH-FDR
        z_vals = np.full(len(sub), np.nan)
        p_raw = np.full(len(sub), np.nan)
        q_fdr = np.full(len(sub), np.nan)
        for i, r in sub.iterrows():
            if tested[i]:
                z_vals[i] = two_prop_z(
                    int(r["repeat_customers"]), int(r["customers"]), p_overall
                )
                p_raw[i] = 2 * (1 - norm.cdf(abs(z_vals[i])))
        if tested.any():
            q_fdr[tested] = bh_fdr(p_raw[tested].astype(float))

        for i, r in sub.iterrows():
            n = int(r["customers"])
            k = int(r["repeat_customers"])
            lo, hi = wilson_ci(k, n)
            rows.append({
                "dim_type": dim_type,
                "dim_value": str(r["dim_value"]),
                "customers": n,
                "repeat_customers": k,
                "repeat_rate": round(k / n, 4) if n else np.nan,
                "rate_low": round(lo, 4) if not np.isnan(lo) else np.nan,
                "rate_high": round(hi, 4) if not np.isnan(hi) else np.nan,
                "diff_vs_overall_pp": round((k / n - p_overall) * 100, 2) if n else np.nan,
                "p_value_raw": float(p_raw[i]) if not np.isnan(p_raw[i]) else np.nan,
                "p_value_fdr": float(q_fdr[i]) if not np.isnan(q_fdr[i]) else np.nan,
                # 未达样本量门槛的取值只报点估计，检验留空（NULL ≠ 不显著）
                "is_significant": (np.nan if not tested[i]
                                   else float(q_fdr[i] < ALPHA)),
                "updated_at": DATETIME_NOW,
            })
    exp_df = pd.DataFrame(rows)

    # -----------------------------------------------------------------
    # 第二部分：KM 生存分析
    # -----------------------------------------------------------------
    obs_all, ev_all = km_interval(df, S5_KM_MAX_DAYS)
    log.info("KM 输入：%d 人，其中事件（%d 天内复购）%d 人，删失 %d 人",
             len(obs_all), S5_KM_MAX_DAYS, int(ev_all.sum()), int((1 - ev_all).sum()))

    groups: dict[str, np.ndarray] = {"all": np.ones(len(df), dtype=bool)}
    if df["first_is_late"].notna().any():
        groups["first_late"] = (df["first_is_late"] == 1).to_numpy()
        groups["first_ontime"] = (df["first_is_late"] == 0).to_numpy()
    if df["first_review_score"].notna().any():
        groups["first_bad_review"] = (df["first_review_score"] <= 2).to_numpy()
        groups["first_good_review"] = (df["first_review_score"] >= 4).to_numpy()

    # 每一组 vs 其自然对照组的 log-rank p 值
    counterpart = {
        "all": None,
        "first_late": "first_ontime",
        "first_ontime": "first_late",
        "first_bad_review": "first_good_review",
        "first_good_review": "first_bad_review",
    }

    curve_rows: list[dict] = []
    summary: list[dict] = []
    for gname, mask in groups.items():
        if mask.sum() < 50:
            log.warning("分组 %s 样本仅 %d，跳过 KM", gname, int(mask.sum()))
            continue
        obs_g, ev_g = obs_all[mask], ev_all[mask]
        curve = km_fit(obs_g, ev_g)

        lr_p = np.nan
        other = counterpart.get(gname)
        if other and other in groups:
            m2 = groups[other]
            obs_pair = np.concatenate([obs_g, obs_all[m2]])
            ev_pair = np.concatenate([ev_g, ev_all[m2]])
            grp_pair = np.concatenate([np.zeros(mask.sum(), dtype=int),
                                       np.ones(int(m2.sum()), dtype=int)])
            if grp_pair.sum() > 0 and (grp_pair == 0).sum() > 0:
                _, lr_p = logrank_2group(obs_pair, ev_pair, grp_pair)

        med = median_surv_time(curve)
        for _, r in curve.iterrows():
            curve_rows.append({
                "group_code": gname,
                "t_days": int(r["t_days"]),
                "at_risk": int(r["at_risk"]),
                "events": int(r["events"]),
                "surv": float(r["surv"]),
                "cum_ret": round(1 - float(r["surv"]), 6),
                "ci_low": float(r["ci_low"]),
                "ci_high": float(r["ci_high"]),
                "median_days": med,
                "n_total": int(mask.sum()),
                "n_event": int(ev_g.sum()),
                "logrank_p": float(lr_p) if not np.isnan(lr_p) else None,
                "updated_at": DATETIME_NOW,
            })
        summary.append({
            "group": gname, "n": int(mask.sum()), "events": int(ev_g.sum()),
            "event_rate": ev_g.mean(), "median_days": med, "logrank_p": lr_p,
        })

    curve_df = pd.DataFrame(curve_rows)
    km_sum = pd.DataFrame(summary)

    # -----------------------------------------------------------------
    # 第三部分：PSM —— 首单延迟对复购的效应
    # -----------------------------------------------------------------
    # 州哑变量只取样本量前 10 的州，其余并入基准（避免高维稀疏把倾向得分撑爆）
    top_states = df["first_state"].value_counts().head(10).index.tolist()

    effect_rows: list[dict] = []
    smd_report: list[dict] = []

    for horizon, olabel in ((S5_REPEAT_HORIZON_DAYS, f"repeat_{S5_REPEAT_HORIZON_DAYS}"),
                            (365, "repeat_365")):
        sub = df[df["tenure_days"] >= horizon].copy()
        sub = sub[sub["first_is_late"].notna()].reset_index(drop=True)
        if len(sub) == 0:
            log.warning("口径 %s：样本为空，跳过", olabel)
            continue

        sub["y"] = ((sub["event"] == 1) & (sub["days_to_repeat"] <= horizon)).astype(int)
        treat = sub["first_is_late"].to_numpy(dtype=int)
        y = sub["y"].to_numpy(dtype=float)
        n_t = int(treat.sum())
        n_c = int((1 - treat).sum())
        log.info("%s 口径：样本 %d（观察期>=%d 天），处理组(延迟) %d / 对照组(准时) %d",
                 olabel, len(sub), horizon, n_t, n_c)

        # 基线：不做匹配，直接相减（这一行存在的意义就是展示"不控制混杂会偏多少"）
        naive = float(y[treat == 1].mean() - y[treat == 0].mean())
        se_naive = float(np.sqrt(
            y[treat == 1].var(ddof=1) / max(n_t, 1) + y[treat == 0].var(ddof=1) / max(n_c, 1)
        ))

        effect_rows.append({
            "outcome": olabel, "method": "naive",
            "n_treat": n_t, "n_control": n_c,
            "treat_value": round(float(y[treat == 1].mean()), 4),
            "control_value": round(float(y[treat == 0].mean()), 4),
            "diff": round(naive, 4), "diff_pp": round(naive * 100, 2),
            "ci_low": round(naive - 1.96 * se_naive, 4),
            "ci_high": round(naive + 1.96 * se_naive, 4),
            "p_value": float(2 * (1 - norm.cdf(abs(naive / se_naive)))) if se_naive > 0 else None,
            "is_significant": int(abs(naive / se_naive) > 1.96) if se_naive > 0 else None,
            "smd_max_after": None, "n_unmatched": None,
            "note": "未匹配的原始差异（含距离/金额/州等混杂）",
            "updated_at": DATETIME_NOW,
        })

        if n_t < S5_PSM_MIN_TREAT or n_c < S5_PSM_MIN_TREAT:
            log.warning("%s：两组样本不足（处理 %d / 对照 %d），跳过匹配", olabel, n_t, n_c)
            continue

        X, cov_names = build_covariates(sub, top_states)
        res = psm_1to1(X, treat, y, RANDOM_SEED)
        if res.get("n_pairs", 0) == 0:
            log.warning("%s：没有匹配上的对，跳过", olabel)
            continue

        mt, mc = res["matched_treat"], res["matched_control"]
        smds_after = [smd(X[mt, j], X[mc, j]) for j in range(X.shape[1])]
        smds_before = [smd(X[treat == 1, j], X[treat == 0, j]) for j in range(X.shape[1])]
        smd_max_after = float(np.nanmax(np.abs(smds_after)))
        smd_max_before = float(np.nanmax(np.abs(smds_before)))

        log.info("%s：匹配 %d 对；最大 |SMD| 从 %.3f 降到 %.3f",
                 olabel, res["n_pairs"], smd_max_before, smd_max_after)
        for j, nm in enumerate(cov_names):
            smd_report.append({
                "outcome": olabel, "covariate": nm,
                "smd_before": round(float(smds_before[j]), 4),
                "smd_after": round(float(smds_after[j]), 4),
            })

        ci_ok = (res["ci_low"] > 0) or (res["ci_high"] < 0)
        effect_rows.append({
            "outcome": olabel, "method": "psm_1to1",
            "n_treat": res["n_pairs"], "n_control": res["n_pairs"],
            "treat_value": round(res["treat_value"], 4),
            "control_value": round(res["control_value"], 4),
            "diff": round(res["point"], 4), "diff_pp": round(res["point"] * 100, 2),
            "ci_low": round(res["ci_low"], 4), "ci_high": round(res["ci_high"], 4),
            "p_value": res["p_value"],
            "is_significant": int(ci_ok),
            "smd_max_after": round(smd_max_after, 4),
            "n_unmatched": res["n_unmatched"],
            "note": (f"1:1 最近邻匹配，卡尺 {S5_PSM_CALIPER}（logit 尺度），"
                     f"无放回；匹配前最大 |SMD| {smd_max_before:.3f}"),
            "updated_at": DATETIME_NOW,
        })

    effect_df = pd.DataFrame(effect_rows)

    # -----------------------------------------------------------------
    # 勾稽
    # -----------------------------------------------------------------
    check(len(exp_df) == len(base), "体验交叉表输出行数 = 输入行数", log)
    check(abs(float(exp_df[exp_df["dim_type"] == "first_is_late"]["customers"].sum())
              - total_n) < 1, "首单履约维度人数合计 = 总人数", log)
    check(bool(exp_df[exp_df["is_significant"] == 1].empty
               or (exp_df.loc[exp_df["is_significant"] == 1, "p_value_fdr"] < ALPHA).all()),
          "标为显著的维度 FDR q 值均 < 0.05", log)
    if not curve_df.empty:
        check(bool((curve_df["surv"].between(0, 1)).all()), "生存率落在 [0,1]", log)
        check(bool((curve_df["cum_ret"].between(0, 1)).all()), "累计复购率落在 [0,1]", log)
    if not effect_df.empty:
        psm_rows = effect_df[effect_df["method"] == "psm_1to1"]
        if not psm_rows.empty:
            check(bool((psm_rows["smd_max_after"] <= 0.1).all()),
                  f"匹配后最大 |SMD| <= 0.1（实际 "
                  f"{psm_rows['smd_max_after'].max():.4f}），否则说明协变量没配平", log)

    # -----------------------------------------------------------------
    # 回写
    # -----------------------------------------------------------------
    if args.dry_run:
        log.info("--dry-run：不回写数据库")
    else:
        log.info("写入 ads_s5_experience_repeat：%d 行",
                 write_table(engine, exp_df, "ads_s5_experience_repeat", log=log))
        log.info("写入 ads_s5_survival_curve：%d 行",
                 write_table(engine, curve_df, "ads_s5_survival_curve", log=log))
        log.info("写入 ads_s5_experience_effect：%d 行",
                 write_table(engine, effect_df, "ads_s5_experience_effect", log=log))

    # -----------------------------------------------------------------
    # 控制台汇报
    # -----------------------------------------------------------------
    print("\n" + "=" * 82)
    print("S5-02　复购专题（口径说明：复购 = 窗口内出现第二单；窗口 = 2017-01 起）")
    print("=" * 82)

    print(f"\n总体复购率：{total_k} / {total_n} = {p_overall:.2%}")

    print(f"\n【一】各维度复购率（仅列 n≥{S5_MIN_CUSTOMERS_DIM} 的取值，按复购率降序）")
    for dim_type in DIM_CN:
        sub = exp_df[(exp_df["dim_type"] == dim_type)
                     & (exp_df["customers"] >= S5_MIN_CUSTOMERS_DIM)]
        if sub.empty:
            continue
        sub = sub.sort_values("repeat_rate", ascending=False)
        show = sub.drop(columns=["updated_at"])
        print(f"\n[{DIM_CN[dim_type]}]  {len(sub)} 个取值")
        print(fmt_table(show, floatfmt=",.4f"))

    print("\n【二】KM 生存分析（首购后 N 天内复购的比例）")
    print(fmt_table(km_sum.assign(
        event_rate=lambda d: (d["event_rate"] * 100).round(2),
        logrank_p=lambda d: d["logrank_p"].round(4),
    ), floatfmt=",.4f"))
    print(f"\n提醒：'median_days' 为空表示该组的复购率始终没到 50%（不是数据缺失）。")

    print("\n【三】首单延迟对复购的效应")
    if effect_df.empty:
        print("  （未产出）")
    else:
        print(fmt_table(effect_df.drop(columns=["updated_at", "note"]), floatfmt=",.4f"))
        print("\n  匹配后各协变量均衡性（|SMD|<0.1 视为均衡）：")
        print(fmt_table(pd.DataFrame(smd_report), floatfmt=",.4f"))

    print("\n" + "-" * 82)
    print("读法提示：")
    print("  1. naive 与 psm_1to1 的差距 = 混杂造成的偏倚大小。两者接近 → 结论稳。")
    print("  2. 若 PSM 后的 CI 跨 0，只能说'未发现延迟降低复购的证据'，")
    print("     不能写'延迟对复购没有影响'——功效不足与效应为零是两回事。")
    print("  3. KM 的分组差异是**描述性**的；因果解释一律以 PSM 那一节为准。")
    print("\nS5-02 完成。")


if __name__ == "__main__":
    sys.exit(main())
