"""数据库连接配置。

改这一处就行：把 DB["password"] 换成你的密码（或设环境变量 OLIST_DB_PASSWORD）。
"""
from __future__ import annotations

import os


def _env(key: str, default: str) -> str:
    return os.environ.get(key, default)


# ---- 连接参数 -------------------------------------------------------------
DB = {
    "host": _env("OLIST_DB_HOST", "127.0.0.1"),
    "port": _env("OLIST_DB_PORT", "3306"),
    "user": _env("OLIST_DB_USER", "root"),
    # ★ 改成你的密码，或设置环境变量 OLIST_DB_PASSWORD
    "password": _env("OLIST_DB_PASSWORD", "123456"),
    # ⚠️ 库名必须是 sql_name：本机 olist_dw 是早期只导了一半的库（缺 dwd_orders），
    #    全部 ods/dwd/dws/ads 表与已冻结的分析结果都在 sql_name 里。改错库会静默读出空表。
    "database": _env("OLIST_DB_NAME", "sql_name"),
}

# ---- 连接串（就是 create_engine 里用的那一条）-----------------------------
# 注意：mysql+pymysql 是驱动名，charset=utf8mb4 必须带，
#       否则巴西地名的重音字符（São Paulo / Amapá）会乱码或写不进去。
DB_URL = (
    f"mysql+pymysql://{DB['user']}:{DB['password']}"
    f"@{DB['host']}:{DB['port']}/{DB['database']}?charset=utf8mb4"
)

# 一次性打印出来核对（不含密码）
DB_URL_SAFE = (
    f"mysql+pymysql://{DB['user']}:***"
    f"@{DB['host']}:{DB['port']}/{DB['database']}?charset=utf8mb4"
)


# ---- 分析参数（改这里，不用翻脚本）--------------------------------------
# 完整月判定的订单量阈值：必须与 sql/05_s2_结构下钻.sql 里的 500 一致
MIN_ORDERS_FOR_COMPLETE_MONTH = 500

# Bootstrap 重抽样次数
BOOTSTRAP_B = 1000        # s2_01 三因子分解
BOOTSTRAP_B_STRUCT = 500  # s2_03 结构贡献度（维度多，降到 500 控制耗时）

# 随机种子：固定住，保证结果可复现
# ⚠️ 必须与运行目录 D:\pycharm3\olist\config.py 一致（20260820），
#    否则 S2~S4 已冻结的 Bootstrap 区间、S4 模型数值无法复现。
RANDOM_SEED = 20260820

# 显著性水平
ALPHA = 0.05

# ---- S3 履约体验参数 ------------------------------------------------------
# 右截断护栏：月度送达率低于此值的月份从趋势检验中剔除
# （窗口末端有"已下单未送达"的订单，它们不在履约口径里，会低估延迟率）
S3_TRUNCATION_RATIO = 0.90

# 品类/州进入延迟率显著性检验的最小履约订单数（低于它只报点估计，不报检验）
S3_MIN_ORDERS_DIM = 100

# S3 按天分块 Bootstrap 次数
BOOTSTRAP_B_S3 = 500

# ---- S4 差评预警参数 ------------------------------------------------------
# 时间外推划分：该月（含）之后进测试集，之前进训练集（不做随机划分！）
S4_TEST_START = "2018-05"

# 干预成本假设：每单主动关怀优惠券面额（巴西雷亚尔），仅用于增益表成本换算
S4_COUPON_COST_BRL = 15.0

# 增益曲线取的头部比例（%）
S4_TOP_PCTS = (1, 2, 5, 10, 20, 30, 50)


# ---- S5 价值分层参数 ------------------------------------------------------
# 【口径提示】以下三行必须与 sql/10_s5_价值分层.sql 保持一致：
#   R 切点 180 天、F 切点 2 单、M 切点取中位数（SQL 内用行号法算，无需参数）
# 该脚本末尾的自检 7.2 会验证八格齐全，可用来发现两处不一致。
S5_R_ACTIVE_DAYS = 180      # recency <= 该值 → 活跃
S5_F_REPEAT_ORDERS = 2      # order_cnt >= 该值 → 复购

# KM 生存分析的最大观察天数：超过它的部分按右删失处理
# （客户进入观察期的时间不同，需要一个统一横轴；365 天覆盖了 96% 以上的复购发生窗口）
S5_KM_MAX_DAYS = 365

# "180 天复购"限定口径，用于 PSM 的结果变量与稳健性对照
S5_REPEAT_HORIZON_DAYS = 180

# 维度进入复购率显著性检验的最小客户数（低于它只报点估计）
S5_MIN_CUSTOMERS_DIM = 200

# K-means 候选簇数（最终由轮廓系数选）
S5_K_RANGE = (2, 3, 4, 5, 6)

# PSM 参数
S5_PSM_CALIPER = 0.05       # 倾向得分 logit 尺度上的卡尺（约 0.2×SD 的常见取值）
S5_PSM_MIN_TREAT = 200      # 处理组少于该数则不做匹配，只报描述性对比
BOOTSTRAP_B_S5 = 500        # PSM 效应的 Bootstrap（按匹配对重抽）次数


# ---- S6 策略效果评估参数 ---------------------------------------------------
# ⚠️ S6 是**反事实仿真**，不是 A/B 实验（Olist 历史数据里平台从未跑过补偿实验）。
#    下面三个参数是「主测算用哪一组取值」，所有结论都必须配敏感性分析一起看。
#
# 挽回率 p：策略执行后「问题被真正消除」的比例。这是**假设值**。
#   注意 p 对三条策略含义一致：p=1.0 表示该策略完全消除了延迟带来的差评增量。
#   现实预期：P1 提速最难做满（承运商不可控）、P3 事后补偿最难见效（S5 已证差评不驱动复购）。
S6_BASE_RESCUE_RATE = 0.5

# 差评单位价值 v（R$）：主测算直接用 S4 实测的「拦前 10% 单位干预成本」，
#   这是唯一有数据支撑的锚点。v 属于品牌/声誉范畴，本身没有客观值 ⇒ 必须做敏感性。
S6_BASE_BAD_VALUE = 40.75

# 二维敏感性网格（p × v），用来画盈亏平衡线
S6_RESCUE_RATES = (0.1, 0.2, 0.3, 0.4, 0.5, 0.7, 1.0)
S6_BAD_VALUES = (20.0, 30.0, 40.75, 60.0, 80.0, 100.0)

# 预算档位（R$），用于产出「给定预算怎么分」的分配方案
S6_BUDGET_LEVELS = (50_000, 100_000, 200_000, 500_000)

# 只有「真正消除延迟」的策略才享受复购挽回收益。
#   依据 S5：差评→复购 log-rank p=0.4803（不成立），所以「缓解差评」类策略（P2/P3）
#   不能声称挽回了复购 —— 强行加进来会虚增收益，这是本专题最容易犯的错。
S6_REPEAT_ELIGIBLE = ("p1_expedite",)

