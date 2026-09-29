"""S4-01　差评预警：签收后、评价前的差评概率预测

回答的问题：能不能在客户写下差评之前，就把高风险订单认出来？
业务闭环：对头部风险单主动干预（关怀 + 优惠券），把差评消灭在发生前。

产出：回写三张表
    ads_s4_eval        —— 两模型的评估指标（PR-AUC / ROC-AUC / 阈值下 P&R）
    ads_s4_gain        —— 干预增益曲线（"拦前 k% 风险单能覆盖多少差评"）
    ads_s4_importance  —— 特征重要性（逻辑回归 |系数| + HGB 置换重要性）

用法：
    python s4_01_bad_review_model.py --dry-run
    python s4_01_bad_review_model.py

方法说明（每一条都是）：
  1. 为什么不做随机 train/test split：
     订单有时间结构，随机切分会让模型"偷看未来"（用 2018-08 的经验预测 2017-03），
     上线后面对的永远是"用历史预测未来"。所以按月做时间外推：
     训练 2017-01~2018-04，测试 2018-05~2018-08。这比随机划分的指标低，
     但那才是真实上线能达到的水平——报好看的数字骗自己没有意义。
  2. 为什么主指标是 PR-AUC 而不是 ROC-AUC / 准确率：
     差评是 ~10% 的不平衡类，全预测"好评"就有 90% 准确率——准确率在这里是废指标；
     ROC-AUC 在不平衡下会虚高（负类太多，FPR 分母大）。
     业务真正关心的是"圈出来的人里有多少真是差评、差评被圈出来多少"，
     这正是 PR 曲线下的面积。
  3. 阈值不取 0.5：在训练集上取 F1 最大点。差评预警是运营动作，
     阈值对应的是干预预算，不是概率语义。
  4. 为什么配两个模型：逻辑回归（白盒、系数可解释、给讲得清）
     + HistGradientBoosting（性能上限、原生吃缺失值）。
     两模型差距大 ⇒ 存在非线性/交互；差距小 ⇒ 线性故事就够讲。
  5. 阈值/超参数都在训练集定，测试集只看一次——防止"调到测试集上"。
"""
from __future__ import annotations

import argparse

import numpy as np
import pandas as pd
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.inspection import permutation_importance
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import (
    average_precision_score,
    brier_score_loss,
    precision_recall_curve,
    roc_auc_score,
)
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.impute import SimpleImputer

from common import (
    check,
    complete_window,
    fmt_table,
    get_engine,
    month_panel,
    read_table,
    setup_logging,
    table_exists,
    write_table,
)
from config import RANDOM_SEED, S4_COUPON_COST_BRL, S4_TEST_START, S4_TOP_PCTS

MODEL_CN = {"logreg": "逻辑回归", "hgb": "梯度提升树"}

# 特征清单（与 sql/09 的 ads_s4_order_features 一一对应，不含 order_id / stat_month / is_bad）
FEATURES = [
    "is_late", "delay_hours", "total_delivery_hours", "lastmile_hours",
    "carrier_hours", "approve_hours", "estimated_hours", "is_seller_late",
    "avg_distance_km",
    "order_amount", "freight_ratio", "item_cnt", "seller_cnt", "product_cnt",
    "pay_type_cnt", "has_credit_card", "max_installments",
    "photos_qty", "description_length", "weight_g", "volume_cm3",
    "seller_hist_cnt", "seller_hist_bad_rate", "cat_hist_cnt", "cat_hist_bad_rate",
    "dow",
]


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="S4-01 差评预警模型")
    p.add_argument("--seed", type=int, default=RANDOM_SEED)
    p.add_argument("--dry-run", action="store_true", help="只训练打印，不回写")
    return p.parse_args()


def best_f1_threshold(y: np.ndarray, score: np.ndarray) -> tuple[float, float]:
    """训练集上取 F1 最大的阈值。返回 (阈值, 对应F1)。"""
    prec, rec, thr = precision_recall_curve(y, score)
    f1 = 2 * prec * rec / np.where(prec + rec > 0, prec + rec, 1)
    i = int(np.nanargmax(f1[:-1]))  # 最后一个点无阈值
    return float(thr[i]), float(f1[i])


def gain_table(model: str, y: np.ndarray, score: np.ndarray,
               top_pcts: tuple[int, ...], coupon_cost: float) -> pd.DataFrame:
    """按风险分从高到低圈头部 k%，算差评捕获率与干预成本。"""
    n = len(y)
    n_bad = int(y.sum())
    order = np.argsort(-score)
    y_sorted = y[order]
    cum_bad = np.cumsum(y_sorted)
    rows = []
    for pct in top_pcts:
        k = max(1, int(round(n * pct / 100)))
        captured = int(cum_bad[k - 1])
        precision = captured / k
        rows.append({
            "model": model,
            "top_pct": pct,
            "n_orders": k,
            "n_bad_total": n_bad,
            "captured": captured,
            "recall": round(captured / n_bad, 4) if n_bad else np.nan,
            "precision_": round(precision, 4),
            "lift": round(precision / (n_bad / n), 4) if n_bad else np.nan,
            "cost_brl": round(k * coupon_cost, 2),
            "cost_per_bad": round(k * coupon_cost / captured, 2) if captured else np.nan,
        })
    return pd.DataFrame(rows)


