# Git 与两台机器同步

## origin/main 会被强推改写历史（实测 2026-09-24）

- Windows 那台会把 Mac 上的多个提交压成一两个新提交再强推，`git fetch` 会打印 `+ ... (forced update)`。
- 实测那次：Mac 本地 `129dfc5` 领先 19 个提交，远程 `4055fd3` 是同一批工作被压成 `1f01ee3` + `4055fd3` 两个提交。内容等价，但提交不再一一对应。
- **结论：Mac 上不要指望 `git pull` 能合并**，同步口径是"以远程为准覆盖本地"：

```sh
git fetch --all --prune
git branch backup/mac-<sha> <sha>   # 覆盖前先留备份，reflog 只有 90 天
git reset --hard origin/main
```

## 别信 `git status` 的 "up to date with 'origin/main'"

- 它只对照本地缓存的 remote-tracking ref，不代表远程没动。**要判断远程有没有新东西必须先 `git fetch`。**
- 反过来，本地自己的任务里那次 `status` 显示干净且 up to date，`fetch` 之后才发现远程已强推。
