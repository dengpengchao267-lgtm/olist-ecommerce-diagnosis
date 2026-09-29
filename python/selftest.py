"""S2/S5 方法自检：不连数据库，只验证纯函数逻辑与勾稽恒等式。

为什么要有这个文件：
    统计方法的错误不会报错，只会静默给出一个看起来正常的数。
    所以方法必须先在没有数据库的情况下验证一遍——LMDI 的恒等式、
    Bootstrap 的逐轮勾稽、MK 检验的方向、断点检测的误报率、
    KM 生存率与 log-rank 的手算对照。
    跑通它，才有资格说"我的分解结果是对的"。

用法：
    python selftest.py
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import numpy as np
import pandas as pd

import s2_03_mix_effect as s3
import s2_04_aov_mix as s4
import s5_01_rfm_cluster as s5c
import s5_02_repeat_survival as s5
import s6_01_strategy_eval as s6
from common import (
    bh_fdr,
    binary_segmentation,
    bootstrap_decomposition,
    lmdi_additive,
    log_ols_slope,
    mann_kendall,
    mann_kendall_min_p,
    wilson_ci,
)

fails: list[str] = []


def ck(name: str, cond, extra="") -> None:
    ok = bool(cond)
    print(("PASS  " if ok else "FAIL  ") + name + ("   " + str(extra) if extra != "" else ""))
    if not ok:
        fails.append(name)


# ---------- 1. LMDI 恒等式：分解必须无残差 -------------------------------
rng = np.random.default_rng(0)
worst = 0.0
for _ in range(2000):
    x0 = rng.uniform(0.5, 500, 3)
    x1 = x0 * rng.uniform(0.5, 2.0, 3)
    v0, v1 = x0.prod(), x1.prod()
    worst = max(worst, abs(lmdi_additive(v0, v1, x0, x1).sum() - (v1 - v0)) / max(1.0, abs(v1 - v0)))
ck("LMDI 三项之和 ≡ ΔGMV（相对误差 < 1e-12）", worst < 1e-12, f"max_rel={worst:.3e}")

c = lmdi_additive(100.0, 110.0, (10.0, 1.0, 10.0), (11.0, 1.0, 10.0))
ck("只有因子1 变化时，贡献全部落在因子1",
   abs(c[0] - 10.0) < 1e-9 and abs(c[1]) < 1e-9 and abs(c[2]) < 1e-9,
   [round(float(v), 6) for v in c])

c = lmdi_additive(50 * 100.0, 60 * 110.0, (50, 1.0, 100.0), (60, 1.0, 110.0))
ck("LMDI 按对数变化比例分摊交叉项（不是 ΔQ×P0 那种朴素分解）",
   abs(c[0] - 1600.0 * math.log(60 / 50) / (math.log(60 / 50) + math.log(110 / 100))) < 1e-6,
   [round(float(v), 4) for v in c])

# ---------- 2. Mann-Kendall：方向正确 + 抗异常值 + 功效边界 -------------
inc = mann_kendall(np.arange(12) + rng.normal(0, 0.1, 12))
ck("单调上升 → increasing", inc["trend"] == "increasing" and inc["p_value"] < 0.05, f"p={inc['p_value']:.4f}")
ck("单调下降 → decreasing", mann_kendall(np.arange(12)[::-1].astype(float))["trend"] == "decreasing")
ck("纯噪声 → no trend", mann_kendall(rng.normal(100, 5, 12))["trend"] == "no trend")

# 功效边界：n=4 时完全单调的 MK 最小 p 值仍是 0.0894 > 0.05，
# 也就是说 4 个观测点的 MK 检验【永远不可能显著】。
# 此时正确结论是"样本不足、无法判定"，不是"无趋势"——两者分量完全不同。
ck("最小可达 p：n=4 是 0.0894（>0.05，不可能显著）",
   abs(mann_kendall_min_p(4) - 0.0894) < 0.001, f"{mann_kendall_min_p(4):.4f}")
ck("最小可达 p：n=5 是 0.0275（<0.05，可以判定）",
   abs(mann_kendall_min_p(5) - 0.0275) < 0.001, f"{mann_kendall_min_p(5):.4f}")

n4 = mann_kendall(np.array([100.0, 120.0, 150.0, 190.0]))
ck("n=4 完全单调：判为『样本不足』而不是『no trend』",
   n4["trend"] == "样本不足" and n4["can_detect"] is False and n4["n"] == 4,
   f"trend={n4['trend']}, tau={n4['tau']}, p={n4['p_value']:.4f}, min_p={n4['min_p']:.4f}")

n5 = mann_kendall(np.array([100.0, 120.0, 150.0, 190.0, 240.0]))
ck("n=5 完全单调：能判定为 increasing",
   n5["trend"] == "increasing" and n5["can_detect"] is True, f"p={n5['p_value']:.4f}")

n6 = mann_kendall(np.array([100.0, 120.0, 150.0, 190.0, 240.0, 300.0]))
ck("n=6 单调上升 → increasing", n6["trend"] == "increasing" and n6["n"] == 6, f"p={n6['p_value']:.4f}")

ck("n=3 判『样本过少』", mann_kendall(np.array([1.0, 2.0, 3.0]))["trend"] == "样本过少")
ck("返回值带 n / min_p / can_detect（便于诊断）",
   all({"n", "min_p", "can_detect"} <= set(mann_kendall(np.arange(k, dtype=float)))
       for k in (3, 4, 6, 12)))

spiky = np.array([10, 11, 12, 13, 900, 15, 16, 17, 18, 19], dtype=float)
ck("插入巨大尖峰后趋势结论不变（这是选 MK 而不选 OLS 的原因）",
   mann_kendall(spiky)["trend"] == "increasing")

# ---------- 3. 断点检测：能检出，且不误报 -------------------------------
ck("均值突变处被检出", binary_segmentation(np.log(np.concatenate([np.full(10, 100.0), np.full(10, 50.0)])),
                                            min_size=3, max_breaks=4) == [10])
ck("常数序列不误报断点（最怕无中生有）", binary_segmentation(np.log(np.full(20, 100.0))) == [])
slope = log_ols_slope(np.array([100 * (1.1 ** i) for i in range(12)]))
ck("对数斜率 ≈ 月增率 10%", abs(np.exp(slope) - 1.1) < 1e-6, f"{np.exp(slope) - 1:.6f}")


# ---------- 4. Bootstrap：逐轮都要满足勾稽 -------------------------------
def synth_month(m, n_days, buyers_per_day, gmv_per_day, code_offset):
    rows = []
    for d in range(n_days):
        for k in range(buyers_per_day):
            rows.append({
                "stat_month": m,
                "d": pd.Timestamp("2018-01-01") + pd.Timedelta(days=d),
                "buyer_code": code_offset + d * buyers_per_day + k,
                "delivered_cnt": 1,
                "gmv": gmv_per_day,
            })
    return pd.DataFrame(rows)


m0, m1 = pd.Timestamp("2018-01-01"), pd.Timestamp("2018-02-01")
daily = pd.concat([synth_month(m0, 10, 5, 100.0, 0), synth_month(m1, 10, 6, 110.0, 1000)], ignore_index=True)

boot, boot_delta = bootstrap_decomposition(daily, m0, m1, b=50, seed=1)
resid = np.nanmax(np.abs(np.nansum(boot, axis=1) - boot_delta))
ck("Bootstrap 每一轮内部 三项之和 ≡ 该轮 ΔGMV", resid < 1e-6, f"max_resid={resid:.3e}")
ck("去重客户数没有被按天重复计数",
   abs(boot_delta.mean() - (60 * 110.0 - 50 * 100.0)) < 1e-6,
   f"mean_delta={boot_delta.mean():.2f}")

# ---------- 5. 结构贡献度：加总必须等于整体增长率 -----------------------
A0 = rng.uniform(0, 100, size=(10, 4)).round(2)
A1 = A0 * rng.uniform(0.5, 1.5, size=(10, 4)).round(2)
G0, G1 = A0.sum(axis=0), A1.sum(axis=0)
contrib = (G1 - G0) / G0.sum() * 100
ck("各维度贡献之和 ≡ 整体增长率", abs(contrib.sum() - (G1.sum() - G0.sum()) / G0.sum() * 100) < 1e-9)
ck("bootstrap_contrib 输出形状正确", s3.bootstrap_contrib(A0, A1, 50, 1).shape == (50, 4))


# ---------- 6. AOV 五效应分解：恒等式 + 两个边界情形 ---------------------
def _decomp(q0, a0, q1, a1, f0, f1, o0, o1):
    return s4.decompose_aov(sum(q0), sum(a0), f0, o0,
                            sum(q1), sum(a1), f1, o1,
                            np.asarray(q0, float), np.asarray(a0, float),
                            np.asarray(q1, float), np.asarray(a1, float))


rng2 = np.random.default_rng(7)
worst = 0.0
for _ in range(200):
    k = int(rng2.integers(3, 9))
    q0 = rng2.integers(10, 500, k).astype(float)
    q1 = rng2.integers(10, 500, k).astype(float)
    p0 = rng2.uniform(5.0, 300.0, k)
    p1 = p0 * rng2.uniform(0.7, 1.3, k)
    a0, a1 = q0 * p0, q1 * p1
    o0 = int(q0.sum() / rng2.uniform(1.0, 2.5)) + 1
    o1 = int(q1.sum() / rng2.uniform(1.0, 2.5)) + 1
    eff, pi, mi, aux = _decomp(q0, a0, q1, a1, rng2.uniform(50, 5000), rng2.uniform(50, 5000), o0, o1)
    worst = max(worst, abs(sum(eff.values()) - aux["dAOV"]) / max(1.0, abs(aux["dAOV"])))
ck("AOV 五效应：五项之和 ≡ ΔAOV（200 组随机数据）", worst < 1e-9, f"max_rel={worst:.3e}")

# 边界 1：所有品类价格不变 —— 价格效应必须严格为 0
q0 = np.array([100.0, 150.0]); a0 = np.array([1000.0, 3000.0])
q1 = np.array([120.0, 130.0]); a1 = np.array([1200.0, 2600.0])   # 单价都是 10 / 20，没变
eff, _, _, _ = _decomp(q0, a0, q1, a1, 200.0, 300.0, 100, 110)
ck("所有品类单价不变时，价格效应严格为 0", abs(eff["price"]) < 1e-9, f"price={eff['price']:.3e}")

# 边界 2：本期新增一个上期不存在的品类 —— 其影响不应混入价格效应
q0 = np.array([100.0, 100.0, 0.0]);    a0 = np.array([1000.0, 2000.0, 0.0])
q1 = np.array([100.0, 100.0, 100.0]);  a1 = np.array([1000.0, 2000.0, 5000.0])
eff, pi, mi, _ = _decomp(q0, a0, q1, a1, 200.0, 300.0, 100, 150)
ck("新品类出现时，价格效应为 0（影响不混入价格维度）",
   abs(eff["price"]) < 1e-9 and abs(pi[2]) < 1e-9, f"price={eff['price']:.3e}, 新品类price_i={pi[2]:.3e}")
ck("新品类出现时，结构效应为正", eff["mix"] > 0, f"mix={eff['mix']:.4f}")

# 边界 3：某品类消失 —— 结构效应为负
q0 = np.array([100.0, 100.0, 100.0]);  a0 = np.array([1000.0, 2000.0, 5000.0])
q1 = np.array([100.0, 100.0, 0.0]);    a1 = np.array([1000.0, 2000.0, 0.0])
eff, _, _, _ = _decomp(q0, a0, q1, a1, 200.0, 300.0, 100, 100)
ck("品类消失时，价格效应为 0 且结构效应为负",
   abs(eff["price"]) < 1e-9 and eff["mix"] < 0, f"price={eff['price']:.3e}, mix={eff['mix']:.4f}")

# ---------- S5：比例区间、KM 生存分析、log-rank、PSM ----------
# 这些是自己实现的统计方法（没引 lifelines），必须用可手算的例子对照。
print("\n--- S5 方法自检 ---")

# S5.1 Wilson 区间：用 S3 实跑过的真实细胞验证端点
lo, hi = wilson_ci(95, 396)
ck("Wilson(95/396) 端点与 S3 实跑一致",
   abs(lo - 0.2005) < 5e-4 and abs(hi - 0.2843) < 5e-4, f"[{lo:.4f}, {hi:.4f}]")
lo, hi = wilson_ci(0, 10)
ck("Wilson 在 k=0 时下界不为负（Wald 区间会越界）", lo >= 0.0, f"[{lo:.4f}, {hi:.4f}]")

# S5.2 BH-FDR：单调性与边界
q = bh_fdr(np.array([0.001, 0.02, 0.03, 0.9]))
ck("BH-FDR 的 q 值 >= 原始 p 值", bool((q >= np.array([0.001, 0.02, 0.03, 0.9]) - 1e-12).all()),
   np.round(q, 4).tolist())
ck("BH-FDR 的 q 值不超过 1", bool((q <= 1.0).all()), np.round(q, 4).tolist())
ck("BH-FDR 保持原始顺序（不是排序后返回）", bool((np.argsort(q) == np.argsort(np.array([0.001, 0.02, 0.03, 0.9]))).all()))

# S5.3 KM：无删失时生存率应等于经验生存函数
c1 = s5.km_fit(np.array([1, 2, 3, 4, 5]), np.array([1, 1, 1, 1, 1]))
ck("KM 无删失：S(t) = 1 - t/n",
   np.allclose(c1["surv"].to_numpy(), [0.8, 0.6, 0.4, 0.2, 0.0]), c1["surv"].tolist())

# S5.4 KM：删失样本不产生事件时点，但计入风险集
c2 = s5.km_fit(np.array([1, 2, 3, 4, 5]), np.array([1, 1, 1, 0, 1]))
ck("KM 带删失：事件时点数 = 4（4 那天是删失，不产生时点）", len(c2) == 4, len(c2))
ck("KM 带删失：t=5 处风险集只剩 1 人", int(c2["at_risk"].iloc[-1]) == 1, c2["at_risk"].tolist())

# S5.5 KM：CI 用 Greenwood + log-log，闭式验算 t=1 处
#      Greenwood 项 = 1/(5·4)=0.05 → Var(log(-log S)) = 0.05/(ln0.8)^2
#      CI = S ** exp(±z·sqrt(Var))，z 必须用精确的 norm.ppf(0.975)=1.959964
#      （用字面量 1.96 会差出 ~1e-5，那是我写测试时踩过的坑，不是实现的问题）
from scipy.stats import norm as _norm  # noqa: E402

_z = _norm.ppf(0.975)
_v = math.sqrt(0.05 / math.log(0.8) ** 2)
_lo = 0.8 ** math.exp(_z * _v)
_hi = 0.8 ** math.exp(-_z * _v)
# 容差取 1e-6：km_fit 为了写库会把 surv/CI 四舍五入到 6 位小数（DECIMAL(8,6)），
# 所以这里不可能比 1e-6 更严 —— 这不是实现误差。
ck("KM 的 CI 与 Greenwood+log-log 闭式解一致",
   abs(c1["ci_low"].iloc[0] - _lo) < 1e-6 and abs(c1["ci_high"].iloc[0] - _hi) < 1e-6,
   f"got=[{c1['ci_low'].iloc[0]:.6f}, {c1['ci_high'].iloc[0]:.6f}] want=[{_lo:.6f}, {_hi:.6f}]")

# S5.6 KM：全删失 → 无事件时点，返回空表而不是报错
ck("KM 全删失返回空表", len(s5.km_fit(np.array([1, 2, 3]), np.array([0, 0, 0]))) == 0)

# S5.7 log-rank：手算对照（t=1 E1=0.5 V=0.25；t=2 E1=2/3 V=0.2222；t=3 E1=1 V=0）
#      O1=1, E1=2.166667, V=0.472222 → chi2 = 2.882353, p = 0.0895552
_chi2, _p = s5.logrank_2group(
    np.array([1.0, 2, 3, 4]), np.array([1, 1, 1, 1]), np.array([0, 0, 1, 1])
)
ck("log-rank chi2 与手算一致（2.882353）", abs(_chi2 - 2.8823529) < 1e-5, f"chi2={_chi2:.6f}")
ck("log-rank p 与手算一致（0.0895552）", abs(_p - 0.0895552) < 1e-5, f"p={_p:.7f}")

# S5.8 log-rank：两组事件时间分布完全相同 → chi2 必须恰好为 0
_chi2, _p = s5.logrank_2group(
    np.array([1.0, 2, 3, 4, 1, 2, 3, 4]), np.array([1] * 8), np.array([0, 0, 0, 0, 1, 1, 1, 1])
)
ck("log-rank 无差异时 chi2=0 且 p=1", abs(_chi2) < 1e-9 and abs(_p - 1.0) < 1e-9,
   f"chi2={_chi2:.3e}, p={_p:.3f}")

# S5.9 标准化均值差 SMD
ck("SMD 同分布时为 0", abs(s5.smd(np.array([1.0, 2, 3]), np.array([1.0, 2, 3]))) < 1e-12)
ck("SMD 手算对照 1.4142136",
   abs(s5.smd(np.array([0.0, 1.0]), np.array([-1.0, 0.0])) - math.sqrt(2)) < 1e-6)

# S5.10 K-means 特征矩阵：log 变换后再标准化，各列均值≈0、标准差≈1
_rng = np.random.default_rng(7)
_raw = pd.DataFrame({
    "recency_days": _rng.gamma(2, 60, 500),
    "order_cnt": np.where(_rng.random(500) < 0.03, _rng.integers(2, 6, 500), 1),
    "monetary": _rng.lognormal(5, 1.2, 500),
})
_X = s5c.build_matrix(_raw, ["recency_days", "order_cnt", "monetary"])
ck("K-means 特征矩阵：标准化后各列均值≈0",
   bool(np.allclose(_X.mean(axis=0), 0.0, atol=1e-9)), np.round(_X.mean(axis=0), 12).tolist())
ck("K-means 特征矩阵：标准化后各列标准差≈1",
   bool(np.allclose(_X.std(axis=0), 1.0, atol=1e-9)), np.round(_X.std(axis=0), 6).tolist())
ck("K-means 特征矩阵：无 NaN/Inf（顺序错成「先标准化再 log」就会出 NaN）",
   bool(np.isfinite(_X).all()))

# S5.11 PSM：query 必须是 2D（(1,1)），否则 sklearn 1.0+ 会报#      "Expected 2D array, got 1D array instead" —— 这是 s5_02 实跑踩过的真坑。
#      直接模拟 logit[i:i+1] 的查询形态，必须显式升维才能跑通。
from sklearn.neighbors import NearestNeighbors as _NN  # noqa: E402
_logit = np.array([-2.0300234])                       # 实跑中触发 bug 的那个 logit 值
_query = _logit[:, None]                              # 修法：logit[i:i+1, None]
_tree = _NN(n_neighbors=1).fit(_query)                # 用同样的 1D→2D 升维来建树
    # 确保两侧都是 (1,1)，模拟修后的查询路径
_dist_ok, _idx_ok = _tree.kneighbors(_query, n_neighbors=1)
ck("PSM query 升维 (1,1)：kneighbors 不报错",
   _dist_ok.shape == (1, 1) and _idx_ok.shape == (1, 1),
   f"dist.shape={_dist_ok.shape}, idx.shape={_idx_ok.shape}")
# 反向断言：如果不升维直接传 1D，应当按 sklearn 当前实现抛错。
# 这是对"修复"的双重锁——只要 sklearn 还要求 2D，这条断言就会触发；以后即便我们
# 误把修法回退掉，selftest 也立刻能抓到。
try:
    _tree.kneighbors(_logit, n_neighbors=1)           # 直接传 1D——应该报错
    ck("PSM 传 1D query 时 sklearn 必须拒绝（防回退）", False,
       "sklearn 居然接受了 1D query —— 它已不再校验维度，本次修复的前提不再成立")
except ValueError:
    ck("PSM 传 1D query 时 sklearn 必须拒绝（防回退）", True)

# S5.12 PSM：全链路跑通检查（不验证 n_pairs，因为小样本 LR 倾向得分不稳定）
#      这条锁的是"psm_1to1 能从入口到出口跑完不抛异常"，覆盖范围：
#      query 升维、LR 拟合、logit 计算、tree.kneighbors、卡尺判断、返回结构。
#      真正的"PSM 配出 N 对"是真实数据（66k / 28k 样本）才稳定的事，
#      selftest 用 25 个样本去测 n_pairs 没有意义 —— 那是在测 LR 的小样本行为。
_rng_psm = np.random.default_rng(20260827)  # 固定种子，让 selftest 输出可复现
_X_psm = _rng_psm.normal(size=(25, 3))
_treat_psm = np.array([1] * 5 + [0] * 20)
_y_psm = _treat_psm.astype(float) + _rng_psm.normal(scale=0.3, size=25)
try:
    _res = s5.psm_1to1(_X_psm, _treat_psm, _y_psm, 20260827)
    _psm_ok = True
except Exception as _e:                                # noqa: BLE001
    _psm_ok = False
    _psm_err = repr(_e)
ck("PSM 全链路不抛异常（query 升维 + LR + 卡尺 + 返回结构）",
   _psm_ok, "OK" if _psm_ok else _psm_err)
# 仅作为信息项：让你知道小样本下配对率（不是断言）
if _psm_ok:
    print(f"  [info] PSM 25 样本配对数={_res.get('n_pairs', 0)}（小样本下可能为 0，非断言）")


print("\n--- S6 策略评估自检 ---")

# S6.1 三条策略的成本口径：手算对照（最容易被"平均成一个数"的地方）
_PARAMS = {
    "p1_expedite_cost": 8.0, "p2_voucher_face": 15.0, "p2_redeem_rate": 0.6,
    "p2_contact_cost": 2.0, "p3_voucher_face": 10.0, "p3_redeem_rate": 0.65,
    "bad_review_cost": 40.75, "repeat_effect_pp": -1.46, "aov_delayed": 171.29,
    "aov_ontime": 158.54, "baseline_bad_ontime": 9.19, "baseline_bad_late": 53.99,
}
ck("S6 成本口径 P1 = 单均加急成本 8.00",
   abs(s6.cost_per_order("p1_expedite", _PARAMS) - 8.0) < 1e-9,
   s6.cost_per_order("p1_expedite", _PARAMS))
ck("S6 成本口径 P2 = 券15×0.6 + 触达2 = 11.00",
   abs(s6.cost_per_order("p2_intercept", _PARAMS) - 11.0) < 1e-9,
   s6.cost_per_order("p2_intercept", _PARAMS))
ck("S6 成本口径 P3 = 券10×0.65 = 6.50",
   abs(s6.cost_per_order("p3_voucher", _PARAMS) - 6.5) < 1e-9,
   s6.cost_per_order("p3_voucher", _PARAMS))

# S6.2 compute_roi 的恒等式（用一组可心算的输入）
_R = s6.compute_roi("p3_voucher", covered_orders=1000, covered_customers=990,
                    covered_gmv=171290.0, params=_PARAMS, rescue_rate=0.5, bad_value=40.0)
# 可挽救差评 = 1000 × (0.5399 − 0.0919) = 448 个；成本 = 1000 × 6.5 = 6500
# 收益 = 448 × 0.5 × 40 = 8960；净 = 2460；ROI = 8960/6500 = 1.3784615...
ck("S6 可挽救差评上限按「延迟差评率 − 准时差评率」算",
   abs(_R["bad_upper"] - 1000 * (0.5399 - 0.0919)) < 1e-9, _R["bad_upper"])
ck("S6 总成本 = 覆盖单数 × 单均成本",
   abs(_R["total_cost"] - 6500.0) < 1e-9, _R["total_cost"])
ck("S6 ROI 恒等式：roi = 收益 / 成本",
   abs(_R["roi_b"] - 8960.0 / 6500.0) < 1e-12, _R["roi_b"])
ck("S6 净收益恒等式：net = 收益 − 成本",
   abs(_R["net_benefit_b"] - (8960.0 - 6500.0)) < 1e-9, _R["net_benefit_b"])

# S6.3 P3 不属于复购挽回适用策略（S5 证差评不驱动复购）⇒ 复购项必须为 0
ck("S6 P3 的复购挽回为 0（差评不驱动复购，不得虚增收益）",
   _R["rescued_repeat"] == 0.0 and _R["revenue_repeat"] == 0.0,
   f"rescued={_R['rescued_repeat']}, revenue={_R['revenue_repeat']}")
_R1 = s6.compute_roi("p1_expedite", covered_orders=1000, covered_customers=990,
                     covered_gmv=171290.0, params=_PARAMS, rescue_rate=0.5, bad_value=40.0)
# P1 是「真正消除延迟」，享受复购收益：990 × 0.0146 × 0.5 = 7.227 个客户
ck("S6 P1 的复购挽回按客户数算（非订单数）",
   abs(_R1["rescued_repeat"] - 990 * 0.0146 * 0.5) < 1e-9,
   f"{_R1['rescued_repeat']:.6f} vs 期望 {990 * 0.0146 * 0.5:.6f}")

# S6.4 盈亏平衡点的定义：把 p* 代回应得净收益 ≈ 0
_p_star = _R["breakeven_p_b"]
_R_star = s6.compute_roi("p3_voucher", covered_orders=1000, covered_customers=990,
                         covered_gmv=171290.0, params=_PARAMS,
                         rescue_rate=_p_star, bad_value=40.0)
ck("S6 盈亏平衡点 p*：代回后净收益 ≈ 0",
   abs(_R_star["net_benefit_b"]) < 1e-6, f"p*={_p_star:.6f}, net={_R_star['net_benefit_b']:.8f}")
# 手算：p* = 6500 / (448 × 40) = 0.3627232...
ck("S6 盈亏平衡点 p* 与手算一致",
   abs(_p_star - 6500.0 / (448.0 * 40.0)) < 1e-9,
   f"{_p_star:.8f} vs {6500.0 / (448.0 * 40.0):.8f}")

# S6.5 预算分配：任何档位的分配总额不得超过预算（含 unallocated 留痕）
_roi_df = pd.DataFrame([
    dict(s6.compute_roi("p1_expedite", 1000, 990, 171290.0, _PARAMS, 0.5, 40.0)),
    dict(s6.compute_roi("p2_intercept", 5000, 4980, 894198.0, _PARAMS, 0.5, 40.0)),
    dict(s6.compute_roi("p3_voucher", 8000, 7600, 1312232.0, _PARAMS, 0.5, 40.0)),
])
_plan = pd.DataFrame(s6.budget_plan(_roi_df, _PARAMS))
_alloc_sum = _plan.groupby("budget_level")["allocated"].sum()
_budget_vals = _alloc_sum.index.to_numpy(dtype=float)
ck("S6 预算分配：各档位分配总额不超过预算",
   bool((_alloc_sum.to_numpy(dtype=float) <= _budget_vals + 1e-6).all()),
   {float(k): round(float(v), 2) for k, v in _alloc_sum.items()})
ck("S6 预算分配：亏损策略不参与分配（allocated 必须为 0）",
   bool((_plan.loc[_plan["strategy"] == "p2_intercept", "allocated"] == 0).all()),
   _plan.loc[_plan["strategy"] == "p2_intercept", "allocated"].tolist())

print("\n" + ("全部通过" if not fails else f"失败 {len(fails)} 项: {fails}"))
sys.exit(1 if fails else 0)
