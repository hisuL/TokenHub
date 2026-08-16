# TokenHub 思朗单机离线版

版本：`0.5.0-silang.1`

本包用于 Linux x86_64 内网单机部署。运行形态为 Nginx 单入口、TokenHub v0.5 优化版和本机 PostgreSQL 16，不包含负载均衡、云数据库、APISIX 或全链路追踪组件。

## 运行边界

- Nginx 只承担统一入口和长连接反向代理，不执行负载均衡。
- TokenHub 同一容器运行 Backend 与 Frontend。
- PostgreSQL 数据保存在宿主机安装目录。
- TokenHub 自带的请求、用量、费用和路由记录保留。
- Metrics、OTLP Trace、正文 Trace 和 Provider 出站正文审计默认关闭。
- 主机故障不会自动切换，数据库备份应复制到另一块磁盘或内网 NAS。

## 环境要求

- Linux x86_64
- Docker Engine 可用
- Docker Compose v2，或兼容的 `docker-compose`
- `sha256sum`、`gzip`、`tar`、`od`
- 默认至少占用端口 `8080`

当前应用包不包含 Docker RPM/DEB。目标操作系统版本确认后，可追加对应系统的 Docker 离线运行时附件。

## 安装

```bash
tar -xzf tokenhub-silang-offline-0.5.0-silang.1-linux-amd64.tar.gz
cd tokenhub-silang-offline-0.5.0-silang.1-linux-amd64
sudo ./bin/install.sh \
  --public-base-url http://192.168.1.20:8080 \
  --admin-password 'TokenHub@2026'
```

安装脚本执行以下操作：

1. 校验包内所有文件的 SHA-256。
2. 检查 Linux、x86_64、Docker 和 Compose。
3. 从本地压缩归档导入三个固定版本镜像，不访问镜像仓库。
4. 首次安装写入指定的管理员密码，并生成管理 Token、数据库密码和数据加密密钥。
5. 输出控制台地址和管理员密码，但不启动服务。

凭据保存在 `/opt/tokenhub-silang/.env`，权限为 `0600`。重复执行安装脚本会保留原凭据和数据库。
安装完成后必须先修改 `.env` 和 `app/config/models.json`，再手动执行 `start.sh`。

仅执行环境和包检查：

```bash
sudo ./bin/install.sh --check-only \
  --public-base-url http://192.168.1.20:8080
```

## 启停

```bash
sudo /opt/tokenhub-silang/app/bin/start.sh
sudo /opt/tokenhub-silang/app/bin/restart.sh
sudo /opt/tokenhub-silang/app/bin/stop.sh
```

## 模型配置

复制并修改模型配置：

```bash
sudo cp config/models.example.json /opt/tokenhub-silang/app/config/models.json
sudo chmod 600 /opt/tokenhub-silang/app/config/models.json
sudo vi /opt/tokenhub-silang/app/config/models.json
sudo /opt/tokenhub-silang/app/bin/configure-models.sh
```

配置中需要提供 SGLang Router 的内网 Base URL、鉴权信息，以及客户模型名到上游模型名的映射。将 `enabled` 改为 `true` 后执行配置脚本。脚本采用固定 Provider/Resource ID，重复执行不会重复创建已有对象。

## 运维

```bash
sudo /opt/tokenhub-silang/app/bin/status.sh
sudo /opt/tokenhub-silang/app/bin/backup.sh
```

备份包同时保存 PostgreSQL dump 和 TokenHub 加密密钥，因此权限固定为 `0600`，应按敏感凭据管理。恢复操作会先自动创建当前状态备份：

```bash
sudo /opt/tokenhub-silang/app/bin/restore.sh \
  /opt/tokenhub-silang/backups/tokenhub-backup-YYYYmmdd_HHMMSS.tar.gz \
  --yes
```

停止并移除容器、保留数据：

```bash
sudo /opt/tokenhub-silang/app/bin/uninstall.sh
```

永久删除应用、数据库、凭据和备份：

```bash
sudo /opt/tokenhub-silang/app/bin/uninstall.sh --purge-data --yes
```

## 离线验收要求

正式交付前使用与客户目标机相同的操作系统，在无默认路由、无 DNS、空 Docker 镜像缓存的环境中完成：全新安装、宿主机重启、非流式调用、流式调用、Claude Code 工具调用、备份、恢复和卸载保留数据验证。
