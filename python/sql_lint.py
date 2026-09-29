"""SQL 结构校验器 —— 抓 sqlglot 解析抓不到的那类错。

【为什么需要这个脚本】
`sqlglot.parse(sql, read='mysql')` 只能告诉你"语法合法"，不能告诉你"列对得上"。
而数仓脚本里最常见的致命错误恰恰是列错位：
  - CREATE TABLE 有 29 列，INSERT 的目标列写了 28 个（漏一列、错位一列）
  - INSERT 没写目标列、靠 SELECT 的位置对齐，但 SELECT 少给了一个表达式
  - UNION ALL 的几条分支列数不一致（最容易漏：只在第一条分支里加了一列）

这类错 MySQL 报的错往往指向别处（1366 Truncated incorrect / 1136 Column count
doesn't match value count），排查很费时间。本脚本在跑之前就把它挡下来。

【检查项】
1. UNION [ALL] 各分支的投影列数必须一致
2. 每个 INSERT ... SELECT 的「目标列数 == 投影列数」
   - 写了显式列清单 → 拿清单长度比
   - 没写显式列清单 → 拿 CREATE TABLE 的列数比（位置对齐）
3. 投影里的 `*` / `alias.*` 会顺着 CTE、子查询、以及**跨文件的物理表**解析出列数
   （解析不出来时标记 SKIP，不算通过，需要人工确认）
4. `--explain`：把每条 INSERT 的 SELECT 交给真库跑一遍 `EXPLAIN`（不写数据、不执行）
   —— 这一项专抓**静态解析通过但 MySQL 拒绝执行**的错，例如
   `SUM(... OVER ()) OVER ()` 这种窗口套窗口（MySQL 3593），sqlglot 不报错。

【用法】
    python sql_lint.py                      # 校验 sql/ 目录下全部 .sql
    python sql_lint.py ../sql/10_xxx.sql    # 只校验指定文件
    python sql_lint.py --explain            # 额外连库做 EXPLAIN 语义校验（需 config.py + pymysql）
    python sql_lint.py --explain --db sql_name

【退出码】0 = 无 FAIL；1 = 有 FAIL

【实现注意】
- sqlglot 30.x 里 SELECT 的 FROM 子句键名是 `from_`（不是 `from`），必须两个都试。
- ODS 脚本里的 LOAD DATA LOCAL INFILE 不在 sqlglot 的方言覆盖内，会解析失败；
  用 ErrorLevel.IGNORE 降级处理并记 WARN，不让它污染结果。
- EXPLAIN 模式要求相关表已存在（CTE 从别的文件继承表时，那条语句不适用本模式）。
"""
from __future__ import annotations

import glob
import os
import re
import sys

import sqlglot
from sqlglot import exp

# FROM 子句在不同 sqlglot 版本下的键名
FROM_KEYS = ("from", "from_")


def ddl_columns(create: exp.Create) -> list[str] | None:
    """从 CREATE TABLE 里取出真实列名（排除主键/索引等表级约束）。"""
    schema = create.this
    if not isinstance(schema, exp.Schema):
        return None
    return [e.name for e in schema.expressions if isinstance(e, exp.ColumnDef)]


def unwrap(expr: exp.Expression) -> exp.Expression:
    """剥掉 CTE（WITH）外壳，取到真正的 query 本体。"""
    while isinstance(expr, exp.With):
        expr = expr.this
    return expr


def from_table(select: exp.Select) -> exp.Expression | None:
    """取 SELECT 的 FROM 目标节点（兼容 from / from_ 两种键名）。"""
    for k in FROM_KEYS:
        src = select.args.get(k)
        if src is not None:
            return src.this
    return None


def union_branches(expr: exp.Expression) -> list[exp.Expression]:
    """把 UNION [ALL] 链条摊平成有序的分支列表。"""
    expr = unwrap(expr)
    if isinstance(expr, exp.Union):
        return union_branches(expr.this) + union_branches(expr.expression)
    return [expr]


