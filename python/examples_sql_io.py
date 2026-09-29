"""MySQL 读写速查 —— 把这四种写法记住就够了。

跑一遍这个文件，四种读写方式都走一遍，对照你的教程看差异。

    python examples_sql_io.py        # 只读，不写库
    python examples_sql_io.py --write # 额外做一次写入演示（建一张 tmp_ 临时表）

（本文件只演示读写，不做分析，所以不需要先跑 sql/05）
"""
from __future__ import annotations

import argparse

import pandas as pd

from common import get_engine, read_sql, read_table, write_df, write_table
from config import DB_URL_SAFE


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--write", action="store_true", help="额外演示写入")
    args = p.parse_args()

    print("连接串：", DB_URL_SAFE)

    # ========================================================================
    # 1. 创建引擎对象
    #    连接串在 config.py 里拼好（DB_URL），改密码只需改那一处
    # ========================================================================
    engine = get_engine()

    # ========================================================================
    # 2. 读全表 —— 最简单
    #        df = pd.read_sql('ads_gmv_factors', engine)
    #    封装成了 read_table，写法一模一样，只是不用每次手写 pd.read_sql
    # ========================================================================
    df = read_table(engine, "ads_gmv_factors")
    print("\n[1] 读全表 ads_gmv_factors：", df.shape)
    print(df.head(5).to_string(index=False))

    # ========================================================================
    # 3. 读指定数据 —— 表大、或只要一部分时用
    #        df = pd.read_sql('select ... from ... limit 0,2', engine)
    #    推荐用 :参数 占位，别用 f-string 拼 SQL（拼错了不会报错，只会出错数据）
    #        反例：f"SELECT * FROM t WHERE m >= '{x}'"
    # ========================================================================
    df2 = read_sql(
        engine,
        """
        SELECT stat_month, gmv, gmv_all, aov, orders_per_buyer
        FROM ads_gmv_trend
        WHERE is_complete_month = 1 AND stat_month >= :since
        ORDER BY stat_month
        """,
        since="2017-01-01",
    )
    print("\n[2] 读指定数据（带条件）：", df2.shape)
    print(df2.head(5).to_string(index=False))

    # 只看前 2 行（等价于教程里的 limit 0,2）
    print("\n[2b] 只取 2 行：")
    print(read_sql(engine, "SELECT stat_month, gmv FROM ads_gmv_trend LIMIT 2").to_string(index=False))

    # ========================================================================
    # 4. 写入 —— 两种情形，用哪个取决于表是不是"结果表"
    # ========================================================================
    if not args.write:
        print("\n[3] 跳过写入演示。加 --write 参数可以真的写一次。")
        return

    demo = df2.head(5).copy()

    # 4a. 往一张空表灌第一批数据 —— 直接用 append
    print("\n[3a] write_df + if_exists='replace' 写入 tmp_sql_io_demo")
    write_df(engine, demo, "tmp_sql_io_demo", if_exists="replace")
    print("     读回：", read_table(engine, "tmp_sql_io_demo").shape)

    # 4b. 结果表 —— 必须先清空再写
    #     ⚠️ 直接 append 的后果：表上有主键 → Duplicate entry 报错；
    #        表上没主键 → 不报错，但行数悄悄翻倍。两种都不能接受。
    print("\n[3b] write_table（先删后插，可重复执行）写第二遍")
    write_table(engine, demo, "tmp_sql_io_demo")
    write_table(engine, demo, "tmp_sql_io_demo")
    print("     连写两次后行数仍为：", len(read_table(engine, "tmp_sql_io_demo")), "（没有翻倍）")

    print("\n演示表 tmp_sql_io_demo 已留下，不需要了就 DROP TABLE 删掉。")


if __name__ == "__main__":
    main()
