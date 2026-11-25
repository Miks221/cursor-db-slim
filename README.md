# Cursor 数据库清理

精简 Cursor 本机 `state.vscdb` 的小工具：按时间 / 归档 / 会话类型筛选，预估体积后再清理。原生 macOS 应用，约 2 MB，arm64 + Intel。

## 下载

GitHub Actions 会在每次推送到 `main` 时打包 `.app`：

1. 打开仓库的 **Actions**
2. 选最近一次成功的 **Build**
3. 下载产物 `Cursor-DB-Cleaner-macos`

或打 `v*` 标签，CI 会挂到 Releases。

本地构建：

```bash
./macos/build.sh
open dist/Cursor\ 数据库清理.app
```

## 命令行

```bash
python3 cursor_db.py prune --days 5                       # dry-run：列出已归档 / 5 天未更新的会话
python3 cursor_db.py prune --days 5 --protect-pinned --fix-pins --vacuum --apply
python3 cursor_db.py slim            # dry-run
python3 cursor_db.py slim --apply
python3 cursor_db.py repair --apply
```

必须先完全退出 Cursor。原库会改名为带时间戳的备份，可在应用的「备份」页删除。

`prune` 在原库里直接删，先克隆一份 `.pre-prune`，核对失败自动换回，适合定期跑。
`agentKv:blob` 是会话检查点，不能整段丢：`prune`、`slim` 和 macOS 应用都只删被清理会话独占的块，保留会话引用到的块缺一个就中止。