def collect_ctes(node: exp.Expression) -> dict[str, exp.Expression]:
    """收集作用域内的 CTE：名字 → query 本体。"""
    out: dict[str, exp.Expression] = {}
    for with_ in node.find_all(exp.With):
        for cte in with_.expressions:
            if isinstance(cte, exp.CTE) and cte.alias:
                out[cte.alias] = unwrap(cte.this)
    return out


def is_star(e: exp.Expression) -> bool:
    return isinstance(e, exp.Star) or (
        isinstance(e, exp.Column) and isinstance(e.this, exp.Star)
    )


def projection_count(
    select: exp.Expression,
    ctes: dict[str, exp.Expression],
    registry: dict[str, int],
    depth: int = 0,
) -> int | None:
    """算出一条 SELECT 的投影列数；解析不出 `*` 时返回 None。"""
    if depth > 12:
        return None
    select = unwrap(select)
    if isinstance(select, exp.Union):
        return projection_count(select.this, ctes, registry, depth + 1)
    if isinstance(select, exp.Values):
        # INSERT ... VALUES (...), (...)：列数 = 第一个元组的表达式个数
        tuples = select.expressions
        if not tuples:
            return None
        return len(tuples[0].expressions)
    if not isinstance(select, exp.Select):
        return None

    n = 0
    for e in select.expressions:
        if not is_star(e):
            n += 1
            continue
        table = from_table(select)
        if table is None:
            return None
        if isinstance(table, exp.Subquery):
            sub = projection_count(table.this, ctes, registry, depth + 1)
            if sub is None:
                return None
            n += sub
            continue
        name = table.name if isinstance(table, exp.Table) else None
        if name and name in ctes:
            sub = projection_count(ctes[name], ctes, registry, depth + 1)
            if sub is None:
                return None
            n += sub
            continue
        if name and name in registry:
            n += registry[name]  # 跨文件解析：物理表的已知列数
            continue
        return None
    return n


def parse_sql(sql: str, rel: str) -> tuple[list, int]:
    """解析 SQL；对 sqlglot 覆盖不到的语句（LOAD DATA 等）降级处理。"""
    unparsed = 0
    try:
        return [s for s in sqlglot.parse(sql, read="mysql") if s], 0
    except Exception:  # noqa: BLE001
        stmts = [
            s
            for s in sqlglot.parse(sql, read="mysql", error_level=sqlglot.ErrorLevel.IGNORE)
            if s
        ]
        total_hint = sql.count(";")
        unparsed = max(0, total_hint - len(stmts))
        return stmts, unparsed


def build_registry(files: list[str]) -> dict[str, int]:
    """两遍扫描第一遍：收集全部文件里 CREATE TABLE 的列数，供跨文件 `*` 解析。"""
    reg: dict[str, int] = {}
    for f in files:
        sql = open(f, encoding="utf-8").read()
        stmts, _ = parse_sql(sql, os.path.basename(f))
        for s in stmts:
            if isinstance(s, exp.Create) and str(s.kind).upper() == "TABLE":
                cols = ddl_columns(s)
                if cols and s.this.this is not None:
                    reg[s.this.this.name] = len(cols)
    return reg


