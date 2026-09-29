# machine-handoff

## 它是什么

`machine-handoff` 是一个面向 Windows 开发工作站的换机交接与恢复规划 Skill，适用于换新电脑、重装 Windows，或开发环境损坏后的重建。它使用本机 PowerShell 收集旧电脑的开发环境线索，并把结果整理成你指定位置的 Handoff Package，让你和 Agent 能先看清旧机有什么、目标机缺什么，再决定需要恢复哪些内容。它不是磁盘镜像或一键克隆整套 Windows 的工具。

## 它能帮你做什么

- **盘点环境：**检查 Windows 和开发工具的版本与状态，发现运行时、工具链、编辑器、AI Agent、WSL、容器、Git、SSH/GPG 的安全元数据，以及限定范围内的项目和数据路径。
- **整理可迁移配置：**对明确支持的 JSON/JSONC/文本/INI 配置限长读取；识别到敏感字段时先脱敏，无法安全处理时就不保存正文，并为安全工件记录独立文件和 hash。
- **比较新旧机器：**对照来源机和目标机快照，指出已存在、缺失、冲突或未知的项目，生成包含依赖、前置条件、风险和验证方式的恢复计划。
- **按批准恢复并核验：**目前只支持复制白名单内、已捕获的 `SAFE_COPY`/`REDACTED_COPY` 配置工件；目标已有文件时先备份，完成后重新采集并验证。

## 它会实际执行哪些操作

1. 根据所选模式运行仓库内的 PowerShell 脚本和固定的本机探测命令，并受全局/单项时间、命令输出、目录深度和文件大小预算限制。
2. 换机主流程是“旧机 `Prepare` → 新机 `Restore`”：先在旧电脑生成 Handoff Package，再把它带到新电脑，让 Agent 读取文档与清单、盘点目标机、整理差异并给出恢复步骤。完整迁移通常使用 `Deep`；快速盘点使用 `Standard`。
3. 将快照、清单、报告和安全配置工件写入 `-PackagePath`。winget 导出使用临时文件并在结束后清理；Package 不会自动上传。
4. `Restore` 默认只生成计划和结果，不改目标机。只有重新提供当前计划哈希和精确操作 ID 后，才会备份目标文件并执行白名单配置复制。

它不会扫描整个磁盘、复制整个 AppData、采集私钥或认证缓存、执行 Package 里的命令、安装软件、修改 Windows 系统设置、启动停止的 WSL 发行版或自动导入 WSL。Package 可能包含机器标签、私有路径、工具版本和项目状态，应放在可信位置并视为私有资料。

## 支持范围

- Windows PowerShell 5.1 是基线，PowerShell 7 同样支持。
- `Standard` 提供快速、安全的 metadata 盘点；`Deep` 增加有预算的开发生态采集和受支持配置文件的安全副本。
- `SafeMode` 是单独的开关：跳过 winget 导出和 WSL 命令探测，不代表 Standard/Deep。
- Deep 包含 Git 与 PowerShell、VS Code/Cursor、Codex/Claude/Gemini/OpenCode/Cursor Agent、Node/Python/.NET，以及 WSL Deep、Rust/Java/Go/C/C++/Visual Studio、JetBrains、Docker/Podman、SSH/GPG 的本机 metadata。
- 工作站摘要包含架构、CPU/RAM/GPU/逻辑磁盘摘要、固定 Optional Features、Developer Mode/Long Paths、代理状态、PowerToys 和 Windows Terminal；不会枚举全量设备/驱动。
- 缺失工具报告为 `NOT_FOUND`/`ABSENT`；超时、解析失败或未运行的检查会保留 `UNKNOWN`、`PARTIAL` 或 `NOT_TESTED`。
- 根目录发现有深度、目录数量和总时间预算，不跨 junction/reparse point。
- 配置和 Package JSON 输入有字节、深度、元素、字符串和数量上限；超限会返回固定的 partial/blocked 状态。

## 安装

使用 Vercel Skills CLI 安装到目标 Agent 的用户级 Skill 目录：

```powershell
npx skills add qingranawa/machine-handoff --skill machine-handoff --global
```

安装时按提示选择 Agent。安装器复制静态 Skill 文件，不会运行收集脚本。安装器需要 Node.js/npm；运行 Skill 脚本需要 PowerShell。首次使用 `npx` 时可能会提示确认运行 CLI。

