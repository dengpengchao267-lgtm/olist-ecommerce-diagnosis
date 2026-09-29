# `common.py` 函数手册

`olist_ecommerce_analysis/python/common.py` 是 S2 三个脚本共用的公共模块。
本文逐个说明其中每个函数的作用、每个参数的含义、返回值，以及"为什么这么写"。

> 阅读顺序建议：先看第三节的**函数总览表**建立全局印象，需要细节时再翻第四节。
> 第一次读可以跳过标注「内部」的私有函数。

---

## 一、这个模块是干什么的

一句话：**把 S2 需要重复用到的五件事集中到一个文件里**。

| 它负责 | 对应章节 |
|---|---|
| 连数据库、打日志 | 四·1 |
| 读表 / 写表（含幂等写入） | 四·2、四·3 |
| 把明细整理成分析用的"面板数据" | 四·4 |
| 统计方法：LMDI 分解、Bootstrap、MK 检验、断点检测 | 四·5 ~ 四·7 |
| 渲染和断言的小工具 | 四·8 |

**它不负责什么**（这条更重要）：

- 不写业务 SQL 的清洗逻辑 —— 那是 SQL 层的活
- 不画图 —— 最终图表全在 Tableau
- 不定义口径 —— 口径在 `docs/口径与指标字典.md`，这里只是引用

一句话概括设计原则：**SQL 负责取数与聚合，Python 只做 SQL 算不出来的事。**

---

## 二、它依赖的配置项（都在 `config.py`）

`common.py` 顶部从 `config` 导入了 5 个东西，另有两个常量被 `s2_01` / `s2_03` 直接使用。

| 名称 | 类型 | 值 | 被谁用 | 含义 |
|---|---|---|---|---|
| `DB_URL` | str | — | `get_engine()` | 完整连接串：`mysql+pymysql://用户:密码@主机:端口/库?charset=utf8mb4` |
| `DB` | dict | — | `table_exists()` | 连接参数字典，目前只用来取 `DB["database"]` 拼 `information_schema` 的查询条件 |
| `MIN_ORDERS_FOR_COMPLETE_MONTH` | int | `500` | `month_panel()` | 完整月判定阈值。**必须与 `sql/05_s2_结构下钻.sql` 里的 500 一致**，否则 Python 与 SQL 的完整月判断会打架 |
| `RANDOM_SEED` | int | `20260820` | `bootstrap_decomposition()` 的默认 `seed` | 随机种子。固定住才能"我这边跑出来是这个数，你也能复现"。⚠️ 必须与运行目录 `D:\pycharm3\olist\config.py` 一致，否则 S2~S4 已冻结的 Bootstrap 区间复现不出来 |
| `ALPHA` | float | `0.05` | `ci_bounds()`、`mann_kendall()` | 显著性水平。取 0.05 即 95% 置信区间 / p < 0.05 判为显著 |
| `BOOTSTRAP_B` | int | `1000` | `s2_01` 的 `--b` 默认值 | 三因子分解的重抽样次数 |
| `BOOTSTRAP_B_STRUCT` | int | `500` | `s2_03` 的 `--b` 默认值 | 结构贡献度的重抽样次数（维度多，降一半控耗时） |

---

## 三、函数总览

| # | 函数 | 一句话作用 | 分类 |
|---|---|---|---|
| 1 | `setup_logging(name)` | 初始化日志并返回一个 logger | 连接与日志 |
| 2 | `get_engine()` | 按 `DB_URL` 创建数据库引擎 | 连接与日志 |
| 3 | `read_table(engine, table_name)` | 读整张表 | 读 |
| 4 | `read_sql(engine, sql, **params)` | 按自定义 SQL 读，支持参数占位 | 读 |
| 5 | `table_exists(engine, table_name)` | 判断表是否存在 | 读 |
| 6 | `write_df(engine, df, table_name, ...)` | 把 DataFrame 写进 MySQL | 写 |
| 7 | `write_table(engine, df, table_name, ...)` | **先删后插**的幂等写入 | 写 |
| 8 | `_clean_nan(df)` | 把 NaN/NaT 转成 None（内部） | 写 |
| 9 | `month_panel(engine)` | 月度面板：GMV、三因子、完整月标记 | 面板数据 |
| 10 | `complete_window(panel, log)` | 算出有效分析区间 `[起, 止]` | 面板数据 |
| 11 | `month_pairs(panel, start, end)` | 列出区间内相邻的月份对 | 面板数据 |
| 12 | `daily_order_panel(engine)` | 日 × 客户 的下单明细 | 面板数据 |
| 13 | `daily_dim_panel(engine, dim_type)` | 日 × 维度的 GMV | 面板数据 |
| 14 | `_log_mean(a, b)` | 对数平均（LMDI 的核，内部） | 分解 |
| 15 | `lmdi_additive(v0, v1, x0, x1)` | LMDI 三因子加法分解 | 分解 |
| 16 | `bootstrap_decomposition(daily, month0, month1, b, seed)` | 按天分块 Bootstrap | 分解 |
| 17 | `ci_bounds(samples, alpha)` | 按列取百分位置信区间 | 分解 |
| 18 | `mann_kendall(x)` | Mann-Kendall 趋势检验 | 趋势 |
| 19 | `log_ols_slope(y)` | 对数序列的 OLS 斜率 | 趋势 |
| 20 | `binary_segmentation(y, min_size, max_breaks)` | 均值变点检测（二分分割） | 趋势 |
| 21 | `fmt_table(df, floatfmt)` | 把 DataFrame 打成文本表 | 工具 |
| 22 | `check(cond, msg, log)` | 勾稽断言，不过就中止 | 工具 |
| 23 | `prep(m)` | 把一个月整理成"每天一个块"（内部·**内嵌**在 `bootstrap_decomposition` 里） | 分解 |
| 24 | `sse(seg)` | 一段序列的残差平方和（内部·**内嵌**在 `binary_segmentation` 里） | 趋势 |

