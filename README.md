# V2bX hardened deployment

本仓库是 `rmomo5285-droid/V2bX` 安全加固核心的配套部署与运维脚本。当前
`feat/hardened-v2bx-deployment` 为发布候选分支，尚未创建正式 Release，也不应
直接用于生产节点。

支持矩阵：

| Core | Protocols |
| --- | --- |
| Xray | Shadowsocks, VLESS, VMess, Trojan |
| sing-box | Shadowsocks, VLESS, VMess, Hysteria 1/2, Trojan, TUIC, AnyTLS |
| native Hysteria2 | Hysteria2 |

主要交付内容包括：事务式迁移和自动回滚、组件与核心 Release 的 SHA-256 校验、
保守路由模板、旧原生 Hy2 中国 ACL 的精确识别与移除、独立可回滚的网络调优和
低内存保护，以及有界日志轮转和按用户审计查询。

正式操作前先阅读 [运维手册](docs/OPERATIONS.md)。本分支不提供一键生产 URL；
必须先完成 Release 资产、摘要、归档内容和灰度门禁验收。

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
