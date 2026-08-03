# V2bX 安全加固运维手册

## 发布状态与边界

本文对应核心分支 `fix/xboard-hy2-abuse-hardening` 和部署分支
`feat/hardened-v2bx-deployment`。二者在正式 Tag/Release、Linux 资产独立校验和
五节点灰度完成前都是发布候选，不得直接扩展到生产节点。

迁移保留 `/etc/V2bX`、全部已配置核心与节点以及自定义路由。仅补充缺失的加固
默认值；已有 `AbuseGuardConfig` 字段优先。网络调优与低内存保护是迁移之后的
独立事务，各自失败不会回滚已成功迁移的核心。

禁止把配置、API key、证书私钥或日志中的认证参数提交到仓库。普通四层代理无法
看到 HTTPS 加密后的完整 URL；用户审计日志不能被当作 TLS 内容审计。

## 发布前验收

在两个干净工作树中执行各自 README 的开发验证，并确认对应 GitHub Actions
成功。部署仓库的 `components.sha256` 必须与下列八个文件完全一致：

```text
V2bX.sh
initconfig.sh
network-tune.sh
resource-guard.sh
fix-legacy-hy2-config.sh
migrate-to-rmomo-v2bx.sh
V2bX.service
v2bx.logrotate
```

创建正式 Release 后，必须在独立临时目录下载 Linux 归档和 `.sha256`，执行：

```bash
sha256sum -c V2bX-linux-64.zip.sha256
unzip -tq V2bX-linux-64.zip
unzip -l V2bX-linux-64.zip
```

归档至少应包含可执行 `V2bX`、`README.md`、`LICENSE`、默认 JSON 配置和 geodata。
同时运行解压后的 `V2bX version`。摘要或内容任一不符即停止，不进入灰度。

## 迁移流程

只使用已从正式部署 Release 取得并独立校验的脚本目录。首先做只读检查：

```bash
sudo ./migrate-to-rmomo-v2bx.sh check
```

检查输出必须包含受支持的 service backend、目标资产名和 `READY`。若报告配置不是
严格 JSON、服务管理器不受支持、旧 Hy2 ACL 被自定义或部分损坏，应先人工处理，
不得绕过。

灰度时固定核心版本和部署脚本版本，不使用漂移的分支名：

```bash
sudo env V2BX_SCRIPT_REF=vX.Y.Z ./migrate-to-rmomo-v2bx.sh apply --version vX.Y.Z
```

迁移会在旧服务仍运行时完成下载、核心归档摘要、组件摘要、shell 语法、配置和
二进制自检，然后才停服切换。成功输出会给出 `BACKUP: <ID>`。逐节点记录该 ID、
核心摘要、服务状态和观察时间，不在多台机器上并行首次验证。

查看状态和用户限频审计：

```bash
sudo ./migrate-to-rmomo-v2bx.sh status
sudo V2bX userlog USER_UUID 30
```

## 回滚

回滚最近一次迁移：

```bash
sudo ./migrate-to-rmomo-v2bx.sh rollback
```

回滚指定备份：

```bash
sudo ./migrate-to-rmomo-v2bx.sh rollback BACKUP_ID
```

迁移健康检查失败会自动恢复旧二进制、配置、管理脚本、service 文件和辅助组件，
并恢复迁移前的服务启停状态。若输出 `CRITICAL`，停止后续节点并按输出的备份目录
人工核对，不要再次覆盖现场。

## 独立调优事务

网络参数只使用检查、应用、回滚三步：

```bash
sudo V2bX tune check
sudo V2bX tune apply
sudo V2bX tune rollback
```

低内存原生 Hysteria2 保护只应用于脚本判定符合条件的节点：

```bash
sudo V2bX resources check
sudo V2bX resources apply
sudo V2bX resources status
sudo V2bX resources rollback
```

两类事务都应单独记录备份 ID。生产防火墙、供应商出站限制和现有 sysctl 所有权
仍需人工维护；这些脚本不是 IDS 或 DDoS 防护设备。

## 五节点灰度门禁

只有 Release 资产验收通过后，才选择覆盖不同核心、协议、内存规格和服务管理器
的五个节点。每台至少核对启动稳定性、面板同步、TCP/UDP 连通、规则命中、审计
限频、内存与连接数、日志轮转以及显式回滚。五台全部通过并完成观察窗口后，才可
另行批准扩大范围。
