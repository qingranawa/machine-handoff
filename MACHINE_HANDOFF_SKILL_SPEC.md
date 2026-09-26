# machine-handoff：Windows 工作站交接 Skill 实现规格

状态：设计稿，供 GPT-6 Luna 实现。本文只规定行为、数据契约和验收边界；不表示已安装 Skill、采集本机或执行迁移。

## 1. Problem Definition

Windows 开发工作站换机、重装或恢复时，软件列表不足以重建工作环境：工具版本、编辑器扩展、AI 编码代理规则、WSL 项目位置、PATH、登录状态及本地唯一数据都可能遗漏。`machine-handoff` 应在旧机形成一份**可阅读、可比较、可执行恢复计划**的 Handoff Package；在新机先检查现状，再提出差异和操作，最后验证结果。

成功标准是另一位 Agent 仅凭 Package 就能回答：旧机如何用于工作、重要资产在哪、什么可以重建、什么需要人工迁移或重新登录、恢复顺序及尚未解决的阻碍。它不能把“未发现备份”写成“确认没有备份”，也不能把“命令成功”写成“用户可正常使用”。

## 2. Scope

仅支持 Windows 开发工作站。核心脚本以系统自带的 Windows PowerShell 5.1 为最低运行基线，PowerShell 7 可用时也应通过测试；不依赖预装第三方模块。采集范围限定为当前用户、可读的系统级环境变量、实际存在的工具，以及用户指定或明确约定的工作目录。

| 领域 | 最小采集内容 | 边界 |
| --- | --- | --- |
| 系统与环境 | Windows 版本/build、用户主目录、主要卷与盘符、User/Machine 环境变量名、可安全记录的路径型变量、分别记录的 User/Machine PATH、与开发直接相关的设置 | 不导出注册表树；不枚举硬件、服务、计划任务或系统组件全集 |
| 软件 | winget 可匹配软件、重要但无法匹配的软件、便携软件、包管理器；安装来源、是否仍需使用、恢复策略 | Windows 内置应用和驱动不做完整盘点；硬件专属或过时软件默认 `REVIEW`/`SKIP` |
| 开发工具 | Git、Node.js、npm、pnpm、存在时的 yarn/bun、Python、pip/pipx/uv、.NET SDK、Java、Rust/Go/CMake、PowerShell、Windows Terminal 的发现结果与版本 | 工具不存在记 `ABSENT`，不可执行记 `UNKNOWN`；不假定都要安装 |
| IDE/编辑器 | 实际检测到的 VS Code、Visual Studio、JetBrains、Cursor 等；扩展/插件、profiles、settings、keybindings、snippets 的位置与安全摘要 | 不复制整个用户配置目录或插件缓存 |
| AI 编码代理 | Codex、Claude Code、Gemini CLI、OpenCode、Cursor Agent 的安装/配置位置，以及全局说明、AGENTS.md、CLAUDE.md、Skills、MCP、hooks、plugins、rules、permissions、终端集成清单 | 只采集实际存在项；不运行会显示凭据的诊断或认证命令 |
| WSL | 已安装发行版与 WSL 版本、`.wslconfig`、`/etc/wsl.conf` 的安全摘要、Windows/WSL 项目路径关系、是否建议整发行版迁移 | 默认只形成 export/import 计划，不导出映像 |
| 数据 | `DATA_LOCATION_MAP`：项目、Git 仓库、Documents、Desktop、Obsidian Vault、自定义工作目录、WSL 项目、云同步目录；`CRITICAL_UNBACKED_DATA` 候选 | 仅检查已知根目录与用户补充目录；不递归扫描整个磁盘 |

默认项目发现深度为相对每个授权根目录的 3 层，支持显式调整与排除路径；符号链接、junction 和 reparse point 不跨越遍历。目录内容大小估算可选，不应成为默认全量递归操作。对发现的 Git 仓库至少记录 remote、当前分支、未提交/未跟踪文件和未推送提交的状态，避免把“有 remote”误作“代码已备份”。Git remote、云同步路径或备份软件存在只能构成线索；“已备份”必须有明确可验证的副本或用户确认。

## 3. Non-Goals

不做 forensic inventory、完整硬件/驱动迁移、系统镜像、数据库、Web UI、daemon、实时监听、通用依赖图、Windows 配置管理平台。默认不执行 WSL export/import、不复制整个 AppData、不自动同步项目数据、不自动安装软件、不修改生产配置或系统关键设置。只对当前任务发现且有迁移意义的组件建模。

