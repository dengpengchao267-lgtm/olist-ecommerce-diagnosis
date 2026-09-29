# Olist 电商平台经营诊断与增长策略分析

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Python](https://img.shields.io/badge/Python-3.11%2B-blue)](https://www.python.org/)
[![MySQL](https://img.shields.io/badge/MySQL-8.0-orange)](https://www.mysql.com/)
[![Tableau](https://img.shields.io/badge/Tableau-ready-blueviolet)](https://www.tableau.com/)

> **基于 Kaggle *Brazilian E-Commerce Public Dataset by Olist* 的端到端业务分析项目**——从数据清洗、口径建模，到增长诊断、模型预警、策略评估，6 大专题完整闭环。

---

## 📌 项目亮点

| 专题 | 核心问题 | 关键数字 |
|---|---|---|
| **S2** GMV 增长归因 | 增长靠拉新还是客单价？ | 拉新贡献 **104.2%**、客单价 **−5.3%**、2017-11 后断崖 |
| **S3** 履约体验瓶颈 | 评分断崖在哪？瓶颈在谁？ | **第 3 天断崖 −1.63 分**、**86.2% 在承运商** |
| **S4** 差评预警模型 | 差评能提前拦吗？ | HGB PR-AUC **0.336**、拦前 1% 精度 **71%** |
| **S5** 价值分层 | 差评会让人不复购吗？ | **证伪 p=0.4803**、复购是"人格特质"不是体验结果 |
| **S6** 策略效果评估 | 干预值不值钱？ | **P3 ROI 1.404 最优**、**P2 亏损 −9,381**（修正 S4） |

> **一句话**：平台正在"用规模换利润、用体验换增长"——S6 给出的处方是**先做延迟补偿券（R$20K 净收益），同时用"首单 3 件+"作为复购种子人群抓手**。

完整结论见 [`docs/总报告_Olist电商经营诊断与增长策略分析.md`](docs/总报告_Olist电商经营诊断与增长策略分析.md)。

---

## 🏗️ 项目结构

```
olist_ecommerce_analysis/
├── README.md                          ← 你正在看的
├── LICENSE                            ← MIT
├── 项目框架.md                        ← 项目设计与原则
├── docs/                              ← 报告层
│   ├── 口径与指标字典.md
│   ├── 技术栈分工说明.md
│   ├── common_函数手册.md
│   ├── S1~S6_执行方案.md              ← 6 份执行方案
│   ├── S1~S6_结果分析报告.md          ← 6 份专题结果
│   └── 总报告_Olist电商经营诊断与增长策略分析.md  ← 整合总报告 ⭐
├── sql/                               ← 数据层（MySQL 8.0）
│   ├── README.md                      ← 运行顺序与依赖关系
│   ├── 00~04*.sql                     ← ods → dwd → dws → ads 建仓
│   ├── 04b_隐式转换验收.sql           ← 静默错误捕捉
│   └── 05~11_*.sql                    ← S2~S6 专题 SQL
└── python/                            ← 计算层
    ├── README.md                      ← 运行顺序与依赖关系
    ├── requirements.txt
    ├── config.py                      ← 数据库配置与参数（统一源）
    ├── common.py                      ← 通用方法（读写、统计、CI、FDR）
    ├── sql_lint.py                    ← SQL 三层验证工具
    ├── selftest.py                    ← 60 项自检（不连库）
    └── s2~s6_0*.py                    ← 各专题主程序

---

## 🛠️ 技术栈

- **数据库**：MySQL 8.0（四层建模 ods → dwd → dws → ads，**口径统一在 SQL 层**）
- **编程语言**：Python 3.11+（统计推断、机器学习、置信区间）
- **BI 工具**：Tableau（直连 ads 层，仅呈现，不定义口径）
- **核心库**：pandas / numpy / scipy / scikit-learn / statsmodels / pymysql / sqlalchemy

---

## 🚀 快速上手

### 1. 数据准备

下载 Kaggle 数据集 [Brazilian E-Commerce Public Dataset by Olist](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce)，解压后得到 9 个 CSV 文件。

### 2. 建库与数据导入

按 `sql/README.md` 的运行顺序，依次在 MySQL 中执行：

```bash
# 在 PyCharm 数据库控制台或 MySQL CLI 粘贴执行
1. sql/00_ods_建表与导入.sql          # 建库、9 张 ods 表、导入 CSV
2. sql/00b_导入体检.sql               # 校验列错位等静默错误
3. sql/01_dwd_清洗与宽表.sql          # 清洗产出 dwd
4. sql/02_dws_主题汇总.sql            # 主题汇总
5. sql/03_ads_看板结果表.sql          # Tableau 直连的 ads 表
6. sql/04_校验与对账.sql
7. sql/04b_隐式转换验收.sql           # 必跑：抓隐式日期转换
```

### 3. 跑各专题（按 SQL → Python 顺序）

| 专题 | 跑 SQL | 跑 Python |
|---|---|---|
| S2 | `05/06/07_*.sql` | `s2_01_gmv_decomposition.py` → `s2_02` → `s2_03` → `s2_04` |
| S3 | `08_*.sql` | `s3_01_delay_impact.py` → `s3_02_bottleneck.py` |
| S4 | `09_*.sql` | `s4_01_bad_review_model.py` |
| S5 | `10_*.sql`（+`10b_策略表段_可直接粘贴.sql`） | `s5_01_rfm_cluster.py` → `s5_02_repeat_survival.py` |
| S6 | `11_*.sql` | `s6_01_strategy_eval.py`（⚠️ 依赖 s5_02 先跑完） |

### 4. 安装依赖

```bash
pip install -r python/requirements.txt
```

### 5. 自检

```bash
python python/selftest.py    # 60 项，不连库，验证手写函数与数值
python python/sql_lint.py    # SQL 静态解析
python python/sql_lint.py --explain    # 连库对每条 INSERT 跑 EXPLAIN
```

---

## 🔬 核心方法论

### 1. 三层 SQL 验证（缺一层就会漏）
1. `sqlglot` 解析（MySQL 方言）
2. `sql_lint.py` 抓列错位（UNION 分支列数、INSERT 目标列数）
3. `sql_lint.py --explain` 连库 EXPLAIN（**抓到过窗口套窗口的真 bug，sqlglot 一声不吭**）

### 2. 关键纪律
- **口径锁在 SQL 层**——Tableau 只画不定义，环形口径（如瀑布图"每段起点 = 前面所有段累加"）必须 SQL 算好
- **计算层不 round，只在展示层与写库层 round**——避免舍入污染恒等式断言
- **手写统计必须做数值验证，且必须覆盖整条调用路径**——s5_02 的 PSM 自检真空让 `logit[i:i+1]` 漏升维的 bug 溜到实跑
- **PSM 不控制 first_order_score**——评分是"延迟→复购"的中介，控制它会挡住真实效应

### 3. 反事实仿真而非 A/B 实验（S6）
- Olist 历史数据里平台**从没跑过延迟补偿实验** ⇒ **S6 是反事实仿真**
- 两个数据里不存在的参数（p 挽回率、v 差评价值）**做成 (p × v) 二维敏感性网格**，输出**盈亏平衡条件**而不是单点 ROI
- **42 个参数组合中 P3 永远最优、P2 永远最差——排序不依赖参数取值**

---

## 📊 主要结论速览

### 业务侧（给老板）
1. **延迟做补偿券**（P3）：R$20K 净收益、ROI 1.404、覆盖 7,661 单
2. **风险拦截不能做**（P2）：ROI 0.830 亏损——**修正了 S4 的建议**
3. **预算上限 R$65K**——给多了花不出去（**瓶颈不是钱，是可干预池规模**）
4. **首单 3 件+ 是唯一强复购信号**——下单时就能识别，最值得运营
5. **不要按品类做包装改进**——S3 数据不支持；地理问题不是商品问题

### 技术侧（项目方法论）
1. **GMV 拆解**：三因子恒等式 + MK 趋势分段检验
2. **因果推断**：KM 生存分析 + PSM 1:1 匹配
3. **机器学习**：HGB + 边际成本曲线 + k% 拦截
4. **不确定性量化**：(p × v) 二维敏感性 + 盈亏平衡点
5. **工程纪律**：60 项 selftest + 三层 SQL 验证 + 口径锁 SQL

---

## 📝 文档导航

| 文档 | 内容 |
|---|---|
| [`docs/总报告_*.md`](docs/) | **项目总报告（推荐先读）** |
| [`docs/S*_结果分析报告.md`](docs/) | 6 份专题结果分析（含数字、图表、追问） |
| [`docs/S*_执行方案.md`](docs/) | 6 份专题执行方案（含设计决策、口径选择） |
| [`sql/README.md`](sql/) | SQL 脚本运行顺序与依赖 |
| [`python/README.md`](python/) | Python 脚本运行顺序与依赖 |

---

## 📜 License

本项目采用 [MIT License](LICENSE)。

数据源 [Brazilian E-Commerce Public Dataset by Olist](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce) 采用 [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/)（仅用于学术与演示，不用于商业用途）。