> **一共 24 个 `def`**：22 个在模块顶层（其中 `_clean_nan`、`_log_mean` 以下划线开头，是内部函数），
> 2 个内嵌在其他函数内部（`prep`、`sse`，外部调不到）。用 `grep -n "^\s*def " common.py` 可以核对。

模块级还有一个常量字典 `DIM_SQL`，见 4.13。

---

## 四、逐个详解

### 4.1 连接与日志

#### `setup_logging(name)`

```python
def setup_logging(name: str) -> logging.Logger:
```

**作用**：配置全局日志格式（`时间 | 级别 | 消息`），并返回一个具名 logger。

| 参数 | 类型 | 含义 |
|---|---|---|
| `name` | str | logger 名字，一般传脚本短名如 `"s2-01"`，只影响日志里的标识 |

**返回**：`logging.Logger`

**示例**：
```python
log = setup_logging("s2-01")
log.info("连接 %s/%s", host, database)
log.warning("跳过缺失月份")
```

**备注**：内部调用的是 `logging.basicConfig`，**同一进程内只有第一次调用生效**。所以只在脚本的 `main()` 开头调一次。

---

#### `get_engine()`

```python
def get_engine() -> Engine:
```

**作用**：把 `config.DB_URL` 交给 SQLAlchemy 的 `create_engine`，返回数据库引擎对象。后续所有读写都靠它。

**参数**：无。

**返回**：`sqlalchemy.engine.Engine`

**示例**：
```python
engine = get_engine()
# 等价于手写：
# engine = create_engine('mysql+pymysql://root:密码@127.0.0.1:3306/olist_dw?charset=utf8mb4')
```

**备注**：内部固定了两个参数，都不是可选项——

- `pool_pre_ping=True`：取连接前先探活。脚本跑几分钟后 MySQL 可能已经断掉空闲连接，不探活就会在某个不确定的位置突然报错。
- `future=True`：使用 SQLAlchemy 2.0 的 API 风格。

---

### 4.2 读数据

#### `read_table(engine, table_name)`

```python
def read_table(engine: Engine, table_name: str) -> pd.DataFrame:
```

**作用**：读整张表，最省事的读法。

| 参数 | 类型 | 含义 |
|---|---|---|
| `engine` | Engine | `get_engine()` 的返回值 |
| `table_name` | str | 表名，**不用加库名**（库已经在连接串里指定了） |

**返回**：`pd.DataFrame`，列名与表字段一致

**示例**：
```python
df  = read_table(engine, "ads_gmv_factors")
trend = read_table(engine, "ads_gmv_trend")
```

**备注**：表大时别用——它会把整表拉进内存。本项目里 `dwd_orders` 有 99,441 行、`dwd_order_items` 有 112,650 行，读它们要用 `read_sql` 自己加条件。

---

#### `read_sql(engine, sql, **params)`

```python
def read_sql(engine: Engine, sql: str, **params) -> pd.DataFrame:
```

**作用**：按自定义 SQL 读，支持 `:名字` 占位符。

| 参数 | 类型 | 含义 |
|---|---|---|
| `engine` | Engine | 引擎对象 |
| `sql` | str | SQL 语句，占位符写成 `:参数名` |
| `**params` | 任意 | 键值对，键 = 占位符名字，值 = 实际取值。可以一个都不传 |

**返回**：`pd.DataFrame`

**示例**：
```python
df = read_sql(engine,
              "SELECT * FROM ads_gmv_trend WHERE stat_month >= :since",
              since="2017-01-01")
```

**备注**：**不要用 f-string 拼 SQL**。

```python
# ✗ 别这么写
read_sql(engine, f"SELECT * FROM t WHERE m >= '{x}'")
```
拼错了 SQL 不会报错，只会给你一个看起来正常的错数据——这和之前那个 `\r` 是同一类问题：**静默失败最贵**。

---

#### `table_exists(engine, table_name)`

```python
def table_exists(engine: Engine, table_name: str) -> bool:
```

**作用**：查 `information_schema.TABLES`，判断某张表是否存在。用来在回写前给出一句人话报错，而不是让 `to_sql` 抛一个难懂的异常。

| 参数 | 类型 | 含义 |
|---|---|---|
| `engine` | Engine | 引擎对象 |
| `table_name` | str | 表名 |

