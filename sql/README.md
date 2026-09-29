# SQL 脚本运行说明

## 一、运行顺序

| 顺序 | 文件 | 作用 |
|---|---|---|
| 1 | `00_ods_建表与导入.sql` | 建库 `olist_dw`、建 9 张 ods 原始表、批量导入 Kaggle CSV、建索引 |
| 2 | `00b_导入体检.sql` | **导入后必跑**：校验每列内容的形态，捕捉「列错位」这类静默错误 |
| 3 | `01_dwd_清洗与宽表.sql` | 类型转换、去重、缺失处理，产出 6 张 dwd 表（订单宽表 + 商品明细） |
| 4 | `02_dws_主题汇总.sql` | 产出 5 张 dws 主题表（日 GMV、品类月、卖家、用户画像、留存） |
| 5 | `03_ads_看板结果表.sql` | 产出 Tableau 直连的 ads 结果表（含 3 张由 Python 回写的空表） |
| 6 | `04_校验与对账.sql` | 校验行数、口径、数据坑，确认跑通 |
| 6.5 | `04b_隐式转换验收.sql` | **只要写过一次「原样字符串直接灌进 DATETIME 列」就必须跑**：验证有没有静默产生 `0000-00-00 00:00:00` |
| 7 | `05_s2_结构下钻.sql` | S2（GMV 拆解与增长归因）用：补 `dws_state_monthly`，建 `ads_gmv_trend` / `ads_gmv_structure` / `ads_gmv_decomposition`；后两张由 Python 回写 |
| 8 | `06_s2_AOV结构拆解.sql` | S2 收尾：建 `ads_aov_decomposition` / `ads_aov_mix_detail` / `ads_aov_effect_window` 三张空表，供 `python/s2_04_aov_mix.py` 回写（AOV 分解已按邓的要求舍弃，表保留但可跑可不跑） |
| 9 | `07_s2_瀑布图结果表.sql` | S2 呈现：建 `ads_gmv_waterfall_base` / `ads_gmv_waterfall`（瀑布口径锁 SQL 层，Tableau 只画甘特条） |
| 10 | `08_s3_履约链路.sql` | S3（履约体验）：建月度履约画像 / 延迟分桶 / 瓶颈口径表 3 张汇总 + 4 张统计空表（s3_01/s3_02 回写） |
| 11 | `09_s4_差评预警特征.sql` | S4（差评预警）：建订单级特征宽表 `ads_s4_order_features`（含防泄漏历史特征）+ 3 张统计空表（s4_01 回写） |
| 12 | `10_s5_价值分层.sql` | S5（价值分层）：建修正版 RFM 分层 `ads_s5_rfm_v2`（三维二值八格）+ 复购画像 / 首购体验交叉表 / 生存分析输入 / 分层策略表 4 张 + 4 张统计空表（s5_01/s5_02 回写） |
| 13 | `11_s6_策略效果评估.sql` | S6（策略效果评估）：建可干预订单池 `ads_s6_intervention_pool`（95,832 行，三条策略命中标记）+ 参数表 `ads_s6_strategy_params`（实测 6 / 假设 6）+ 策略×月输入表 + 3 张空表（s6_01 回写） |
| — | `10b_S5策略表段_可直接粘贴.sql` | 从 `10` 切出的策略表片段（DROP+CREATE+INSERT），供在 PyCharm 控制台直接粘贴 |