def lint_file(path: str, registry: dict[str, int]) -> tuple[int, int, int]:
    """返回 (fail, skip, ok)。"""
    rel = os.path.basename(path)
    sql = open(path, encoding="utf-8").read()
    stmts, unparsed = parse_sql(sql, rel)

    if unparsed:
        print(f"[WARN] {rel}: 有约 {unparsed} 条语句超出 sqlglot 方言覆盖（如 LOAD DATA），已跳过")

    ddl: dict[str, int] = {}
    for s in stmts:
        if isinstance(s, exp.Create) and str(s.kind).upper() == "TABLE":
            cols = ddl_columns(s)
            if cols and s.this.this is not None:
                ddl[s.this.this.name] = len(cols)
    known_cols = {**registry, **ddl}

    fail = skip = ok = 0
    for s in stmts:
        if not isinstance(s, exp.Insert):
            continue

        target = s.this
        explicit: list[str] | None = None
        if isinstance(target, exp.Schema):
            explicit = [c.name for c in target.expressions]
            table_name = target.this.name
        else:
            table_name = target.name

        ctes = collect_ctes(s)
        branches = union_branches(s.expression)
        counts = [projection_count(b, ctes, known_cols) for b in branches]

        # 检查 1：UNION 各分支列数一致
        known = [c for c in counts if c is not None]
        if len(known) >= 2 and len(set(known)) > 1:
            print(f"[FAIL] {rel} -> {table_name}: UNION 各分支列数不一致 {counts}")
            fail += 1
            continue

        # 检查 2：目标列数 == 投影列数
        if explicit is not None:
            expected: list[str] | int | None = explicit
            expect_n = len(explicit)
        elif table_name in known_cols:
            expected = None
            expect_n = known_cols[table_name]
        else:
            expected = None
            expect_n = None

        got = counts[0]
        if expect_n is None:
            print(f"[SKIP] {rel} -> {table_name}: 找不到 CREATE TABLE，目标列数未知")
            skip += 1
        elif got is None:
            print(f"[SKIP] {rel} -> {table_name}: 投影列数无法静态解析"
                  f"（含 `*` 且源表未知，或非 SELECT/VALUES 结构），需人工确认")
            skip += 1
        elif expect_n != got:
            print(f"[FAIL] {rel} -> {table_name}: 目标列数 {expect_n} != 投影列数 {got}"
                  f"（差 {expect_n - got}）")
            if explicit is not None:
                print(f"        显式列清单（{len(explicit)} 项）: {explicit}")
            else:
                print(f"        按 CREATE TABLE 的 {expect_n} 列位置对齐")
            if len(branches) > 1:
                print(f"        UNION 分支各自列数: {counts}")
            fail += 1
        else:
            how = "显式列清单" if explicit is not None else "按 DDL 位置对齐"
            print(f"[ OK ] {rel} -> {table_name}: {got} 列对齐（{how}）")
            ok += 1

    return fail, skip, ok


def iter_statements(sql_text: str) -> list[str]:
    """按分号切语句（先去掉 `--` 注释行，避免注释里的分号切错）。"""
    body = "\n".join(
        ln for ln in sql_text.splitlines() if not ln.strip().startswith("--")
    )
    return [s.strip() for s in body.split(";") if s.strip()]