**返回**：`bool`（存在为 `True`）

**示例**：
```python
if not table_exists(engine, "ads_gmv_structure"):
    raise SystemExit("ads_gmv_structure 不存在，请先执行 sql/05_s2_结构下钻.sql")
```

**备注**：库名是从 `DB["database"]` 取的，所以调用方不用关心当前连的是哪个库。

---

### 4.3 写数据

#### `write_df(engine, df, table_name, if_exists="append", index=False, log=None)`

```python
def write_df(engine, df, table_name, if_exists="append", index=False, log=None) -> int:
```

**作用**：把 DataFrame 写进 MySQL。等价于手写 `df.to_sql(表名, engine, index=False, if_exists='append')`。

| 参数 | 类型 | 默认 | 含义 |
|---|---|---|---|
| `engine` | Engine | — | 引擎对象 |
| `df` | DataFrame | — | 要写入的数据 |
| `table_name` | str | — | 目标表名 |
| `if_exists` | str | `"append"` | `"append"` 追加 ／ `"replace"` 删表重建 ／ `"fail"` 表存在就报错 |
| `index` | bool | `False` | **是否把 DataFrame 的行号也写成一列**。必须是 `False`，否则表里多出一列 `index`（0,1,2…），下次读回来还得手动删 |
| `log` | Logger \| None | `None` | 传了就打一行日志，不传就静默写入 |

**返回**：`int`，写入行数

**示例**：
```python
n = write_df(engine, df, "tmp_demo", if_exists="replace")
```

**备注**：⚠️ **`append` 不会去重**。同一批数据跑两遍就是两倍行数。往结果表回写请用下面的 `write_table`。

---

#### `write_table(engine, df, table_name, clear_first=True, clear_where=None, clear_params=None, log=None)`

```python
def write_table(engine, df, table_name, clear_first=True,
                clear_where=None, clear_params=None, log=None) -> int:
```

**作用**：**先删后插**的幂等写入。重复执行多少次，表里的数据都只有一份。

| 参数 | 类型 | 默认 | 含义 |
|---|---|---|---|
| `engine` | Engine | — | 引擎对象 |
| `df` | DataFrame | — | 要写入的数据 |
| `table_name` | str | — | 目标表名 |
| `clear_first` | bool | `True` | 写之前是否先删除已有数据。默认开 |
| `clear_where` | str \| None | `None` | 自定义删除语句。给定时只删一部分；为 `None` 时整表清空（`DELETE FROM 表名`） |
| `clear_params` | dict \| None | `None` | `clear_where` 里的 `:参数` 取值 |
| `log` | Logger \| None | `None` | 传了就打日志 |

**返回**：`int`，写入行数（数据为空时返回 `0` 并跳过）

**示例**：
```python
# 常规用法：整表重写
write_table(engine, result, "ads_gmv_decomposition", log=log)

# 只重算最近半年：保留更早的历史
write_table(engine, recent, "ads_gmv_decomposition",
            clear_where="DELETE FROM ads_gmv_decomposition WHERE stat_month >= :m",
            clear_params={"m": "2018-01-01"},
            log=log)
```

**备注**：为什么默认要清空，两种坏结果都不能接受——

| 情形 | 直接 `append` 的后果 |
|---|---|
| 表上有主键（如 `(stat_month, factor)`） | 第二次跑报 `Duplicate entry` |
| 表上没主键 | **不报错，但行数悄悄翻倍** ← 更危险 |

代价是一次 DELETE，换来的是**可重复执行**。对一个要反复调参、反复重跑的分析脚本，这是必须的。

---

#### `_clean_nan(df)`　〔内部〕

```python
def _clean_nan(df: pd.DataFrame) -> pd.DataFrame:
```

**作用**：把 `NaN` / `NaT` 统一转成 `None`，让它写进 MySQL 时落成 `NULL`。

| 参数 | 类型 | 含义 |
|---|---|---|
| `df` | DataFrame | 待清洗的数据 |

**返回**：转换后的 DataFrame（新对象，不改原表）

**备注**：**这一步不能省**。不转的话 DECIMAL 列会收到字符串 `'nan'`——轻则报 `Incorrect decimal value`，重则**静默写进一堆 0**。而 `NULL` 和 `0` 是两件事：一种是"不知道"，一种是"等于零"，混在一起口径就废了。

用下划线开头表示它是内部函数，`write_df` 会自动调用，外部不需要直接用。

---

### 4.4 面板数据

#### `month_panel(engine)`

```python
def month_panel(engine: Engine) -> pd.DataFrame:
```

**作用**：拉出月度面板——每个月一行，含订单量、GMV、三个因子，以及"是不是完整月"的标记。是 `s2_01` / `s2_02` / `s2_03` 三个脚本的共同起点。

| 参数 | 类型 | 含义 |
|---|---|---|
| `engine` | Engine | 引擎对象 |

**返回**：DataFrame，列为

