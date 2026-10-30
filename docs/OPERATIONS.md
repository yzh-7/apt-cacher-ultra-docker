# 运维手册

## 1. 日常健康检查

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:6789/healthz      # 200 + body "ok"
docker inspect -f '{{.State.Health.Status}} restarts={{.RestartCount}}' apt-cacher-ultra
docker logs --since 1h apt-cacher-ultra 2>&1 | grep -ciE 'level=ERROR'
```

关键指标（`curl -s http://127.0.0.1:6789/metrics`）：

| 指标 | 看什么 |
|---|---|
| `acu_blobs_db_count` / `acu_blobs_db_total_bytes` | 缓存体量与增长趋势 |
| `acu_suites_tracked` | 已跟踪的 suite 数（应等于你在用的仓库数量级） |
| `acu_snapshots_current` / `acu_snapshots_stale` | 快照是否新鲜；stale 长期 >0 说明 adoption 或回源有问题 |
| `acu_http_requests_total` | 按 `outcome` 分类（`hit` 比例是缓存有效性的直接读数） |
| `acu_gpg_key_status` | 密钥状态：`loaded_ok` 数量对得上密钥环数量 |
| `acu_tls_mitm_generated_total` / `acu_tls_mitm_denied_total` | MITM 在签 / 在拒；denied 突增说明 `allowed_host_regex` 与在用域名不一致 |
| `acu_upstream_fetch_failures_total` | 回源失败计数 |

## 2. 容量

这台机器上 `[gc] url_path_ttl = "0s"`：URL 条目**永不过期**，缓存只增不减。要控制增长只有两条路：设 `url_path_ttl`，或监控并人工清理。

```bash
df -h /data/harbor
du -sh /data/harbor/apt-cacher-ultra
curl -s http://127.0.0.1:6789/metrics | awk '/^acu_blobs_db_total_bytes/{print $2/1073741824" GiB"}'
```

告警建议：数据盘使用率 >85%，或 `acu_blobs_db_total_bytes` 一周增量超过预算时通知。改 `url_path_ttl` 会改变缓存保留行为，属于要明确决策的变更（本仓库默认不擅自改，`make-container-config.sh` 只动四处）。

## 3. 备份

状态全在缓存目录里（`cache.db` + `blobs/` + `ca/` + 状态文件）。停机一致最简单：

```bash
docker stop apt-cacher-ultra
sudo tar --xattrs -C /data/harbor -czf /mnt/backup/acu-cache-$(date +%F).tar.gz apt-cacher-ultra
docker start apt-cacher-ultra
```

不想停机就拷 `cache.db` 的在线副本（daemon 自己会周期产出在线副本；用 `.db` 与它的 journal 一起拷，恢复时优先用 daemon 生成的副本）。

**`ca/` 必须进备份**：里面是客户端已信任的 MITM CA 与其私钥（`ca.key` 是 0600）。备份介质要与私钥同等保护。丢了 `ca/` 而客户端还装着旧 CA，故障表现为 `certificate issuer is unknown`，且只能靠重新分发新 CA 修复。

## 4. 镜像同步：GHCR → 内网 Harbor

GitHub Actions 跑在 GitHub 的机器上，**到不了 172.31.0.3**，所以发布方向是 Actions → GHCR，服务器再从 GHCR 镜像一份进 Harbor（`deploy/harbor-sync.sh`，按 digest 比对，已同步的不重复拉）。

```bash
cd deploy
cp harbor-sync.env.example harbor-sync.env      # chmod 600，不进 git
# HARBOR_REGISTRY=172.31.0.3:7777  HARBOR_PROJECT=infrastructure  IMAGE_NAME=apt-cacher-ultra
# HARBOR_USER / HARBOR_PASSWORD 用 Harbor 的 robot 账号（推镜像用，不要用人类账号）
# SYNC_TAGS="latest 1.0.2"
DRY_RUN=1 ./harbor-sync.sh            # 先看会做什么
./harbor-sync.sh
```

Harbor 侧需要：项目 `infrastructure`、一个有 *push* 权限的 robot 账号、以及允许 GHCR 出网。服务器 Docker 已配置 `insecure-registries: ["172.31.0.3:7777"]`（`/etc/docker/daemon.json`）；若换成 HTTPS 证书，这段可去掉。