`skills` 由 Vercel 提供并包含匿名使用遥测。安装前设置 `DISABLE_TELEMETRY=1` 或 `DO_NOT_TRACK=1` 可关闭遥测。详见 [skills CLI](https://github.com/vercel-labs/skills)。

更新和卸载：

```powershell
npx skills update machine-handoff --global
npx skills remove machine-handoff --global --agent codex
```

## 换机主流程与可选模式

日常换机主要是两个阶段：旧机用 `Prepare` 生成 Package；新机用 `Restore` 检查环境并生成计划。`Update`、`Diff` 和 `Validate` 是有特定需要时使用的辅助模式，并非每次换机都必须单独选择。

| 模式 | 作用 | 是否属于日常换机主流程 |
| --- | --- | --- |
| `Prepare` | 在旧/来源机采集环境，生成快照、配置工件、报告和决策文件 | 是：准备旧机 Package |
| `Restore` | 在新/目标机采集现状，对照来源机并生成恢复计划 | 是：新机恢复入口；默认只生成计划 |
| `Update` | 旧机环境变化后刷新已有 Package，保留决策和已有工件 | 可选：迁移前刷新 |
| `Diff` | 对比两个已有快照，不重新采集机器 | 可选：单独诊断；Restore 本身已包含比较 |
| `Validate` | 核验目标机当前状态 | 可选：手工恢复后的独立检查；批准执行的 Restore 会复采并验证其配置副本 |

确定性入口示例：

```powershell
powershell.exe -NoProfile -File .\scripts\machine-handoff.ps1 `
  -Mode Prepare `
  -Profile Deep `
  -PackagePath 'C:\Handoff\source' `
  -SafeMode
```

省略 `-Profile` 时使用 `Standard`。Deep 会在安全预算内检查已支持的配置类型，并将脱敏副本放进 Package；格式不受支持或无法可靠脱敏时，只写入固定状态，不保存正文。

`Restore` 默认只生成 `manifests/restore-plan.json` 与 `manifests/restore-result.json`，并输出当前 `PLAN_SHA256`。可执行动作时，用户必须重新运行并同时提供当前 plan SHA 与精确 action ID：

```powershell
powershell.exe -NoProfile -File .\scripts\machine-handoff.ps1 `
  -Mode Restore `
  -PackagePath 'C:\Handoff\source' `
  -ApprovePlanSha256 '<plan-sha256>' `
  -ApproveActionIds '<action-id>'
```

v2.0 白名单执行器当前只支持复制已捕获的 `SAFE_COPY`/`REDACTED_COPY` 配置工件；目标已存在时，计划显示冲突与备份路径，执行前先备份目标文件。执行后会重新采集目标并写入验证结果。安装软件、设置 Git 配置、执行 Profile/Hook、导入密钥、启动/导入 WSL、复制 Docker volumes 仍为审阅或人工步骤。

`-SafeMode` 仍会向指定 Package 写入收集结果，但跳过 winget 导出和所有 WSL 命令探测。可用 `pwsh` 替代 `powershell.exe`。

## Package 与安全

- Package 写入用户指定的路径；工具不会把 Package 上传到远端。路径可指向共享位置，因此应选择可信且访问受限的目录。Package 可能包含机器标签、私有路径、工具版本和项目状态，应放在 Git 仓库之外并视为私有资料。
- Snapshot schema v2 可读取 v1 Package；旧路径 metadata 不会自动变成配置副本。
- 可迁移配置采用来源分类、格式解析、结构化脱敏、二次检查、hash 和独立工件文件。配置工件使用内容 hash 文件名，更新不会静默覆盖旧副本。
- 永不采集 SSH/GPG 私钥、Credential Manager、浏览器凭据、Cookie 数据库、云认证缓存、Agent 登录缓存或 `.env` 正文；认证需要在新机器手动完成。
- Profile、hook、tasks、规则和 MCP 命令被当作不可信配置数据。采集不会执行它们，恢复计划默认需要审阅。
- WSL 不会因采集而启动停止的发行版，也不会自动导出。Docker volumes 不会默认打包。
- Package 更新通过同卷 staging、逐文件原子写入、回滚日志和 generation hash manifest 保持一致；无法验证旧 generation 时会安全停止。
- `Restore` 默认生成计划并等待用户审批；批准后只执行白名单配置复制，目标文件已存在时会先备份再替换。它不会自动安装软件、修改环境变量、执行 Profile/Hook 或导入 WSL。

## 本地验证

无需 Pester 或其他测试模块：

```powershell
powershell.exe -NoProfile -File .\tests\smoke.ps1
powershell.exe -NoProfile -File .\tests\unit.ps1
powershell.exe -NoProfile -File .\tests\config-artifacts.ps1
powershell.exe -NoProfile -File .\tests\package-transactions.ps1
powershell.exe -NoProfile -File .\tests\security-package.ps1
powershell.exe -NoProfile -File .\tests\deep-integration.ps1
powershell.exe -NoProfile -File .\tests\prepare-integration.ps1
powershell.exe -NoProfile -File .\tests\collectors\workstation.ps1
powershell.exe -NoProfile -File .\tests\collectors\wsl-deep.ps1
powershell.exe -NoProfile -File .\tests\collectors\toolchains.ps1
powershell.exe -NoProfile -File .\tests\collectors\platform-tools.ps1
powershell.exe -NoProfile -File .\tests\collectors\wsl-base.ps1
powershell.exe -NoProfile -File .\tests\git-probe-safety.ps1
powershell.exe -NoProfile -File .\tests\restore-engine.ps1
```

对应的 GitHub Actions 在 Windows runner 上用 Windows PowerShell 5.1 与 PowerShell 7 运行这些门禁及各领域 fixture。合成 Secret 测试会扫描最终 Package，并断言原值出现次数为 0。

## 许可证

MIT，见 [LICENSE](LICENSE)。
