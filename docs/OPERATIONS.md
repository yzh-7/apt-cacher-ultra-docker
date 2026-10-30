# 运维手册

## 1. 日常健康检查

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:6789/healthz      # 200 + body "ok"
docker inspect -f '{{.State.Health.Status}} restarts={{.RestartCount}}' apt-cacher-ultra
docker logs --since 1h apt-cacher-ultra 2>&1 | grep -ciE 'level=ERROR'
```

关键指标（`curl -s http://127.0.0.1:6789/metrics`）：

以下名字是从这台机器的 `/metrics`（738 行）里实际抓出来的，不是推测；`acu_keyring*` 这类**不存在**，密钥环数量只有状态页有（`smoke-test.sh` 因此读状态页）。

| 指标 | 看什么 |
|---|---|
| `acu_blobs_db_count` / `acu_blobs_db_total_bytes` | 缓存体量与增长趋势 |
| `acu_suites_tracked` | 已跟踪的 suite 数（应与在用的仓库数量级一致） |
| `acu_freshness_stale_suites` | 索引过期的 suite 数；长期 >0 说明刷新或回源有问题 |
| `acu_snapshots_current` / `acu_snapshots_displaced` | 采纳了多少快照、替换掉多少旧快照 |
| `acu_adoption_total` / `acu_adoption_members_skipped_total` | adoption 在跑还是被跳过；skipped 增长要看 reason |
| `acu_requests_total{outcome=…,host=…}` | `outcome="hit"` 占比就是缓存有效性 |
| `acu_blobs_zero_refcount_backlog` / `acu_blobs_actually_reapable` / `acu_gc_blobs_reaped_total` | GC 有没有在回收；backlog 只涨不降就是 GC 没干活 |
| `acu_mitm_cert_issued_total` / `acu_mitm_cert_cache_lookups_total` | MITM 在签多少证书、缓存命中如何 |
| `acu_mitm_ca_not_after_unixtime` | **CA 到期时间**，比事后发现客户端报错早很多 |
| `acu_admin_refresh_failures_total` / `acu_admin_refresh_last_success_unixtime` | 状态页后台刷新的健康度 |
| `acu_inflight_requests` / `acu_request_duration_seconds_*` | 负载与延迟分布 |

一条现成的读数命令（同一个脚本可以直接放进巡检 cron）：

```bash
./scripts/metrics-snapshot.sh                    # 默认 http://127.0.0.1:6789
./scripts/metrics-snapshot.sh http://127.0.0.1:16789   # 验证实例
```

## 2. 容量

`[gc] url_path_ttl = "0s"` 时 URL 条目**永不过期**，缓存只增不减。控制增长只有两条路：设 `url_path_ttl`，或者监控 + 人工清理。

```bash
df -h /data/harbor
du -sh /data/harbor/apt-cacher-ultra
curl -s http://127.0.0.1:6789/metrics | awk '/^acu_blobs_db_total_bytes/{printf "%.1f GiB\n", $2/1073741824}'
```

告警建议：数据盘使用率 >85%，或 `acu_blobs_db_total_bytes` 一周增量超过预算。改 `url_path_ttl` 会改变缓存保留行为，属于要明确决策的变更（`make-container-config.sh` 只动四处，不擅自改它）。

## 3. 备份

状态全在缓存目录里（`cache.db` + `blobs/` + `ca/` + 状态文件）。停机一致最简单：

```bash
docker stop apt-cacher-ultra
sudo tar --xattrs -C /data/harbor -czf /mnt/backup/acu-cache-$(date +%F).tar.gz apt-cacher-ultra
docker start apt-cacher-ultra
```

**`ca/` 必须进备份**：里面是客户端已信任的 MITM CA 与其私钥（`ca.key` 是 0600），备份介质要与私钥同等保护。丢了 `ca/` 而客户端仍装着旧 CA，故障表现为 `certificate issuer is unknown`，只能靠重新分发新 CA 修复。

## 4. 镜像同步：GHCR → 内网 Harbor

GitHub Actions 跑在 GitHub 的机器上，**到不了 172.31.0.3**，所以发布方向是 Actions → GHCR，服务器再从 GHCR 镜像一份进 Harbor（`deploy/harbor-sync.sh`，按 digest 比对，已同步的不重复搬）。

```bash
cd deploy
cp harbor-sync.env.example harbor-sync.env      # chmod 600，不进 git
DRY_RUN=1 ./harbor-sync.sh                      # 先看会做什么
./harbor-sync.sh
```

三条已验证行为：上游没有该 tag → `SKIP` 并退出 0；digest 不同 → `COPY`；digest 相同 → `OK already at`（每小时跑也不会白搬）。

### Harbor 侧的前置条件（本机现状）

