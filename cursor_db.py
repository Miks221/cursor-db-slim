#!/usr/bin/env python3
"""整理 Cursor 本地会话库 state.vscdb。

子命令：
  prune   原地删除已归档 / 超过 N 天未更新的会话（默认 dry-run），适合定期跑
  slim    按归档 / 活跃度复制出精简库（默认 dry-run）
  repair  把误写成 BLOB 的键改回 TEXT，并重建侧栏索引

用法：
  python3 ~/cursor-db-slim/cursor_db.py prune --days 5
  python3 ~/cursor-db-slim/cursor_db.py prune --days 5 --protect-pinned --fix-pins --apply
  python3 ~/cursor-db-slim/cursor_db.py slim --days 7 --apply
  python3 ~/cursor-db-slim/cursor_db.py repair --apply

agentKv:blob 是会话检查点的内容寻址存储，不是可丢的缓存：消息的 conversationState
指向这里，缺一块 Cursor 就报 "This conversation's data is missing and can't be restored"。
有一部分块是用会话的 blobEncryptionKey 加密的，从外面看不到它们还引用了谁，所以
"只复制走得到的块"会漏。默认改为 safe：只删被清理会话走得到、而保留会话走不到的块，
谁也走不到的块原样保留。
  safe（默认）  只删上面那部分
  all          一块不删
  none         全部丢弃，保留的会话都无法续聊，只在明确不要这些会话时用
[未验证] safe 的判定依赖"加密块里的引用不会单独指向被删会话才可见的块"。还没在真实库上
跑过 prune --apply 之后逐个打开保留会话续聊确认；验证前保留 .pre-prune-* / .pre-slim。

必须先完全退出 Cursor。prune 先克隆一份 .pre-prune-<时间> 再原地删（默认留最近 3 份），
删完在新库上重走一遍保留会话：行数不变、引用到的块都在，否则自动换回；
slim 原库只读复制，成功后再就位，失败可弃用临时文件。

硬约束（精简时写错过一次，已写进复制路径）：
  - 禁止 text_factory=bytes。键必须是 TEXT，否则 Cursor 用字符串查不到登录态。
  - 侧栏索引用 composerHeaders.value 重建，不要按 allComposers 过滤（会剪空）。
  - cursorDiskKV 的 value 有二进制，不能一律 CAST AS TEXT。
"""

from __future__ import annotations

import argparse
import base64
import binascii
import json
import os
import re
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

AGENT_KV = ("agentKv:", "agentKv;")
BLOB_PREFIX = "agentKv:blob:"
BLOB_RANGE = ("agentKv:blob:", "agentKv:blob;")
CHECKPOINT_PREFIXES = ("agentKv:checkpoint:", "agentKv:bubbleCheckpoint:")
BLOB_SEED_PREFIXES = ("bubbleId", "composerData", "checkpointId")
BLOB_MODES = ("safe", "all", "none")
PINNED_KEY = "cursor/pinnedComposers"
# protobuf 里长度 32 的 length-delimited 字段：0x20 前一字节是 wire type 2 的 tag 末字节
PB_HASH = re.compile(
    rb"(?s)(?<=["
    + re.escape(bytes(b for b in range(0x80) if b & 7 == 2))
    + rb"])\x20(?=(.{32}))"
)
HEX_HASH = re.compile(rb"[0-9a-fA-F]{64}")
B64_HASH = re.compile(rb"[A-Za-z0-9+/_-]{43}=")
HEX_STATE = re.compile(r"(?:[0-9a-fA-F]{2})+")


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


def value_bytes(v) -> bytes:
    if v is None:
        return b""
    return v.encode("utf-8") if isinstance(v, str) else bytes(v)


def b64_bytes(s) -> bytes | None:
    if isinstance(s, str):
        s = s.encode("ascii", "ignore")
    s = s.replace(b"-", b"+").replace(b"_", b"/")
    try:
        return base64.b64decode(s + b"=" * (-len(s) % 4))
    except (binascii.Error, ValueError):
        return None


