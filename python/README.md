# S2 Python 脚本说明

GMV 拆解与增长归因（专题 S2）的统计计算层。

**分工前提**：SQL 负责取数与聚合，Python 只做 SQL 算不出来的事——分解、检验、区间估计。
最终图表全部在 Tableau，本目录不产出交付图。

---

## 一、目录

```
python/
├─ config.py                     连接串 DB_URL + 分析参数（改这里，不用翻脚本）
├─ common.py                     公共模块：读写封装、面板数据、LMDI、Bootstrap、MK、断点检测
├─ s2_01_gmv_decomposition.py    三因子 LMDI 分解 + Bootstrap  → ads_gmv_decomposition
├─ s2_02_trend_breakpoint.py     趋势检验 + 断点检测           → ads_gmv_trend
├─ s2_03_mix_effect.py           品类/州 结构贡献度            → ads_gmv_structure
├─ s2_04_aov_mix.py             ★ AOV 五效应分解（价格 vs 结构）→ ads_aov_*（三张）
├─ s3_01_delay_impact.py         S3：延迟对评分的影响（MW + 剂量反应）→ ads_s3_score_diff / ads_s3_delay_impact
├─ s3_02_bottleneck.py           S3：品类/州瓶颈 + 环节耗时 + 趋势    → ads_s3_bottleneck / ads_s3_stage
├─ s4_01_bad_review_model.py     S4：差评预警（logreg + HGB，时间外推）→ ads_s4_eval / ads_s4_gain / ads_s4_importance
├─ s5_01_rfm_cluster.py          S5：R/F/M 分层 vs K-means 交叉验证（轮廓系数选 K、ARI）
├─ s5_02_repeat_survival.py      S5：复购率（Wilson CI+FDR）+ KM 生存分析 + PSM 效应 → 三张 ads_s5_*
├─ s6_01_strategy_eval.py        S6：三条策略的反事实 ROI + (p×v) 二维敏感性 + 预算分配 → 三张 ads_s6_*
├─ sql_lint.py                   SQL 结构校验：抓「列错位 / UNION 分支列数不一致」（语法解析抓不到）
├─ examples_sql_io.py            读写速查：四种读写方式各跑一遍
├─ selftest.py                   方法自检（不连数据库，当前 60 项）
└─ requirements.txt
```

## 二、MySQL 读写：四种写法

全部集中在 `common.py` 里，跑一遍 `python examples_sql_io.py` 就能看到效果。

```python
from common import get_engine, read_table, read_sql, write_df, write_table

# 1. 创建引擎对象（连接串在 config.py 的 DB_URL）
engine = get_engine()

# 2. 读全表 —— 等价于 pd.read_sql('ads_gmv_factors', engine)
df = read_table(engine, "ads_gmv_factors")

# 3. 读指定数据 —— 表大或只要一部分时用；:参数 占位，别用 f-string 拼 SQL
df2 = read_sql(engine,
               "SELECT * FROM ads_gmv_trend WHERE stat_month >= :since",
               since="2017-01-01")

# 4a. 写入（灌第一批数据）—— 等价于 df.to_sql('t', engine, index=False, if_exists='append')
write_df(engine, df2, "my_table", if_exists="append")

# 4b. 写入（结果表回写）—— 先删后插，重复跑不翻倍
write_table(engine, df2, "ads_gmv_decomposition")
```

**为什么结果表要用 `write_table` 而不是直接 `append`**：

| 情形 | 直接 `if_exists='append'` 的后果 |
|---|---|
| 表上有主键（如 `(stat_month, factor)`） | 第二次跑报 `Duplicate entry` |
| 表上没主键 | **不报错，但行数悄悄翻倍** —— 更危险 |

`write_table` 多做的唯一一件事就是先 `DELETE`，然后照样 append。代价是一次删除，换来的是可重复执行。

**两个必须记住的坑**：

1. `index=False` 不能省。不写就会多出一列 `index`（0,1,2…），下次读回来还得手动删。
2. `charset=utf8mb4` 不能省。少了它，巴西地名的重音字符（`São Paulo` / `Amapá`）会乱码或直接写不进去。
3. 写入前 `common._clean_nan()` 会把 `NaN` 转成 `None`。不转的话 DECIMAL 列会收到字符串 `'nan'`——轻则报错，重则**静默写进一堆 0**（而 `NULL` 和 `0` 是两件事）。