> **第 7、8 步的后续**：跑完 `05` 后依次跑 `python/s2_01` → `s2_02` → `s2_03`；
> 跑完 `06` 后跑 `python/s2_04_aov_mix.py`。Python 侧的说明见 `python/README.md`。
> **第 10、11 步的后续**：跑完 `08` 后依次跑 `python/s3_01` → `s3_02`；
> 跑完 `09` 后跑 `python/s4_01_bad_review_model.py`（需要 scikit-learn ≥1.2，见 requirements.txt）。
> **第 12 步的后续**：跑完 `10` 后依次跑 `python/s5_01_rfm_cluster.py` → `python/s5_02_repeat_survival.py`。
> **第 13 步的后续**：跑完 `11` 后跑 `python/s6_01_strategy_eval.py`（⚠️ 依赖 `ads_s5_experience_effect` 已有数，
> 所以必须 **s5_02 先跑完**）。S6 是反事实仿真，不是 A/B 实验——`p`（挽回率）与 `v`（差评价值）
> 在数据里不存在，全部结论必须配二维敏感性一起读。
> 各脚本末节的勾稽/自检必须全过再往下跑。
> `05` 最后一节是**截面勾稽**（品类合计 = 州合计 = 总量），三个差值必须严格为 0.00，
>
> **⚠️ `10` 的第一个查询是"诊断"不是"自检"**：它会打印 `sql/02` 那套五分位 `f_score`
> 各档的真实 `order_cnt` 分布。预期结果是 f_score 1~4 四档的 `min=max=1`、`repeat_users=0`
> ——**看到这个结果是正常的**，它正是 S5 重做 RFM 的理由（F 维在 3% 复购率下分箱退化）。
> 只有出现"四档的 order_cnt 各不相同"时才说明 sql/02 的 NTILE 行为变了，需要回头核对。
>
> **校验器限制说明**：`00_ods_建表与导入.sql` 里的 `LOAD DATA ... FIELDS TERMINATED BY`
> 是 MySQL 专有语法，`sqlglot` 解析会报 `ParseError` —— 这是校验器的限制，不是脚本错误，
> 该文件已在生产环境完整跑通。其余脚本的 `INSERT` 已用 `python/sql_lint.py` 逐条校验
> **目标列数 = 投影列数**（含 UNION ALL 分支间的一致性），当前 **37 条 INSERT、0 FAIL**。
> 不为 0 就先别往下跑。

> **`04b` 为什么单独列一档：`INSERT` 成功 ≠ 数据正确。**
> 隐式转换（字符串直接塞进 DATETIME 列）遇到非法值**不报错**，只留一条 warning，
> 在非严格模式下会静默变成 `0000-00-00 00:00:00`。
> `04b` 的核心是**双路径对账**：拿落库值（隐式转换的结果）与 `STR_TO_DATE` 显式解析的结果逐行比对，
> 两份必须完全一致——这能把零值、截断、补零等**所有**隐式转换的痕迹一次性抓出来。

> `00b` 不要跳过。`LOAD DATA` 是按**位置**把 CSV 的列灌进表里的，如果 CSV 的实际列序和脚本里的
> 列清单不一致，MySQL **不会报错**，只会静默地让整表数据错位——直到你写 dwd 转换时才会以
> 各种诡异的方式爆出来。详见「常见报错」里的 `Truncated incorrect INTEGER value`。

## 二、前置配置（只做一次）

### 1. 开启 local_infile（必需）

**服务端**（管理员权限执行一次，或写进 `my.ini` 后重启）：
```sql
SET GLOBAL local_infile = 1;
-- 检查：SHOW VARIABLES LIKE 'local_infile';  应为 ON
```

**客户端**按你用的工具选一个：
- 命令行：`mysql --local-infile=1 -u root -p`
- **DataGrip：数据源属性 → 高级(Advanced) → 找到 `allowLoadLocalInfile` 设为 `true`**
  （若列表里没有这一项，就手工添加一条同名属性）。改完必须**断开重连**才生效。
- DBeaver：连接 → 编辑连接 → 驱动属性 → 新增 `allowLoadLocalInfile` = `true`
- MySQL Workbench：连接 → Advanced → Others → 填入 `OPT_LOCAL_INFILE=1`

> ⚠️ **两边都要开，缺一个就报 `ERROR 3948 (42000): Loading local data is disabled`。**
> 报错信息里那句 "must be enabled on both the client and server sides" 就是这个意思：
> · 服务端漏了 → 管理员账号执行 `SET GLOBAL local_infile = 1;`
> · 客户端漏了 → 按上面配置你用的工具，然后**断开重连**

