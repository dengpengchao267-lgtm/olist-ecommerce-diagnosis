"""S5-01　客户分层：业务规则分层 vs K-means 聚类（交叉验证）

【这个脚本回答什么】
    sql/10 已经用「三维二值 RFM」（R 活跃/沉睡 × F 复购/单次 × M 高值/低值）把客户分成 8 格。
    但那是**基于业务规则**的切法。脚本用**无监督学习**独立地再分一次，然后回答：
        "我按业务规则切出来的 8 群，和数据自己聚出来的群，是不是一回事？"
    一致 → 分层有数据支撑，不是拍脑袋；
    不一致 → 差异本身就是信息（说明某一维在数据里没有区分度）。

【为什么必须先 log 变换再标准化】
    K-means 最小化的是**欧氏距离**，它对量纲和极端值都极其敏感：
      1) 量纲问题：recency 是"天"（0~700），monetary 是"雷亚尔"（0~1.3 万）。
         不标准化的话两者单位等价，距离完全被金额主导。
      2) 极端值问题：monetary 极度右偏（绝大多数客户一两百块、极少数上万）。
         不取对数，少数大额客户到中心的距离是普通客户的几十倍，
         K-means 会把它们单独拆成一簇、把其余 99% 塞进另一簇 —— 这叫"被极端值绑架"。
    log 变换把乘法差异变成加法差异、压缩右尾，让"1,000 块比 100 块高多少"与
    "100 块比 10 块高多少"在距离上等价 —— 这才是"价值等级"应有的语义。
    ⚠️ 顺序必须是「先 log 再标准化」。反过来会把负值送进 log，直接得到 NaN。

【为什么用轮廓系数选 K，而不是看肘部】
    肘部法（inertia 拐点）是主观判断，不同人看出不同的 K，不可复现。
    轮廓系数有界（[-1,1]）且能直接比大小，报告里写得出一句确定的话：
    "在 K=2..6 中，K=x 的轮廓系数最高"。

【ARI 是什么】
    Adjusted Rand Index：把两套分群方案做交叉表后衡量一致程度，
    并对随机分组做了修正（随机分组期望 0，完全一致为 1）。
    注意：ARI 低**不等于**分层做错了 —— 它衡量的是"是否同一套切法"，不是"哪个更好"。

【产出】ads_s5_cluster_eval（长表：轮廓系数 / 簇规模 / 交叉表 / ARI）
【用法】python s5_01_rfm_cluster.py [--dry-run]
"""
from __future__ import annotations

import argparse
import sys

import numpy as np
import pandas as pd
from sklearn.cluster import KMeans
from sklearn.metrics import adjusted_rand_score, silhouette_score
from sklearn.preprocessing import StandardScaler

from common import (
    check,
    fmt_table,
    get_engine,
    read_table,
    setup_logging,
    write_table,
)
from config import RANDOM_SEED, S5_F_REPEAT_ORDERS, S5_K_RANGE

RFM_COLS = ["recency_days", "order_cnt", "monetary"]
RM_COLS = ["recency_days", "monetary"]


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="S5-01 客户分层：业务规则分层 vs K-means")
    p.add_argument("--dry-run", action="store_true", help="只打印，不回写数据库")
    return p.parse_args()


# ---------------------------------------------------------------------------
# 特征准备
# ---------------------------------------------------------------------------
def build_matrix(df: pd.DataFrame, cols: list[str]) -> np.ndarray:
    """log1p 变换 → 标准化。返回 K-means 可直接消费的矩阵。"""
    raw = df[cols].astype(float).to_numpy()
    logged = np.log1p(np.clip(raw, 0, None))  # clip 兜住理论上的负值
    return StandardScaler().fit_transform(logged)