## 三、环境准备

```bash
pip install -r requirements.txt

# 配置数据库：推荐用环境变量，不要把密码写进仓库
set OLIST_DB_HOST=127.0.0.1
set OLIST_DB_USER=root
set OLIST_DB_PASSWORD=你的密码
set OLIST_DB_NAME=olist_dw
```
（Windows CMD 用 `set`，PowerShell 用 `$env:XXX="..."`，bash 用 `export`。）
不改环境变量也行——直接编辑 `config.py` 里的默认值，但**别把带密码的版本提交到 Git**。

**先跑自检**，确认方法层没问题再去连库：

```bash
python selftest.py
# 期望输出最后一行：全部通过
```
它验证的是：LMDI 三项之和恒等于 ΔGMV、Bootstrap 每一轮内部也满足这个恒等式、
Mann-Kendall 的方向判定正确且能抗异常值、断点检测能检出突变且不对常数序列误报、
结构贡献度加总等于整体增长率。**这些性质不过，后面的数不用看。**

## 四、运行顺序

```bash
# 1. SQL 侧：建表 + 填充基础列（必须先跑，python 要往这几张表回写）
#    在 DataGrip / Workbench 里执行 sql/05_s2_结构下钻.sql
#    跑完先看第五节的"截面勾稽"：三个差值必须严格为 0.00

# 2. 三因子归因
python s2_01_gmv_decomposition.py --dry-run   # 先看结果，不写库
python s2_01_gmv_decomposition.py             # 确认无误后回写

# 3. 趋势与断点
python s2_02_trend_breakpoint.py --dry-run
python s2_02_trend_breakpoint.py

# 4. 结构贡献度
python s2_03_mix_effect.py --dry-run
python s2_03_mix_effect.py

# 5. AOV 五效应分解（S2 收尾，回答"客单价为什么跌"）
#    先执行 sql/06_s2_AOV结构拆解.sql 建三张空表
python s2_04_aov_mix.py --dry-run
python s2_04_aov_mix.py

# 6. S3 履约体验（先执行 sql/08_s3_履约链路.sql，末节 4 条自检必须全过）
python s3_01_delay_impact.py --dry-run
python s3_01_delay_impact.py
python s3_02_bottleneck.py --dry-run
python s3_02_bottleneck.py

# 7. S4 差评预警（先执行 sql/09_s4_差评预警特征.sql，需要 scikit-learn ≥1.2）
python s4_01_bad_review_model.py --dry-run
python s4_01_bad_review_model.py

# 8. S5 价值分层（先执行 sql/10_s5_价值分层.sql，末节 9 条自检必须全过）
python s5_01_rfm_cluster.py --dry-run
python s5_01_rfm_cluster.py
python s5_02_repeat_survival.py --dry-run
python s5_02_repeat_survival.py

# 9. S6 策略效果评估（先执行 sql/11_s6_策略效果评估.sql）
#    ⚠️ 必须等 s5_02 跑完（它回写的 ads_s5_experience_effect 是 S6 的输入之一）
python s6_01_strategy_eval.py --dry-run
python s6_01_strategy_eval.py

# 10. 方法自检（60 项，不连库）
python selftest.py
```

所有脚本都支持 `--dry-run`（只算不写）。**第一次跑一律先 dry-run。**

### 改过 SQL 之后先跑一次结构校验

```bash
python sql_lint.py                       # 校验 sql/ 下全部文件
python sql_lint.py ../sql/10_s5_价值分层.sql   # 只校验一个文件
python sql_lint.py --explain             # 再加一道：连库 EXPLAIN 做语义校验
```

它检查的是 `sqlglot` **抓不到**的那类错：CREATE TABLE 列数与 INSERT 目标列数不一致、
UNION ALL 各分支列数不一致（最容易漏——只在第一条分支里加了一列）。
这两类错 MySQL 报的错往往指向别处，排查很费时间。
有 `SKIP` 时说明该处投影含 `*` 且源表未知，**要人工确认**，不能当成通过。