def hash_candidates(data: bytes):
    """data 里所有可能是块哈希的 32 字节串；调用方再按已知块过滤，误报只会少删。"""
    for m in PB_HASH.finditer(data):
        yield m.group(1)
    for m in HEX_HASH.finditer(data):
        yield bytes.fromhex(m.group().decode())
    for m in B64_HASH.finditer(data):
        b = b64_bytes(m.group())
        if b and len(b) == 32:
            yield b


def encoded_states(obj, out: list) -> None:
    """JSON 里 "~base64" 或长十六进制的字段（conversationState 等）解码后收进 out。"""
    if isinstance(obj, str):
        if obj.startswith("~") and len(obj) > 8:
            b = b64_bytes(obj[1:])
            if b:
                out.append(b)
        elif len(obj) >= 64 and len(obj) % 2 == 0 and HEX_STATE.fullmatch(obj):
            out.append(bytes.fromhex(obj))
    elif isinstance(obj, dict):
        for v in obj.values():
            encoded_states(v, out)
    elif isinstance(obj, list):
        for v in obj:
            encoded_states(v, out)


def id_ranges(base: str) -> list[tuple[str, str]]:
    """base 本身和 base: 开头的键；不会命中以 base 为前缀的其他 id。"""
    return [(base, base + "\x01"), (base + ":", base + ";")]


def scoped_ranges(cid: str, prefixes=COMPOSER_SCOPED) -> list[tuple[str, str]]:
    ranges = [r for p in prefixes for r in id_ranges(f"{p}:{cid}")]
    ranges += [r for p in CHECKPOINT_PREFIXES for r in id_ranges(f"{p}{cid}")]
    return ranges


def composer_ranges(cid: str) -> list[tuple[str, str]]:
    return scoped_ranges(cid)


def seed_refs(cur: sqlite3.Cursor, cid: str, known: dict) -> set[bytes]:
    ranges = scoped_ranges(cid, BLOB_SEED_PREFIXES)
    refs: set[bytes] = set()
    for lo, hi in ranges:
        rows = cur.execute(
            "SELECT value FROM cursorDiskKV WHERE key >= ? AND key < ?", (lo, hi)
        ).fetchall()
        for (v,) in rows:
            raw = value_bytes(v)
            chunks = [raw]
            try:
                encoded_states(json.loads(raw), chunks)
            except (ValueError, UnicodeDecodeError):
                pass
            for chunk in chunks:
                refs.update(h for h in hash_candidates(chunk) if h in known)
    return refs


def load_blob_keys(cur: sqlite3.Cursor) -> dict[bytes, str]:
    known = {}
    for (k,) in cur.execute(
        "SELECT key FROM cursorDiskKV WHERE key >= ? AND key < ?", BLOB_RANGE
    ).fetchall():
        k = as_key(k)
        try:
            known[bytes.fromhex(k[len(BLOB_PREFIX):])] = k
        except ValueError:
            continue
    return known


def blob_closure(cur, roots, known: dict, cache: dict) -> set[bytes]:
    seen: set[bytes] = set()
    stack = [h for h in roots if h in known]
    while stack:
        h = stack.pop()
        if h in seen:
            continue
        seen.add(h)
        kids = cache.get(h)
        if kids is None:
            row = cur.execute(
                "SELECT value FROM cursorDiskKV WHERE key = ?", (known[h],)
            ).fetchone()
            data = value_bytes(row[0] if row else None)
            kids = {k for k in hash_candidates(data) if k in known and k != h}
            cache[h] = kids
        stack.extend(kids - seen)
    return seen


def blob_plan(conn: sqlite3.Connection, keep: set[str], purge: set[str]) -> dict:
    """keep_set：保留会话走得到的块；drop：只有被清理会话走得到的块。"""
    cur = conn.cursor()
    known = load_blob_keys(cur)
    cache: dict = {}
    keep_roots: set[bytes] = set()
    for cid in keep:
        keep_roots |= seed_refs(cur, cid, known)
    purge_roots: set[bytes] = set()
    for cid in purge:
        purge_roots |= seed_refs(cur, cid, known)
    keep_set = blob_closure(cur, keep_roots, known, cache)
    drop = blob_closure(cur, purge_roots, known, cache) - keep_set
    drop_bytes = 0
    for h in drop:
        drop_bytes += cur.execute(
            "SELECT COALESCE(length(CAST(value AS BLOB)),0) FROM cursorDiskKV WHERE key = ?",
            (known[h],),
        ).fetchone()[0]
    return {
        "total": len(known),
        "known": known,
        "keep_keys": {known[h] for h in keep_set},
        "drop_keys": {known[h] for h in drop},
        "drop_bytes": drop_bytes,
    }