| 列 | 含义 |
|---|---|
| `stat_month` | 月份（当月 1 号），datetime |
| `order_cnt` | 当月订单总数（含未送达） |
| `delivered_cnt` | 已送达订单数 |
| `buyers` | 当月**有过任意状态订单**的去重客户数（`customer_unique_id`） |
| `gmv` | 已送达订单的 GMV，含运费 |
| `gmv_all` | 全部状态的订单总额 |
| `orders_per_buyer` | 因子2 = `delivered_cnt / buyers` |
| `aov` | 因子3 = `gmv / delivered_cnt` |
| `is_complete_month` | 1 = 完整月（`order_cnt >= 500`），0 = 不完整 |

**示例**：
```python
panel = month_panel(engine)
start, end = complete_window(panel, log)
```

**备注**：口径与 `sql/03_ads_看板结果表.sql` 里的 `ads_gmv_factors` **刻意保持一致**（连 `buyers` 的定义都一样），这样两张表能对得上。`s2_01` 里还会再跟 SQL 的结果做一次对账，偏差超过 0.01 就直接报错——**防止 Python 和 SQL 的口径悄悄漂移**。

---

#### `complete_window(panel, log=None)`

```python
def complete_window(panel, log=None) -> tuple[pd.Timestamp, pd.Timestamp]:
```

**作用**：算出有效分析区间 `[起, 止]`，把首尾不完整的月份挡在外面。

| 参数 | 类型 | 默认 | 含义 |
|---|---|---|---|
| `panel` | DataFrame | — | `month_panel()` 的输出，必须有 `stat_month` 和 `is_complete_month` 两列 |
| `log` | Logger \| None | `None` | 传了就把区间和被剔除的月份打出来 |

**返回**：`(start, end)` 两个 `pd.Timestamp`，分别是第一个和最后一个完整月

**示例**：
```python
start, end = complete_window(panel, log)
# 日志：有效分析区间：2017-01 ~ 2018-08
#       剔除不完整月份 4 个：2016-09, 2016-12, 2018-09, 2018-10
```

**备注**：这个函数存在的唯一理由是**Olist 数据的首尾是残缺的**——2016 年只有零星几个月，2018-09 之后订单骤降到个位数。直接拿全序列画趋势会得到"暴涨 + 断崖"两个假象。

规则是「取第一个完整月到最后一个完整月，**中间无论是否达标都保留**」。中间月份量低是真实的业务波动，不是数据缺失，剔掉就是篡改数据。

没有任何月份满足条件时抛 `ValueError`。

---

#### `month_pairs(panel, start, end)`

```python
def month_pairs(panel, start, end) -> list[tuple[pd.Timestamp, pd.Timestamp]]:
```

**作用**：列出区间内**相邻**的月份对，用于环比类的分解。

| 参数 | 类型 | 含义 |
|---|---|---|
| `panel` | DataFrame | `month_panel()` 的输出 |
| `start` | Timestamp | 区间起点（含） |
| `end` | Timestamp | 区间终点（含） |

**返回**：`[(上期, 本期), ...]` 的列表

**示例**：
```python
pairs = month_pairs(panel, start, end)
# [(2017-01, 2017-02), (2017-02, 2017-03), ...]
```

**备注**：返回的是 `(基期, 报告期)` 的顺序，`s2_01` 里写成 `for m0, m1 in pairs`——**m0 是上期、m1 是本期**，别搞反，否则贡献的正负号会整体颠倒。

---

#### `daily_order_panel(engine)`

```python
def daily_order_panel(engine: Engine) -> pd.DataFrame:
```

**作用**：拉出「日 × 客户」粒度的下单明细，供按天分块 Bootstrap 使用。

| 参数 | 类型 | 含义 |
|---|---|---|
| `engine` | Engine | 引擎对象 |

**返回**：DataFrame，列为

| 列 | 含义 |
|---|---|
| `d` | 日期 |
| `stat_month` | 所属月份 |
| `buyer_id` | 客户 `customer_unique_id`（32 位十六进制） |
| `buyer_code` | 客户的整数编码，由 `pd.factorize` 生成 |
| `delivered_cnt` | 该客户当天已送达的订单数 |
| `gmv` | 该客户当天已送达订单的金额合计 |

**示例**：
```python
daily = daily_order_panel(engine)
boot, boot_delta = bootstrap_decomposition(daily, m0, m1, b=1000)
```

**备注**：**为什么非要做到"日 × 客户"这么细？** 因为月度"下单客户数"是一个**去重计数**：同一客户在两天各下一单只算 1 个人。所以重抽样时不能把"每天的去重人数"直接加起来，必须保留客户身份、重新去重。

多出来的 `buyer_code` 列就是为了这个：把 32 位十六进制 ID 压成整数，后面 `np.unique` 去重能快一个数量级。

---

#### `daily_dim_panel(engine, dim_type)`

```python
def daily_dim_panel(engine: Engine, dim_type: str) -> pd.DataFrame:
```

**作用**：拉出「日 × 维度」的 GMV，供结构贡献度的按天 Bootstrap 使用。

| 参数 | 类型 | 含义 |
|---|---|---|
| `engine` | Engine | 引擎对象 |
| `dim_type` | str | 维度类型，只能是 `"category"`（品类）或 `"state"`（州） |