| 项 | 值 |
|---|---|
| 项目 | `infrastructure`，**public**（客户端匿名 pull，推送才需要凭据） |
| robot | `robot$infrastructure+acu-sync`，仅该项目的 `repository:push` + `repository:pull` |
| 凭据文件 | 服务器上 `/etc/apt-cacher-ultra-docker/harbor-sync.env`，mode 600 |
| Docker | `/etc/docker/daemon.json` 里已有 `insecure-registries: ["172.31.0.3:7777"]` |

Harbor 是明文 HTTP，因此 `docker buildx imagetools inspect` 对它不可用（这个子命令没有 insecure 开关），脚本改用 distribution v2 API 的 `Docker-Content-Digest` 取 digest。

如果要在别的 Harbor 上重做这套账号，注意 v2.15 的两个字段名坑：建项目用 `project_name`（不是嵌套的 `project.name`，否则报一句误导性的 "Project name is illegal in length"），robot 的权限项用 `access[].resource` + `access[].action`（不是 `type`）。robot 的 secret 只在创建响应里返回一次，且 Harbor 会**忽略**你自带的 `secret` 值——自己生成再填进去是拿不到的。

### 让它自动跑

```bash
# 1) 脚本装到固定位置（仓库目录可能被删，unit 不指向工作副本）
sudo install -d -m 0755 /usr/local/src/apt-cacher-ultra-docker
sudo install -m 0755 deploy/harbor-sync.sh /usr/local/src/apt-cacher-ultra-docker/
sudo cp -a docs /usr/local/src/apt-cacher-ultra-docker/        # unit 里的 Documentation= 指向它

# 2) 凭据
sudo install -d -m 0700 /etc/apt-cacher-ultra-docker
sudo install -m 0600 deploy/harbor-sync.env /etc/apt-cacher-ultra-docker/harbor-sync.env

# 3) 定时器
sudo install -m 0644 deploy/acu-sync.service deploy/acu-sync.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now acu-sync.timer

# 4) 验证
sudo systemctl start acu-sync.service            # 立刻手动跑一次
journalctl -u acu-sync.service -n 20 --no-pager
systemctl list-timers acu-sync.timer --no-pager
```

`acu-sync.service` 用 `Environment=ACU_SYNC_ENV=…` 而不是 `EnvironmentFile=`：systemd 的 `EnvironmentFile` 会把引号当字面量保留，而 robot 账号名是 `robot$project+user` 这种带 `$` 又需要引号的值。脚本自己解析该文件（并且**不会覆盖**调用方已设置的环境变量）。

## 5. 更新镜像

流水线只在**上游有新版本**时构建；基础镜像（含 `ca-certificates`）变化由 `rebuild-base.yml` 每周处理，只前移 `latest`，不动版本 tag。

服务器侧真正用上更新还需要有人拉新镜像并重启服务。本仓库故意**不自动重启生产服务**：升级 apt 缓存会影响整栋楼的 apt 行为，值得人来点头。手动步骤见 DEPLOYMENT.md §8；想半自动化，就在同步完成后接一个 `docker compose pull && docker compose up -d`，但请把它当成显式的变更而不是后台顺手做的事。

## 6. 安全注意

- **状态页无鉴权**：`[admin] listen = 0.0.0.0:6789` 且 `htpasswd_file = ""` 时，状态页、`/metrics` 以及写端点 `POST /reconcile` 对所有能连到 6789 的机器开放。三条收敛路：绑 `127.0.0.1:6789`、配 `htpasswd_file`、防火墙限内网。`smoke-test.sh` 第 6 项会把这种情况报成 FAIL（除非显式 `--allow-open-admin`）。
- **MITM CA 无域名约束**（默认 `allowed_host_regex = ""`）：这把 CA 能签任意域名，装进客户端就等于给缓存机一个全局签发权。收紧流程见 DEPLOYMENT.md §5（改配置 + 删 `ca/` 重新生成 + 重新分发）。
- **容器权限**：`cap_drop ALL`、`no-new-privileges`、只读根文件系统、非 root（113:112）。要加监控就加只读挂载，不要加 capability。
- **凭据**：`deploy/harbor-sync.env` 与 `/etc/apt-cacher-ultra-docker/harbor-sync.env` 都不进 git，仓库里只有 `*.example`。GHCR 若保持公开包，服务器就不需要任何 GHCR 凭据。

## 7. 与宿主机既有 apt 问题的关系

这台机器上现在有两类 apt 故障，与是否容器化无关：

- `NO_PUBKEY 7EA0A9C3F273FCD8`（download.docker.com）：客户端侧缺仓库 keyring。
- `cli.github.com` / `pkgs.k8s.io` 走缓存时报 `The certificate issuer is unknown`：客户端没装缓存的 MITM CA；另外 `/etc/apt/keyrings/kubernetes-apt-keyring.gpg` 是 0 字节，属独立问题。

缓存容器不修这两件事。真要修，先决定"是否给全机安装一把无约束 CA"——这是安全决策，不是运维便利。