**替代方案（拿不到管理员权限时用）**：
```sql
SHOW VARIABLES LIKE 'secure_file_priv';   -- 先看服务器允许从哪个目录读文件
```
把 9 个 CSV 拷进那个目录，再把脚本里的 `LOAD DATA LOCAL INFILE` 改成 `LOAD DATA INFILE`，
路径换成**服务器视角**的绝对路径即可。
（`LOCAL` 的含义是"从客户端读文件"，去掉 `LOCAL` 就变成"从服务器读文件"，因此不再需要 local_infile 权限。）

### 2. 下载数据

Kaggle 搜索 **Brazilian E-Commerce Public Dataset by Olist**，解压后应得到 9 个 CSV。
建议统一放到 `D:/olist_data/`（**用正斜杠 `/`，不要用反斜杠**）。

### 3. 改路径

`00_ods_建表与导入.sql` 里有 9 处 `'D:/olist_data/xxx.csv'`，全部改成你的实际路径。

## 三、环境要求

- MySQL **8.0.19+**（`01_dwd` 用到了 `INSERT ... WITH ... SELECT` 的写法）
- 字符集 `utf8mb4`（葡萄牙语重音字符必须）
- 排序规则统一 `utf8mb4_0900_ai_ci`（MySQL 8.0 的 utf8mb4 默认值）。
  **库和表必须一致**，否则跨表 JOIN 会报 `Illegal mix of collations`。
  > 坑点：建表只写 `DEFAULT CHARSET=utf8mb4` 不写 `COLLATE` 时，用的是**字符集的**默认排序规则
  > （8.0 = `utf8mb4_0900_ai_ci`），不是**数据库的**默认排序规则。两边写不一样就会出现不一致。
  >
  > 核对：`SELECT @@character_set_database, @@collation_database;`
  > 对齐：`ALTER DATABASE olist_dw CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;`
  >
  > 补充：`0900_ai_ci` 里的 `ai` = accent-insensitive，即 `'São Paulo'` 与 `'Sao Paulo'` 视为相等。
  > 对本项目的巴西地名来说这是好事（重音写法不一致也能匹配上）。
- 建议 `innodb_buffer_pool_size` ≥ 1GB（geolocation 表 100 万行）

## 四、预计耗时

| 步骤 | 耗时（参考） |
|---|---|
| 00 导入 | 3–8 分钟（geolocation 100 万行最慢） |
| 01 dwd | 1–3 分钟 |
| 02 dws | 1–2 分钟 |
| 03 ads | 1–2 分钟 |

## 五、常见报错

| 报错 | 原因 | 解决 |
|---|---|---|
| `ERROR 3948 (42000): Loading local data is disabled` | 服务端没开 local_infile | 见上文「前置配置 1」 |
| `ERROR 29 (HY000): File '...' not found` | 路径写错，或用了反斜杠 | 用正斜杠，确认文件真实存在 |
| 导入后中文/重音字符乱码 | 连接字符集不是 utf8mb4 | 脚本首行已 `SET NAMES utf8mb4`；客户端也设为 utf8mb4 |
| 数字列出现 `Truncated incorrect DOUBLE value` | CSV 行尾带 `\r` | 脚本已用 `SET <最后一列> = TRIM(TRAILING '\r' FROM ...)` 处理 |
| 行数比预期少几十行 | 数据里有跨行的引号内容 | 已在 `LOAD DATA` 用 `OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"'` 处理 |
| **`Truncated incorrect INTEGER value: '2017-03-29 13:05:42'`** | 数字列里存了日期 → 列错位，或存在个别脏行 | 用 `00b_导入体检.sql` 判断范围，再用 `00c_列错位定位.sql` 定位到具体行 |
| **每张表都整齐地少 1 行** | **CSV 最后一行没有行尾换行符**，`LOAD DATA` 会跳过它 | 见下方「关于末行换行」 |
| **`[HY000][1525] Incorrect DATETIME value: '0000-00-00 00:00:00'`** | 你写的 **字面量本身**在当前 `sql_mode`（含 `NO_ZERO_DATE`）下非法，查询还没碰到数据就炸了 | **别用等值比较**。查零值改用范围比较：`WHERE ts < '1000-01-01'` |
| **`[HY000][1525] Incorrect DATE value`（换个日期值报同样的错）** | 会话 `sql_mode` 与脚本里 `SET SESSION sql_mode = ...` 不一致（IDE 里分段执行时用的是服务器默认值） | `SELECT @@SESSION.sql_mode, @@GLOBAL.sql_mode;` 对比；**同一段 SQL 在不同会话表现不同，是一类很隐蔽的坑** |