**返回**：DataFrame，列 `d`（日期）、`stat_month`（月份）、`dim_value`（维度取值）、`gmv`（当天该维度的已送达 GMV）

**示例**：
```python
daily_cat = daily_dim_panel(engine, "category")
daily_state = daily_dim_panel(engine, "state")
```

**备注**：两个维度的 SQL 模板放在模块级常量 **`DIM_SQL`** 里（一个 dict，键是 `"category"` / `"state"`）。传了字典里没有的键会直接抛 `KeyError`——这是刻意的，比静默返回空表好。

注意两个维度的 GMV 口径：品类维度用 `price + freight_value` 按明细汇总，州维度用 `order_amount`。两者合计都等于总 GMV——`sql/05` 最后一节的截面勾稽就是在验这件事。

---

### 4.5 LMDI 三因子分解

#### `_log_mean(a, b)`　〔内部〕

```python
def _log_mean(a: float, b: float) -> float:
```

**作用**：对数平均函数 `L(a,b) = (a−b) / (ln a − ln b)`。它是 LMDI 的核——把"两个时点之间的权重"定义成对数平均，从而消掉交叉项。

| 参数 | 类型 | 含义 |
|---|---|---|
| `a` | float | 第一个值（通常是报告期总量） |
| `b` | float | 第二个值（通常是基期总量） |

**返回**：`float`

**备注**：`a == b` 时直接返回 `a`。因为此时公式是 `0/0`，而按极限定义值就是 `a`。这一行不能省，否则每次"两期持平"都会抛除零错误。

---

#### `lmdi_additive(v0, v1, x0, x1)`

```python
def lmdi_additive(v0: float, v1: float,
                  x0: Sequence[float], x1: Sequence[float]) -> np.ndarray:
```

**作用**：LMDI-I 加法分解。把总量变化 `ΔV = V1 − V0` 完整拆成各因子的贡献之和。

| 参数 | 类型 | 含义 |
|---|---|---|
| `v0` | float | **基期总量**。本项目 = 上个月的 GMV |
| `v1` | float | **报告期总量**。本项目 = 本月的 GMV |
| `x0` | Sequence[float] | **基期各因子值**，顺序 = `(下单人数, 人均下单次数, 客单价)` |
| `x1` | Sequence[float] | **报告期各因子值**，顺序必须与 `x0` 一致 |

**返回**：`np.ndarray`，长度与因子数相同，第 `i` 个元素是第 `i` 个因子贡献的**金额**

**公式**：
```
ΔV_i = L(V1, V0) × ln(x_i1 / x_i0)
```

**示例**：
```python
x0 = (1000, 1.05, 120.0)     # 上月：1000 人、人均 1.05 单、客单 120
x1 = (1200, 1.04, 115.0)     # 本月
v0, v1 = x0[0]*x0[1]*x0[2], x1[0]*x1[1]*x1[2]
contrib = lmdi_additive(v0, v1, x0, x1)
print(contrib.sum(), v1 - v0)      # 两者必然相等
```

**备注**：

1. **`v0`/`v1` 必须大于 0**，否则抛 `ValueError`。因为要对它们取对数。
2. **`v1 == v0` 时返回全零数组**——没有变化就没有贡献。
3. 三条性质让它比朴素分解更适合归因：**无残差**（三项之和严格等于 ΔV）、**可加**、**因子对称**。对比之下 `ΔV = ΔQ·P₀ + Q₀·ΔP + ΔQ·ΔP` 会多出一个交叉项，归属给谁没有客观标准，结论会随分配方式变。
4. 各因子与总量的关系必须是 `V = x₁·x₂·x₃`（**乘法链**）。如果用加法链拆，这个函数不适用。

---

#### `bootstrap_decomposition(daily, month0, month1, b=1000, seed=RANDOM_SEED)`

```python
def bootstrap_decomposition(daily, month0, month1, b=1000, seed=RANDOM_SEED)
        -> tuple[np.ndarray, np.ndarray]:
```

**作用**：对两个月之间的 GMV 变化做**按天分块 Bootstrap**，得到各因子贡献的抽样分布，用来算置信区间。

| 参数 | 类型 | 默认 | 含义 |
|---|---|---|---|
| `daily` | DataFrame | — | `daily_order_panel()` 的输出（日 × 客户明细） |
| `month0` | Timestamp | — | **基期**月份 |
| `month1` | Timestamp | — | **报告期**月份 |
| `b` | int | `1000` | 重抽样次数。次数越多区间越稳，耗时也越长 |
| `seed` | int | `RANDOM_SEED` | 随机种子。固定住保证结果可复现 |

**返回**：二元组

| 元素 | 形状 | 含义 |
|---|---|---|
| `contrib` | `(b, 3)` | 每一轮重抽样下，三个因子各自的贡献额 |
| `delta` | `(b,)` | 每一轮重抽样下的 `ΔGMV` |

**示例**：
```python
boot, boot_delta = bootstrap_decomposition(daily, m0, m1, b=1000)
lo, hi = ci_bounds(boot)                                  # 每个因子的 95% CI
resid = np.max(np.abs(boot.sum(axis=1) - boot_delta))      # 逐轮勾稽，应 < 1e-6
```

