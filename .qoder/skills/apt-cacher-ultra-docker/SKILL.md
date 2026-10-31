---
name: apt-cacher-ultra-docker
description: 部署、验证、升级、回滚 apt-cacher-ultra 的容器镜像，并把镜像从 GHCR 同步到内网 registry。当用户提到 apt-cacher-ultra、acu 容器、容器化 apt 缓存、给 apt 缓存服务器换镜像或升基础镜像、把 apt 缓存镜像推到内网 registry 或 harbor、缓存容器起不来或缓存不命中、要决定 apt 缓存的数据放哪块盘时使用。不用于 apt-cacher-ng，不改上游 apt-cacher-ultra 源码，不替用户决定何时切换生产 apt 缓存实例。
---

# 用容器跑 apt-cacher-ultra

所有实际工作都调用工具仓库里已验证过的脚本。不要在 skill 里重写 compose、配置派生或冒烟逻辑——那份代码有 CI 和真机验证，重复实现只会漂移。

## 0. 开工前必须确认的四件事

缺任何一条先问用户，不要猜：

1. 目标主机是哪台，有没有 Docker 与 compose。
2. 镜像从哪来：直接 `ghcr.io/<owner>/apt-cacher-ultra`，还是内网 registry。
3. 缓存数据放哪块盘（见第 2 节；这是本 skill 最容易做错的地方）。
4. 主机上是否已有 apt 缓存在跑（systemd 服务或另一个容器）。有则默认并行试点，不接管。

## 1. 找到工具仓库

```bash
scripts/locate.sh
```

它按 `ACU_REPO` → 常见安装位置 → 克隆公开仓库的顺序找，打印仓库路径。找不到就报错退出，此时告诉用户仓库地址请他确认，**不要自己攒一份 compose 文件**。后续所有命令都在这个路径下执行。

## 2. 先出计划，再动手（默认 dry-run）

```bash
scripts/plan.sh                     # 只读，打印判定过程
scripts/plan.sh --apply             # 用户认可后才落盘
```

`plan.sh` 决定三件事，并把每条排除理由讲出来。规则如下，你要能替它解释：

**存储位置（硬规则，无例外）**

- 系统盘不选。缓存写满系统盘是本 skill 要防的第一号事故。
- 不在 `/etc/fstab` 里的挂载不选。重启后目录不存在，Docker 会建一个空目录，于是 CA 私钥丢失，所有客户端 HTTPS 立刻失败。
- 只认块设备支撑的 `ext4`/`xfs`/`btrfs`，排除 `tmpfs`/`overlay`、`/snap/*`、`/var/lib/kubelet/*`、名字含 `backup`/`archive`/`swap`/`media` 的卷。
- 剩余空间低于门槛（默认 10 GiB）不选。
- 主机上已有 apt 缓存在跑时：**沿用它所在的那块盘，但换一个目录**。同一个缓存存储不能同时给两个守护进程用。
- 排完只剩 0 个候选 → 停下来问用户，不要退回系统盘。剩 ≥2 个 → 选剩余空间最大的，但把另一个也列出来让他一句话就能改。

**配置来源**

- 主机上已有调优过的 `config.toml` → 继承它（`plan.sh` 会自动找到）。
- 干净主机 → 用上游打包默认值。
- 两种情况都强制 `--enable-adoption`。上游默认 `[adoption] enabled = false`，照搬得到的是状态页 `KEYS 0`、快照永不采纳的服务：起来了，但是废的。
- 配置只写新文件（`config.container.toml`），**永不覆盖现有 `config.toml`**。派生只改四处：`dir`、代理监听、管理监听、`keyring_dirs`；`retention`/`gc`/`adoption`/`mitm`/`freshness` 原样继承。

**端口与是否接管**

- 默认并行试点：代理 `127.0.0.1:16790`、管理 `127.0.0.1:16789`。
- 生产端口 `3142`/`6789` 只有在用户明确同意、且传了 `--allow-takeover` 时才允许占用。

**必须停下来问用户的五种情形**

1. 数据盘候选为 0。
2. 多个候选且含义不同（例如一块是数据盘、一块是备份卷）。
3. 选中的盘同时是镜像 registry 存 blob 的盘（共享容量，互相挤）。
4. 要换缓存目录，而旧目录里有 CA：迁 `ca/`（客户端无感）还是接受新 CA（所有客户端要重新信任）——这个决定不属于你。
5. 要占用生产端口或停掉现有实例。

计划报告必须让用户一眼能复核：选定哪块盘、为什么、排除了哪些以及为什么、配置从哪来、改了哪几处、用哪些端口、有哪几项要他确认。

## 3. 部署

```bash
scripts/deploy.sh --mode poc [--image <ref>] [--cache-dir <dir>] [--config <toml>]
scripts/deploy.sh --mode prod --allow-takeover      # 只有用户同意接管才用
```

`--image` 优先给 digest 引用（`<registry>/<project>@sha256:...`），不要只给 `latest`：换基础镜像时 `latest` 会移动，digest 才是可回滚的引用。

`deploy.sh` 依次做：准备缓存目录（`113:112`、`0750`；目录非空时拒绝改属主）→ 起容器（host 网络、只读根文件系统、`cap_drop ALL`、三个 keyring 目录只读挂载）→ 立刻调验证。

## 4. 验证是硬门禁