### 关于「末行换行」

`LINES TERMINATED BY '\n'` 要求每行都以换行符结束。**文件最后一行如果没有换行符，那一行读不到，表就会比文件少 1 行。**

判定依据不用猜——直接看 `LOAD DATA` 执行后的结果消息：

```
Query OK, 112649 rows affected
Records: 112649  Deleted: 0  Skipped: 1  Warnings: 1
                                     ↑ 这个 1 就是被跳过的末行
```

**先诊断**（PowerShell，看每个文件最后一个字节是什么）：
```powershell
Get-ChildItem "D:/olist_data/*.csv" | ForEach-Object {
  $b = [System.IO.File]::ReadAllBytes($_.FullName)
  $t = if ($b[-1] -eq 10) {'LF 有换行'} elseif ($b[-1] -eq 13) {'CR 有换行'} else {'没有换行 ← 就是它'}
  "{0,-45} 末字节={1}  {2}" -f $_.Name, $b[-1], $t
}
```

**再修复**（只给缺失的补，不动已有的）：
```powershell
Get-ChildItem "D:/olist_data/*.csv" | ForEach-Object {
  $b = [System.IO.File]::ReadAllBytes($_.FullName)
  if ($b[-1] -ne 10 -and $b[-1] -ne 13) {
    [System.IO.File]::AppendAllText($_.FullName, "`n")
    "已补换行: $($_.Name)"
  }
}
```

补完后重新导入受影响的那几张表即可（`TRUNCATE TABLE ods_xxx;` 再跑对应的 `LOAD DATA`）。

> 差 1 行对分析结论没有影响，但**不能就这么放过**——查清原因、在数据字典里写明白，
> 这才是"数据可信"的一部分。被问"你怎么保证数据完整"，这就是现成的答案。

### 关于「列错位」的补充说明

`LOAD DATA` 的列清单 `(order_id, order_item_id, ...)` 是按**位置**匹配的，不是按名字。
所以列对不上时 MySQL **不会报错**，它会把第 2 列的值塞进第 2 个字段，不管那个值是什么。
**错误只会在下游转换时才暴露。**

**两种错位，处理方式完全不同：**

| 类型 | 特征 | 处理 |
|---|---|---|
| **整表错位** | 几乎所有行的该列都异常，且前几行就看得出来 | 核对 CSV 表头，按实际列序改 `LOAD DATA` 列清单，`TRUNCATE` 后重导 |
| **个别脏行** | 前几行正常，只有少数行异常 | CSV 本身有个别行字段数不对（多半是落单的双引号或多/少一个逗号），用 `00c_列错位定位.sql` 第四节定位到 CSV 行号后查看 |

> ⚠️ **前几行正确 ≠ 整表正确。** 只有某一行多一个字段，就会让那一行后面的字段整体错位——
> 这类错误只影响个别行，却会让整个 dwd 构建失败。

排查第一步：**核对 CSV 的第一行表头**。
```bash
# 命令行
head -1 "D:/olist_data/olist_order_items_dataset.csv"
# PowerShell
Get-Content "D:/olist_data/olist_order_items_dataset.csv" -TotalCount 1
```
官方 Kaggle 版本的 `olist_order_items_dataset.csv` 表头应当是：
```
order_id,order_item_id,product_id,seller_id,shipping_limit_date,price,freight_value
```

**排障工具：**
- `00b_导入体检.sql` —— 常规护栏，每次导完数据都跑一遍，看哪张表哪一列出问题
- `00c_列错位定位.sql` —— 专项排障，把坏行拉出来看、定位到 CSV 行号、顺带排查 `payment_installments`

## 六、重新构建

脚本设计为**可重复执行**：`00` 会 `DROP DATABASE IF EXISTS olist_dw` 后重建。
如果库里已有你自己写的表，先备份。