## 4. Skill Architecture

`SKILL.md` 是 Agent 工作流入口，负责意图识别、模式路由、权限边界及按需加载参考文件；PowerShell 脚本只承担稳定的采集、规范化、比较、校验。Agent 负责解释异常、筛选过时软件、确认恢复目标、生成面向人的说明和逐项操作决策。不要把开放式判断硬编码成大量规则。

入口 frontmatter 必须含 `name: machine-handoff` 和说明何时使用的 `description`。正文保持精简，链接到对应 reference；不在每次调用时加载所有资料。这符合 OpenAI 对 Skill 目录、`SKILL.md` 和 references/scripts/assets 分工的现行说明：[OpenAI Skills 文档](https://developers.openai.com/api/docs/guides/tools-skills)。

`machine-handoff prepare|update|restore|validate|diff` 是**面向 Agent 的模式语法**，在 Codex 中可明确调用 `$machine-handoff prepare` 等模式。Skill 文件本身不会自动注册同名全局终端命令。确定性入口另提供 `powershell.exe -NoProfile -File <Skill目录>\scripts\machine-handoff.ps1 -Mode <mode>`；若要在终端直接输入裸命令，需另行把入口放到已有 PATH 目录或安装 shim。v1 不自动改 PATH，也不声称安装 Skill 后裸命令自然可用。

## 5. Directory Structure

目标 Skill 目录由后续实现者按当前安装规则放置；本次设计采用用户指定的 `~/.codex/skills/machine-handoff/`。若实施环境另有统一技能本体/链接约定，先核对实际目录，不能复制成两个可漂移的本体。

```text
machine-handoff/
├── SKILL.md
├── references/
│   ├── collection.md          # 范围、Windows 规则、collector 与 AI Agent 发现
│   ├── package-schema.md      # JSON 契约、Markdown 映射、版本与更新规则
│   ├── restore-validation.md  # action、安全级别、diff、恢复和验证
│   └── secrets.md             # 敏感值分类、过滤、日志与配置副本规则
├── scripts/
│   ├── machine-handoff.ps1    # 参数检查、模式调度、原子输出
│   ├── collect.ps1            # 有界、只读 collector 函数
│   └── state.ps1              # schema 检查、diff、validation
└── assets/
    ├── HANDOFF.template.md    # 面向人的总览模板
    └── source.snapshot.template.json  # 最小 JSON 形状示例
```

`agents/openai.yaml`、包装插件、安装器及额外脚本并非 v1 必需。`SKILL.md` 不应重复 reference 内容。实现 Skill 时需按本机用户规则更新能力清单，但该操作不属于本次设计交付。

## 6. Modes

| 模式 | 输入 | 输出与行为 | 写入边界 |
| --- | --- | --- | --- |
| `PREPARE` | Package 路径；可选项目根目录与排除项 | 采集旧机，形成 source snapshot、报告和初始迁移计划；显示缺口与待人工确认项 | 对旧机只读；仅创建指定 Package；默认不拷贝原始配置 |
| `UPDATE` | 现有 Package；同一旧机的新采集 | 校验 schema/来源，重新采集并更新自动生成部分；保留人工决策 | 原子替换生成文件；保留上一版 source snapshot 以便回退；不覆盖 `configs/` 手工文件 |
| `RESTORE` | Package；新机采集；用户确认的目标路径 | `inspect → diff → plan → execute approved safe operations → verify`；每次重新读取目标状态 | 未通过 plan 审阅不执行写入；不覆盖已有文件；每项修改有结果记录 |
| `VALIDATE` | source snapshot、当前目标状态、已选择的目标映射 | 重新检查目标并输出 PASS/WARN/FAIL/UNKNOWN 及剩余工作 | 只写 Package 中的 validation 报告 |
| `DIFF` | 两份兼容 snapshot，或 source Package 与当前机器 | 规范化比较并输出差异，不生成安装动作 | 只读输入；可把差异结果写入指定输出路径 |

`UPDATE` 与 `RESTORE` 不混用：前者刷新旧机事实，后者在新机操作。`VALIDATE` 可独立重复运行。`DIFF` 不推断“新版本一定更好”或“路径不同一定错误”；目标路径以已确认的映射为准。

## 7. Collector Design

统一函数契约：`Collect-<Domain> -Context <CollectionContext> -> <CollectorResult>`。`CollectionContext` 含 `mode`、`roots`、`maxDepth`、`excludes`、`deadline`、`privacyPolicy`、`hostRole`；`CollectorResult` 含 `domain`、`status`（`OK|PARTIAL|UNAVAILABLE|ERROR`）、`items`、`warnings`、`provenance`、`collectedAt`。collector 只能返回已经过滤的结构化对象；不得把原始命令 stdout/stderr、异常全文或配置文件正文写入结果。

`collect.ps1` 中保留九个按领域分组的函数，不拆成九个独立脚本。每个函数先检测能力，再采集；某工具不存在不会导致其他领域失败。

| Collector | 输入/发现方式 | 主要输出 |
| --- | --- | --- |
| `system` | Windows/用户/卷的限定查询 | OS build、用户目录、盘符映射、迁移相关设置状态 |
| `env` | User 与 Machine 范围分别读取；PATH 分段 | 安全变量、敏感变量存在标记、PATH 项及无效路径标记；绝不导出全部值 |
| `software` | winget 导出结果与有限的已安装程序来源；用户指定便携目录 | 包标识、来源、版本、可恢复性和待审核项 |
| `dev` | 实际找到的可执行文件和只读版本命令 | 工具/版本/路径、包管理器存在性、全局包清单中确有迁移价值的项 |
| `shell` | PowerShell、Terminal、profile 的已知位置 | shell 版本、profile/Terminal 配置位置及安全设置摘要 |
| `editors` | 已知配置目录和工具自身只读列表命令 | 编辑器、扩展/插件 ID、profile 与配置清单 |
| `agents` | 已检测代理的已知用户级目录及显式附加路径 | 指令/Skill/MCP/hooks/plugins/rules/permissions 的名称、位置、启用状态与依赖 Secret 名称 |
| `wsl` | 发行版列表、版本、两个指定配置位置；必要时只读进入已存在发行版 | distro、配置安全摘要、项目路径、export 建议及估计成本级别 |
| `data` | 用户指定根、Documents、Desktop、已确认的 Vault/云同步目录 | 路径地图、Git 状态摘要、备份证据、未备份候选与待确认问题 |

采集命令用固定参数调用，设置超时；禁止执行远程脚本、认证命令和有写入副作用的“诊断”。`winget export` 可提供结构化安装清单，但它会尝试匹配已装程序并对无法匹配者给出警告，不能把导出文件当作完整软件清单；默认导出不锁版本，恢复时逐项审阅。依据：[Microsoft winget export 文档](https://learn.microsoft.com/en-us/windows/package-manager/winget/export)。

## 8. Handoff Package Schema

Package 以 JSON 为唯一机器可读事实源，Markdown 是可重建的人类视图。避免在两个格式里手工维护互相冲突的事实。

```text
machine-handoff/
├── HANDOFF.md            # 一页总览、恢复顺序、风险与 blocker
├── SYSTEM.md             # Windows、用户目录、磁盘、环境变量与 PATH
├── SOFTWARE.md           # 软件和安装来源/策略
├── DEVELOPMENT.md        # 工具链、shell、IDE、WSL
├── AI_AGENTS.md          # 代理生态；不用 AGENTS.md 文件名，以免被当作指令加载
├── DATA.md               # DATA_LOCATION_MAP、CRITICAL_UNBACKED_DATA 候选
├── MIGRATION_PLAN.md     # 差异、动作、责任、顺序与验证状态
├── manifests/
│   ├── source.snapshot.json
│   ├── source.previous.json       # UPDATE 后至多保留一版
│   ├── destination.snapshot.json  # RESTORE/VALIDATE 后创建
│   ├── decisions.json             # 人工路径映射、排除和动作审批记录
│   ├── diff.json
│   └── validation.json
├── evidence/
│   └── collection-status.json     # 采集结果/时间/失败原因码，无原始日志
└── configs/                      # 可选；经审阅的安全配置副本
```

初次 `PREPARE` 只需生成 source、decisions、collection-status 和七份 Markdown；destination/diff/validation 在新机运行后生成。不要生成空占位文件。`source.previous.json` 只在 `UPDATE` 时产生。`configs/` 没有合格副本时不创建。

`source.snapshot.json` 顶层最小契约如下；领域内部只保留与上述采集范围有关的字段，缺失与未采集须区分。各组件状态统一使用 `PRESENT|ABSENT|UNKNOWN`，collector 自身状态另用第 7 节的四个状态。

```json
{
  "schemaVersion": 1,
  "snapshotId": "uuid",
  "sourceId": "uuid-created-on-prepare",
  "role": "SOURCE",
  "collectedAt": "ISO-8601-with-offset",
  "platform": "windows",
  "collection": { "roots": [], "excludes": [], "maxDepth": 3, "domainStatus": {} },
  "system": {}, "env": {}, "software": [], "dev": [], "shell": {},
  "editors": [], "agents": [], "wsl": [], "dataLocations": [],
  "unbackedDataCandidates": [], "manualItems": []
}
```

可比较组件的共同字段：`id`（稳定的领域内键）、`domain`、`sourceState`、`desiredState`、`evidence`（安全摘要）、`confidence`（`CONFIRMED|INFERRED|UNKNOWN`）、`restorePolicy`（`RESTORE|REVIEW|SKIP`）。路径同时保留原路径与可配置的目标路径映射，不能对旧盘符做字符串替换后直接写入。

`DATA_LOCATION_MAP` 每项至少含 `id/type/sourcePath/targetPathCandidate/ownership/backupEvidence/transferAction/verification`；`CRITICAL_UNBACKED_DATA` 条目至少含 `path/reason/evidence/status`。默认 `status=CANDIDATE`，只有外部副本经核对或用户确认后才改变结论。Package 可能包含私有项目名、路径和软件清单，应放在用户指定的受控位置，生成报告时说明其敏感性。

## 9. Restore Strategy

恢复顺序：先确认目标卷/目录及关键数据的去向，再准备包管理器和基础工具链，接着装编辑器与代理，最后恢复安全配置、项目和 WSL，并重新登录与验证。依赖只用这几个阶段表达，不构建通用依赖图。

每个差异项统一为：

```json
{
  "component": "dev:pnpm",
  "sourceState": {},
  "destinationState": {},
  "desiredState": {},
  "action": "INSTALL",
  "risk": "LOW",
  "safety": "CONFIRM",
  "reason": "source requires pnpm; destination absent",
  "preconditions": [],
  "verification": [],
  "status": "PLANNED"
}
```

`action` 只允许 `INSTALL|COPY|RECREATE|SYNC|REAUTHENTICATE|REVIEW|SKIP`；`risk` 为 `LOW|MEDIUM|HIGH`，说明潜在影响；`safety` 为 `AUTO|CONFIRM|MANUAL`，规定执行门槛。两者不互相推导。`AUTO` 仅用于已审阅计划内、目标缺失且可重复的低风险动作，例如创建指定空目录或写入 Package 自身的结果；`CONFIRM` 用于安装软件、修改 PATH/环境变量、复制到用户目录、导入 WSL 等，每批列出具体目标后执行；`MANUAL` 用于重新认证、密钥、硬件相关配置、目标已有内容冲突与敏感配置。`SKIP` 必须写理由。

恢复执行器在每项操作前重检前置条件；目标已存在时比较并提出 `REVIEW`，不能直接覆盖。修改现有配置必须先有可恢复副本和目标级确认；系统级变更、提权、生产配置、破坏性操作还须遵守当前会话的更高权限规则。`winget import` 不作为默认一键恢复，因为导出匹配不完整，且老机器软件可能不适合新机。WSL 只生成计划；整发行版导出/导入需用户单独指定发行版、文件和落盘位置。Microsoft 文档说明 `wsl --export` 默认生成 tar，`--vhd` 仅适用于 WSL 2；`wsl --unregister` 会删除发行版数据，因此不进入自动恢复流程：[WSL 基本命令](https://learn.microsoft.com/en-us/windows/wsl/basic-commands)。

## 10. Secret Handling

**不可写入 Package、日志、终端输出或 Agent 最终报告的值：**密码、API key、OAuth/会话 token、cookie、SSH/GPG 私钥内容、Credential Manager 凭据、`.env` 值、BitLocker 恢复密钥。也不保存这些值的 hash、前后缀或长度。

Secret 只保留名称、依赖组件、存在性及人工重设动作，例如：

```text
OPENAI_API_KEY
Present: true
Value: REDACTED
UsedBy: Codex
Migration: SET_MANUALLY
```

环境变量采用**安全字段允许列表**：只有已识别为普通路径/版本等类型且通过检查的值可输出；未知变量只输出名称与是否存在。PATH 单独逐项筛查，疑似凭据片段不落盘。不得因为变量名看似无害就直接输出原值。对于配置文件，默认只保存路径、文件类别和安全摘要，并列为 `CONFIG_COPY_CANDIDATE`；用户逐项指定要带走的文件后，才把已审阅且脱敏成功的副本放入 `configs/`。候选可包括编辑器 settings/keybindings/snippets、Terminal settings、PowerShell profile 和代理规则，但每个文件仍单独过安全检查。未知格式或无法可靠过滤的文件不复制，标记 `MANUAL`。不使用通用正则宣称可彻底清洗任意配置。

采集脚本先在内存中规范化并过滤，再序列化；不使用 transcript、详细命令日志或错误对象全文。外部程序 stderr 只转换为固定错误码与简短安全说明。写入前做第二次敏感模式检查；命中时停止写入该文件并记录 `REDACTION_BLOCKED`，不把命中的文本写入诊断。临时文件位于受控 Package 同卷，原子替换前检查；失败时删除本次临时文件。

## 11. Validation

`state.ps1` 对每个选定组件产生 `PASS|WARN|FAIL|UNKNOWN`。`PASS` 必须有当前目标的实测证据；`WARN` 表示可用但版本/路径不同或仍需人工确认；`FAIL` 表示明确缺失或关键行为失败；`UNKNOWN` 表示无法检测、未运行或需要登录/界面核实。未选择迁移的 `SKIP` 项不计入失败，但显示原因。

| 领域 | 必须核验的可观察结果 |
| --- | --- |
| 软件与 PATH/env | 选定软件存在且能启动或被包管理器识别；User/Machine PATH 目标项存在、顺序/重复项可解释；安全变量与 Secret 名称的存在性核对 |
| Git 与工具链 | Git 可运行，用户配置/凭据状态需分开；Node/npm/pnpm、Python/pip/pipx/uv、.NET 及实际选定工具可运行，版本符合已确认的要求 |
| WSL | 所选发行版存在、版本正确、配置被读取、指定 WSL 项目路径可访问；未执行整体迁移时保持 `UNKNOWN`/待办 |
| IDE/代理 | 目标编辑器启动并具有选定扩展；规则/Skills/MCP/hooks/plugins/permissions 的文件和启用状态匹配；MCP 连接与代理实际登录需分别验证 |
| 数据 | 每个高优先级目标路径存在且抽样可读；Git repo remote/branch/未推送提交状态检查；本地唯一候选有明确转移或备份结论 |

脚本只执行廉价、只读且可重复的检查；需要图形界面、账号登录、真实 MCP 调用或远程备份确认的项目由 Agent 列人工核验，不伪报 `PASS`。报告给出各状态数量、阻碍项、证据时间和下一步；无需构建通用测试框架。

## 12. Error Handling

- **缺工具或权限：**单个 collector 记 `UNAVAILABLE`/`PARTIAL`，其余继续；只说明缺哪类信息，不通过提权或安装来补采。
- **超时或异常输出：**停止该命令，记安全错误码；不回显原始 stdout/stderr。WSL 无法进入时仍保留发行版列表并标注内部配置 `UNKNOWN`。
- **schema 不兼容或 Package 损坏：**`RESTORE` 停止于只读检查，列出文件与版本问题；不猜测字段含义后执行。
- **路径不存在、盘符变化、reparse point：**保留源路径并请求目标映射；不静默改写或跨越目录边界。
- **目标冲突：**停止该项，显示目标和安全摘要，改为 `REVIEW`；不清理目标或重复复制。
- **中途失败：**已完成项、失败项、尚未执行项分别记录；重新运行先重新检查目标状态，防止重复副作用。
- **敏感值疑似泄漏：**阻止相关输出，标记 `REDACTION_BLOCKED`；不得把样本附在错误报告中。

## 13. Implementation Plan for Luna

以下是**实施清单**，不是要求本次会话开始编码。目标是在一个主要工作会话完成 v1。

1. **建立目录与入口。** 创建上文列出的 `SKILL.md`、四份 reference、三份脚本、两份 asset。`SKILL.md` 只写触发词、模式路由、共同安全约束和按模式阅读的 reference 链接。先核对实际 Codex Skill 目录及既有文件，不覆盖同名 Skill。
2. **固定数据契约。** 在 `package-schema.md` 定义 schema v1、领域最小字段、状态枚举、决策文件和 Markdown 映射；实现严格输入校验、稳定 ID、原子写入与一版回退。模板只服务总览和 JSON 形状，其他 Markdown 由同一渲染逻辑生成。
3. **实现只读采集。** 在单个 `collect.ps1` 中实现九个函数，优先 system/env/software/dev，然后 shell/editors/agents/wsl/data。每个函数只访问已知位置或授权根；工具缺失返回状态，不触发安装。AI agent 和配置文件以清单/安全摘要为主，不写通用配置解析器。
4. **实现模式调度和状态比较。** `machine-handoff.ps1` 实现 `PREPARE/UPDATE/RESTORE/VALIDATE/DIFF` 参数、前置检查和输出；`state.ps1` 实现规范化 diff、简易 action 生成和 validation。恢复的实际执行保持很窄：v1 自动操作仅限 Package 产物及获批的空目录；软件安装、配置复制、WSL 操作以逐项计划和人工执行指引为主。若实现少量可执行安全动作，必须有预检查、确认和后验证。
5. **验证和删减。** 使用伪造但真实形状的 source/destination JSON 测 diff；用临时目录验证有界遍历、UPDATE 幂等、目标冲突、collector 失败、缺工具和异常终止；用含模拟 token 的 fixture 验证所有输出与错误信息均不含值；在 Windows PowerShell 5.1 与 PowerShell 7（若存在）分别运行核心检查；对一台受控 Windows 环境做一次只读 `PREPARE` 试运行，人工检查 Markdown/JSON。运行 Skill 校验工具，检查入口 frontmatter 与所有 reference 链接。不要用真实 secret 作 fixture。

**明确不实现：**全盘扫描、自动大体积数据复制、默认 WSL export/import、一键 winget import、任意配置文件自动脱敏器、通用回滚引擎、远程账号验证、插件市场同步、复杂依赖图、数据库、UI、后台服务。可由 Agent 当场判断的软件淘汰与目标路径选择不固化为脚本。

## 14. Acceptance Criteria

1. `PREPARE` 在指定 Package 路径产出结构有效、可读的 source snapshot 与七份 Markdown；旧机除 Package 外没有修改。没有安装的工具正确显示 `ABSENT`/`UNAVAILABLE`，不会凭空列入恢复计划。
2. 所有遍历有明确根、深度与排除项；测试中不会沿 junction、符号链接或默认走遍整盘。失败 collector 不阻断其他结果，状态与时间可追踪。
3. 软件清单区分 winget 匹配项、无法匹配的重要软件、便携软件和待淘汰项；硬件专属软件不会默认安装。
4. AI agent 报告覆盖实际检测到的 Codex、Claude Code、Gemini CLI、OpenCode、Cursor Agent 配置类别；不存在的类别标注缺失，不制造空副本。
5. `DATA_LOCATION_MAP` 对指定工作目录、Git repo、Documents/Desktop、Vault、WSL、云同步目录给出路径与目标候选；`CRITICAL_UNBACKED_DATA` 默认标为候选，不能只凭 Git remote 或云同步目录推断已备份。
6. `RESTORE` 先生成当前状态与差异计划；未审阅计划不得写入，目标已有内容不得覆盖；每项动作明确 action、risk、safety、前置条件和验证方式。`DIFF` 本身只读，`VALIDATE` 可重复运行。
7. 模拟 Secret 值不会出现在任何 Markdown、JSON、配置副本、临时文件、错误输出或日志；需要重新登录/设密钥的项目以名称和 `SET_MANUALLY` 呈现。
8. 对选定的软件、工具链、WSL、IDE/扩展、代理配置、repo 和数据路径形成 `PASS|WARN|FAIL|UNKNOWN`，无法实测的项目不会被当成 `PASS`。
9. `UPDATE` 保留人工决策，原子更新自动生成部分，并保留最多一份前版 snapshot；重复运行不产生累积重复项。Skill 的 frontmatter、引用路径和脚本入口通过实际校验。

### 设计删减结果

最终限定为 **1 个 Skill 入口、4 份 reference、3 个脚本、2 个模板、7 份人类报告**。原可扩展的驱动/硬件盘点、所有 Windows 设置、全自动复制、通用脱敏器、复杂依赖关系和持续监控均已排除。保留的确定性代码仅服务有界采集、结构化比较、报告生成及可验证的安全动作。