**备注**：

- **为什么按天重抽样**：月度 GMV 是"若干天之和"，天是它自然的构成单位。按订单重抽样会打散时间结构，按天保留"天"这个整体，更贴近数据的生成方式。
- **`delta` 为什么也要返回**：用来验证 **Bootstrap 的每一轮内部**都满足"三项之和 = 该轮 ΔGMV"。这比只验总样本更严——只验总样本可能是碰巧对上。
- **客户去重**：重抽样时是"把若干天的客户编码拼起来再 `np.unique`"，**不是**把各天人数相加。
- 某轮出现零值（比如抽到的天数里没有已送达订单）时，该轮记为 `NaN`，后续 `np.nanpercentile` 会自动跳过。
- 指定的月份没有日度数据时抛 `ValueError`。

---

#### `ci_bounds(samples, alpha=ALPHA)`

```python
def ci_bounds(samples: np.ndarray, alpha: float = ALPHA) -> tuple[np.ndarray, np.ndarray]:
```

**作用**：按列取百分位置信区间——把 Bootstrap 样本变成"这个变化有多大把握是真的"。

| 参数 | 类型 | 默认 | 含义 |
|---|---|---|---|
| `samples` | ndarray | — | 形如 `(b, k)` 的样本矩阵，通常是 `bootstrap_decomposition` 的 `contrib` |
| `alpha` | float | `0.05` | 显著性水平。`0.05` → 取 2.5% 和 97.5% 分位，即 95% 区间 |

**返回**：`(lo, hi)` 两个长度 `k` 的数组，分别是各列区间的下界和上界

**示例**：
```python
lo, hi = ci_bounds(boot)                 # 95%
lo, hi = ci_bounds(boot, alpha=0.10)     # 90%（区间更窄）
```

**备注**：

- 内部用 `np.nanpercentile`（不是 `np.percentile`），这样 Bootstrap 里那些 `NaN` 轮次会被自动跳过，不用先手动清理。
- **怎么读结果**：区间**不跨 0** → 这个因子的作用是真的，可以拿去汇报；区间**跨 0** → 只能说"未观察到显著影响"，**不能说"没有影响"**。这是统计和拍脑袋的分界线。

---

### 4.6 趋势检验与断点检测

#### `mann_kendall(x)`

```python
def mann_kendall(x: Sequence[float]) -> dict:
```

**作用**：Mann-Kendall 趋势检验，判断序列是否存在**单调趋势**（含并列值修正）。

| 参数 | 类型 | 含义 |
|---|---|---|
| `x` | Sequence[float] | 时间序列，本项目传每月的 GMV（或 log GMV） |

**返回**：dict

| 键 | 含义 |
|---|---|
| `tau` | Kendall 秩相关系数，范围 −1 ~ 1；正数=上升 |
| `p_value` | 检验 p 值 |
| `trend` | `"increasing"` / `"decreasing"` / `"no trend"` / `"样本过少"` |
| `s` | MK 统计量 S（用于诊断） |
| `z` | 标准化后的 Z 值（用于诊断） |

**示例**：
```python
r = mann_kendall(panel["gmv"])
print(r["trend"], r["p_value"])
if r["p_value"] < 0.05:
    print("存在显著单调趋势")
```

**备注**：

- **为什么不用 OLS 斜率**：MK 是**非参数**检验，不要求正态分布，只看数据的相对大小顺序，**对异常值稳健**。Olist 的月度 GMV 有 11 月黑五这种尖峰，OLS 斜率会被那几个月直接带偏。
- 样本量 < 4 时返回全 `NaN` 和 `"样本过少"`，不抛异常——分段检验时某些短分段本来就不够。
- 判定显著用的是 `config.ALPHA`（0.05）。
- 序列里的 `NaN` 会被先剔除再计算。

---

#### `log_ols_slope(y)`

```python
def log_ols_slope(y: Sequence[float]) -> float:
```

**作用**：对序列取对数后做 OLS 拟合，返回斜率。**因为是对数尺度，斜率可以解释为"每期平均增长率"**。

| 参数 | 类型 | 含义 |
|---|---|---|
| `y` | Sequence[float] | 时间序列（原值，不用自己取对数，函数内部会取） |

**返回**：`float` 斜率；有效值不足 3 个时返回 `nan`

**示例**：
```python
slope = log_ols_slope(seg["gmv"])
月均增长率 = (np.exp(slope) - 1) * 100      # 单位 %
```

**备注**：只用 `y > 0` 的点（对数要求正数）。它和 `mann_kendall` 是互补的——**MK 回答"有没有趋势、是否显著"，`log_ols_slope` 回答"趋势有多快"**。报告里两个都要给：只给斜率会被问"显著吗"，只给 p 值会被问"变化多快"。

---

#### `binary_segmentation(y, min_size=3, max_breaks=4)`

```python
def binary_segmentation(y, min_size=3, max_breaks=4) -> list[int]:
```

**作用**：均值变点检测——找出序列里"水平发生跳变"的位置。用二分分割 + BIC 惩罚实现。