def missing_keys(conn: sqlite3.Connection, keys) -> list[str]:
    cur = conn.cursor()
    return [
        k
        for k in keys
        if cur.execute("SELECT 1 FROM cursorDiskKV WHERE key = ?", (k,)).fetchone()
        is None
    ]


def workspace_dbs(db: str) -> list[str]:
    root = os.path.join(os.path.dirname(os.path.dirname(db)), "workspaceStorage")
    if not os.path.isdir(root):
        return []
    out = []
    for name in sorted(os.listdir(root)):
        path = os.path.join(root, name, "state.vscdb")
        if os.path.exists(path):
            out.append(path)
    return out


def read_pins(path: str) -> list | None:
    try:
        conn = connect_ro(path)
        row = conn.execute(
            "SELECT value FROM ItemTable WHERE key = ?", (PINNED_KEY,)
        ).fetchone()
        conn.close()
    except sqlite3.Error:
        return None
    if not row:
        return None
    try:
        pins = json.loads(as_text(row[0]) or "[]")
    except ValueError:
        return None
    return pins if isinstance(pins, list) else None


def pinned_ids(db: str) -> set[str]:
    ids = set()
    for path in workspace_dbs(db):
        for p in read_pins(path) or []:
            if isinstance(p, str):
                ids.add(p)
    return ids


def fix_pins(db: str, alive: set[str], apply: bool, backup: str | None = None) -> int:
    """删掉指向已不存在会话的置顶；返回去掉的条数。apply 时原名单先写进 backup。"""
    removed, saved = 0, {}
    for path in workspace_dbs(db):
        pins = read_pins(path)
        if not pins:
            continue
        kept = [p for p in pins if not isinstance(p, str) or p in alive]
        if len(kept) == len(pins):
            continue
        if apply and db_holders(path):
            print(f"      {path} 被占用，置顶未改")
            continue
        removed += len(pins) - len(kept)
        saved[path] = (pins, kept)
    if apply and saved:
        if backup:
            with open(backup, "w", encoding="utf-8") as fh:
                json.dump({p: v[0] for p, v in saved.items()}, fh)
        for path, (_, kept) in saved.items():
            w = sqlite3.connect(path, timeout=60)
            with w:
                w.execute(
                    "UPDATE ItemTable SET value = ? WHERE key = ?",
                    (json.dumps(kept), PINNED_KEY),
                )
            w.close()
    return removed


def cursor_is_running() -> list[str]:
    """只认 Cursor 主进程，忽略 Helper / crashpad。"""
    try:
        out = subprocess.run(
            ["pgrep", "-fl", "Cursor.app/Contents/MacOS/Cursor"],
            capture_output=True,
            text=True,
            timeout=15,
        ).stdout.strip()
    except Exception:
        return []
    return [
        l
        for l in out.splitlines()
        if l.strip()
        and "Cursor.app/Contents/MacOS/Cursor" in l
        and "Cursor Helper" not in l
        and "CursorDBCleaner" not in l
    ]


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
    busy, _, _ = w.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
    w.close()
    wal = db + "-wal"
    left = os.path.getsize(wal) if os.path.exists(wal) else 0
    if busy or left:
        sys.exit(f"WAL 没能合并进主库（busy={busy}，-wal 剩 {human(left)}），已中止")


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


