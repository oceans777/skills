# oceans777 Skill Publishing Design

## 背景

`oceans777/skills` 已经是入口仓库，负责 clone 后初始化子仓库、验证结构、安装 skill，并保护用户本地已有 skill 不被覆盖。现在缺少的是安全、可重复的“上传本地 skill 到 GitHub 子仓库”的流程。

这个流程不能只是复制目录并提交。skill 会被完全开源，里面可能包含本机路径、token、私有提示词、第三方授权不清晰的内容，或者和另一个仓库里的 skill 同名。因此上传逻辑必须先审计、再明确分类、再 staging、再发布。

## 目标

新增程序化发布流程，让维护者可以在任意电脑上把本地 skill 安全地放入 oceans777 组织仓库：

```powershell
.\oceans.ps1 import
.\oceans.ps1 stage -SourceRoot "$HOME\.codex\skills" -Skill frontend-design -Target oceans
.\oceans.ps1 publish
```

POSIX shell 对应命令：

```sh
./oceans import
./oceans stage --source-root "$HOME/.codex/skills" --skill frontend-design --target oceans
./oceans publish
```

最终其他用户或另一台电脑只需要：

```sh
git clone https://github.com/oceans777/skills.git
cd skills
./setup.sh
```

Windows 用户使用：

```powershell
git clone https://github.com/oceans777/skills.git
cd skills
.\setup.ps1
```

## 非目标

第一版不做自动批量上传全部本地 skill。必须显式指定 skill 名称和目标仓库。

第一版不自动修复风险内容。脚本只报告风险并阻止 staging，维护者人工清理后重试；确实需要保留时用显式 override。

第一版不替维护者判断第三方授权是否合法。`community-skills` 必须有 attribution 文件，脚本验证文件存在，但授权判断仍由维护者负责。

## 命令模型

入口命令新增两个子命令：

```text
stage
publish
```

`stage` 只复制一个本地 skill 到目标子仓库的工作树，不提交、不推送。

`publish` 验证两个子仓库，提交并推送有变化的子仓库，然后回到入口仓库更新 submodule 指针并提交推送。

PowerShell 参数：

```powershell
.\oceans.ps1 stage -SourceRoot "$HOME\.codex\skills" -Skill frontend-design -Target oceans
.\oceans.ps1 stage -SourceRoot "$HOME\.agents\skills" -Skill discuz-x5 -Target oceans
.\oceans.ps1 stage -SourceRoot "$HOME\.codex\skills" -Skill adapted-skill -Target community -UpstreamUrl "https://github.com/example/adapted-skill" -UpstreamLicense MIT
.\oceans.ps1 publish
```

POSIX 参数：

```sh
./oceans stage --source-root "$HOME/.codex/skills" --skill frontend-design --target oceans
./oceans stage --source-root "$HOME/.agents/skills" --skill discuz-x5 --target oceans
./oceans stage --source-root "$HOME/.codex/skills" --skill adapted-skill --target community --upstream-url "https://github.com/example/adapted-skill" --upstream-license MIT
./oceans publish
```

## Stage 规则

`stage` 的输入：

```text
source_root: 本地 skill 根目录，默认 CODEX_HOME/skills 或 ~/.codex/skills
skill: 单个 skill 文件夹名
target: oceans 或 community
allow_risk: 默认 false
replace_existing: 默认 false
upstream_url: community 目标建议提供
upstream_license: community 目标建议提供
```

`stage` 的检查顺序：

1. 验证 source root 存在。
2. 验证 skill 名称只包含小写字母、数字、连字符。
3. 拒绝 `.system`。
4. 验证源 skill 目录存在。
5. 验证源 skill 有顶层 `SKILL.md`。
6. 扫描 secret-like 文本和本地绝对路径。
7. 如果发现风险且没有 `allow_risk`，失败并打印具体风险。
8. 检查 `repos/oceans-skills/skills/<skill>` 和 `repos/community-skills/skills/<skill>` 是否已有同名目录。
9. 如果任一目标已有同名目录且没有 `replace_existing`，失败。
10. 复制目录到目标子仓库。
11. 删除复制结果里的 `.oceans-skill-source`，避免把安装 marker 发布进源仓库。
12. 如果目标是 community，确保 `UPSTREAM.md`、`PATCHES.md`、`LICENSE` 存在；缺失时生成最小模板并让 `validate` 继续强制检查。