`--explain` 是**第二道防线**，专抓"语法合法但 MySQL 拒绝执行"的写法：
`sqlglot` 只保证语法，判不了语义。已被它抓到过的真 bug：
窗口函数套窗口函数 `SUM( ... SUM(x) OVER () ... ) OVER ()`（MySQL 报 `[HY000][3593]`，
`sqlglot` 一声不吭）。加了 `--explain` 后这类错在跑之前就报出来。
它只 `EXPLAIN`、不执行、不写库；要求相关表已存在（跨文件继承表的语句不适用）。

常用参数：
| 参数 | 作用 |
|---|---|
| `--dry-run` | 只计算并打印，不回写数据库 |
| `--b 2000` | 调整 Bootstrap 次数（`s2_02` 没有这个参数） |
| `--last 3` | 只处理最近 3 个月份对（调试用，`s2_01`） |
| `--dims category` | 只算某个维度（`s2_03`） |
| `--max-breaks 2` | 限制断点个数（`s2_02`） |
| `--top 15` | 品类明细打印条数（`s2_04`） |

## 五、每个脚本在回答什么

| 脚本 | 问题 | 关键方法 | 产出表 |
|---|---|---|---|
| `s2_01` | 是量的问题还是价的问题？ | LMDI-I 加法分解 + 按天分块 Bootstrap | `ads_gmv_decomposition` |
| `s2_02` | 从哪个月开始变的？是不是噪音？ | Mann-Kendall 趋势检验 + 二分分割断点检测 | `ads_gmv_trend` |
| `s2_03` | 具体是哪些品类、哪些州？ | 可加贡献度分解 + 按天分块 Bootstrap | `ads_gmv_structure` |
| `s2_04` | **客单价为什么跌？是降价还是换结构？** | **AOV=P×N+f 五效应精确分解** + 月级 Bootstrap + 符号检验 | `ads_aov_*` 三张 |

### `s2_04` 的分解链（S2 收尾的核心分析）

`ΔAOV` 被拆成五个效应，**五项之和严格等于 ΔAOV**（有断言把关）：

```
AOV = P × N + f          P=件均价  N=单均件数  f=单均运费
      ↓
ΔAOV = 价格效应 + 结构效应 + 件数效应 + 运费效应 + 交叉项
         N0·Σs_i0Δp_i   N0·Σp_i0Δs_i   P0·ΔN    Δf
```

- **价格效应**为负 → 各品类自己降价了 → 动作落在**定价与折扣**
- **结构效应**为负 → 低单价品类占比上升了 → 动作落在**品类结构运营**

## 七、常见报错

| 报错 | 原因 | 解决 |
|---|---|---|
| `Access denied for user` | 密码/用户名不对 | 改 `config.py` 或设环境变量 `OLIST_DB_PASSWORD` |
| `Can't connect to MySQL server` | 服务没起 / host 端口不对 | 确认 MySQL 在跑；注意 `127.0.0.1` 与 `localhost` 在 Windows 上行为可能不同 |
| `Table 'olist_dw.dwd_orders' doesn't exist` | 没跑 `01_dwd` | 按 README 顺序先建 ods/dwd |
| `ads_gmv_trend 不存在` | 没跑 `sql/05_s2_结构下钻.sql` | 先跑 SQL，再跑 Python |
| `勾稽失败` 报错并中断 | 分解有残差，或口径与 SQL 不一致 | **不要改容差放过它。**说明某一层口径漂了，回查 `--dry-run` 的打印 |
| Bootstrap 很慢 | 次数太大 | `--b 300` 先看结果，最终版本再跑 1000 次 |
| 中文输出乱码（Windows） | 控制台编码 | `set PYTHONIOENCODING=utf-8` |

## 八、验收标准

S2 的脚本层验收，只有四条：

1. `selftest.py` 全部通过；
2. 三个脚本的勾稽断言全部通过（日志里出现"勾稽通过"）；
3. `ads_gmv_decomposition` / `ads_gmv_trend` / `ads_gmv_structure` 三张表有数据；
4. 各月三因子贡献占比之和 = 1（脚本已断言）。

**注意：「跑通」不等于「结论对」。** 最终结论必须由第四条保证——
每个月三个因子的贡献占比加起来必须是 100%，差一点都不行。
