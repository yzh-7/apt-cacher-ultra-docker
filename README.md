# apt-cacher-ultra 容器镜像与自动跟踪流水线

上游 [linsomniac/apt-cacher-ultra](https://github.com/linsomniac/apt-cacher-ultra) 提供 `.deb`、systemd unit 和一个静态 Go 二进制，**不提供生产容器镜像**。本仓库补上容器化交付：

- `Dockerfile`：上游官方二进制 + `ca-certificates`，非 root 运行，只读根文件系统可跑
- `watch-upstream.yml`：定时发现上游新版本 → 自动打 tag
- `build.yml`：下载并**按上游 SHA256SUMS 校验**二进制 → 构建 → **冒烟测试通过才发布** → 推 GHCR 打版本 tag 与 `latest`
- `rebuild-base.yml`：基础镜像（含 ca-certificates）变化时每周重建 `latest`
- `deploy/`：面向真实机器的 compose、配置派生脚本、缓存目录准备脚本、GHCR→Harbor 内网同步脚本
- `docs/`：部署手册、运维手册、流水线说明

上游自己在 e2e 测试里就是用容器跑这个 daemon 的（该仓库的 `e2e/Dockerfile.cache`），本仓库沿用了同样的形态。

## 已验证到什么程度

2026-10-30 在目标机 `172.31.0.3`（Ubuntu 24.04，Docker 29.6）上把每一步真实跑过一遍：

| 步骤 | 结果 |
|---|---|
| `fetch-upstream.sh 1.0.2` | sha256 `085a0dff…b5343`，与上游 `SHA256SUMS` 一致 |
| `make-container-config.sh` | 只改 4 处（+ `--enable-adoption` 时 5 处），diff 可审阅 |
| `prepare.sh` | 缓存目录建成 `113:112`，三个 keyring 目录检查通过 |
| `docker build -f Dockerfile` | 成功，compact 体积 17.7 MB（`docker images` 显示 36.9 MB） |
| `docker build -f Dockerfile.source` | 成功，产物 `-version` 报 `1.0.2`（不是 `dev`） |
| 推 Harbor → 从 Harbor 拉回 | `172.31.0.3:7777/infrastructure/apt-cacher-ultra:1.0.2`，digest `55e0d47d…` |
| `compose.poc.yaml` 起服务 | 镜像只从 Harbor 拉（本地同名镜像已删），healthy，与 systemd 实例并存不打架 |
| `scripts/smoke-test.sh` | **10/10 PASS**：healthz、30 把密钥环、其中 21 把来自挂载的宿主 keyring、真实上游取包 1.4 MB、第二次 `outcome=hit`、`apt-get download` 成功、MITM HTTPS 用容器自身 CA 验证通过、admin 只在 loopback、二进制版本一致、缓存数据库非空 |
| 根盘影响 | `df -h /` 前后都是 609G/73%，缓存 2.0 MB 全在 `/data/harbor` |
| `acu-sync.timer` | 安装并 enabled，手动触发一次 service 退出码 0，日志正常 |
| `scripts/ci-rehearsal.sh` | 在目标机完整预演 CI 的构建+门槛：**exit 0，10/10 PASS**（缓存命中 3 ms 对比回源 8238 ms） |
| Actions 首次运行（tag push `v1.0.2`） | [run #1](https://github.com/yzh-7/apt-cacher-ultra-docker/actions/runs/41161108441) 22/22 步 success，CI 内冒烟同样 10 PASS |
| GHCR 包 | `ghcr.io/yzh-7/apt-cacher-ultra` 的 `1.0.2` / `latest` / `1.0.2-b9`，digest `sha256:e9fb53a2…`，**可匿名拉取** |
| Harbor 镜像 | `172.31.0.3:7777/infrastructure/apt-cacher-ultra` 两个 tag 的 digest 与 GHCR 完全一致 |
| 用 Harbor 里的 CI 产物再起一次服务 | `prepare.sh` + `compose.poc.yaml` + 冒烟 10 PASS；两轮真实 `apt-get update` 后 `hit 5 / miss 7` |
| `watch-upstream.yml` 手动触发 | 判定 `v1.0.2 already exists` → `action=skip`，不重复建 tag |
| `rebuild-base.yml` 手动触发（修好之后） | `newest` success、`rebuild` **skipped**（基础镜像没动就不重建） |
| Dependabot | 自行开出 6 个 PR（5 个 actions + alpine 3.20→3.24），每个 PR 的 `build.yml` 都是绿的，已全部合并 |
| skill 的四个脚本（`locate`/`plan`/`deploy`/`rollback`） | 在目标机上跑完整流程：计划 → `--apply` → 按 digest 部署 → 冒烟 **10 PASS** → 回滚再验证 **10 PASS**；`review-skill` 机械校验 **PASS（阻断 0 · 建议 0 · 提示 0）** |

尚未完成的只有 GitHub 侧：仓库还没建（等 PAT），所以 Actions 首次绿与 GHCR 推镜像还没发生。

## 5 分钟上手（已有镜像的机器）

```bash
git clone https://github.com/yzh-7/apt-cacher-ultra-docker.git
cd apt-cacher-ultra-docker/deploy

# 1) 缓存目录（必须是数据盘）+ 容器配置 + keyring 检查，一次做完
sudo ACU_OUT_CONFIG=/etc/apt-cacher-ultra/config.container.toml \
     ../deploy/prepare.sh /data/harbor/apt-cacher-ultra /etc/apt-cacher-ultra/config.toml prod

# 2) 起服务
cp .env.example .env && $EDITOR .env
docker compose up -d

# 3) 验证
../scripts/smoke-test.sh --admin http://127.0.0.1:6789 --proxy http://127.0.0.1:3142 \
    --container apt-cacher-ultra --min-keys 9 --allow-open-admin
```

完整步骤、客户端配置、CA 安装、升级回滚、故障排查见 **[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md)**；日常运维（备份、容量、指标、内网 Harbor 同步）见 **[docs/OPERATIONS.md](docs/OPERATIONS.md)**；自动跟踪与 secrets 配置见 **[docs/TRACKING.md](docs/TRACKING.md)**。

## 镜像

| 位置 | 名字 |
|---|---|
| GHCR（流水线发布处） | `ghcr.io/yzh-7/apt-cacher-ultra:<版本>` 与 `:latest` |
| 内网 Harbor（由服务器同步） | `172.31.0.3:7777/infrastructure/apt-cacher-ultra:<版本>` |

版本 tag 永不移动（可复现）；`latest` 会随新版本或每周基础镜像重建前移。

## 仓库结构

```
Dockerfile                  生产镜像：官方二进制 + ca-certificates，uid 113:112
Dockerfile.source           上游没发预编译二进制时的手工回退（源码构建）
scripts/
  fetch-upstream.sh         取上游 release 二进制，按 SHA256SUMS 校验
  watch-upstream.sh         发现新版本 / 判断是否已构建（供 Actions 调用）
  newest-tag.sh             本仓库最新的 v* tag
  resolve-version.sh        CI 用哪个版本、是否发布的唯一判定处（可本地跑）
  ci-rehearsal.sh           在任意有 Docker 的机器上预演 CI 的构建与发布门槛
  metrics-snapshot.sh       把值得盯的指标一次读出来（含 MITM CA 到期时间）
  smoke-test.sh             10 项部署验证（CI 发布前的门槛）
deploy/
  compose.yaml              生产形态 compose（host 网络、只读根、cap_drop ALL）
  compose.poc.yaml          并行试点形态（16790/16789，不动现有服务）
  prepare.sh                缓存目录权限、配置派生、keyring 目录检查
  make-container-config.sh  从宿主 config.toml 派生容器配置（含 --enable-adoption）
  harbor-sync.sh            GHCR → 内网 Harbor 镜像同步（按 digest 幂等）
  .env.example              compose 变量
  harbor-sync.env.example   同步所需凭据样例（真文件不进 git）
  acu-sync.service/.timer   每小时同步一次的 systemd 单元
docs/
  DEPLOYMENT.md             部署手册
  OPERATIONS.md             运维手册
  TRACKING.md               流水线与 secrets
.github/workflows/
  watch-upstream.yml        定时轮询上游 → 打 tag
  build.yml                 构建 + 冒烟 + 发布（可被复用调用）
  rebuild-base.yml          基础镜像变化时每周重建
.github/dependabot.yml      基础镜像与 Actions 版本升级
.qoder/skills/apt-cacher-ultra-docker/
  SKILL.md                  给 agent 的流程与判断规则
  scripts/                  locate / plan / deploy / verify / rollback / mirror-sync
  references/               部署细节、实测坑、registry 流程
  assets/                   apt 代理配置片段、同步 env 模板
```

## 给 agent 用的 skill

仓库自带一个 skill：`.qoder/skills/apt-cacher-ultra-docker/`。它不重复实现部署逻辑，只负责**判断**和**编排**，实际动作调本仓库已验证的脚本。

```bash
ln -s "$PWD/.qoder/skills/apt-cacher-ultra-docker" ~/.dsh/skills/apt-cacher-ultra-docker   # 本机可用
cp -r .qoder/skills/apt-cacher-ultra-docker <别的项目>/.qoder/skills/                      # 跟着项目走
```

四个脚本，默认都是先判断再动手：

| 脚本 | 作用 |
|---|---|
| `locate.sh` | 找到仓库 checkout（`ACU_REPO` → 常见路径 → 克隆） |
| `plan.sh` | **决定缓存放哪块盘、继承哪份配置、能不能占端口**，打印全部理由；dry-run 默认，`--apply` 才落盘 |
| `deploy.sh` | 按 digest 起服务，紧接着跑冒烟门禁；缺 `--cache-dir/--config` 会拒绝并先打印计划 |
| `verify.sh` | 十项门禁 + 指标快照，退出码即门禁结果 |
| `rollback.sh` | 按 digest 回滚（cache/config 从运行中的容器反查），回滚后强制重新验证 |
| `mirror-sync.sh` | 外部 registry → 内网 registry，凭据只从 `--env-file` 读 |

`plan.sh` 的存储判定是硬规则：不选系统盘、不选不在 `/etc/fstab` 里的挂载、不选备份卷、低于容量门槛不选；已有缓存在跑时沿用它所在的盘但换目录。判断不出来的时候它**拒绝动手**并提问，而不是猜一个。在这台机器上的实际输出：

```
选定 /data/harbor/apt-cacher-ultra-container （盘 /data/harbor，剩余约 10534G）
排除 /：系统盘（已用 73%）
排除 /mnt/data1：不在 /etc/fstab 里，重启后可能不存在（缓存目录会变空，CA 会丢）
排除 /mnt/backup：卷名表明它是备份/归档/交换用途
ASK - 选中的 /data/harbor 同时是镜像 registry 存数据的盘，会互相挤容量。接受，还是换一块盘？
```

## 必须知道的三件事

1. **缓存目录里的 `ca/` 就是客户端已信任的 MITM CA。** 换目录或删缓存 = 生成新 CA = 所有已装 CA 的客户端立即报错。见 DEPLOYMENT.md 的 CA 一节。
2. **签名密钥必须挂载。** 容器里没有宿主的 `/usr/share/keyrings`，`[adoption] require_signature=true` 会全线失败。`prepare.sh` 会检查，`smoke-test.sh` 会验证"至少一把 key 来自 `/keyrings/`"。
3. **上游打包默认配置里 `[adoption] enabled = false`。** 照默认跑等于不加载任何密钥、不做快照 adoption——和调优过的宿主实例是两种服务。要 adoption 就 `prepare.sh`/`make-container-config.sh` 加 `--enable-adoption`（或 `ACU_ENABLE_ADOPTION=1`）。

## 许可

上游 apt-cacher-ultra 是 CC0-1.0。本仓库的打包脚本、流水线与文档采用 MIT（见 `LICENSE`）。