`stage` 的输出必须清楚说明：

```text
staged-skill: <name>
target_repository: oceans-skills 或 community-skills
target_path: <path>
risk_status: none detected 或 blocked
next: run validate, then publish
```

## Publish 规则

`publish` 的执行顺序：

1. 确认入口仓库工作树没有非 staged/publish 相关的未提交改动；如果有，失败并提示维护者先处理。
2. 在两个子仓库运行 status。
3. 运行 PowerShell 或 shell 版 `validate-skills`，取决于当前平台入口。
4. 对有变化的 `repos/oceans-skills` 提交：`skills: publish staged first-party skills`。
5. 对有变化的 `repos/community-skills` 提交：`skills: publish staged community skills`。
6. 推送有变化的子仓库。
7. 回到入口仓库，检测 submodule 指针变化。
8. 提交入口仓库：`repos: update skill submodules`。
9. 推送入口仓库。

如果任何一步失败，后续步骤停止，不做回滚。Git 工作树保留现场，维护者可以检查并继续。

## 安全策略

默认不上传任何 skill。维护者必须显式指定 skill 和 target。

默认不覆盖已有仓库 skill。覆盖必须显式使用 `replace_existing`。

默认不允许风险内容。风险包括：

```text
api_key、secret、token、password、authorization bearer、sk- 开头的疑似 key
/Users/、/home/、C:\Users\、/private/ 等本地绝对路径
```

默认不上传 `.system`。

默认不发布缺少 `SKILL.md` 的目录。

默认不发布跨仓库同名 skill。`validate` 已经负责拒绝这种情况，`stage` 也必须提前检查。

## 文件边界

新增脚本：

```text
scripts/stage-skill.ps1
scripts/stage-skill.sh
scripts/publish-skills.ps1
scripts/publish-skills.sh
```

修改入口：

```text
oceans.ps1
oceans
README.md
docs/commands.md
```

测试：

```text
scripts/test-stage-skill.ps1
scripts/test-stage-skill.sh
scripts/test-publish-skills.ps1
scripts/test-publish-skills.sh
```

## 数据流

```mermaid
flowchart LR
  Local["Local skill root"] --> Import["import report"]
  Local --> Stage["stage one explicit skill"]
  Stage --> FirstParty["repos/oceans-skills/skills"]
  Stage --> Community["repos/community-skills/skills"]
  FirstParty --> Validate["validate"]
  Community --> Validate
  Validate --> Publish["publish child repos"]
  Publish --> Entry["update oceans777/skills submodule pins"]
```

## 测试策略

测试必须使用临时目录和临时 Git 仓库，不写真实 `repos/oceans-skills` 或 `repos/community-skills`，也不写真实 `~/.codex/skills`。

`stage` 测试覆盖：

```text
成功 staging first-party skill
成功 staging community skill 并生成 attribution 模板
拒绝 .system
拒绝缺少 SKILL.md
拒绝 secret-like 内容
拒绝 local absolute path
拒绝跨仓库同名
拒绝覆盖已有 skill，除非显式 replace_existing
复制时移除 .oceans-skill-source marker
```

`publish` 测试覆盖：

```text
无子仓库变化时不提交
有 first-party 变化时只提交 first-party 子仓库并更新入口 submodule
有 community 变化时只提交 community 子仓库并更新入口 submodule
validate 失败时停止，不提交不推送
入口仓库有无关未提交改动时停止
```

网络推送测试不在单元测试里真实连接 GitHub。脚本内部应把 Git 命令集中在小函数里，测试可用本地 bare repo 作为 remote。

## 成功标准

维护者可以在 Windows、Ubuntu、macOS 上用相同流程上传单个 skill。

上传流程不会误覆盖仓库已有 skill。

上传流程不会默认发布有风险内容的 skill。

发布后，其他用户只 clone `oceans777/skills` 并运行 setup，就能同步到最新已发布 skill。

## 决策

采用显式单 skill staging，而不是全量自动上传。原因是它更适合开源发布：每次只处理一个清晰对象，审计结果和 Git diff 都容易 review。

采用 `stage` 和 `publish` 分离，而不是一个 `upload` 一步到位。原因是公开发布前需要给维护者检查工作树 diff 的机会。

保留 `import` 为 report-only。原因是 import 是发现和分类工具，不应该承担写入和发布职责。