```bash
scripts/verify.sh --mode poc [--version 1.0.2] [--min-keys 9]
```

退出码就是工具仓库里 `smoke-test.sh` 的退出码。**十项全过才算部署成功**，包括：healthz、密钥环数量、至少一把密钥来自挂载的宿主 keyring、回源取索引、第二次请求 `outcome=hit`、真实 `apt-get download` 取到一个 `.deb`、MITM HTTPS 用本容器 CA 验证通过、管理端口只在 loopback、二进制版本与预期一致、缓存数据库非空。

任一项失败就停在第 4 节，不要把"服务起来了"当成结果汇报给用户。失败判读见 `references/pitfalls.md`。

## 5. 客户端接入

模板在 `assets/apt-proxy.conf`。唯一正确姿势是**源保持真实主机名，代理指过去**：

```bash
Acquire::http::Proxy "http://<cache-host>:3142";
```

绝不要把 apt 源直接写成缓存地址。那样 apt 发的是 origin-form 请求（`GET /ubuntu/...` 配 `Host: <cache>`），守护进程无法从 `Host` 反推上游，实测返回 `400 Bad Request`，日志里是 `outcome=bad`。

启用 MITM（HTTPS 源也走缓存）时，客户端必须信任缓存的 CA，否则 `cli.github.com`、`prod-cdn.packages.k8s.io` 这类源会报 `The certificate issuer is unknown`。CA 在 `<cache.dir>/ca`，指纹用容器命令打印，不要凭记忆写。

## 6. 升级与回滚

升级：拉新 digest → `verify.sh` 通过 → 才动 tag 引用。回滚：

```bash
scripts/rollback.sh --digest sha256:<旧 digest> --mode poc
```

回滚后**必须重新跑 verify**。只比 digest，不比 tag 名；`<ver>-b<run>` 是不可变引用，`latest` 不是。基础镜像重建会保持同一版本号但换 digest，这是设计如此。

## 7. 镜像同步到内网 registry

GitHub 托管的 runner 到不了内网地址，所以流水线只发到 GHCR，由内网那台机器自己搬进 Harbor 这类 registry。

```bash
scripts/mirror-sync.sh --env-file <path> [--tags "latest 1.0.2"]
```

只允许 `--env-file`，不接受命令行传密码——命令行凭据会留在 shell history 和 `ps` 里。env 文件里放 registry 地址、项目、机器账号凭据、要同步的 tag。模板是 `assets/sync.env.example`，真实凭据文件权限 `600`、属 root。

明文 HTTP 的 registry 读不到 digest 的坑见 `references/registry-flows.md`：`docker buildx imagetools inspect` 没有 `--insecure`，只能走 registry v2 API 的 `Docker-Content-Digest` 头。

## 8. 上游发新版时

本 skill 只做预演和报告，**不代替 Actions 打 tag**：

```bash
ci-rehearsal.sh [version]      # 工具仓库里的那个，路径来自 locate.sh
```

它把构建与十项门槛在本地重放一遍，退出码即门槛结果。通过后再由仓库的 Actions 决定发布。判断有没有新版：工具仓库里的 `watch-upstream.sh`。

## 9. 常见症状先查哪里

| 症状 | 先看 |
|---|---|
| 容器直接退出，日志 `cache.dir ... not writable` | 缓存目录属主必须是 `113:112` |
| 状态页 `KEYS 0`、快照永不采纳 | 配置里 `adoption.enabled = false`，需要 `--enable-adoption` |
| `apt-get update` 对缓存地址报 400，日志 `outcome=bad` | 源写成了缓存主机，见第 5 节 |
| HTTPS 源报 `The certificate issuer is unknown` | 客户端没信任缓存 CA |
| 密钥环数量对不上主机 | keyring 目录要**既 bind-mount 又写进 `keyring_dirs`** |
| 命中率长期为 0 | `references/pitfalls.md` 的判读顺序 |
| 系统盘被写满 | 缓存目录跑到了系统盘，回到第 2 节 |

完整清单与更多实测坑在 `references/pitfalls.md`；部署细节 `references/deploy-steps.md`；registry 与 digest 流程 `references/registry-flows.md`。按需读，不要一次全读进来。

## 10. 边界

- 不停止或切换现有生产 apt 缓存实例，除非用户明确要求并给出 `--allow-takeover`。
- 不改 `gc.url_path_ttl`、不放宽管理端口的鉴权，除非用户要求。
- 不打印、不落盘、不提交任何 registry 凭据。
- 不在 skill 文件或产出里写内网 IP、主机名、机器特有路径；这些一律来自 env 或命令行参数。
- 不在 skill 里复制 compose 或冒烟测试的实现。

## 资源

- `scripts/locate.sh` `scripts/plan.sh` `scripts/deploy.sh` `scripts/verify.sh` `scripts/rollback.sh` `scripts/mirror-sync.sh`：薄封装，都可直接执行、都可用 `--help`。
- `references/deploy-steps.md`：首次部署、keyring 挂载、CA 继承与客户端信任。
- `references/pitfalls.md`：实测踩过的坑与判读顺序。
- `references/registry-flows.md`：GHCR → 内网 registry → 按 digest 部署，以及 digest 读取方法。
- `assets/apt-proxy.conf`：客户端 apt 代理配置片段。
- `assets/sync.env.example`：registry 同步配置模板，不含真实凭据。
