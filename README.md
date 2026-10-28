# sbvm

`sbvm` 是一个基于 [sing-box](https://github.com/SagerNet/sing-box) 的
Bash 管理脚本，用于管理 **VMess + WebSocket（纯 IP、无域名）**节点。

## 一键安装

复制下面的命令运行。请先将 `你的用户名/你的仓库名` 替换为实际的 GitHub
仓库地址：

``` bash
curl -fsSL https://raw.githubusercontent.com/wcdd/vms/main/sbvm.sh -o /tmp/sbvm.sh && sudo bash /tmp/sbvm.sh
```

安装完成后，可直接运行：

``` bash
sudo sbvm
```

## 功能

-   安装、更新 sing-box
-   新增、修改、删除和查看节点
-   导出 VMess 分享链接及二维码（需安装 `qrencode`）
-   管理服务、查看日志和运行状态
-   配置备份、恢复与失败回滚
-   防火墙端口处理及故障诊断
-   可选网络参数调优

## 使用要求

-   Linux 服务器，建议使用支持 `systemd` 的发行版
-   需要 `root` 权限或 `sudo`
-   服务器需能访问 GitHub 下载文件

## 注意事项

-   节点默认使用 VMess + WebSocket，**TLS 默认关闭**。
-   云服务器的安全组或网络 ACL 需要在服务商控制台单独放行对应 TCP 端口。
-   脚本会修改系统配置、防火墙规则和服务设置；使用前请先审查脚本，并备份重要数据。
-   请遵守所在地法律法规及服务器服务商的使用政策。