def explain_check(files: list[str], db: str | None = None) -> tuple[int, int]:
    """把每条 INSERT 的 SELECT 交给真库 EXPLAIN 一遍（不执行、不写库）。

    这是结构校验的补充：sqlglot 只保证"语法合法"，MySQL 还会拒绝一批
    "语法合法但语义非法"的写法，最典型的就是窗口函数套窗口函数：
        SUM( ... SUM(x) OVER () ... ) OVER ()      -> [HY000][3593]
    只有真库能判出来。返回 (ok, fail)。
    """
    try:
        import pymysql
    except ImportError:
        print("[WARN] 未安装 pymysql，跳过 --explain 语义校验")
        return 0, 0

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    try:
        import config
    except ImportError:
        print("[WARN] 找不到 config.py，跳过 --explain 语义校验")
        return 0, 0

    db_name = db or config.DB["database"]
    try:
        conn = pymysql.connect(
            host=config.DB["host"], port=int(config.DB["port"]),
            user=config.DB["user"], password=config.DB["password"],
            database=db_name, charset="utf8mb4", connect_timeout=5,
        )
    except Exception as e:  # noqa: BLE001
        print(f"[WARN] 连不上 {db_name}，跳过 --explain 语义校验：{e}")
        return 0, 0

    print(f"\n{'=' * 64}")
    print(f"EXPLAIN 语义校验（库 {db_name}，只解析不执行）")
    print("=" * 64)

    # 本批文件里新建的表 —— 它们在库里可能还不存在，EXPLAIN 会报 1146。
    # 这属于工具的能力边界，必须报 SKIP 而不是 FAIL（把"不知道"当成"失败"会训练出
    # 忽略告警的习惯，那比不检查更危险）。
    local_created: set[str] = set()
    for f in files:
        for m in re.finditer(
            r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?[`\w.]*?([`\w]+)",
            open(f, encoding="utf-8").read(), re.I,
        ):
            local_created.add(m.group(1).strip("`").lower())

    cur = conn.cursor()
    try:
        cur.execute(
            "SELECT table_name FROM information_schema.tables WHERE table_schema = %s",
            (db_name,),
        )
        existing = {r[0].lower() for r in cur.fetchall()}
    except Exception:  # noqa: BLE001
        existing = set()

    ok = fail = skip = 0
    for f in files:
        rel = os.path.basename(f)
        for st in iter_statements(open(f, encoding="utf-8").read()):
            if not re.match(r"INSERT\s+INTO\b", st, re.I):
                continue
            m = re.match(r"INSERT\s+INTO\s+[`\w.]+\s*(\([^)]*\))?\s*", st, re.I | re.S)
            if not m:
                continue
            target = re.search(r"INSERT\s+INTO\s+([`\w.]+)", st, re.I).group(1)
            select_sql = st[m.end():].strip()
            if not select_sql:
                continue

            # ① INSERT ... VALUES：MySQL 不支持 EXPLAIN 这种形式（报 1064），
            #    而它是语法问题不是语义问题 —— 属于工具边界，报 SKIP。
            if re.match(r"VALUES\b", select_sql, re.I):
                print(f"[SKIP] {rel} -> {target}: VALUES 形式无法 EXPLAIN（MySQL 限制，非错误）")
                skip += 1
                continue

            # ② 引用了「本批文件新建、但库里还没有」的表：依赖未满足，报 SKIP。
            referenced = {
                t.strip("`").lower()
                for t in re.findall(r"(?:FROM|JOIN)\s+[`\w.]*?([`\w]+)", select_sql, re.I)
            }
            missing = sorted(t for t in referenced
                             if t in local_created and t not in existing)
            if missing:
                print(f"[SKIP] {rel} -> {target}: 依赖本批新建的表 {missing}，"
                      f"需先真跑建表才能语义校验")
                skip += 1
                continue

            try:
                cur.execute("EXPLAIN " + select_sql)
                cur.fetchall()
                print(f"[ OK ] {rel} -> {target}")
                ok += 1
            except Exception as e:  # noqa: BLE001
                code = getattr(e, "args", [None])[0]
                print(f"[FAIL] {rel} -> {target}: {code or type(e).__name__}")
                print(f"        {e}")
                fail += 1

    cur.close()
    conn.close()
    if skip:
        print(f"（另有 {skip} 条 SKIP：属工具能力边界，需真跑库验证，不计入失败）")
    return ok, fail


def main() -> int:
    args = sys.argv[1:]
    explain = "--explain" in args
    if explain:
        args.remove("--explain")
    db = None
    if "--db" in args:
        i = args.index("--db")
        db = args[i + 1]
        del args[i:i + 2]

    if args:
        files: list[str] = []
        for a in args:
            files.extend(glob.glob(a) or [a])
    else:
        here = os.path.dirname(os.path.abspath(__file__))
        files = sorted(glob.glob(os.path.join(here, "..", "sql", "*.sql")))

    registry = build_registry(files)

    total_fail = total_skip = total_ok = 0
    for f in files:
        print(f"\n===== {os.path.basename(f)} =====")
        fa, sk, ok = lint_file(f, registry)
        total_fail += fa
        total_skip += sk
        total_ok += ok

    print(f"\n{'=' * 64}")
    print(f"结构校验合计：OK {total_ok} ｜ SKIP {total_skip}（需人工确认）｜ FAIL {total_fail}")
    print("=" * 64)

    if explain:
        e_ok, e_fail = explain_check(files, db)
        print(f"\n{'-' * 64}")
        print(f"语义校验（EXPLAIN）合计：OK {e_ok} ｜ FAIL {e_fail}")
        print("-" * 64)
        total_fail += e_fail

    return 1 if total_fail else 0


if __name__ == "__main__":
    raise SystemExit(main())