def classify(conn: sqlite3.Connection, days: int, protect: set[str] = frozenset()) -> dict:
    cur = conn.cursor()
    cutoff = int(time.time() * 1000) - days * 86_400_000
    cur.execute(
        "SELECT composerId, createdAt, lastUpdatedAt, isArchived, isSubagent, value "
        "FROM composerHeaders"
    )
    heads = {}
    for cid, created, updated, archived, is_sub, value in cur.fetchall():
        cid = as_key(cid)
        try:
            info = json.loads(as_text(value) or "{}")
        except Exception:
            info = {}
        if not isinstance(info, dict):
            info = {}
        sub = info.get("subagentInfo") or {}
        child = bool(is_sub) or bool(info.get("isBestOfNSubcomposer"))
        parent = None
        if child:
            parent = (
                sub.get("rootParentConversationId")
                or sub.get("parentComposerId")
                or info.get("parentComposerId")
            )
        heads[cid] = {
            "created": created or 0,
            "updated": updated or 0,
            "archived": bool(archived),
            "is_sub": child,
            "root": parent,
        }
    for cid, h in heads.items():
        root, seen = h["root"], {cid}
        while root in heads and heads[root]["is_sub"] and heads[root]["root"] and root not in seen:
            seen.add(root)
            root = heads[root]["root"]
        h["root"] = root

    keep, reasons = set(), {}
    for cid, h in heads.items():
        if cid in protect or cid == "empty-state-draft":
            keep.add(cid)
            reasons[cid] = "指定保留"
        elif h["is_sub"] and h["root"] in heads:
            continue
        elif (not h["archived"]) and h["updated"] >= cutoff:
            keep.add(cid)
            reasons[cid] = "活跃"
    for cid, h in heads.items():
        if h["is_sub"] and h["root"] in heads and h["root"] in keep and cid not in keep:
            keep.add(cid)
            reasons[cid] = "子代理跟随父会话"

    return {
        "heads": heads,
        "keep": keep,
        "purge": set(heads) - keep,
        "cutoff": cutoff,
        "archived": {c for c, h in heads.items() if h["archived"]},
        "stale": {
            c for c, h in heads.items() if not h["archived"] and h["updated"] < cutoff
        },
        "protected": {c for c in heads if c in protect},
    }


def measure(conn: sqlite3.Connection, keep: set[str], mode: str, plan: dict | None) -> dict:
    cur = conn.cursor()
    stats = {"per_prefix": {}, "keep_bytes": 0, "keep_rows": 0}
    for prefix in COMPOSER_SCOPED:
        rows = byts = 0
        for cid in keep:
            for lo, hi in id_ranges(f"{prefix}:{cid}"):
                cur.execute(
                    "SELECT COUNT(*), COALESCE(SUM(length(CAST(value AS BLOB))),0) "
                    "FROM cursorDiskKV WHERE key >= ? AND key < ?",
                    (lo, hi),
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
        "SELECT COUNT(*), COALESCE(SUM(length(CAST(value AS BLOB))),0) "
        "FROM cursorDiskKV WHERE key >= ? AND key < ?",
        AGENT_KV,
    )
    blob_rows, blob_bytes = cur.fetchone()
    if mode == "none":
        stats["dropped_blob_rows"] = blob_rows
        return stats
    if mode == "safe" and plan:
        blob_rows -= len(plan["drop_keys"])
        blob_bytes -= plan["drop_bytes"]
        stats["dropped_blob_rows"] = len(plan["drop_keys"])
    stats["per_prefix"]["agentKv:*"] = (blob_rows, blob_bytes)
    stats["keep_rows"] += blob_rows
    stats["keep_bytes"] += blob_bytes
    return stats


def report(db: str, cls: dict, stats: dict, days: int, mode: str) -> int:
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
    if mode == "none":
        print(
            f"  {'agentKv (全部丢弃)':34s} {stats['dropped_blob_rows']:>9,} 行"
            f"  —— 保留的会话也将无法续聊"
        )
    elif mode == "safe":
        print(
            f"  {'agentKv:blob (只属于被清理会话)':34s} "
            f"{stats.get('dropped_blob_rows', 0):>9,} 行 → 丢弃"
        )
    print(f"\n预计新库体积: {human(projected)}")
    print(f"预计可释放  : {human(cur_size - projected)}")
    need = projected + 512 * 1024 * 1024
    if free < need:
        print(f"\n[空间不足] 需要 {human(need)}，当前 {human(free)}。")
        print("           可改用 prune 原地删除，不需要新库那么多空间。")
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


