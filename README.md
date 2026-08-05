# V2bX hardened deployment

本仓库是 [`rmomo5285-droid/V2bX`](https://github.com/rmomo5285-droid/V2bX)
安全加固核心的配套部署与运维脚本。当前稳定组合为部署脚本
[`v0.1.3`](https://github.com/rmomo5285-droid/V2bX-script/releases/tag/v0.1.3)
与核心 [`v0.1.1`](https://github.com/rmomo5285-droid/V2bX/releases/tag/v0.1.1)。
正式节点应使用固定版本 Release；默认分支用于同步上游和后续开发。

`v0.1.1` 增加对早期 `codex-bilibili-cn-exception` 配置的严格兼容迁移；只有标记、
位置和全部规则完全匹配时才删除旧 ACL，自定义或损坏内容仍会被拒绝。`v0.1.2`
取消自动内存硬限制并增加辅助事务后的最终连续存活门禁。`v0.1.3` 增加可选 BBR
内核检测/安装入口，并配套核心 `v0.1.1` 的三核心统一 XBoard 路由判定。

## 支持范围

| Core | Protocols |
| --- | --- |
| Xray | Shadowsocks, VLESS, VMess, Trojan |
| sing-box | Shadowsocks, VLESS, VMess, Hysteria 1/2, Trojan, TUIC, AnyTLS |
| native Hysteria2 | Hysteria2 |

## 与上游部署脚本的主要区别

| 项目 | 上游脚本 | 本 Fork `v0.1.3` |
| --- | --- | --- |
| 核心下载 | 可跟随脚本或分支变化 | 固定核心 Release，下载后校验归档 SHA-256 |
| 已部署迁移 | 直接覆盖或依赖人工操作 | 旧服务运行期间准备，停服前完成校验，失败自动恢复 |
| 配置保留 | 需要人工备份确认 | 保留 `/etc/V2bX`、节点、核心和自定义路由，记录事务备份 ID |
| Hy2 ACL | 容易把中国 ACL 与业务规则混在一起 | 仅识别完整托管块后清理，自定义/损坏 ACL 拒绝自动覆盖 |
| 路由一致性 | 由各核心分别解释 | 配套核心统一执行 XBoard `block` 域名和 BitTorrent 规则 |
| 网络调优 | 菜单脚本直接修改 | `check/apply/rollback` 独立事务，保守设置 TCP、ECN、窗口和 fq 默认值 |
| BBR | 无固定入口 | `V2bX bbr check/install` 可选执行，不自动替换内核或重启 |
| 内存限制 | 容易对小内存机器一刀切 | `MemoryMax` 默认关闭，测量业务峰值后再手动启用 |
| 日志 | 缺少统一轮转/查询入口 | 10 MiB x 5、最长 7 天轮转，支持按 UUID 查询阻断/滥用日志 |

## 一行安装

命令固定脚本和核心版本，并在执行前校验安装脚本 SHA-256：

```bash
curl --proto '=https' --tlsv1.2 -fLo /tmp/v2bx-install-v0.1.3.sh https://github.com/rmomo5285-droid/V2bX-script/releases/download/v0.1.3/install.sh && printf '%s  %s\n' '46d6a44b2134fdebb349b42cbd7696e3d4e76d80e4b978e265ab9196ffbea2cb' /tmp/v2bx-install-v0.1.3.sh | sha256sum -c - && env V2BX_SCRIPT_REF=v0.1.3 bash /tmp/v2bx-install-v0.1.3.sh v0.1.1
```

## 一行迁移

```bash
curl --proto '=https' --tlsv1.2 -fLo /tmp/v2bx-migrate-v0.1.3.sh https://github.com/rmomo5285-droid/V2bX-script/releases/download/v0.1.3/migrate-to-rmomo-v2bx.sh && printf '%s  %s\n' 'c5c2a3cb4cfbdbdd342f7740e37b8e2c760a929986b2ecafb78fcc2ad5cdda89' /tmp/v2bx-migrate-v0.1.3.sh | sha256sum -c - && env V2BX_SCRIPT_REF=v0.1.3 bash /tmp/v2bx-migrate-v0.1.3.sh check && env V2BX_SCRIPT_REF=v0.1.3 bash /tmp/v2bx-migrate-v0.1.3.sh apply --version v0.1.1
```

迁移器在旧服务仍运行时完成下载、核心归档摘要、组件摘要、shell 语法、配置和
二进制检查，随后才停服切换；最终连续健康检查失败会自动恢复旧二进制、配置、
管理脚本和服务状态。

## 迁移结果怎么看

| 输出 | 含义 |
| --- | --- |
| `Service: active` | V2bX 服务正在运行 |
| `Abuse guard: 1/1-enabled` | 已配置节点全部启用单用户滥用保护 |
| `Legacy Hy2 ACL: absent` | 旧 Hy2 中国 ACL 已不存在 |
| `Guard: not installed` | 可选内存硬限制未启用，不是迁移失败 |
| `Memory: N MiB` | 服务器总内存，不是 V2bX 当前进程占用 |
| `DEFAULT QDISC: fq ... live ... not changed` | 设置新队列默认值，没有在线替换当前网卡 qdisc |
| `BACKUP: ID` | 当前事务可使用的回滚备份 ID |

BBR 只作用于 TCP；Hysteria2 的 UDP/QUIC 继续使用协议自身的拥塞控制。真实业务
可能稳定使用 600 MiB 或更多内存，因此 `MemoryMax` 默认不安装。

迁移完成后无需为了“让切换生效”再次重启，先检查：

```bash
systemctl is-active V2bX
V2bX status
journalctl -u V2bX --since '10 minutes ago' --no-pager
V2bX userlog USER_UUID 30
```

网络调优、BBR 和低内存保护是独立操作：

```bash
V2bX tune check
V2bX bbr check
V2bX resources status
```

对应回滚：

```bash
/usr/local/share/v2bx/migrate-to-rmomo-v2bx.sh rollback
V2bX tune rollback
V2bX resources rollback
```

正式操作前阅读 [运维手册](docs/OPERATIONS.md)。首次扩大部署前应选择覆盖不同核心、
协议和内存规格的节点完成灰度。

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
