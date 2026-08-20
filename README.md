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
python3 cursor_db.py slim            # dry-run
python3 cursor_db.py slim --apply
python3 cursor_db.py repair --apply
```

必须先完全退出 Cursor。原库会改名为带时间戳的备份，可在应用的「备份」页删除。