def copy_kv_range(sc, dc, lo: str, hi: str, raw_value=False, skip=None) -> int:
    sc.execute("SELECT key, value FROM cursorDiskKV WHERE key >= ? AND key < ?", (lo, hi))
    total = 0
    while True:
        raw = sc.fetchmany(2000)
        if not raw:
            break
        rows = [
            (as_key(k), v if raw_value else as_kv_value(v))
            for k, v in raw
        ]
        if skip:
            rows = [r for r in rows if not skip(r[0])]
        dc.executemany("INSERT INTO cursorDiskKV(key, value) VALUES (?,?)", rows)
        total += len(rows)
    return total


def purged_agent_key(purge: set[str], drop_keys: set[str]):
    def skip(key: str) -> bool:
        if key in drop_keys:
            return True
        for p in CHECKPOINT_PREFIXES:
            if key.startswith(p):
                cid = key[len(p):].split(":", 1)[0]
                return cid in purge
        return False

    return skip


def slim_apply(db: str, out: str, cls: dict, mode: str, plan: dict | None) -> None:
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
        f"isSubagent, recency, checkpointAt, value, subagentTypeName "
        f"FROM composerHeaders WHERE composerId IN ({marks})",
        tuple(keep),
    )
    dc.executemany(
        "INSERT INTO composerHeaders ("
        "composerId, workspaceId, createdAt, lastUpdatedAt, isArchived, "
        "isSubagent, recency, checkpointAt, value, subagentTypeName"
        ") VALUES (?,?,?,?,?,?,?,?,?,?)",
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
                as_text(r[9]),
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
            for lo, hi in id_ranges(f"{prefix}:{cid}"):
                total += copy_kv_range(sc, dc, lo, hi)
        dst.commit()
        print(f"      {prefix:34s} 累计 {total:,} 行")
    for prefix in KEEP_WHOLESALE:
        total += copy_kv_range(sc, dc, prefix, prefix + "~")
        dst.commit()
        print(f"      {prefix + '*':34s} 累计 {total:,} 行")
    if mode != "none":
        skip = purged_agent_key(cls["purge"], plan["drop_keys"] if plan else set())
        total += copy_kv_range(sc, dc, *AGENT_KV, raw_value=True, skip=skip)
        dst.commit()
        print(f"      {'agentKv:*':34s} 累计 {total:,} 行")

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
    if plan:
        lost = missing_keys(dst, plan["keep_keys"])
        if lost:
            src.close()
            dst.close()
            sys.exit(f"保留会话引用的 {len(lost)} 个块没进新库（如 {lost[0]}），已中止就位")
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
    mode = "all" if args.keep_agent_blobs else args.agent_blobs
    conn = connect_ro(db)
    bad = non_text_keys(conn)
    if bad:
        conn.close()
        sys.exit(f"有 {bad} 个键不是 TEXT，按范围查不到它们，先跑 repair --apply")
    cls = classify(conn, args.days, protect_set(args, db))
    plan = blob_plan(conn, cls["keep"], cls["purge"]) if mode != "none" else None
    if plan and mode == "all":
        plan["drop_keys"], plan["drop_bytes"] = set(), 0
    stats = measure(conn, cls["keep"], mode, plan)
    code = report(db, cls, stats, args.days, mode)
    conn.close()
    if not args.apply:
        print("\n以上为 dry-run，未改动任何数据。加 --apply 执行。")
        sys.exit(code)
    if code != 0:
        sys.exit(code)
    slim_apply(db, out, cls, mode, plan)


def protect_set(args: argparse.Namespace, db: str) -> set[str]:
    ids = set()
    for item in args.protect or []:
        ids.update(x.strip() for x in item.split(",") if x.strip())
    if args.protect_pinned:
        ids |= pinned_ids(db)
    return ids


def clone_file(src: str, dst: str) -> None:
    """macOS 上用 APFS clone，瞬间完成、不立刻占空间；其它系统整份复制。"""
    for suffix in ("", "-wal", "-shm"):
        if os.path.exists(dst + suffix):
            os.remove(dst + suffix)
    if sys.platform == "darwin":
        if subprocess.run(["cp", "-c", src, dst], capture_output=True).returncode == 0:
            return
    shutil.copy2(src, dst)


def restore_backup(db: str, backup: str) -> None:
    for suffix in ("-wal", "-shm"):
        if os.path.exists(db + suffix):
            os.remove(db + suffix)
    os.replace(backup, db)


def rotate_backups(db: str, suffix: str, keep: int) -> None:
    old = sorted(p for p in os.listdir(os.path.dirname(db)) if p.startswith(os.path.basename(db) + suffix))
    for name in old[:-keep] if keep > 0 else old:
        path = os.path.join(os.path.dirname(db), name)
        os.remove(path)
        print(f"      删除旧备份 {name}")


def non_text_keys(conn: sqlite3.Connection) -> int:
    n = conn.execute("SELECT COUNT(*) FROM cursorDiskKV WHERE typeof(key) != 'text'").fetchone()[0]
    n += conn.execute(
        "SELECT COUNT(*) FROM composerHeaders WHERE typeof(composerId) != 'text'"
    ).fetchone()[0]
    return n


def alive_ids(conn: sqlite3.Connection) -> set[str]:
    ids = {as_key(r[0]) for r in conn.execute("SELECT composerId FROM composerHeaders")}
    for (k,) in conn.execute(
        "SELECT key FROM cursorDiskKV WHERE key >= 'composerData:' AND key < 'composerData;'"
    ):
        ids.add(as_key(k)[len("composerData:"):])
    return ids


def kept_row_counts(conn: sqlite3.Connection, keep: set[str]) -> dict[str, int]:
    counts = {}
    for cid in keep:
        counts[cid] = sum(
            conn.execute(
                "SELECT COUNT(*) FROM cursorDiskKV WHERE key >= ? AND key < ?", (lo, hi)
            ).fetchone()[0]
            for lo, hi in composer_ranges(cid)
        )
    return counts


def verify_kept(conn: sqlite3.Connection, keep: set[str], counts: dict, known: dict) -> list[str]:
    """在删除后的库上重新走一遍保留会话：行数不变，引用到的块（按删除前的块表）都还在。"""
    problems = []
    for cid, n in kept_row_counts(conn, keep).items():
        if n != counts[cid]:
            problems.append(f"{cid} 行数 {counts[cid]} → {n}")
    cur = conn.cursor()
    roots: set[bytes] = set()
    for cid in keep:
        roots |= seed_refs(cur, cid, known)
    reach = blob_closure(cur, roots, known, {})
    lost = missing_keys(conn, [known[h] for h in reach])
    if lost:
        problems.append(f"保留会话引用的 {len(lost)} 个块不见了（如 {lost[0]}）")
    return problems


def refresh_header_index(conn: sqlite3.Connection) -> None:
    cur = conn.cursor()
    if not cur.execute(
        "SELECT 1 FROM ItemTable WHERE key = 'composer.composerHeaders'"
    ).fetchone():
        return
    cur.execute("SELECT composerId, isSubagent, value FROM composerHeaders")
    header = rebuild_header_index(cur.fetchall())
    cur.execute(
        "UPDATE ItemTable SET value = ? WHERE key = 'composer.composerHeaders'",
        (json.dumps(header, ensure_ascii=False),),
    )
    cur.execute(
        "UPDATE ItemTable SET value = ? WHERE key = 'composer.composerHeaders.version'",
        (f"{int(time.time() * 1000)}-{len(header['allComposers'])}",),
    )


def prune_report(db: str, cls: dict, plan: dict, conn, days: int, dangling: int) -> None:
    cur = conn.cursor()
    rows = byts = 0
    for cid in cls["purge"]:
        for lo, hi in composer_ranges(cid):
            r, b = cur.execute(
                "SELECT COUNT(*), COALESCE(SUM(length(CAST(value AS BLOB))),0) "
                "FROM cursorDiskKV WHERE key >= ? AND key < ?",
                (lo, hi),
            ).fetchone()
            rows += r
            byts += b
    heads = cls["heads"]
    top = [c for c in cls["purge"] if not heads[c]["is_sub"]]
    print(f"\n库文件      : {db}（{human(os.path.getsize(db))}）")
    print(
        f"清理条件    : 已归档，或 {days} 天内没有更新（截止 "
        f"{time.strftime('%Y-%m-%d %H:%M', time.localtime(cls['cutoff'] / 1000))}）"
    )
    print(f"会话总数    : {len(heads)}，保留 {len(cls['keep'])}，指定保留 {len(cls['protected'])}")
    print(f"待删会话    : {len(cls['purge'])}（顶层 {len(top)}，子代理 {len(cls['purge']) - len(top)}）")
    print(f"  会话数据行      : {rows:,} 行  {human(byts)}")
    print(
        f"  agentKv:blob    : 共 {plan['total']:,} 块，保留会话引用 {len(plan['keep_keys']):,}，"
        f"只属于待删会话 {len(plan['drop_keys']):,} 块 {human(plan['drop_bytes'])} → 删除"
    )
    print(f"  失效置顶        : {dangling} 条")
    print(f"预计腾出库内空间: {human(byts + plan['drop_bytes'])}（文件要 VACUUM 后才变小）")
    for cid in sorted(top, key=lambda c: heads[c]["updated"]):
        h = heads[cid]
        when = time.strftime("%m-%d %H:%M", time.localtime(h["updated"] / 1000)) if h["updated"] else "无时间"
        print(f"    {when} {'归档' if h['archived'] else '过期'} {cid}")


def cmd_prune(args: argparse.Namespace) -> None:
    db = os.path.abspath(os.path.expanduser(args.db))
    if not os.path.exists(db):
        sys.exit(f"找不到库文件：{db}")
    if args.apply:
        require_idle(db)
        print("[1/6] 合并 WAL ...")
        checkpoint(db)
    conn = connect_ro(db)
    bad = non_text_keys(conn)
    if bad:
        conn.close()
        sys.exit(f"有 {bad} 个键不是 TEXT，按范围查不到它们，先跑 repair --apply")
    cls = classify(conn, args.days, protect_set(args, db))
    if len(cls["purge"]) > args.max_purge:
        conn.close()
        sys.exit(f"待删 {len(cls['purge'])} 条，超过 --max-purge {args.max_purge}，已中止")
    if cls["purge"] and not (cls["keep"] - {"empty-state-draft"}) and not args.force:
        conn.close()
        sys.exit("清理后一个会话都不剩，确认要这样做再加 --force")
    plan = blob_plan(conn, cls["keep"], cls["purge"])
    alive_after = alive_ids(conn) - cls["purge"]
    dangling = fix_pins(db, alive_after, apply=False) if args.fix_pins else 0
    prune_report(db, cls, plan, conn, args.days, dangling)
    conn.close()
    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump(
                {
                    "purge": sorted(cls["purge"]),
                    "purge_top": sorted(c for c in cls["purge"] if not cls["heads"][c]["is_sub"]),
                    "keep": len(cls["keep"]),
                    "drop_blobs": len(plan["drop_keys"]),
                    "drop_blob_bytes": plan["drop_bytes"],
                    "dangling_pins": dangling,
                },
                fh,
                ensure_ascii=False,
            )
    if not args.apply:
        print("\n以上为 dry-run，未改动任何数据。加 --apply 执行。")
        return
    if not cls["purge"] and not dangling:
        print("\n没有要删的会话。")
        return

    stamp = time.strftime("%Y%m%d-%H%M%S")
    backup = f"{db}.pre-prune-{stamp}"
    print(f"[2/6] 克隆备份到 {backup} ...")
    conn = connect_ro(db)
    counts = kept_row_counts(conn, cls["keep"])
    conn.close()
    clone_file(db, backup)
    print("[3/6] 删除会话行与只属于它们的块 ...")
    try:
        w = sqlite3.connect(db, timeout=120)
        try:
            with w:
                for cid in cls["purge"]:
                    w.execute(
                        "DELETE FROM composerHeaders WHERE CAST(composerId AS TEXT) = ?", (cid,)
                    )
                    for lo, hi in composer_ranges(cid):
                        w.execute("DELETE FROM cursorDiskKV WHERE key >= ? AND key < ?", (lo, hi))
                w.executemany(
                    "DELETE FROM cursorDiskKV WHERE key = ?", [(k,) for k in plan["drop_keys"]]
                )
                refresh_header_index(w)
            print("[4/6] 核对 ...")
            problems = []
            check = w.execute("PRAGMA quick_check").fetchone()[0]
            if check != "ok":
                problems.append(f"quick_check={check}")
            heads = w.execute(
                "SELECT COUNT(DISTINCT CAST(composerId AS TEXT)) FROM composerHeaders"
            ).fetchone()[0]
            if heads != len(cls["keep"]):
                problems.append(f"会话头 {heads}/{len(cls['keep'])}")
            problems += verify_kept(w, cls["keep"], counts, plan["known"])
        finally:
            w.close()
    except BaseException:
        restore_backup(db, backup)
        print("      中途出错，已换回删除前的库")
        raise
    if problems:
        restore_backup(db, backup)
        sys.exit("核对失败（" + "；".join(problems[:5]) + "），已换回删除前的库")
    print(f"      quick_check=ok，保留会话行数不变、引用的块都在，会话头 {heads}")
    if args.fix_pins:
        conn = connect_ro(db)
        alive = alive_ids(conn)
        conn.close()
        pins_backup = f"{db}.pins-{stamp}.json"
        print(f"[5/6] 去掉失效置顶 {fix_pins(db, alive, apply=True, backup=pins_backup)} 条")
    else:
        print("[5/6] 置顶未动")
    if args.vacuum:
        w = sqlite3.connect(db, timeout=120)
        free_pages, page = (
            w.execute("PRAGMA freelist_count").fetchone()[0],
            w.execute("PRAGMA page_size").fetchone()[0],
        )
        spare = shutil.disk_usage(os.path.dirname(db)).free
        if free_pages * page < 256 * 2**20:
            print(f"[6/6] 空闲页只有 {human(free_pages * page)}，不 VACUUM")
        elif spare < os.path.getsize(db) * 2.2:
            print(f"[6/6] 磁盘只剩 {human(spare)}，不够 VACUUM")
        else:
            print(f"[6/6] VACUUM（回收 {human(free_pages * page)}）...")
            w.execute("VACUUM")
        w.close()
    else:
        print("[6/6] 未 VACUUM：库内空闲页会被后续写入复用")
    rotate_backups(db, ".pre-prune-", args.keep_backups)
    print(f"\n完成。库 {human(os.path.getsize(db))}；删除前的库在 {backup}（保留最近 {args.keep_backups} 份）。")


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
        "isSubagent, recency, checkpointAt, value, subagentTypeName FROM composerHeaders"
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
            as_text(row[9]),
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
        "INSERT INTO composerHeaders ("
        "composerId, workspaceId, createdAt, lastUpdatedAt, isArchived, "
        "isSubagent, recency, checkpointAt, value, subagentTypeName"
        ") VALUES (?,?,?,?,?,?,?,?,?,?)",
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

    def add_selection(p: argparse.ArgumentParser, days: int) -> None:
        p.add_argument("--db", default=default_db())
        p.add_argument("--days", type=int, default=days)
        p.add_argument("--apply", action="store_true")
        p.add_argument("--protect", action="append", help="始终保留的会话 id，逗号分隔，可重复")
        p.add_argument("--protect-pinned", action="store_true", help="置顶的会话始终保留")

    prune = sub.add_parser("prune", help="原地删除已归档 / 过期会话（默认 dry-run）")
    add_selection(prune, 5)
    prune.add_argument("--fix-pins", action="store_true", help="去掉指向已不存在会话的置顶")
    prune.add_argument(
        "--vacuum",
        action="store_true",
        help="空闲页超过 256 MiB 时 VACUUM；WAL 模式下要临时多占约一倍库体积",
    )
    prune.add_argument("--max-purge", type=int, default=500)
    prune.add_argument("--keep-backups", type=int, default=3, help="保留最近几份 .pre-prune-*")
    prune.add_argument("--force", action="store_true", help="允许清理后一个会话都不剩")
    prune.add_argument("--json", default=None, help="把待删清单写到这个文件")
    prune.set_defaults(func=cmd_prune)

    slim = sub.add_parser("slim", help="按归档 / 活跃度精简（默认 dry-run）")
    add_selection(slim, 7)
    slim.add_argument("--agent-blobs", choices=BLOB_MODES, default="safe")
    slim.add_argument("--keep-agent-blobs", action="store_true", help="同 --agent-blobs all")
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