| 参数 | 类型 | 默认 | 含义 |
|---|---|---|---|
| `y` | Sequence[float] | — | 序列。**建议传 `log(GMV)`**：取对数后更接近同方差，且变点对应"增长率变化" |
| `min_size` | int | `3` | 一个分段最少要有的观测数。太小会导致"断点"只是在拟合噪音 |
| `max_breaks` | int | `4` | 最多找几个断点。二十来个月的序列，四个已经够多了 |

**返回**：`list[int]`，断点在数组里的**索引位置**（升序）。没有断点返回 `[]`

**示例**：
```python
s = panel[(panel.stat_month >= start) & (panel.stat_month <= end)].sort_values("stat_month")
breaks = binary_segmentation(np.log(s["gmv"].to_numpy()), min_size=3, max_breaks=4)
print([s.iloc[b]["stat_month"] for b in breaks])    # 索引 → 具体月份
```

**判定标准**：某处切分带来的残差平方和下降（gain），必须**同时**满足两个条件才认可：

1. `gain > 0`
2. `gain > BIC 惩罚 = sigma² × ln(n)`

`sigma²` 用整段残差方差估计（而不是各分段自己估），避免"切得越多越划算"的过度切分。

**备注**：

- **「退化保护」那一行不能删**（`np.ptp(y) <= 1e-12 × |mean|` 时直接返回 `[]`）。常数序列的残差平方和在浮点下是 **1e-30** 量级的噪声，而 BIC 惩罚是 **1e-31** 量级——噪声会随机超过惩罚，**凭空造出一个断点**。断点检测最怕无中生有，这种误报比漏报危险得多。（这个 bug 是 `selftest.py` 抓出来的。）
- **为什么不用 `ruptures` 库**：月度只有二十来个观测，带 BIC 惩罚的二分分割足够，而且每一步的判定都能讲清楚、无额外依赖。需要更复杂的多断点模型时再换 PELT。
- 返回的是**索引**不是月份，调用方自己映射——因为函数不应该假设调用方用的是不是月份数据。

---

### 4.7 小工具

#### `fmt_table(df, floatfmt=",.2f")`

```python
def fmt_table(df: pd.DataFrame, floatfmt: str = ",.2f") -> str:
```

**作用**：把 DataFrame 渲染成对齐的纯文本表，用于在控制台汇报结果。

| 参数 | 类型 | 默认 | 含义 |
|---|---|---|---|
| `df` | DataFrame | — | 要渲染的数据 |
| `floatfmt` | str | `",.2f"` | 浮点数的 format spec：`","` 加千分位，`.2f` 保留两位。想调精度传 `",.4f"` |

**返回**：`str` 多行文本

**示例**：
```python
print(fmt_table(result[["stat_month", "factor_cn", "contribution_amount"]]))
print(fmt_table(tail, floatfmt=",.4f"))     # 比例类指标用四位小数
```

**备注**：内部用 `pd.option_context` 临时放宽显示宽度（200 列宽 / 最多 50 列），退出时自动还原，不会污染全局设置。

---

#### `check(cond, msg, log)`

```python
def check(cond: bool, msg: str, log: logging.Logger) -> None:
```

**作用**：勾稽断言。条件成立就打一行「勾稽通过」，**不成立直接抛异常中止脚本**。

| 参数 | 类型 | 含义 |
|---|---|---|
| `cond` | bool | 断言条件。通常是"两项独立算出来的数是否相等" |
| `msg` | str | 断言说明，会出现在日志里。**要写清在比什么、差多少** |
| `log` | Logger | 日志对象 |

**返回**：`None`（失败时抛 `AssertionError`）

**示例**：
```python
# 三因子贡献之和必须严格等于 GMV 变化量
check(abs(contrib.sum() - delta) < 0.01,
      f"{m1:%Y-%m} 三因子贡献合计 = ΔGMV（{contrib.sum():.2f} vs {delta:.2f}）",
      log)
```

**备注**：**"宁可跑不完，也不能跑出错的数。"** 这是整个项目的原则——分析脚本最可怕的不是报错，而是安安静静跑完、交出一个看起来正常但错了的结果。所以宁可让它在勾稽失败处停下来。

**唯一的纪律：勾稽失败时不要放宽容差让它过去。** 那不是修 bug，那是在删掉唯一的报警器。

---

### 4.8 内嵌函数（定义在别的函数里面的两个）

这类函数只在宿主函数内部存在，外部调不到，所以没有"公开 API"的负担，但它们的逻辑同样值得知道。

#### `prep(m)`　〔内嵌于 `bootstrap_decomposition`〕

```python
def prep(m: pd.Timestamp):
```

**作用**：把一个月的日度明细整理成「**每天一个块**」——这是按天分块 Bootstrap 的第一道工序。

| 参数 | 类型 | 含义 |
|---|---|---|
| `m` | Timestamp | 要整理的月份（如 `Timestamp('2018-05-01')`） |

**返回**：三元组 `(buyers, delivered, gmv)`

