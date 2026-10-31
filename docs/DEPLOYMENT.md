# 部署手册

面向把 apt-cacher-ultra 作为**容器**跑在一台 apt 缓存机上的场景。以目标机为例：
`172.31.0.3`（Ubuntu 24.04，5 块 NVMe，缓存放 14T 数据盘 `/data/harbor`，服务 `:3142` 代理 / `:6789` 状态页）。

---

## 0. 前提

- Docker（带 compose v2+）或 podman。服务器版镜像：`ghcr.io/yzh-7/apt-cacher-ultra`。
- 一块**数据盘**放缓存。不要把缓存放根盘：`[gc] url_path_ttl = "0s"` 意味着缓存条目永不过期，只进不出。
- 如果这台机器上已经跑着 `.deb` + systemd 版：先确认它的缓存目录和 CA（见 §2 与 §5），切换时**沿用同一个目录**。

---

## 1. 拿到镜像

三种来源，任选其一。

```bash
# A. 直接从 GHCR 拉
docker pull ghcr.io/yzh-7/apt-cacher-ultra:1.0.2

# B. 内网机器从 Harbor 拉（服务器每小时从 GHCR 同步过来，见 OPERATIONS.md）
docker pull 172.31.0.3:7777/infrastructure/apt-cacher-ultra:1.0.2

# C. 本地自己构建（不需要 Go，只需要上游 release 二进制）
./scripts/fetch-upstream.sh 1.0.2 dist        # 下载并按上游 SHA256SUMS 校验
docker build -f Dockerfile -t apt-cacher-ultra:1.0.2 dist
```

镜像里有什么：Alpine 基础 + `ca-certificates` + 16 MB 静态二进制（`ldd` = not a dynamic executable，SQLite 走纯 Go 的 `modernc.org/sqlite`，OpenPGP 走 Go 库，**不需要 gnupg**）。compact 体积 17.7 MB，空闲 RSS 约 14 MB。

---

## 2. 一次性准备：`deploy/prepare.sh`

```bash
cd deploy
sudo ACU_OUT_CONFIG=/etc/apt-cacher-ultra/config.container.toml \
     ./prepare.sh /data/harbor/apt-cacher-ultra /etc/apt-cacher-ultra/config.toml prod
```

它做四件事：

1. **缓存目录所有权**。容器以 `uid 113:gid 112`（与上游 `.deb` 建的用户一致）运行。docker 会把不存在的挂载源建成 `root:root`，于是 daemon 直接拒绝启动：
   `startup failed err="load config: cache.dir "/var/lib/apt-cacher-ultra": not writable"`
   这是第一次部署最常踩的坑。目录已存在且属主正确时这一步什么都不做；目录已存在且**非空**但属主不对时它会**拒绝**擅自 chown，让你自己决定。
2. **生成容器配置**（`make-container-config.sh`）。只改四处：缓存目录、代理监听、admin 监听、`keyring_dirs`。其余 retention/gc/adoption/MITM 原样继承，`diff` 可审阅。
3. **检查三个 keyring 目录**是否存在，准备挂载。
4. 打印下一步命令。

### 关于 `[adoption] enabled = false`

上游打包默认配置里 adoption 是关的，此时 daemon **不加载任何签名密钥**（状态页 `KEYS 0`），也永不采纳签名快照——和调优过的宿主实例是两种行为。

- 从已调优的宿主配置派生：`enabled = true` 会被继承，无需额外操作。
- 从上游默认配置派生（或全新部署）：加 `--enable-adoption`，或设 `ACU_ENABLE_ADOPTION=1`。CI 就是用它，否则流水线测不到验签路径。

`prepare.sh` 会在关闭时明确警告。

---

## 3. 起服务

```bash
cd deploy
cp .env.example .env      # 改 ACU_IMAGE / ACU_CACHE_DIR / ACU_CONFIG
docker compose up -d
docker ps --filter name=apt-cacher-ultra
```

`compose.yaml` 的关键决定，改之前请先看懂：

