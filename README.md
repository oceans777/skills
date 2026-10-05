# oceans777（海洋技能库）

面向 AI（人工智能）编程助手的 Skill（技能）集合。

**选一个需要的技能，把下面对应的完整安装句子发给编程助手即可。你不需要自己记住克隆命令、安装目录或脚本参数。**

## 可用技能

### prd-blueprint（需求文档总纲技能）

当你明确要求编写或更新 PRD（产品需求文档）时，把当前可访问的讨论整理成“一句话目的＋功能清单＋验收标准”的独立总纲，再展开完整文档，并在对话中原样展示总纲。详细需求必须对应总纲，帮助发现遗漏、擅自扩展和验收缩水。

**安装：复制整句话，发给你正在使用的编程助手。**

```text
请帮我把这个 Skill（技能）安装到当前项目：https://github.com/oceans777/oceans-skills/tree/main/skills/prd-blueprint
```

**使用示例：**

> 使用 prd-blueprint（需求文档总纲技能），把我们刚才讨论的内容写成产品需求文档。

普通讨论、仅提及需求文档或明确要求暂不写文档时，不应触发文档生成。这个技能不自动启动开发，也不创建半小时定时核查任务。

[查看技能说明与完整文档](https://github.com/oceans777/oceans-skills/tree/main/docs/prd-blueprint) · [查看发布状态](catalog/skills/prd-blueprint.skill)

### git-upstream-sync-guard（上游代码同步保护技能）

用于持续接收官方更新的二次开发项目：区分上游镜像和自己的定制代码，同步前做预检，验证通过后再进入后续分支。出现冲突、工作区不干净或分支异常时先停止核查，不用强制覆盖掩盖问题。

**安装：复制整句话，发给你正在使用的编程助手。**

```text
请帮我把这个 Skill（技能）安装到当前项目：https://github.com/oceans777/oceans-skills/tree/main/skills/git-upstream-sync-guard
```

**使用示例：**

> 使用 git-upstream-sync-guard（上游代码同步保护技能），先检查当前项目的上游同步方案，暂时不要合并代码。

[查看技能说明](https://github.com/oceans777/oceans-skills/blob/main/skills/git-upstream-sync-guard/SKILL.md) · [查看发布状态](catalog/skills/git-upstream-sync-guard.skill)

## 安装后怎么用

先让助手确认技能已被当前项目识别，再发送上面的使用示例。之后可以正常描述需求，由支持自动匹配的助手按触发条件选择技能；没有匹配时，直接说“使用某某技能”。**文件已复制不等于已识别，也不等于每次都会自动触发。**

“一句话安装”是发给编程助手的请求，不是终端命令。助手需要支持技能、能够访问仓库，并获得目标目录的写入权限；不能访问你电脑的普通网页对话，不能直接完成本地安装。

<details>
<summary>安装范围、更新与结果核对</summary>

- 上面的句子指定“当前项目”。助手应确认项目根目录和当前工具支持的项目技能目录，只安装选中的技能；不支持项目级安装时应说明，不能悄悄改成全局安装。
- 安装应包含完整技能目录及其模板、引用资料和脚本，不能只复制 `SKILL.md`（技能说明文件）。仅在取得必要权限后执行安装；遇到同名文件或本地修改先保留并报告。
- 安装后应回报实际位置、来源版本和宿主识别结果。需要重新加载或重启时明确提示；未验证的部分不能标成成功。不因安装技能而改写业务代码、覆盖项目规则或创建定时任务。
- 上面的链接指向单个技能的源码目录。直接安装不等于使用本仓库的托管安装流程，不自动获得本仓库的版本固定、来源标记、内容指纹校验或归档停用管理。
- 单技能更新应沿用原安装方式，并先保留本地修改。已经使用本仓库托管安装的目录，应继续通过入口更新，避免混用安装方式覆盖管理标记；完整流程见[命令说明](docs/commands.md)和[技能生命周期](docs/skill-lifecycle.md)。

</details>

<details>
<summary>已归档技能与完整目录</summary>

首页仅推荐当前启用的技能。完整状态、归档原因和替代关系以[技能目录](catalog/skills)为准，状态含义见[技能生命周期](docs/skill-lifecycle.md)。

本入口的托管安装会跳过已归档技能，并按生命周期规则处理带有有效来源标记的已有副本。归档不会删除远端源码；通过第三方安装器或手工复制的副本不自动纳入本入口管理，不能把“源码仍可下载”当成“仍在推荐使用”。

</details>

## 高级使用与维护

普通使用者到这里即可。需要批量安装、统一更新或维护仓库时，再查看下面的内容。

<details>
<summary>备用：通过入口仓库批量安装</summary>

这不是上面的单技能项目级安装。默认初始化面向 Codex（编程助手）的用户级技能目录，安装当前启用的技能；不要为了安装一个项目技能，直接执行这套默认批量流程。

需先安装 Git（版本控制工具），并具备访问入口及子仓库的网络条件。在业务项目之外选择存放入口仓库的位置。

**Windows（视窗操作系统）：** 在 PowerShell（命令行环境）中执行：

```powershell
git clone https://github.com/oceans777/skills.git
cd skills
.\setup.ps1
```

**Ubuntu（乌班图操作系统）或 macOS（苹果电脑操作系统）：** 在终端中执行：

```sh
git clone https://github.com/oceans777/skills.git
cd skills
./setup.sh
```

`setup.ps1`（视窗初始化脚本）和 `setup.sh`（终端初始化脚本）会初始化固定版本的子仓库，无需用户另记子仓库命令。

更新托管技能时，在入口仓库目录先同步，再安装：

```powershell
.\oceans.ps1 sync
.\oceans.ps1 install
```

```sh
./oceans sync
./oceans install
```

其中 `sync`（同步）更新入口和固定的子仓库版本，并核对生命周期；`install`（安装）校验并更新已启用的托管技能。这里的默认命令针对默认用户级目录；曾经指定其他工具或自定义目录的，应继续沿用相同目标，不要把默认命令当成所有项目都已更新。

脚本报错、权限受限或网络不可达时，保留错误并排查，不强制覆盖文件或绕过组织的安全策略。手工安装及更多参数见[命令说明](docs/commands.md)。

</details>

| 文档 | 内容 |
| --- | --- |
| [安装、命令与发布](docs/commands.md) | 手工操作、不同工具、导入和维护者发布流程。 |
| [技能状态与审核](docs/skill-lifecycle.md) | 启用、候选审核、归档、阻止使用和内容完整性校验。 |
| [同步与冲突策略](docs/skill-sync-policy.md) | 托管更新和本地内容保护。 |
| [仓库结构](docs/repository-model.md) | 入口、自有技能和社区技能的职责划分。 |

本仓库负责导航和统一管理；技能源码分别位于 [oceans-skills（自有技能仓库）](https://github.com/oceans777/oceans-skills) 与 [community-skills（社区技能仓库）](https://github.com/oceans777/community-skills)。无需为使用单个技能同时安装全部仓库。