| 元素 | 类型 | 含义 |
|---|---|---|
| `buyers` | `list[np.ndarray]` | 每天一个数组，装的是**当天下过单的客户整数编码**（`buyer_code`） |
| `delivered` | `np.ndarray` | 每天已送达的订单数，长度 = 该月天数 |
| `gmv` | `np.ndarray` | 每天已送达订单的金额合计，长度同上 |

**为什么要写成"每天一个块"**：Bootstrap 要按天重抽样，就必须能**整体取出某一天的全部信息**。`buyers` 存的是客户编码而不是人数——这是关键：重抽样后要把若干天的编码**拼起来重新去重**，如果这里只存了人数，信息就永久丢失了。

---

#### `sse(seg)`　〔内嵌于 `binary_segmentation`〕

```python
def sse(seg: np.ndarray) -> float:
```

**作用**：算一段序列的**残差平方和**（Sum of Squared Errors），也就是"这段数据离自己的均值有多远"。

| 参数 | 类型 | 含义 |
|---|---|---|
| `seg` | ndarray | 一段序列（如某个月份区间的 log GMV） |

**返回**：`float`，残差平方和。空数组返回 `0.0`

**为什么需要它**：断点检测的本质就是"**在这里切一刀，能不能让两段各自更整齐**"。

```
gain = 不切时的 SSE − (左段 SSE + 右段 SSE)
```

`gain` 越大，说明这一刀切得越值。整个 `binary_segmentation` 就是在所有可能的切点上找 `gain` 最大的那个。

**备注**：公式是 `Σ(x − mean(x))²`。用"离均值的平方距离"而不是"离直线的距离"，是因为这里检测的是**均值跳变**（水平变点），不是在拟合趋势。这是它和回归的分工：趋势交给 `mann_kendall` 和 `log_ols_slope`，变点交给它。

---

## 五、三个脚本各用了哪些函数

| 函数 | `s2_01` | `s2_02` | `s2_03` | `selftest` |
|---|---|---|---|---|
| `setup_logging` | ✅ | ✅ | ✅ | |
| `get_engine` | ✅ | ✅ | ✅ | |
| `read_table` | ✅（读回核对） | ✅（读回核对） | ✅（读回核对） | |
| `read_sql` | 间接 | 间接 | 间接 | |
| `table_exists` | | ✅ | ✅ | |
| `write_table` | ✅ | | ✅ | |
| `month_panel` | ✅ | ✅ | ✅ | |
| `complete_window` | ✅ | ✅ | ✅ | |
| `month_pairs` | ✅ | | ✅ | |
| `daily_order_panel` | ✅ | | | |
| `daily_dim_panel` | | | ✅ | |
| `lmdi_additive` | ✅ | | | ✅ |
| `bootstrap_decomposition` | ✅ | | | ✅ |
| `ci_bounds` | ✅ | | ✅ | |
| `mann_kendall` | | ✅ | | ✅ |
| `log_ols_slope` | | ✅ | | ✅ |
| `binary_segmentation` | | ✅ | | ✅ |
| `fmt_table` | ✅ | ✅ | ✅ | |
| `check` | ✅ | | ✅ | |

可以看出三条规律：

1. **`month_panel` + `complete_window` 是公共起点**——三个脚本都要先定分析区间，这是"首尾不完整"这个数据事实倒逼出来的。
2. **`check` 只出现在 `s2_01` 和 `s2_03`**——因为只有这两个脚本做了"贡献之和 = 整体变化"这种可断言的恒等式。`s2_02` 做的是检验，输出的是 p 值，没有恒等式可断言。
3. **`s2_02` 是唯一不写 `write_table` 的**——它只更新 `ads_gmv_trend` 的 6 个列，用的是 `UPDATE`，`to_sql` 做不到局部更新。

---

## 七、快速调用示例

```python
from common import *
from config import BOOTSTRAP_B

# 1. 起手三件套
log = setup_logging("demo")
engine = get_engine()

# 2. 定区间
panel = month_panel(engine)
start, end = complete_window(panel, log)
pairs = month_pairs(panel, start, end)

# 3. 读明细
daily = daily_order_panel(engine)

# 4. 分解 + 区间
m0, m1 = pairs[-1]
s0 = panel.set_index("stat_month").loc[m0]
s1 = panel.set_index("stat_month").loc[m1]
x0 = (s0.buyers, s0.orders_per_buyer, s0.aov)
x1 = (s1.buyers, s1.orders_per_buyer, s1.aov)
contrib = lmdi_additive(s0.gmv, s1.gmv, x0, x1)
check(abs(contrib.sum() - (s1.gmv - s0.gmv)) < 0.01, "三因子之和 = ΔGMV", log)

boot, boot_delta = bootstrap_decomposition(daily, m0, m1, b=BOOTSTRAP_B)
lo, hi = ci_bounds(boot)

# 5. 回写
out = pd.DataFrame({
    "stat_month": [m1.date()] * 3,
    "factor": ["buyers", "orders_per_buyer", "aov"],
    "contribution_amount": contrib.round(2),
    "ci_low": lo.round(2),
    "ci_high": hi.round(2),
})
write_table(engine, out, "ads_gmv_decomposition", log=log)
```