| 设置 | 为什么 |
|---|---|
| `network_mode: host` | bridge 网络会对客户端做 SNAT，缓存看到的来源全是自己的网关地址，状态页的按客户端/热路径视图与任何基于 IP 的管控都会失效。host 模式保留真实来源地址，`:3142`/`:6789` 由容器直接绑定。 |
| `user: "113:112"` | 与 `.deb` 用户和既有缓存目录属主一致，切换时不用 chown。 |
| `read_only: true` + `tmpfs /tmp` | 所有可写内容都在缓存卷里，其余可只读。 |
| `cap_drop: [ALL]`、`no-new-privileges` | 监听端口 >1024，不需要任何 capability。 |
| `stop_grace_period: 40s` | 大于 `.deb` unit 的 `TimeoutStopSec=35`，让 daemon 排空在途请求、收尾快照。 |
| 三个 keyring 只读挂载 | 见 §4。 |

**端口冲突**：如果 systemd 版还在跑，先 `sudo systemctl stop apt-cacher-ultra`（否则 `:3142` 被占）。切换正式生效前建议 `sudo systemctl disable apt-cacher-ultra`，避免重启后两个实例抢端口。

---

## 4. 密钥环（最容易静默失效的一处）

daemon 自己加载密钥来验证 InRelease 签名。`.deb` 版能直接读宿主的 `/usr/share/keyrings`、`/etc/apt/trusted.gpg.d`、`/etc/apt/keyrings`；容器里这些路径不存在。所以：

1. `compose.yaml` 把宿主这三个目录挂进 `/keyrings/…`；
2. `make-container-config.sh` 把它们写进 `[adoption] keyring_dirs`。

两者缺一，`require_signature=true` 的每个 suite 都会失败（日志里是 `gpg_failed`，状态页 Suites 表出现 FAILING）。

**宿主新加一把仓库 key 之后，要重启容器才会重新加载**：

```bash
docker restart apt-cacher-ultra
docker logs apt-cacher-ultra 2>&1 | grep keyring_keys   # 确认数量变大
```

`smoke-test.sh` 会断言"至少一把 key 来自 `/keyrings/`"，就是为了堵这个洞——只数总量是查不出挂载失效的，因为 bundled key 是编译进二进制的。

---

## 5. TLS MITM 与 CA（切换时最容易搞坏客户端的一处）

默认 `[tls_mitm] enabled = true`：缓存用一把本地 CA 现场签叶子证书，从而能缓存 HTTPS 源（`download.docker.com`、`cli.github.com` 等）。CA 存在 **缓存目录里的 `ca/`**：

```bash
docker exec apt-cacher-ultra /usr/local/bin/apt-cacher-ultra ca print \
    -config /etc/apt-cacher-ultra/config.toml > acu-ca.crt
```

必须知道的三件事：

1. **CA 属于缓存目录。** 沿用旧目录 = 客户端继续可用；换新目录 = 生成新 CA = 所有已装 CA 的客户端立刻 `certificate issuer is unknown`。备份缓存目录时 `ca/` 必须在内。
2. **客户端要装 CA 才能用 HTTPS 源**（HTTP 源不需要）。Debian/Ubuntu 客户端：
   ```bash
   sudo cp acu-ca.crt /usr/local/share/ca-certificates/apt-cacher-ultra-ca.crt
   sudo update-ca-certificates
   ```
   没装 CA 的机器上，走缓存的 HTTPS 源会报 `The certificate issuer is unknown`——本机上 `cli.github.com`、`pkgs.k8s.io` 现在的 apt 报错就是这个原因（与是否容器化无关）。
3. **默认这把 CA 没有域名约束**（`allowed_host_regex = ""` + `allow_unconstrained_ca = true`）。它装在任何一台机器上，等于给缓存机一个能签任意域名的根。收紧方法：在 `[tls_mitm] allowed_host_regex` 写仓库域名列表，并把 `allow_unconstrained_ca = false`，**然后删掉 `<cache>/ca/` 让它按约束重新生成**，再重新分发 CA 给客户端。改这把 CA 会中断现有客户端，属于要单独决策的事。

`smoke-test.sh` 第 5 项会用容器自己的 CA 去验证一次真实 HTTPS 抓取，CA 丢了或换了会立刻 FAIL。

---

## 6. 客户端怎么指过来

daemon 自带推荐片段：

```bash
docker exec apt-cacher-ultra /usr/local/bin/apt-cacher-ultra -print-apt-conf
```

