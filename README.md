# machine-handoff

`machine-handoff` 是一个 Windows 开发工作站换机、重装和恢复用的 Agent Skill。它收集有限的本机开发环境信息，生成可阅读的 Handoff Package，并在目标机上比较状态、列出需要人工确认的恢复计划。

Skill 遵循 Agent Skills 目录格式，包含 `SKILL.md`、PowerShell 脚本、references 和模板。设计与安全边界见 [MACHINE_HANDOFF_SKILL_SPEC.md](MACHINE_HANDOFF_SKILL_SPEC.md)。

## 支持范围

- Windows 工作站，Windows PowerShell 5.1 为基线；PowerShell 7 也可运行。
- Codex 为首要支持目标。Skill 的基础目录格式可由其他兼容 Agent Skills 的工具使用；脚本行为仍仅面向 Windows。
- `winget`、WSL、Git、编辑器和其他开发工具均为可选项。缺失的程序会记录为 `NOT_FOUND`，未运行的检查保留为 `NOT_TESTED` 或 `UNKNOWN`。
- 收集限定在已知用户配置位置及明确指定的根目录、深度和排除项内；不会递归扫描整个磁盘。

## 安装

使用第三方 Vercel Skills CLI 从 `qingranawa/machine-handoff` 安装到 Codex 用户目录：

```powershell
npx skills add qingranawa/machine-handoff --skill machine-handoff --global --agent codex
```

本项目不发布自己的 npm 安装器；`npx` 调用 Vercel 的 `skills` CLI，从 GitHub 安装静态 Skill 文件。安装只会把 Skill 文件放到 Agent Skills 目录，不会运行收集脚本。安装器需要 Node.js/npm；首次使用 `npx` 时，npm 会让你确认是否安装并运行 CLI。PowerShell 是运行本 Skill 的要求，Node.js 不是。

因此安装命令是 `npx skills add ...`，不是 `npx machine-handoff`。

`skills` 是 Vercel 提供的第三方工具，不属于 Codex。该 CLI 提供匿名使用遥测；可在安装前设置 `DISABLE_TELEMETRY=1` 或 `DO_NOT_TRACK=1` 关闭。详见 [skills CLI](https://github.com/vercel-labs/skills)。

更新与卸载：

```powershell
npx skills update machine-handoff --global
npx skills remove machine-handoff --global --agent codex
```

也可手动把本仓库根目录的 `SKILL.md`、`scripts/`、`references/` 和 `assets/` 复制到目标 Agent 的 `skills/machine-handoff/` 目录。无需复制 README、LICENSE、规格、测试或 CI 文件。安装或更新后先检查脚本来源和目标路径，再调用 Skill。

## 使用模式

在 Codex 中调用 `$machine-handoff` 并指定模式：

| 模式 | 作用 |
| --- | --- |
| `prepare` | 在指定 Package 中生成旧机快照与报告 |
| `update` | 在确认仍是同一来源机器后更新旧机快照 |
| `restore` | 采集目标机并生成差异与待审阅计划 |
| `diff` | 比较两个快照；不更改机器状态 |
| `validate` | 重新采集并核验已选择的项目 |

确定性入口示例：

```powershell
powershell.exe -NoProfile -File .\scripts\machine-handoff.ps1 `
  -Mode Prepare `
  -PackagePath 'C:\Handoff\source' `
  -SafeMode
```

`-SafeMode` 会跳过 winget 导出和 WSL 命令探测；它仍会在指定 Package 路径写入结果。Windows PowerShell 命令也可以用 `pwsh` 执行。

## 安全和隐私

- 脚本将采集结果写入用户指定的本地 Package 路径，不会把 Package 上传到远端。
- Package 可能包含计算机标签、用户配置路径、软件和工具版本、PATH 路径、项目目录及仓库状态。请把 Package 当作私有数据保存，并放在 Git 仓库之外。
- 不收集密码、API key、令牌、Cookie、私钥、Credential Manager 内容、`.env` 值或 BitLocker 恢复密钥；检测到敏感模式会阻止相关输出。
- 默认只记录配置文件的路径、存在性和安全摘要，不保存文件正文。
- 不自动安装软件、复制配置、同步项目、导出或导入 WSL，也不执行破坏性恢复。需要更改时先输出计划，再由用户审阅并逐项授权。
- WSL 不会启动已停止的发行版；无法安全检查的状态保持 `UNKNOWN` 或 `NOT_TESTED`。

## 本地验证

无需 Pester 或其他测试模块：

```powershell
powershell.exe -NoProfile -File .\tests\smoke.ps1
pwsh -NoProfile -File .\tests\smoke.ps1
```

测试使用内存中的合成快照，不连接真实 WSL、winget、GitHub 或 Agent 账号，也不创建含模拟 Secret 的文件。
GitHub Actions 会在 Windows runner 上分别使用 Windows PowerShell 5.1 和 PowerShell 7 运行这组测试。

## 许可证

MIT，见 [LICENSE](LICENSE)。
