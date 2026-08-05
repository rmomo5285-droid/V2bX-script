# V2bX hardened deployment

本仓库是 `rmomo5285-droid/V2bX` 安全加固核心的配套部署与运维脚本。当前稳定
组合为部署脚本 `v0.1.3` 与核心 `v0.1.1`。`v0.1.1` 增加了对早期
`codex-bilibili-cn-exception` 配置的严格兼容迁移：仅当标记、位置和全部域名规则
完全匹配时才删除旧 ACL，任何自定义或损坏内容仍会被拒绝。
`v0.1.2` 根据首台真实灰度结果取消自动内存硬限制，并增加辅助事务后的最终连续
存活门禁；正常业务内存不会再被固定 `MemoryMax` 误杀。
`v0.1.3` 增加可选的 BBR 内核检测/安装入口，并配套核心 `v0.1.1` 的三核心统一
XBoard 路由判定；旧原生 Hy2 中国 ACL 继续以保守、可回滚方式清理。

支持矩阵：

| Core | Protocols |
| --- | --- |
| Xray | Shadowsocks, VLESS, VMess, Trojan |
| sing-box | Shadowsocks, VLESS, VMess, Hysteria 1/2, Trojan, TUIC, AnyTLS |
| native Hysteria2 | Hysteria2 |

主要交付内容包括：事务式迁移和自动回滚、组件与核心 Release 的 SHA-256 校验、
保守路由模板、旧原生 Hy2 中国 ACL 的精确识别与移除、独立可回滚的网络调优和
低内存保护、缺少 BBR 时可选且校验固定版本的第三方内核安装入口，以及有界日志
轮转和按用户审计查询。

正式操作前先阅读 [运维手册](docs/OPERATIONS.md)。迁移时必须分别固定部署脚本和
核心版本，并先完成只读检查；首次扩大部署前仍需完成五节点灰度。

## 一行安装与迁移

### 新机器安装

命令固定部署脚本 `v0.1.3` 和核心 `v0.1.1`，并在执行前校验安装脚本 SHA-256：

```bash
curl --proto '=https' --tlsv1.2 -fLo /tmp/v2bx-install-v0.1.3.sh https://github.com/rmomo5285-droid/V2bX-script/releases/download/v0.1.3/install.sh && printf '%s  %s\n' '46d6a44b2134fdebb349b42cbd7696e3d4e76d80e4b978e265ab9196ffbea2cb' /tmp/v2bx-install-v0.1.3.sh | sha256sum -c - && env V2BX_SCRIPT_REF=v0.1.3 bash /tmp/v2bx-install-v0.1.3.sh v0.1.1
```

### 已部署节点迁移

```bash
curl --proto '=https' --tlsv1.2 -fLo /tmp/v2bx-migrate-v0.1.3.sh https://github.com/rmomo5285-droid/V2bX-script/releases/download/v0.1.3/migrate-to-rmomo-v2bx.sh && printf '%s  %s\n' 'c5c2a3cb4cfbdbdd342f7740e37b8e2c760a929986b2ecafb78fcc2ad5cdda89' /tmp/v2bx-migrate-v0.1.3.sh | sha256sum -c - && env V2BX_SCRIPT_REF=v0.1.3 bash /tmp/v2bx-migrate-v0.1.3.sh check && env V2BX_SCRIPT_REF=v0.1.3 bash /tmp/v2bx-migrate-v0.1.3.sh apply --version v0.1.1
```

迁移器在旧服务仍运行时完成下载、SHA-256、归档、配置和二进制检查，随后才停服
切换；最终连续健康检查失败会自动恢复原二进制、配置和服务状态。

## 路由行为

核心 `v0.1.1` 在 Xray、sing-box 和原生 Hysteria2 中统一执行 XBoard `block`
规则。普通域名匹配自身及全部子域名，支持显式 `regexp:` 和
`protocol:bittorrent`。公共安全规则还会阻止私网/特殊用途目标、TCP 25 和常见
UDP 反射放大端口。

本组合 **不会默认阻断全部中国大陆域名或公网 IP**。只有 XBoard `block` 中的
域名会被阻止；面板未列出的大陆网站仍可访问。旧原生 Hy2 中独立的
`reject(geosite:cn)` / `reject(geoip:cn)` 会在确认属于已知托管配置后移除，防止
三个核心规则不一致以及 Bilibili、Apple 等正常业务被误伤。自定义或损坏 ACL
不会被自动覆盖。

## 迁移结果怎么看

成功结果中的关键字段：

| 输出 | 含义 |
| --- | --- |
| `Service: active` | V2bX 服务正在运行 |
| `Abuse guard: 1/1-enabled` | 已配置节点全部启用单用户滥用保护 |
| `Legacy Hy2 ACL: absent` | 旧 Hy2 中国 ACL 已不存在 |
| `Guard: not installed` | 可选内存硬限制未启用，不是迁移失败 |
| `DEFAULT QDISC: fq ... live ... not changed` | 已设置新队列默认值，没有在线替换当前网卡 qdisc |
| `BACKUP: ID` | 该事务可使用的回滚备份 ID |

BBR 只作用于 TCP；Hysteria2 的 UDP/QUIC 继续使用协议自身的拥塞控制。
`MemoryMax` 默认不安装，因为真实节点在正常负载下可能使用 600 MiB 或更多内存。

迁移完成后无需为了“让切换生效”再执行菜单 6。先检查：

```bash
systemctl is-active V2bX
V2bX status
journalctl -u V2bX --since '10 minutes ago' --no-pager
```

查看指定用户最近 30 分钟的阻断/滥用日志：

```bash
V2bX userlog USER_UUID 30
```

回滚最近一次核心迁移和独立网络调优事务：

```bash
/usr/local/share/v2bx/migrate-to-rmomo-v2bx.sh rollback
V2bX tune rollback
```

生产节点应记录输出中的两个备份 ID；指定备份回滚方式见
[运维手册](docs/OPERATIONS.md)。

## 开发验证

```bash
find . -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
for test_file in tests/test-*.sh; do bash "$test_file"; done
bash scripts/components-manifest.sh check
git diff --check
```

组件发生变化后由维护者更新清单：

```bash
bash scripts/components-manifest.sh write
bash scripts/components-manifest.sh check
```