典型 `/etc/apt/apt.conf.d/99apt-cacher-ultra`：

```
Acquire::http::Proxy "http://172.31.0.3:3142";
Acquire::https::Proxy "http://172.31.0.3:3142";   // 需要客户端已安装缓存 CA
Acquire::http::Proxy::localhost "DIRECT";
Acquire::https::Proxy::localhost "DIRECT";
```

临时试一次而不改配置：

```bash
http_proxy=http://172.31.0.3:3142 apt-get update
```

---

### 一个会踩的坑：不要把 apt 源写成缓存地址

下面这种写法**不行**：

```
deb http://172.31.0.3:3142/ubuntu noble main      # 会得到 400 Bad Request
```

因为 apt 走"origin-form"请求（`GET /ubuntu/...` + `Host: 172.31.0.3`），daemon 从 `Host` 反推上游主机，而那是缓存自己，不是任何上游 → 请求被判 `outcome=bad`（实测 400）。

正确写法是让源保持真实主机名，把代理指过去（就是上面 §6 那段 apt.conf）：

```
deb http://archive.ubuntu.com/ubuntu noble main
```
```
Acquire::http::Proxy "http://172.31.0.3:3142";
```

这样 daemon 看到的是 `canonical_host=archive.ubuntu.com`，才能正确建 key、命中缓存。日志里两种形态一眼可分辨：

```
level=INFO msg=request ... canonical_host=archive.ubuntu.com path=/ubuntu/dists/noble/InRelease outcome=miss
```

### 新实例的 adoption 不会立刻跑

刚起一个空缓存的实例，`acu_suites_tracked` 会随客户端 `apt-get update` 立刻涨（实测 4），但快照 adoption 按自己的节奏跑（这台机器上 `[gc] interval = "1h"`），所以 `acu_adoption_total` 与 `acu_snapshots_current` 一开始是 0 是**正常**的，不是坏了。

`POST /reconcile` 不能催动一个还没有快照的 suite——实测返回 409 `reconcile not triggered (busy, unknown, or no current snapshot)`。它只对已有快照的 suite 有意义。判断新实例是否健康要看：`outcome=hit` 是否出现、`acu_suites_tracked` 是否随客户端增长、`acu_adoption_total` 是否在一个 interval 之后开始增长。

## 7. 部署后验证（必做）

```bash
./scripts/smoke-test.sh \
  --admin http://127.0.0.1:6789 --proxy http://127.0.0.1:3142 \
  --container apt-cacher-ultra --min-keys 9 --allow-open-admin
```

10 项：healthz、密钥环数量、**至少一把 key 来自 `/keyrings/`**、真实上游抓取、第二次 `outcome=hit`、真实 `apt-get download`、MITM HTTPS 用容器 CA 验证通过、admin 监听暴露方式与鉴权是否匹配、二进制版本、缓存数据库非空。

`--allow-open-admin` 只在"你确实要让状态页无鉴权对外开"时加；不加时状态页 `0.0.0.0:6789` + `htpasswd_file = ""` 会直接 FAIL（这是设计上的把关，不是脚本 bug）。

---

## 8. 升级

```bash
docker pull ghcr.io/yzh-7/apt-cacher-ultra:1.1.0
# 用新版本重新生成容器配置：设置名若被上游改名，脚本会报错而不是静默留旧值
sudo ACU_OUT_CONFIG=/etc/apt-cacher-ultra/config.container.toml \
     ./deploy/make-container-config.sh prod /etc/apt-cacher-ultra/config.toml /etc/apt-cacher-ultra/config.container.toml
docker compose up -d          # 只换镜像，缓存目录与 CA 原地继承
./scripts/smoke-test.sh --admin http://127.0.0.1:6789 --proxy http://127.0.0.1:3142 \
    --container apt-cacher-ultra --min-keys 9 --allow-open-admin
```

**升级前必看**上游 release 的 "Upgrade notes"：例如 1.1.0 把 `[gc] interval` 默认从 `1h` 改成 `15m`，并把 `.deb` 默认 `[admin] listen` 从 `0.0.0.0:6789` 改为 `127.0.0.1:6789`——这类变化会直接改变你的暴露面和 GC 节奏。

