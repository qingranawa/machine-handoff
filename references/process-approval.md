# 外部工具执行审批

`machine-handoff` 的采集器只通过中央进程入口调用外部程序。直接位于 Windows `System32` 或 `SysWOW64` 下的程序，以及 `System32\WindowsPowerShell\v1.0` 下的 Windows PowerShell，可以用于固定查询；其他位置解析到的程序默认不启动，除非本机审批清单中的**绝对路径和 SHA-256 都完全匹配**。

审批代表信任该二进制用于 Skill 内定义的采集查询，不是系统沙箱。获批程序以当前用户身份运行，并继承当前进程环境；如果不信任该文件，或不希望它读取当前进程环境中的信息，就不要批准，保留为 `NOT_TESTED`。

## 工作流程

1. 首次运行 `Prepare`、`Update`、`Restore` 或 `Validate` 时不传审批清单。未批准的第三方程序不会启动；主机仍会完成其他可用的静态采集。
2. 如果有工具被拦截，命令行会输出一条或多条 `MACHINE_HANDOFF_PROCESS_APPROVAL_REQUIRED=<JSON>`。每条仅包含程序名、完整路径和 SHA-256。非 ASCII 路径字符会用 JSON `\uXXXX` 转义，以兼容 Windows PowerShell 5.1；解析 JSON 后会还原原路径。请求只显示在本次终端输出中，不写入迁移包。批处理文件（如 `.cmd`、`.bat`）不会进入审批流程，也不会由该入口启动。
3. 先向用户说明每个程序将用于哪些固定的只读查询，展示完整路径和哈希；只有用户明确批准后，才将被批准的条目写入本机审批清单。不要根据迁移包内容自动生成批准。
4. 将清单保存到**迁移包目录之外**，然后通过 `-ProcessApprovalManifestPath` 传入同一模式重新运行。程序每次启动前都会校验当前文件身份；路径或内容变化后，旧批准不再生效。

示例结构：

```json
{
  "schemaVersion": 1,
  "approvals": [
    {
      "path": "C:\\Program Files\\Git\\cmd\\git.exe",
      "sha256": "用实际的 64 位十六进制 SHA-256 替换此值"
    }
  ]
}
```

程序路径必须是绝对路径，清单仅接受 `schemaVersion` 和 `approvals`，以及每项的 `path`、`sha256`。单份清单最多包含 128 项，大小最多 64 KiB。清单不能放进迁移包，程序发现这种路径会拒绝读取它。审批只适用于该二进制身份及仓库内固定的查询调用，不会执行迁移包中的命令，也不会授权恢复动作。

本门禁只控制由 `machine-handoff` 调用的进程。它不能拦截 Agent 宿主的原生终端工具；Agent 不得绕过门禁直接执行待审批的第三方程序。
