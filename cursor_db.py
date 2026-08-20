#!/usr/bin/env python3
"""整理 Cursor 本地会话库 state.vscdb。

子命令：
  slim    按归档 / 活跃度复制出精简库（默认 dry-run）
  repair  把误写成 BLOB 的键改回 TEXT，并重建侧栏索引

用法：
  python3 ~/cursor-db-slim/cursor_db.py slim
  python3 ~/cursor-db-slim/cursor_db.py slim --days 7 --apply
  python3 ~/cursor-db-slim/cursor_db.py repair --apply

必须先完全退出 Cursor。原库只读复制，成功后再就位，失败可弃用临时文件。

硬约束（精简时写错过一次，已写进复制路径）：
  - 禁止 text_factory=bytes。键必须是 TEXT，否则 Cursor 用字符串查不到登录态。
  - 侧栏索引用 composerHeaders.value 重建，不要按 allComposers 过滤（会剪空）。
  - cursorDiskKV 的 value 有二进制，不能一律 CAST AS TEXT。
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import time

DEFAULT_DBS = [
    "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb",
    "~/.config/Cursor/User/globalStorage/state.vscdb",
    "~/AppData/Roaming/Cursor/User/globalStorage/state.vscdb",
]

COMPOSER_SCOPED = [
    "bubbleId",
    "composerData",
    "checkpointId",
    "composerVirtualRowHeights",
    "ofsContent",
    "codeBlockPartialInlineDiffFates",
]
KEEP_WHOLESALE = ["inlineDiff", "composer.content."]
KEEP_LIVE_TEXT = {
    "cursorAuth/accessToken",
    "cursorAuth/refreshToken",
    "cursor/glass.selectedAgent",
}


def default_db() -> str:
    for p in DEFAULT_DBS:
        path = os.path.expanduser(p)
        if os.path.exists(path):
            return path
    return os.path.expanduser(DEFAULT_DBS[0])


def human(n: float) -> str:
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(n) < 1024 or unit == "TiB":
            return f"{n:,.1f} {unit}"
        n /= 1024


def as_text(v):
    if v is None:
        return None
    if isinstance(v, bytes):
        return v.decode("utf-8")
    return v


def as_key(v):
    if isinstance(v, bytes):
        return v.decode("utf-8")
    return v


def as_kv_value(v):
    if v is None:
        return None
    if isinstance(v, str):
        return v
    if isinstance(v, bytes):
        try:
            return v.decode("utf-8")
        except UnicodeDecodeError:
            return v
    return v


def connect_ro(path: str) -> sqlite3.Connection:
    return sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=60)


def cursor_is_running() -> list[str]:
    try:
        out = subprocess.run(
            ["pgrep", "-fl", "Cursor.app"], capture_output=True, text=True, timeout=15
        ).stdout.strip()
    except Exception:
        return []
    return [l for l in out.splitlines() if l.strip()]


def db_holders(path: str) -> list[str]:
    try:
        out = subprocess.run(
            ["lsof", "--", path], capture_output=True, text=True, timeout=30
        ).stdout.strip().splitlines()
    except Exception:
        return []
    return out[1:] if len(out) > 1 else []


def require_idle(db: str) -> None:
    holders = db_holders(db)
    running = cursor_is_running()
    if holders or running:
        print("[中止] 库仍被占用，必须先完全退出 Cursor（Cmd+Q）：")
        for line in (holders + running)[:10]:
            print("   ", line[:160])
        sys.exit(2)


def checkpoint(db: str) -> None:
    w = sqlite3.connect(db, timeout=120)
    w.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    w.close()


def copy_schema(src: sqlite3.Connection, dst: sqlite3.Connection) -> None:
    dst.executescript("PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF;")
    cur = src.cursor()
    cur.execute(
        "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%'"
    )
    for (stmt,) in cur.fetchall():
        dst.execute(stmt if isinstance(stmt, str) else stmt.decode())


def remove_sidecars(path: str) -> None:
    for suffix in ("-wal", "-shm"):
        if os.path.exists(path + suffix):
            os.remove(path + suffix)


def swap_in(db: str, out: str, backup_suffix: str) -> None:
    backup = db + backup_suffix
    remove_sidecars(out)
    os.rename(db, backup)
    for suffix in ("-wal", "-shm"):
        stray = db + suffix
        if os.path.exists(stray):
            os.rename(stray, backup + suffix)
    os.rename(out, db)
    print(f"\n完成。新库 {human(os.path.getsize(db))}")
    print(f"上一份留在：\n  {backup}")
    print("启动 Cursor 确认正常后，再删备份才会真正释放磁盘。")


def finish_wal(dst: sqlite3.Connection) -> None:
    dst.execute("PRAGMA journal_mode=WAL")
    dst.commit()


def classify(conn: sqlite3.Connection, days: int) -> dict:
    cur = conn.cursor()
    cutoff = int(time.time() * 1000) - days * 86_400_000
    cur.execute(
        "SELECT composerId, createdAt, lastUpdatedAt, isArchived, isSubagent, value "
        "FROM composerHeaders"
    )
    heads = {}
    for cid, created, updated, archived, is_sub, value in cur.fetchall():
        cid = as_key(cid)
        root = None
        if is_sub:
            try:
                info = json.loads(as_text(value) or "{}").get("subagentInfo") or {}
                root = info.get("rootParentConversationId") or info.get(
                    "parentComposerId"
                )
            except Exception:
                root = None
        heads[cid] = {
            "created": created or 0,
            "updated": updated or 0,
            "archived": bool(archived),
            "is_sub": bool(is_sub),
            "root": root,
        }

    keep, reasons = set(), {}
    for cid, h in heads.items():
        if (not h["archived"]) and h["updated"] >= cutoff:
            keep.add(cid)
            reasons[cid] = "活跃"
    for cid, h in heads.items():
        root = h["root"]
        if h["is_sub"] and root and root in heads:
            if root in keep and cid not in keep:
                keep.add(cid)
                reasons[cid] = "子代理跟随父会话"
            elif root not in keep and cid in keep:
                keep.discard(cid)
                reasons.pop(cid, None)

    return {
        "heads": heads,
        "keep": keep,
        "purge": set(heads) - keep,
        "cutoff": cutoff,
        "archived": {c for c, h in heads.items() if h["archived"]},
        "stale": {
            c for c, h in heads.items() if not h["archived"] and h["updated"] < cutoff
        },
    }


def measure(conn: sqlite3.Connection, keep: set[str], keep_blobs: bool) -> dict:
    cur = conn.cursor()
    stats = {"per_prefix": {}, "keep_bytes": 0, "keep_rows": 0}
    for prefix in COMPOSER_SCOPED:
        rows = byts = 0
        for cid in keep:
            cur.execute(
                "SELECT COUNT(*), COALESCE(SUM(length(CAST(value AS BLOB))),0) "
                "FROM cursorDiskKV WHERE key >= ? AND key < ?",
                (f"{prefix}:{cid}", f"{prefix}:{cid}~"),
            )
            r, b = cur.fetchone()
            rows += r
            byts += b
        stats["per_prefix"][prefix] = (rows, byts)
        stats["keep_rows"] += rows
        stats["keep_bytes"] += byts
    for prefix in KEEP_WHOLESALE:
        cur.execute(
            "SELECT COUNT(*), COALESCE(SUM(length(CAST(value AS BLOB))),0) "
            "FROM cursorDiskKV WHERE key >= ? AND key < ?",
            (prefix, prefix + "~"),
        )
        r, b = cur.fetchone()
        stats["per_prefix"][prefix + "*"] = (r, b)
        stats["keep_rows"] += r
        stats["keep_bytes"] += b
    cur.execute(
        "SELECT COUNT(*), COALESCE(SUM(length(CAST(value AS BLOB))),0) FROM ItemTable"
    )
    r, b = cur.fetchone()
    stats["per_prefix"]["ItemTable"] = (r, b)
    stats["keep_rows"] += r
    stats["keep_bytes"] += b
    cur.execute(
        "SELECT COUNT(*) FROM cursorDiskKV WHERE key >= 'agentKv:' AND key < 'agentKv;'"
    )
    blob_rows = cur.fetchone()[0]
    if keep_blobs:
        cur.execute(
            "SELECT COALESCE(AVG(length(CAST(value AS BLOB))),0) FROM "
            "(SELECT value FROM cursorDiskKV WHERE key >= 'agentKv:' "
            "AND key < 'agentKv;' LIMIT 3000)"
        )
        est = cur.fetchone()[0] * blob_rows
        stats["per_prefix"]["agentKv:blob (估算)"] = (blob_rows, est)
        stats["keep_rows"] += blob_rows
        stats["keep_bytes"] += est
    else:
        stats["dropped_blob_rows"] = blob_rows
    return stats


def report(db: str, cls: dict, stats: dict, days: int, keep_blobs: bool) -> int:
    cur_size = os.path.getsize(db)
    free = shutil.disk_usage(os.path.dirname(db)).free
    projected = int(stats["keep_bytes"] * 1.15)
    heads = cls["heads"]
    print(f"\n库文件      : {db}")
    print(f"当前体积    : {human(cur_size)}")
    print(f"所在盘可用  : {human(free)}")
    print(
        f"保留窗口    : 最近 {days} 天（截止 "
        f"{time.strftime('%Y-%m-%d %H:%M', time.localtime(cls['cutoff'] / 1000))} 之后有更新）"
    )
    print(f"\n会话总数    : {len(heads)}")
    print(f"  已归档          : {len(cls['archived'])}  → 清理")
    print(f"  超 {days} 天未更新   : {len(cls['stale'])}  → 清理")
    print(
        f"  保留            : {len(cls['keep'])}"
        f"（其中子代理 {sum(1 for c in cls['keep'] if heads[c]['is_sub'])}）"
    )
    print(f"  实际清理会话数  : {len(cls['purge'])}")
    print("\n保留数据明细：")
    for k, (rows, byts) in sorted(
        stats["per_prefix"].items(), key=lambda kv: -kv[1][1]
    ):
        print(f"  {k:34s} {rows:>9,} 行  {human(byts):>12s}")
    if not keep_blobs:
        print(
            f"  {'agentKv:blob (丢弃)':34s} {stats['dropped_blob_rows']:>9,} 行"
            f"  —— 子代理内容寻址缓存；磁盘上的 agent-transcripts 仍保留"
        )
    print(f"\n预计新库体积: {human(projected)}")
    print(f"预计可释放  : {human(cur_size - projected)}")
    need = projected + 512 * 1024 * 1024
    if free < need:
        print(f"\n[空间不足] 需要 {human(need)}，当前 {human(free)}。")
        if keep_blobs:
            print("           去掉 --keep-agent-blobs 可缩小新库。")
        return 1
    print(f"[空间检查] 通过（新库 + 预留 512 MiB = {human(need)} ≤ 可用 {human(free)}）")
    return 0


def rebuild_header_index(rows: list[tuple]) -> dict:
    heads, draft = [], None
    for cid, is_sub, raw in rows:
        cid = as_key(cid)
        try:
            info = json.loads(as_text(raw) or "{}")
        except Exception:
            info = {"type": "head", "composerId": cid}
        if not isinstance(info, dict):
            continue
        info.setdefault("composerId", cid)
        if info.get("isSubagent") or is_sub or info.get("isBestOfNSubcomposer"):
            continue
        if cid == "empty-state-draft" or info.get("isDraft"):
            draft = info
            continue
        heads.append(info)
    heads.sort(
        key=lambda e: int(e.get("lastUpdatedAt") or e.get("createdAt") or 0),
        reverse=True,
    )
    return {"allComposers": ([draft] if draft else []) + heads}


def copy_kv_range(sc, dc, lo: str, hi: str) -> int:
    sc.execute("SELECT key, value FROM cursorDiskKV WHERE key >= ? AND key < ?", (lo, hi))
    total = 0
    while True:
        raw = sc.fetchmany(2000)
        if not raw:
            break
        dc.executemany(
            "INSERT INTO cursorDiskKV(key, value) VALUES (?,?)",
            [(as_key(k), as_kv_value(v)) for k, v in raw],
        )
        total += len(raw)
    return total


def slim_apply(db: str, out: str, cls: dict, keep_blobs: bool) -> None:
    keep = cls["keep"]
    if os.path.exists(out):
        print(f"[清理] 删除半成品 {out} ({human(os.path.getsize(out))})")
        os.remove(out)
        remove_sidecars(out)
    require_idle(db)
    print("[1/5] 合并 WAL 到主库 ...")
    checkpoint(db)

    src = connect_ro(db)
    dst = sqlite3.connect(out, timeout=120)
    copy_schema(src, dst)
    sc, dc = src.cursor(), dst.cursor()

    print("[2/5] 复制 ItemTable 与会话索引 ...")
    sc.execute("SELECT key, value FROM ItemTable")
    dc.executemany(
        "INSERT INTO ItemTable(key, value) VALUES (?,?)",
        [(as_key(k), as_kv_value(v)) for k, v in sc.fetchall()],
    )
    marks = ",".join("?" * len(keep)) or "NULL"
    sc.execute(
        f"SELECT composerId, isSubagent, value FROM composerHeaders "
        f"WHERE composerId IN ({marks})",
        tuple(keep),
    )
    header = rebuild_header_index(sc.fetchall())
    dc.execute(
        "INSERT INTO ItemTable(key, value) VALUES (?,?)",
        ("composer.composerHeaders", json.dumps(header, ensure_ascii=False)),
    )
    sc.execute(
        f"SELECT composerId, workspaceId, createdAt, lastUpdatedAt, isArchived, "
        f"isSubagent, recency, checkpointAt, value FROM composerHeaders "
        f"WHERE composerId IN ({marks})",
        tuple(keep),
    )
    dc.executemany(
        "INSERT INTO composerHeaders VALUES (?,?,?,?,?,?,?,?,?)",
        [
            (
                as_key(r[0]),
                as_text(r[1]),
                r[2],
                r[3],
                r[4],
                r[5],
                r[6],
                r[7],
                as_text(r[8]),
            )
            for r in sc.fetchall()
        ],
    )
    dst.commit()
    print(f"      侧栏 allComposers = {len(header['allComposers'])}")

    print("[3/5] 复制保留会话的正文数据 ...")
    total = 0
    for prefix in COMPOSER_SCOPED:
        for cid in keep:
            total += copy_kv_range(sc, dc, f"{prefix}:{cid}", f"{prefix}:{cid}~")
        dst.commit()
        print(f"      {prefix:34s} 累计 {total:,} 行")
    for prefix in KEEP_WHOLESALE:
        total += copy_kv_range(sc, dc, prefix, prefix + "~")
        dst.commit()
        print(f"      {prefix + '*':34s} 累计 {total:,} 行")
    if keep_blobs:
        total += copy_kv_range(sc, dc, "agentKv:", "agentKv;")
        dst.commit()
        print(f"      {'agentKv:blob':34s} 累计 {total:,} 行")

    print("[4/5] 校验新库 ...")
    dc.execute("PRAGMA integrity_check")
    res = dc.fetchone()[0]
    if res != "ok":
        src.close()
        dst.close()
        sys.exit(f"新库自检失败：{res}；原库未动，删除 {out} 即可")
    for table, pred in (
        ("ItemTable", "typeof(key)!='text'"),
        ("composerHeaders", "typeof(composerId)!='text'"),
        ("cursorDiskKV", "typeof(key)!='text'"),
    ):
        dc.execute(f"SELECT COUNT(*) FROM {table} WHERE {pred}")
        n = dc.fetchone()[0]
        if n:
            src.close()
            dst.close()
            sys.exit(f"{table} 仍有 {n} 行键不是 TEXT，已中止就位")
    dc.execute("SELECT COUNT(*) FROM composerHeaders")
    n_heads = dc.fetchone()[0]
    dc.execute("SELECT COUNT(*) FROM cursorDiskKV")
    n_kv = dc.fetchone()[0]
    finish_wal(dst)
    src.close()
    dst.close()
    print(f"      会话 {n_heads} 条，KV {n_kv:,} 行，integrity_check=ok，键类型=TEXT")

    print("[5/5] 就位（原库改名保留）...")
    swap_in(db, out, ".pre-slim")


def cmd_slim(args: argparse.Namespace) -> None:
    db = os.path.abspath(os.path.expanduser(args.db))
    if not os.path.exists(db):
        sys.exit(f"找不到库文件：{db}")
    out = args.out or db + ".slim"
    conn = connect_ro(db)
    cls = classify(conn, args.days)
    stats = measure(conn, cls["keep"], args.keep_agent_blobs)
    code = report(db, cls, stats, args.days, args.keep_agent_blobs)
    conn.close()
    if not args.apply:
        print("\n以上为 dry-run，未改动任何数据。加 --apply 执行。")
        sys.exit(code)
    if code != 0:
        sys.exit(code)
    slim_apply(db, out, cls, args.keep_agent_blobs)


def pick_header_row(old, new):
    if old is None:
        return new
    old_upd, new_upd = old[3] or 0, new[3] or 0
    if new_upd != old_upd:
        return new if new_upd > old_upd else old
    return new if len(new[8] or "") >= len(old[8] or "") else old


def load_header_rows(cur: sqlite3.Cursor) -> dict[str, tuple]:
    cur.execute(
        "SELECT composerId, workspaceId, createdAt, lastUpdatedAt, isArchived, "
        "isSubagent, recency, checkpointAt, value FROM composerHeaders"
    )
    by_id = {}
    for row in cur.fetchall():
        rec = (
            as_key(row[0]),
            as_text(row[1]),
            row[2],
            row[3],
            row[4],
            row[5],
            row[6],
            row[7],
            as_text(row[8]),
        )
        by_id[rec[0]] = pick_header_row(by_id.get(rec[0]), rec)
    return by_id


def resolve_item_value(key: str, versions: dict) -> tuple[str, str]:
    blob, text = versions.get("blob"), versions.get("text")
    if blob is None:
        return text, "仅新写入"
    if text is None:
        return blob, "仅旧副本"
    if blob == text:
        return text, "两边相同"
    if key in KEEP_LIVE_TEXT or key.startswith("cursor/glass.tabs."):
        return text, "保留当前会话"
    if key == "composer.composerHeaders":
        return blob, "稍后重建"
    if key == "__$__isNewStorageMarker":
        return "false", "强制非新库"
    if key == "__$__targetStorageMarker":
        return blob, "先用原标记再合并"
    return blob, "恢复精简前配置"


def merge_target_marker(original: str | None, keys: list[str]) -> str:
    try:
        marker = json.loads(original) if original else {}
    except Exception:
        marker = {}
    if not isinstance(marker, dict):
        marker = {}
    for k in keys:
        marker.setdefault(k, 1)
    return json.dumps(marker, ensure_ascii=False, separators=(",", ":"))


def cmd_repair(args: argparse.Namespace) -> None:
    db = os.path.abspath(os.path.expanduser(args.db))
    if not os.path.exists(db):
        sys.exit(f"找不到库文件：{db}")
    if not args.apply:
        conn = connect_ro(db)
        cur = conn.cursor()
        print(f"库文件 : {db}")
        print(f"体积   : {human(os.path.getsize(db))}")
        cur.execute("PRAGMA quick_check")
        print(f"quick_check : {cur.fetchone()[0]}")
        cur.execute(
            "SELECT typeof(key), COUNT(*) FROM ItemTable GROUP BY 1"
        )
        print("ItemTable 键类型 :", cur.fetchall())
        cur.execute(
            "SELECT typeof(composerId), COUNT(*) FROM composerHeaders GROUP BY 1"
        )
        print("composerHeaders 键类型 :", cur.fetchall())
        conn.close()
        print("\n以上为检查。完全退出 Cursor 后加 --apply 执行修复。")
        return

    out = db + ".repaired"
    if os.path.exists(out):
        print(f"[清理] 删除半成品 {out} ({human(os.path.getsize(out))})")
        os.remove(out)
        remove_sidecars(out)
    require_idle(db)
    need = os.path.getsize(db) + 512 * 1024 * 1024
    free = shutil.disk_usage(os.path.dirname(db)).free
    if free < need:
        sys.exit(f"空间不足：写新库需要 {human(need)}，当前 {human(free)}")

    print("[1/5] 合并 WAL ...")
    checkpoint(db)
    src = connect_ro(db)
    dst = sqlite3.connect(out, timeout=120)
    copy_schema(src, dst)
    sc, dc = src.cursor(), dst.cursor()

    print("[2/5] 修复 ItemTable ...")
    sc.execute("SELECT key, value FROM ItemTable")
    grouped: dict[str, dict] = {}
    for key, value in sc.fetchall():
        k = as_key(key)
        src_kind = "blob" if isinstance(key, bytes) else "text"
        grouped.setdefault(k, {})[src_kind] = as_text(value)
    resolved, reasons = {}, {}
    for key, versions in grouped.items():
        val, why = resolve_item_value(key, versions)
        resolved[key] = val
        reasons[why] = reasons.get(why, 0) + 1
    headers = load_header_rows(sc)
    header = rebuild_header_index(
        [(cid, rec[5], rec[8]) for cid, rec in headers.items()]
    )
    resolved["composer.composerHeaders"] = json.dumps(header, ensure_ascii=False)
    resolved["composer.composerHeaders.version"] = (
        f"{int(time.time() * 1000)}-{len(header['allComposers'])}"
    )
    resolved["__$__isNewStorageMarker"] = "false"
    resolved["__$__targetStorageMarker"] = merge_target_marker(
        resolved.get("__$__targetStorageMarker"), list(resolved)
    )
    dc.executemany(
        "INSERT INTO ItemTable(key, value) VALUES (?,?)", list(resolved.items())
    )
    dst.commit()
    print("      原因统计:", ", ".join(f"{k} {v}" for k, v in sorted(reasons.items())))
    print(f"      会话索引 allComposers = {len(header['allComposers'])}")

    print("[3/5] 复制 composerHeaders ...")
    dc.executemany(
        "INSERT INTO composerHeaders VALUES (?,?,?,?,?,?,?,?,?)",
        list(headers.values()),
    )
    dst.commit()
    print(f"      会话头 {len(headers)} 条")

    print("[4/5] 复制 cursorDiskKV ...")
    sc.execute(
        "SELECT key, value FROM cursorDiskKV "
        "WHERE typeof(key)='text' OR CAST(key AS TEXT) NOT IN ("
        "  SELECT CAST(key AS TEXT) FROM cursorDiskKV WHERE typeof(key)='text')"
    )
    total = kept_blob = 0
    while True:
        raw = sc.fetchmany(2000)
        if not raw:
            break
        batch = []
        for key, value in raw:
            val = as_kv_value(value)
            if isinstance(val, bytes):
                kept_blob += 1
            batch.append((as_key(key), val))
        dc.executemany("INSERT INTO cursorDiskKV(key, value) VALUES (?,?)", batch)
        total += len(batch)
        if total % 100000 < 2000:
            print(f"      已复制 {total:,} 行")
    dst.commit()
    print(f"      共 {total:,} 行，二进制 value {kept_blob:,} 行")

    print("[5/5] 校验并就位 ...")
    dc.execute("PRAGMA integrity_check")
    res = dc.fetchone()[0]
    if res != "ok":
        src.close()
        dst.close()
        sys.exit(f"新库自检失败：{res}；原库未动，删除 {out} 即可")
    dc.execute("SELECT COUNT(*) FROM ItemTable WHERE typeof(key)!='text'")
    if dc.fetchone()[0]:
        src.close()
        dst.close()
        sys.exit("ItemTable 键仍有非 TEXT，已中止")
    dc.execute("SELECT value FROM ItemTable WHERE key='cursorAuth/cachedEmail'")
    email = (dc.fetchone() or [None])[0]
    dc.execute("SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken'")
    token_ok = bool((dc.fetchone() or [None])[0])
    finish_wal(dst)
    src.close()
    dst.close()
    print(f"      email={email!r}，token={'有' if token_ok else '无'}")
    swap_in(db, out, ".pre-typefix")


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(description="整理 Cursor 本地会话库 state.vscdb")
    sub = ap.add_subparsers(dest="cmd", required=True)

    slim = sub.add_parser("slim", help="按归档 / 活跃度精简（默认 dry-run）")
    slim.add_argument("--db", default=default_db())
    slim.add_argument("--days", type=int, default=7)
    slim.add_argument("--apply", action="store_true")
    slim.add_argument("--keep-agent-blobs", action="store_true")
    slim.add_argument("--out", default=None)
    slim.set_defaults(func=cmd_slim)

    repair = sub.add_parser("repair", help="修复 BLOB 键 / 重建侧栏索引")
    repair.add_argument("--db", default=default_db())
    repair.add_argument("--apply", action="store_true")
    repair.set_defaults(func=cmd_repair)

    args = ap.parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
