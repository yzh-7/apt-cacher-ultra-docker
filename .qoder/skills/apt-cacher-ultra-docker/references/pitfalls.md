# 实测踩过的坑与判读顺序

每条都是在真机和 CI 上出现过的，不是通用提醒。

## 服务"起来了"但实际是废的

**症状**：healthz 正常，状态页 `KEYS 0`，快照永不采纳，命中率长期难看。
**原因**：上游打包默认 `[adoption] enabled = false`。照搬这份默认配置就没有任何签名密钥被加载。
**处置**：配置派生时必须带 `--enable-adoption`（`plan.sh` 已强制）。判读：状态页密钥数量、`acu_adoption_total`、`acu_snapshots_current`。

## 新实例的 adoption 不会立刻跑

**症状**：`acu_suites_tracked` 随客户端 `apt-get update` 涨到 4，但 `acu_adoption_total` 和 `acu_snapshots_current` 一直是 0。
**原因**：快照采纳按自己的节奏跑（这台机器上 `[gc] interval = "1h"`）。
**处置**：等一个 interval 再看增长。`POST /reconcile` 催不动还没有快照的 suite，实测返回 409：`reconcile not triggered (busy, unknown, or no current snapshot)`。

## apt 对缓存地址报 400

**症状**：`apt-get update` 报 `400 Bad Request`，容器日志 `outcome=bad`。
**原因**：apt 源被直接写成缓存主机。此时 apt 发 origin-form 请求（`GET /ubuntu/...` 配 `Host: <cache>`），守护进程无法从 `Host` 反推上游。
**处置**：源保持真实主机名，用 `Acquire::http::Proxy` 指过去。判读：日志里应出现 `canonical_host=archive.ubuntu.com`。

## HTTPS 源报证书签发者未知

**症状**：`The certificate issuer is unknown`（`cli.github.com`、`prod-cdn.packages.k8s.io` 这类源最容易撞）。
**原因**：MITM 签出的证书由缓存自己的 CA 签发，客户端不认这个 CA。
**处置**：要么客户端信任缓存 CA（CA 在 `<cache.dir>/ca`，用容器命令打印指纹），要么让这些源直连（`Acquire::https::Proxy "DIRECT"`）。这是安全决定，交给用户。

## 密钥数量对不上主机

**原因**：keyring 目录只 bind-mount 没写进 `keyring_dirs`，或反过来。也可能主机上那个 keyring 文件是 0 字节（真实出现过：`/etc/apt/keyrings/kubernetes-apt-keyring.gpg` 为空）。
**处置**：挂载与配置两处都要有；挂载前确认源文件存在且非空。

## 容器启动即退出

**症状**：日志 `startup failed err="load config: cache.dir ...: not writable"`。
**原因**：缓存目录不是 `113:112` 所有，或者压根不存在导致 Docker 建了个 root 所有的目录。
**处置**：`install -d -m 0750` 然后 `chown 113:112`。目录非空时不要 `chown -R`。

## 管理端口的暴露

上游打包默认 `listen = "127.0.0.1:6789"`，是安全默认值。**不要**把它改成 `0.0.0.0` 而不同时配 `htpasswd_file`。
1.0.2 里 `X-ACU-Admin` 头不构成鉴权——实测有无这个头，未授权调用都返回 409。所以判断暴露与否要看配置的 `listen` 与 `htpasswd_file`，不要拿"带不带某个头"当测试。

## 读不到 digest

`docker buildx imagetools inspect` 没有 `--insecure`，对明文 HTTP 的 registry 会报 `server gave HTTP response to HTTPS client`。改用 registry v2 API 的 `Docker-Content-Digest` 头（见 `references/registry-flows.md`）。

另一个同族坑：imagetools 的 `--format` 里没有 `.Config` 字段。读 label 要写 `{{ index .Image.Config.Labels "..." }}`；写错时命令报错，如果又被 `|| echo unknown` 吞掉，逻辑会永远走到"未知"分支而不报任何异常。

## 判断是否真在缓存

按这个顺序看，不要只看一个数：

1. `acu_requests_total{outcome="hit"}` 占比 —— 有没有命中。
2. 容器日志同一 URL 两次请求的 `duration_ms` —— 回源和命中的差值是硬证据（实测 8238 ms 对 3 ms）。
3. `acu_blobs_db_count` 与 `acu_blobs_db_total_bytes` —— 存储是否在长。
4. `acu_freshness_stale_suites` —— 索引是否过期。
5. `acu_mitm_ca_not_after_unixtime` —— CA 还有多久到期，比事后发现客户端报错早得多。

`acu_keyring*` 这类指标不存在，密钥数量只在状态页有。
