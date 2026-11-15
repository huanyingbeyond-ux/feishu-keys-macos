# 换电脑后：拉取资产并同步到 GitHub

## 资产包里有什么

- `README.md` — 成果总览、按键对照表、架构图、实测验证
- `docs/` — 完整码表 / HID 协议 / 排障记录 / 本文件
- `src/` — 3 个 Swift 文件（守护进程 + 两个探针）
- `config/mapping.json` — 最终 26 条映射
- `tools/` — 安装自检脚本、HID 描述符解析脚本
- `.gitignore`、`LICENSE` 无
- **完整 `.git` 历史**：解压出来就是一个可直接 `git push` 的仓库，不需要重新 init / commit

## 方式 A：命令行（3 条命令，推荐）

前提：新电脑装了 `git`；GitHub 网页能登录。

1. 在 GitHub 网页新建空仓库，名字建议 `feishu-keys-macos`。**不要**勾选 `Add a README file`、`Add .gitignore`、`Choose a license`——勾了会产生首次提交冲突。
2. 解压资产包，进入解压出来的目录。
3. 依次执行：

```bash
git remote add origin https://github.com/<你的用户名>/feishu-keys-macos.git
git branch -M main
git push -u origin main
```

刷新仓库网页即可看到全部文件和提交历史。

> 如果 `git push` 提示输入密码：GitHub 已**不支持账号密码推送**。两种替代：
> - 生成一个 Personal Access Token（Settings → Developer settings → Tokens (classic) → 勾 `repo`），密码位置粘贴这串 `ghp_` 开头的字符；
> - 或安装 GitHub CLI 后用 `gh auth login` 走浏览器授权。

## 方式 B：完全不碰命令行，网页拖拽

1. 新建空仓库。
2. 仓库页 → **Add file** → **Upload files**。
3. 把解压出来的文件（`README.md`、`docs/`、`src/`、`config/`、`tools/`、`.gitignore`）拖进上传区。
4. 填提交说明 → **Commit changes**。

缺点：网页上传不会带本地提交历史（但资产包里的 `.git` 在本机仍保留）。

## 方式 C：GitHub CLI 一条命令

```bash
brew install gh
gh auth login
gh repo create feishu-keys-macos --public --source=. --remote=origin --push
```

## 换电脑后要让飞鼠重新生效（重要）

云端资产只是**代码和文档**，TCC 授权不会跟着迁移。在新电脑上：

1. 编译：`swiftc -O src/FeishuKeys.swift -o FeishuKeys`
2. 安装：`python3 tools/setup_daemon.py`（会按新电脑的用户目录重新生成 LaunchAgent、安装映射表、让 Karabiner 释放设备）
3. 系统设置 → 隐私与安全性 → **输入监控** 与 **辅助功能**，把新编译出的 `FeishuKeys` 加进去
4. 自检：`python3 tools/setup_daemon.py --check`，看到 `manager open=0` 与两条 `report-callback=OK` 即成功
5. **若需要重编译**，先按 `docs/TROUBLESHOOTING.md` 处理 TCC 授权，顺序不能反

## 安全

- 资产包**不含**任何 token、密码、SSH 私钥；`.gitignore` 已排除编译产物、备份和日志。
- 不要把 token 写进仓库里的任何文件或脚本；用完在 GitHub 设置里删除。
