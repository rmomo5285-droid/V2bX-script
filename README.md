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
