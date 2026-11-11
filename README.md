# Run on Login

Windows 登录流程管理器，使用 PowerShell 5.1 和 Windows Terminal。每个流程由独立 JSON 配置和 PowerShell 脚本定义，通过 CLI 管理。

在本目录打开 PowerShell：

```powershell
.\run.cmd list                    # 查看启用状态
.\run.cmd check                   # 检查目录、脚本、程序是否存在
.\run.cmd run -DryRun             # 预览，不执行流程
.\run.cmd run                     # 立即启动全部已启用流程
.\run.cmd run -Id <task id>          # 单独启动一个流程
.\run.cmd disable -Id <task id>     # 禁用，下次批量启动/登录时跳过
.\run.cmd enable -Id <task id>      # 启用
.\run.cmd add                     # 向导新增配置和脚本
.\run.cmd modify -Id <task id>       # 编辑已有流程的配置和脚本
.\run.cmd remove -Id <task id>       # 确认后移除流程，保留备份
.\run.cmd install                 # 安装当前用户登录自启
.\run.cmd uninstall               # 移除登录自启
```

先运行 `check` 检查环境，再用 `run` 启动流程，最后执行 `install` 设置登录自启。

## 新增、修改与删除

### 新增

```powershell
.\run.cmd add
```

向导依次询问 ID、标题、工作目录、标签颜色，以及要导入的现有 `.ps1` 文件。可选值直接回车使用默认值；不提供现有脚本则创建模板。自动生成 `workflows/<id>.json` 和 `scripts/<id>.ps1`，随后用记事本打开脚本。

也可以直接传参：

```powershell
.\run.cmd add -Id <task id> -Title "我的任务" -WorkingDirectory "D:\my-project" -TabColor "#800000"
.\run.cmd add -Id imported -ScriptFile "D:\tools\existing.ps1" -NoEdit
```

只给 ID 时，标题默认使用 ID，目录默认使用当前目录，颜色默认暗红色。`-ScriptFile` 导入现有脚本并检查语法。`-NoEdit` 跳过打开编辑器。ID 和目标文件名须唯一。

**新增的流程默认禁用**，编辑完成后可先单独试运行，再启用：

```powershell
.\run.cmd run -Id <task id> -DryRun
.\run.cmd run -Id <task id>
.\run.cmd enable -Id <task id>
```

如需根据提示词或终端内容生成启动项，可从子仓库 startup-item-skill（仓库地址：）克隆或下载源码。进入下载后的仓库目录，运行 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1` 安装到 Codex。

### 修改

```powershell
.\run.cmd modify -Id <task id>                   # 打开配置和脚本
.\run.cmd modify -Id <task id> -Edit script      # 只打开脚本，例如修改手机序列号
.\run.cmd modify -Id <task id> -Edit config      # 只打开 JSON 配置
.\run.cmd modify -Id <task id> -WorkingDirectory <new Dir> -Title <task title> -TabColor "#800000"
.\run.cmd modify -Id <task id> -ScriptFile "D:\tools\updated.ps1"
```

未指定修改字段时，默认用记事本打开两个文件，保存即生效；修改任意配置字段（包括 `requires`）可使用 `-Edit config`。传入标题、颜色、目录或脚本文件时直接更新相应内容，其余配置保持原样；也可同时传 `-Edit` 继续手动编辑。不提供 ID 时会列出流程并提示输入 ID。

修改前自动备份原文件。命令参数验证后写入；使用记事本编辑时，保存后可执行 `run -DryRun` 检查配置。共用脚本的修改对所有引用它的流程生效。

### 删除与恢复

```powershell
.\run.cmd remove -Id <task id>                 # 显示文件路径，输入 y 后移除
.\run.cmd remove -Id <task id> -Force          # 跳过确认，仍然保留备份
```

移除 JSON 配置及其未被其他流程引用的 `scripts/` 内脚本，保留共用脚本和外部脚本。不提供 ID 时会列出流程供选择。

备份位于配置目录的 `.backups/<时间-ID-随机后缀>/`，包括 `config.json`、`script.ps1`（原脚本存在时）和记录原始路径的 `manifest.json`。恢复时按 manifest 中的路径复制文件。默认备份目录 `workflows/.backups/` 已加入 `.gitignore`。

新增、删除、禁用、修改配置均无需重新 `install`。

### 配置格式

也可以直接编辑文件。`workflows/*.json` 的文件名决定批量启动的请求顺序，各流程独立执行，不等待前一项结束：

```json
{
  "id": "my-task",
  "enabled": true,
  "title": "我的任务",
  "tabColor": "#800000",
  "workingDirectory": "D:\\my-project",
  "script": "../scripts/my-task.ps1",
  "requires": ["git.exe"]
}
```

- `id` 唯一，使用英文字母、数字、连字符、下划线，以字母或数字开头。
- `enabled`：布尔值，控制是否参与批量启动。
- `title` 设置标题，`tabColor` 使用 `#RRGGBB`。
- `workingDirectory` 使用绝对路径；JSON 中反斜杠写为 `\\`。
- `script` 相对于此 JSON 所在目录，指向独立 `.ps1` 脚本。
- 可选的 `requires` 是供 `check` 检查的程序名称；包含斜杠的条目按相对工作目录的文件路径检查，例如 `./adb.exe`。

在 `scripts/my-task.ps1` 编写流程，例如：

```powershell
$ErrorActionPreference = 'Stop'
& git status
if ($LASTEXITCODE -ne 0) { throw 'git status failed.' }
```

脚本中的程序应在前台运行；外部程序的非零退出码需要显式检查并 `throw`。运行器捕获错误，保留标签页供排查。Windows PowerShell 5.1 下，含中文的 `.ps1` 保存为 UTF-8 BOM；JSON 使用 UTF-8。

### 自定义配置目录

通过 `-ConfigDirectory` 指定配置目录，脚本位于其相邻的 `scripts/` 目录：

```powershell
.\run.cmd add -Id local-task -ConfigDirectory "D:\my-login\workflows"
.\run.cmd enable -Id local-task -ConfigDirectory "D:\my-login\workflows"
.\run.cmd install -ConfigDirectory "D:\my-login\workflows"
```

自定义目录首次 `add` 时自动创建。后续管理命令也要传相同的 `-ConfigDirectory`；登录快捷方式会记住安装时指定的目录。

## 登录自启与运行

`install` 在当前用户启动文件夹中创建 `RunOnLogin.lnk`，登录后运行已启用流程；重复安装会更新快捷方式。移动本目录后，从新位置重新执行 `install`。`uninstall` 移除快捷方式。

运行中的流程会跳过重复启动请求，结束后可再次运行。`run -Id` 可单独启动指定流程，包括已禁用的流程。执行结果和错误显示在各自标签页中。配置修改在下次启动时生效；正在运行的流程通过其标签页操作。

Git、npx 需要在用户 PATH 中可用。启动脚本使用 `-NoProfile`，`run.cmd` 为当前 PowerShell 进程设置 `-ExecutionPolicy Bypass`。
