# V2bX
A V2board node server based on Xray-Core.

一个基于Xray的V2board节点服务端，支持V2ay,Trojan,Shadowsocks协议

Find the source code here: [InazumaV/V2bX](https://github.com/InazumaV/V2bX)

如对脚本不放心，可使用此沙箱先测一遍再使用：https://killercoda.com/playgrounds/scenario/ubuntu

# 详细使用教程

[教程](https://v2bx.v-50.me/)

# 一键安装

```
wget -N https://raw.githubusercontent.com/wyx2685/V2bX-script/master/install.sh && bash install.sh
```

## 已安装节点的一键 Hy2 修复

旧版安装脚本生成的 `/etc/V2bX/hy2config.yaml` 会先拒绝中国域名和 IP，港澳台节点因此也无法回连 B 站。`repair-hy2-cn-route.sh` 只在这两条拒绝规则前加入 B 站域名例外，原有中国目标拦截继续生效，QQ、百度等其他站点不会被放行。脚本不改 Xray、sing-box、管理脚本或 XBoard 面板规则；默认只检查，不写文件：

```bash
wget -O /root/repair-hy2-cn-route.sh https://raw.githubusercontent.com/rmomo5285-droid/V2bX-script/fix/known-issues/repair-hy2-cn-route.sh
chmod 700 /root/repair-hy2-cn-route.sh
/root/repair-hy2-cn-route.sh --check
/root/repair-hy2-cn-route.sh --apply
```

`--apply` 会加锁、保留元数据备份并原子替换配置；仅在 V2bX 原本运行时重启，重启或健康检查失败会自动回滚。若两条中国拒绝规则已经不存在，脚本不会重新添加。以后重新生成 Hy2 配置后可再运行一次；Xray/sing-box 的规则是单独审计项，不由这个最小修复脚本处理。