## 9. 回滚

```bash
docker compose down
docker tag 172.31.0.3:7777/infrastructure/apt-cacher-ultra:1.0.2 apt-cacher-ultra:rollback
ACU_IMAGE=apt-cacher-ultra:rollback docker compose up -d
```

缓存目录与数据格式跨版本沿用（SQLite），回滚不需要数据转换。若新版本已经改过数据库 schema 而旧版本拒绝打开，回滚前把 `cache.db*` 备份一份再试——`.deb` 版和容器版用同一套代码，所以这种情况只发生在真正的版本回退上。

彻底退回 systemd 版：

```bash
docker compose down
sudo systemctl enable --now apt-cacher-ultra
```

---

## 10. 备份与迁移

状态全在一个目录里：

```bash
docker stop apt-cacher-ultra
sudo tar --xattrs -C /data/harbor -czf /mnt/backup/acu-cache-$(date +%F).tar.gz apt-cacher-ultra
docker start apt-cacher-ultra
```

tar 里必须包含 `ca/`（CA 的私钥 `ca.key` 权限 0600，备份介质要同样保护）。恢复：解包到目标缓存目录 → `chown -R 113:112` → `docker compose up -d` → 跑 smoke test。

备份完可以不留运行中断：`url_path_ttl = 0s` 的缓存只是"少了热数据"，daemon 会按需回源。

---

## 11. 故障排查

| 现象 | 原因 | 处理 |
|---|---|---|
| 容器反复重启，日志 `cache.dir …: not writable` | 缓存目录属主不是 113:112（docker 建挂载点默认 root） | `sudo ./deploy/prepare.sh <目录> …` 或 `chown -R 113:112` |
| 启动即退出，日志 `config.toml: is a directory` | compose 里配置文件的**宿主路径不存在**，docker 给你造了个目录 | 先确认宿主文件存在再起（常见于 `.env` 里 `ACU_CONFIG` 写错） |
| 状态页 `KEYS 0`，日志无 `phase2 adoption enabled` | `[adoption] enabled = false`（上游打包默认） | 加 `--enable-adoption` 重新生成配置 |
| Suites 表 FAILING，日志 `gpg_failed` | keyring 没挂载或没写进 `keyring_dirs` | 检查 `/keyrings/…` 挂载与配置；`docker logs … | grep keyring_keys` |
| 客户端 `certificate issuer is unknown` | 客户端没装缓存的 CA，而该源走 HTTPS | 装 §5 的 CA，或给该客户端把 https 代理设为 `DIRECT` |
| 客户端 `NO_PUBKEY …` / `InRelease is not signed` | 客户端侧缺仓库 keyring（与缓存无关） | 在客户端装该仓库 key 到 `/etc/apt/keyrings` |
| `:3142` 被占，容器起不来 | systemd 版还在跑 | `systemctl stop && systemctl disable apt-cacher-ultra` |
| 状态页/`/metrics` 谁都看得到的 `POST /reconcile` | `[admin] listen = 0.0.0.0:6789` 且 `htpasswd_file = ""`（1.0.2 里 `X-ACU-Admin` 头并不能挡住未授权调用：实测有无该头都是 409） | 改回 `127.0.0.1:6789`，或配 `htpasswd_file`，或防火墙限内网 |
| `apt-get update` 对缓存地址报 `400 Bad Request`，日志 `outcome=bad` | 把 apt 源直接写成了缓存主机（见 §6 的坑） | 源保持真实主机名，用 `Acquire::http::Proxy` 指过去 |
| 缓存目录一直涨 | `gc.url_path_ttl = "0s"`（永不过期） | 设 `url_path_ttl`（如 `"180d"`）或加容量告警，见 OPERATIONS.md |

看日志与状态：

```bash
docker logs -f apt-cacher-ultra
docker exec apt-cacher-ultra /usr/local/bin/apt-cacher-ultra -version
curl -s http://127.0.0.1:6789/metrics | grep -E '^acu_(blobs_db_count|blobs_db_total_bytes|suites_tracked|snapshots_current)'
curl -s http://127.0.0.1:6789/ | sed 's/<[^>]*>/ /g' | tr -s ' \n' ' ' | head -c 800
```