def main() -> None:
    args = parse_args()
    log = setup_logging("s4-01")
    engine = get_engine()

    if not table_exists(engine, "ads_s4_order_features"):
        raise SystemExit("ads_s4_order_features 不存在，请先执行 sql/09_s4_差评预警特征.sql")

    # ---- 数据与划分 --------------------------------------------------------
    panel = month_panel(engine)
    start, end = complete_window(panel, log)

    df = read_table(engine, "ads_s4_order_features")
    df["stat_month"] = pd.to_datetime(df["stat_month"])
    df = df[(df["stat_month"] >= start) & (df["stat_month"] <= end)].copy()
    check(not df["order_id"].duplicated().any(), "order_id 无重复", log)
    check(df["is_bad"].isin([0, 1]).all(), "标签只含 0/1", log)

    test_start = pd.Timestamp(S4_TEST_START)
    train = df[df["stat_month"] < test_start]
    test = df[df["stat_month"] >= test_start]
    check(len(train) > 0 and len(test) > 0, "训练/测试集都非空", log)
    check(train["is_bad"].nunique() == 2 and test["is_bad"].nunique() == 2,
          "训练与测试都含正负两类（否则无意义）", log)
    log.info("训练 %d 行（差评率 %.2f%%，%s ~ %s），测试 %d 行（差评率 %.2f%%）",
             len(train), train["is_bad"].mean() * 100,
             f"{train['stat_month'].min():%Y-%m}", f"{train['stat_month'].max():%Y-%m}",
             len(test), test["is_bad"].mean() * 100)

    X_tr, y_tr = train[FEATURES], train["is_bad"].to_numpy()
    X_te, y_te = test[FEATURES], test["is_bad"].to_numpy()
    base_rate = float(y_te.mean())

    # ---- 模型一：逻辑回归（中位数插补 + 标准化，系数可比） -------------------
    logreg = Pipeline([
        ("imp", SimpleImputer(strategy="median")),
        ("sc", StandardScaler()),
        ("clf", LogisticRegression(max_iter=5000, class_weight="balanced",
                                   random_state=args.seed)),
    ])
    # ---- 模型二：HistGradientBoosting（原生吃 NaN；不平衡用手动样本权重） ----
    w = np.where(y_tr == 1, len(y_tr) / (2 * max(y_tr.sum(), 1)),
                 len(y_tr) / (2 * max((y_tr == 0).sum(), 1)))
    hgb = HistGradientBoostingClassifier(
        max_iter=300, learning_rate=0.08, max_leaf_nodes=31,
        l2_regularization=1.0, random_state=args.seed,
    )

    logreg.fit(X_tr, y_tr)
    hgb.fit(X_tr, y_tr, sample_weight=w)

    models = {
        "logreg": (logreg, logreg.predict_proba(X_tr)[:, 1], logreg.predict_proba(X_te)[:, 1]),
        "hgb": (hgb, hgb.predict_proba(X_tr)[:, 1], hgb.predict_proba(X_te)[:, 1]),
    }

    # ---- 评估（阈值在训练集定，测试集只看一次） ------------------------------
    eval_rows, gain_rows, imp_rows = [], [], []
    for name, (mdl, s_tr, s_te) in models.items():
        pr_auc = average_precision_score(y_te, s_te)
        roc_auc = roc_auc_score(y_te, s_te)
        brier = brier_score_loss(y_te, s_te)
        thr, f1_tr = best_f1_threshold(y_tr, s_tr)
        pred_te = (s_te >= thr).astype(int)
        tp = int(((pred_te == 1) & (y_te == 1)).sum())
        fp = int(((pred_te == 1) & (y_te == 0)).sum())
        fn = int(((pred_te == 0) & (y_te == 1)).sum())
        prec_at = tp / max(tp + fp, 1)
        rec_at = tp / max(tp + fn, 1)

        eval_rows += [
            {"model": name, "metric": "pr_auc", "value": round(pr_auc, 4),
             "note": "主指标：测试集 PR 曲线下面积"},
            {"model": name, "metric": "roc_auc", "value": round(roc_auc, 4),
             "note": "不平衡下会虚高，仅作参照"},
            {"model": name, "metric": "brier", "value": round(brier, 4),
             "note": "概率校准参考"},
            {"model": name, "metric": "threshold", "value": round(thr, 4),
             "note": f"训练集 F1 最大点（F1={f1_tr:.3f}）"},
            {"model": name, "metric": "precision_at_thr", "value": round(prec_at, 4),
             "note": "测试集该阈值下的精度"},
            {"model": name, "metric": "recall_at_thr", "value": round(rec_at, 4),
             "note": "测试集该阈值下的召回"},
            {"model": name, "metric": "test_base_rate", "value": round(base_rate, 4),
             "note": "测试集差评率（对照基准）"},
            {"model": name, "metric": "n_train", "value": float(len(train)), "note": "训练行数"},
            {"model": name, "metric": "n_test", "value": float(len(test)), "note": "测试行数"},
        ]

        g = gain_table(name, y_te, s_te, S4_TOP_PCTS, S4_COUPON_COST_BRL)
        gain_rows.append(g)

        # 业务话术：头部 10% 是默认汇报口径
        g10 = g[g["top_pct"] == 10].iloc[0]
        log.info("[%s] PR-AUC=%.4f | 拦前10%%风险单（%d单）覆盖 %.1f%% 差评，"
                 "精度 %.1f%%（基线 %.1f%%，lift %.1f），每拦一单差评成本 R$%.0f",
                 MODEL_CN[name], pr_auc, g10["n_orders"], g10["recall"] * 100,
                 g10["precision_"] * 100, base_rate * 100, g10["lift"],
                 g10["cost_per_bad"])

    # ---- 特征重要性 --------------------------------------------------------
    coef = np.abs(logreg.named_steps["clf"].coef_[0])
    lr_imp = pd.DataFrame({"feature": FEATURES, "importance": coef})
    lr_imp["rank_no"] = lr_imp["importance"].rank(ascending=False, method="first").astype(int)
    lr_imp["model"] = "logreg"
    imp_rows.append(lr_imp)

    perm = permutation_importance(hgb, X_te, y_te, scoring="average_precision",
                                  n_repeats=5, random_state=args.seed, n_jobs=1)
    hb_imp = pd.DataFrame({"feature": FEATURES, "importance": perm.importances_mean})
    hb_imp["rank_no"] = hb_imp["importance"].rank(ascending=False, method="first").astype(int)
    hb_imp["model"] = "hgb"
    imp_rows.append(hb_imp)

    importance = pd.concat(imp_rows, ignore_index=True)
    importance["importance"] = importance["importance"].round(6)

    # ---- 打印结论 ----------------------------------------------------------
    print("\n" + "=" * 100)
    print(f"S4-01　差评预警（时间外推：train < {S4_TEST_START} ≤ test，"
          f"窗口 {start:%Y-%m}~{end:%Y-%m}）")
    print("=" * 100)
    ev = pd.DataFrame(eval_rows)
    print(fmt_table(ev.pivot_table(index="model", columns="metric",
                                   values="value", aggfunc="first")))
    print("\n干预增益曲线（拦前 k% 风险单）：")
    for name in models:
        print(f"\n[{MODEL_CN[name]}]")
        g = [x for x in gain_rows if x.iloc[0]["model"] == name][0]
        print(fmt_table(g[["top_pct", "n_orders", "captured", "recall",
                           "precision_", "lift", "cost_per_bad"]]))
    print("\n特征重要性 Top10（logreg=标准化系数绝对值，hgb=测试集置换重要性）：")
    for name in models:
        top = importance[importance["model"] == name].nsmallest(10, "rank_no")
        print(f"\n[{MODEL_CN[name]}]")
        print(fmt_table(top[["rank_no", "feature", "importance"]]))

    # ---- 回写 --------------------------------------------------------------
    if args.dry_run:
        log.info("--dry-run：不写库。")
        return

    for t in ("ads_s4_eval", "ads_s4_gain", "ads_s4_importance"):
        if not table_exists(engine, t):
            raise SystemExit(f"{t} 不存在，请先执行 sql/09_s4_差评预警特征.sql")

    now = pd.Timestamp.now().strftime("%Y-%m-%d %H:%M:%S")
    ev_out = ev.copy()
    ev_out["value"] = ev_out["value"].astype(float)
    ev_out["updated_at"] = now
    write_table(engine, ev_out, "ads_s4_eval", log=log)

    gain_out = pd.concat(gain_rows, ignore_index=True)
    gain_out["updated_at"] = now
    write_table(engine, gain_out, "ads_s4_gain", log=log)

    imp_out = importance[["model", "feature", "importance", "rank_no"]].copy()
    imp_out["updated_at"] = now
    write_table(engine, imp_out, "ads_s4_importance", log=log)

    log.info("S4-01 完成。")


if __name__ == "__main__":
    main()