def fit_each_k(
    X: np.ndarray, ks: tuple[int, ...], seed: int
) -> tuple[dict[int, float], dict[int, np.ndarray]]:
    """对每个 K 训练一次，同时返回轮廓系数与标签（避免 best_k 再训练一遍）。

    96k 样本上轮廓系数是 O(n^2)，全量算太慢，
    所以用 sample_size 抽样估计 —— sklearn 的抽样估计无偏，比较 K 足够用。
    """
    sil: dict[int, float] = {}
    labels: dict[int, np.ndarray] = {}
    for k in ks:
        km = KMeans(n_clusters=k, n_init=10, random_state=seed)
        lab = km.fit_predict(X)
        labels[k] = lab
        sil[k] = float(
            silhouette_score(X, lab, sample_size=min(20000, len(X)), random_state=seed)
        )
    return sil, labels


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
def main() -> None:
    args = parse_args()
    log = setup_logging("s5_01")
    engine = get_engine()

    # ---- 1. 读客户画像 + 修正版分层 -------------------------------------
    user = read_table(engine, "dws_user_profile")
    rfm2 = read_table(engine, "ads_s5_rfm_v2")
    log.info("读取 dws_user_profile：%d 行；ads_s5_rfm_v2：%d 行", len(user), len(rfm2))

    user = user.dropna(subset=RFM_COLS).reset_index(drop=True)
    check(len(user) > 0, "客户画像非空", log)
    check(bool((user["monetary"] >= 0).all()), "monetary 无负值", log)
    check(bool((user["order_cnt"] >= 1).all()), "order_cnt 至少为 1", log)
    check(bool((user["recency_days"] >= 0).all()), "recency_days 无负值", log)

    # ---- 2. 特征矩阵 ------------------------------------------------------
    X3 = build_matrix(user, RFM_COLS)
    X2 = build_matrix(user, RM_COLS)
    log.info("特征：%s（log1p → StandardScaler）", RFM_COLS)
    log.info("变换后各列标准差（应≈1）：%s", np.round(X3.std(axis=0), 3).tolist())

    # ---- 3. 选 K ----------------------------------------------------------
    sil3, labels3 = fit_each_k(X3, tuple(S5_K_RANGE), RANDOM_SEED)
    best_k = max(sil3, key=lambda k: sil3[k])
    log.info("轮廓系数（R/F/M 三特征）：%s", {k: round(v, 4) for k, v in sil3.items()})
    log.info("最优 K = %d（轮廓系数 %.4f）", best_k, sil3[best_k])
    user["cluster"] = labels3[best_k]

    # ---- 4. 三组一致性对照（ARI）------------------------------------------
    # ⚠️ ads_s5_rfm_v2 是聚合维度表（8 行 = 8 个 rfm_code + 该群总人数），不是客户级。
    #   它把业务规则的关键阈值（thr_recency_days / thr_monetary）放在每行，
    #   把"每个客户属于哪个 rfm_code"留到 Python 端按相同规则重算，
    #   这样口径与 sql/10 100% 一致 —— sql/10 是事实源。
    thr_row = rfm2[rfm2["thr_recency_days"].notna()].iloc[0]
    r_thr = int(thr_row["thr_recency_days"])
    m_thr = float(thr_row["thr_monetary"])
    f_thr = S5_F_REPEAT_ORDERS
    user["r_flag"] = (user["recency_days"] <= r_thr).astype(int)
    user["f_flag"] = (user["order_cnt"]    >= f_thr).astype(int)
    user["m_flag"] = (user["monetary"]     >  m_thr).astype(int)
    user["rfm_code"] = (
        user["r_flag"].astype(str) + user["f_flag"].astype(str) + user["m_flag"].astype(str)
    )
    log.info("业务规则 R/F/M 阈值：R≤%d 天 / F≥%d 单 / M>%.2f 元）—— 与 sql/10 共用 ads_s5_rfm_v2.thr_*",
             r_thr, f_thr, m_thr)
    check(set(user["rfm_code"]).issubset(
              {"000","001","010","011","100","101","110","111"}),
          "rfm_code 全部落在 8 格三维二值空间内", log)
    ari_v2 = adjusted_rand_score(user["rfm_code"], user["cluster"])

    # 对照 A：与 sql/02 那套「五分位 RFM」八类人群的一致性
    #   预期明显更低 —— 这正是 F 维分箱退化的后果，是本节要展示的证据
    ari_old = adjusted_rand_score(user["rfm_segment"].fillna("缺失"), user["cluster"])

    # 对照 B：去掉 F，只用 R/M 再聚一次，看 F 到底贡献了多少结构
    km2 = KMeans(n_clusters=best_k, n_init=10, random_state=RANDOM_SEED)
    lab2 = km2.fit_predict(X2)
    ari_rm = adjusted_rand_score(user["cluster"], lab2)
    sil_rm = float(
        silhouette_score(X2, lab2, sample_size=min(20000, len(X2)), random_state=RANDOM_SEED)
    )

    log.info("ARI（聚类 vs 修正版三维二值八格）  = %.4f", ari_v2)
    log.info("ARI（聚类 vs sql/02 五分位八类人群）= %.4f", ari_old)
    log.info("去掉 F 只用 R/M：轮廓系数 %.4f（三维 %.4f），与三维聚类 ARI = %.4f",
             sil_rm, sil3[best_k], ari_rm)

    # ---- 5. 簇画像（还原到原始单位，业务才读得懂）-------------------------
    prof = (
        user.groupby("cluster")
        .agg(
            customers=("customer_unique_id", "size"),
            avg_recency=("recency_days", "mean"),
            med_monetary=("monetary", "median"),
            avg_monetary=("monetary", "mean"),
            avg_order_cnt=("order_cnt", "mean"),
            repeat_rate=("order_cnt", lambda s: float((s >= 2).mean())),
        )
        .reset_index()
    )
    prof["share_pct"] = (prof["customers"] / prof["customers"].sum() * 100).round(2)

    # ---- 6. 交叉表 --------------------------------------------------------
    cross = pd.crosstab(user["rfm_code"], user["cluster"]).reset_index()
    cluster_cols = [c for c in cross.columns if c != "rfm_code"]

    # ---- 7. 汇总评估表（长表，与 ads_s4_eval 同一风格）--------------------
    rows: list[dict] = [
        {
            "method": "kmeans", "metric": "silhouette", "label": f"k={k}",
            "value": round(v, 4),
            "note": "特征=R/F/M（log1p+标准化），轮廓系数按 20000 抽样估计",
        }
        for k, v in sil3.items()
    ]
    rows += [
        {"method": "kmeans", "metric": "best_k", "label": "best",
         "value": float(best_k), "note": "轮廓系数最大的 K"},
        {"method": "kmeans", "metric": "ari", "label": "vs_rfm_v2",
         "value": round(ari_v2, 4), "note": "聚类 vs 修正版三维二值八格"},
        {"method": "kmeans", "metric": "ari", "label": "vs_old_rfm_segment",
         "value": round(ari_old, 4),
         "note": "聚类 vs sql/02 五分位八类人群（F 分箱在 3% 复购率下退化）"},
        {"method": "kmeans", "metric": "ari", "label": "vs_rm_only",
         "value": round(ari_rm, 4), "note": "三维聚类 vs 去掉 F 的 R/M 聚类"},
        {"method": "kmeans", "metric": "silhouette", "label": "rm_only",
         "value": round(sil_rm, 4), "note": "去掉 F 只用 R/M 的轮廓系数"},
    ]
    rows += [
        {
            "method": "cluster_profile", "metric": "cluster_size",
            "label": f"cluster={int(r['cluster'])}", "value": float(r["customers"]),
            "note": (f"占比 {r['share_pct']}%；R 均值 {r['avg_recency']:.0f} 天；"
                     f"M 中位 {r['med_monetary']:.0f}；F 均值 {r['avg_order_cnt']:.2f}；"
                     f"复购率 {r['repeat_rate']:.2%}"),
        }
        for _, r in prof.iterrows()
    ]
    rows += [
        {"method": "cross_tab", "metric": f"cluster{int(c)}",
         "label": f"rfm={r['rfm_code']}", "value": float(r[c]),
         "note": "业务分层 × 聚类 交叉表单元格人数"}
        for _, r in cross.iterrows()
        for c in cluster_cols
        if int(r[c]) > 0
    ]

    eval_df = pd.DataFrame(rows)
    eval_df["updated_at"] = pd.Timestamp.now().normalize()

    # ---- 8. 勾稽 ----------------------------------------------------------
    check(int(prof["customers"].sum()) == len(user),
          f"各簇人数之和 = 客户总数（{len(user)}）", log)
    check(abs(sil3[best_k] - max(sil3.values())) < 1e-12, "best_k 确为轮廓系数最大值", log)
    check(0.0 <= ari_v2 <= 1.0, "ARI 落在 [0,1]", log)
    check(int(cross[cluster_cols].to_numpy().sum()) == len(user),
          "交叉表合计 = 客户总数（不漏客）", log)
    check(int(user["cluster"].nunique()) == best_k, f"实际簇数 = K（{best_k}）", log)
    check(len(eval_df) == len(eval_df.drop_duplicates(["method", "metric", "label"])),
          "评估表无主键重复（method, metric, label）", log)

    # ---- 9. 回写 ----------------------------------------------------------
    if args.dry_run:
        log.info("--dry-run：不回写数据库")
    else:
        n = write_table(engine, eval_df, "ads_s5_cluster_eval", log=log)
        log.info("写入 ads_s5_cluster_eval：%d 行", n)

    # ---- 10. 控制台汇报 ---------------------------------------------------
    print("\n" + "=" * 78)
    print(f"S5-01　客户分层：K-means（K={best_k}）vs 业务规则三维二值 RFM")
    print("=" * 78)

    print("\n轮廓系数（[-1,1]，越大越好）：")
    for k, v in sorted(sil3.items()):
        print(f"  K={k}: {v:.4f}{'  ← 最优' if k == best_k else ''}")

    print("\n一致性（ARI：1=完全一致，0=与随机分组无异）：")
    print(f"  聚类 vs 修正版三维二值八格  : {ari_v2:.4f}")
    print(f"  聚类 vs sql/02 五分位八类人群: {ari_old:.4f}")
    print(f"  聚类 vs 去掉 F 的 R/M 聚类   : {ari_rm:.4f}")

    print("\n簇画像（已还原原始单位）：")
    print(fmt_table(prof.round(2)))

    print("\n交叉表（行=业务分层八格，列=聚类簇）：")
    print(cross.to_string(index=False))

    print("\n读法：ARI 低不代表分层错，只代表「两套切法不一致」。")
    print("      若「vs 三维二值八格」明显高于「vs 五分位八类」，")
    print("      且去掉 F 后结果几乎不变 → 证实 F 维度在本数据集上无信息量。")
    print("\nS5-01 完成。")


if __name__ == "__main__":
    sys.exit(main())