### 让它自动跑

```bash
# 每小时同步一次，另开机后 5 分钟内补一次
sudo install -d -m 0700 /etc/apt-cacher-ultra-docker
sudo install -m 0600 deploy/harbor-sync.env /etc/apt-cacher-ultra-docker/harbor-sync.env
sudo install -m 0755 deploy/harbor-sync.sh deploy/.env.example /usr/local/src/apt-cacher-ultra-docker/ 2>/dev/null || \
  sudo cp -a deploy /usr/local/src/apt-cacher-ultra-docker

# 定时器：ACU_SYNC_IMAGE 固定成本仓库的绝对路径
sudo tee /etc/systemd/system/acu-sync.service > /dev/null <<'UNIT'
[Unit]
Description=Mirror apt-cacher-ultra images from GHCR to local Harbor
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/apt-cacher-ultra-docker/harbor-sync.env
ExecStart=/usr/local/src/apt-cacher-ultra-docker/harbor-sync.sh
UNIT

sudo tee /etc/systemd/system/acu-sync.timer > /dev/null <<'UNIT'
[Unit]
Description=Hourly GHCR to Harbor mirror of apt-cacher-ultra

[Timer]
OnBootSec=5min
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
UNIT

sudo systemctl daemon-reload && sudo systemctl enable --now acu-sync.timer
systemctl status acu-sync.timer --no-pager
```

上面这段是模板；`deploy/harbor-sync.sh` 读的是仓库内的 `deploy/harbor-sync.env`，两种装法（仓库内跑 / 装到 `/usr/local/src` 跑）都支持，只要 `EnvironmentFile` 与脚本路径对上。

## 5. 更新镜像

流水线只在**上游有新版本**时构建。基础镜像（含 `ca-certificates`）变化由 `rebuild-base.yml` 每周处理，只前移 `latest`，不动版本 tag。

服务器侧要真正用上更新，得有人拉新镜像并重启服务。最省事的做法：在 `acu-sync.timer` 之后接一个 `docker compose up -d`（`--pull always`），或者在 Harbor 同步完成后由你手动 `docker compose pull && docker compose up -d`。本仓库故意**不自动重启生产服务**：升级 apt 缓存会影响整栋楼的 apt 行为，值得人来点头。

## 6. 安全注意

- **状态页无鉴权**：`[admin] listen = 0.0.0.0:6789` 且 `htpasswd_file = ""` 时，状态页、`/metrics` 以及写端点 `POST /reconcile` 对所有能连到 6789 的机器开放。三条收敛路：绑 `127.0.0.1:6789`、配 `htpasswd_file`、防火墙限内网。`smoke-test.sh` 第 6 项会把这种情况报成 FAIL（除非你显式 `--allow-open-admin`）。
- **MITM CA 无域名约束**（默认 `allowed_host_regex = ""`）：这把 CA 能签任意域名，装进客户端就等于给缓存机一个全局签发权。收紧流程见 DEPLOYMENT.md §5（改配置 + 删 `ca/` 重新生成 + 重新分发）。
- **容器权限**：`cap_drop ALL`、`no-new-privileges`、只读根文件系统、非 root（113:112）。要加监控（例如 docker exec 读文件）不要靠加 capability，加挂载即可。
- **凭据**：`deploy/harbor-sync.env` 与 GitHub secrets 都不进 git。仓库里只有 `*.env.example`。

## 7. 与宿主机既有 apt 问题的关系

这台机器上现在有两类 apt 故障，与是否容器化无关：

- `NO_PUBKEY 7EA0A9C3F273FCD8`（download.docker.com）：客户端侧缺仓库 keyring。
- `cli.github.com` / `pkgs.k8s.io` 走缓存时报 `The certificate issuer is unknown`：客户端没装缓存的 MITM CA；`kubernetes-apt-keyring.gpg` 目前是 0 字节，也是独立问题。

缓存容器不修这两件事。真要修，先决定"是否给全机安装一把无约束 CA"——这是安全决策，不是运维便利。
