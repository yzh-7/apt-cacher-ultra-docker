# 自动跟踪上游与发布流水线

## 整体流程

```
                ┌────────────────────────────── GitHub Actions（GitHub 托管 runner）──────────────────────────────┐
                │                                                                                              │
 cron 17 */4    │  watch-upstream.yml                     tag v<新版本>                                       │
 ───────────────▶  watch-upstream.sh ── 上游有新版且本仓库没有对应 tag ──▶ git tag -a v1.1.0 ── push ──┐     │
                │      （blocked 状态直接让 job 失败并说明缺哪个资产）                                    │     │
                └────────────────────────────────────────────────────────────────────────────────────┘     │
                                                                                     push tag v1.1.0 ◀─────┘
                                                                                            │
                                                                                            ▼
                build.yml（同一个 workflow，也可被复用调用）
                  1. scripts/fetch-upstream.sh 1.1.0 dist
                     - 只接受非 draft、非 prerelease 的 release
                     - 必须存在 linux-amd64 资产与 SHA256SUMS，否则退出非 0
                     - 用上游 SHA256SUMS 校验二进制（校验失败 = 构建失败）
                  2. 取该 tag 的 packaging/config/config.toml.default，用
                     deploy/make-container-config.sh 派生出 CI 用的容器配置
                  3. docker build（context=dist，只有已校验的二进制进入镜像）
                  4. docker run（host 网络 + read_only + cap_drop ALL + 只读 keyring 挂载）
                  5. scripts/smoke-test.sh —— 10 项验证，任何一项 FAIL 都不发布
                  6. 通过后才 push GHCR：:<version>、:latest、:<version>-b<run>
                  7. 建 GitHub Release 说明（含上游二进制 sha256、镜像 digest）
                └──────────────────────────────────────────────────────────────────────────────────
                                                                                            │
                                                                                            ▼
                服务器 acu-sync.timer（每小时）→ deploy/harbor-sync.sh → 172.31.0.3:7777/infrastructure/apt-cacher-ultra
```

## 为什么是这个形状

**为什么用 cron 轮询而不是 webhook。** GitHub 无法主动通知一台私有网络里的机器"上游发新版了"，而本仓库也不是上游仓库的一部分（不能往别人仓库加 Action）。所以由本仓库定时查上游 release API，把"发现新版本"变成"在本仓库打一个 tag"。tag 一出现就触发构建，这比让 build.yml 自己判断"有没有新版"更干净：**tag 就是构建意图的记录**，也是回滚与复现的锚点。

**为什么 tag 用 `v` 前缀而镜像 tag 不带。** 上游的 release 名字是 `1.0.2`，本仓库的 git tag 是 `v1.0.2`，镜像 tag 又是 `1.0.2`。这样在 git 里一眼能看出这是版本 tag，在 `docker images` 里一眼能和上游版本对上。

**为什么二进制必须校验。** 流水线把上游二进制直接放进镜像。没有 `SHA256SUMS` 校验，一次 CDN 故障或资产被替换都会静默进入生产缓存。校验失败让构建失败，而不是产生一个"可能有问题"的镜像。

**为什么冒烟测试是发布门槛。** 光构建成功没有任何价值：真正会让部署崩掉的是配置格式变了（上游改了 TOML 设置名）、密钥环挂载方式失效（`require_signature` 全线失败）、MITM CA 不被信任（客户端 `certificate issuer is unknown`）、缓存目录权限（uid 113 写不进去）。这四项都在冒烟测试里，每一项都在真实容器、真实上游、真实 apt 客户端上跑。CI 用 `--enable-adoption` 生成配置，否则测不到验签路径（上游默认 `enabled = false`）。

**为什么 GHCR 而不是直接推 Harbor。** Actions 的托管 runner 到不了 `172.31.0.3`。可选方案是自建 runner（在这台服务器上跑 runner，构建直接推 Harbor），代价是把 GitHub 的 CI 执行面搬进内网、并在生产机上装 runner。目前选择是 GHCR 作为发布处 + 服务器每小时向 Harbor 镜像一份。想换自建 runner，见文末。

## 需要配置的 secrets / 权限

仓库 Settings → Secrets and variables → Actions：

| Secret | 用途 | 需要吗 |
|---|---|---|
| — | 构建与推 GHCR 用内置 `GITHUB_TOKEN`（`packages: write`），无需 secret | — |
| `HARBOR_USER` / `HARBOR_PASSWORD` | 只在服务器上的 `harbor-sync.env` 里，不进 Actions | 服务器侧需要 |
| `GHCR_USER` / `GHCR_TOKEN` | 服务器拉 GHCR；**仓库公开时不需要** | 私有才需要 |

仓库 Settings → Actions → General → Workflow permissions 保持 **Read repository contents and packages permissions** 即可（`watch-upstream.yml` 里推 tag 需要 `contents: write`；如果全局设为 read-only，则该 workflow 顶部的 `permissions: contents: write` 会被 GitHub 覆盖成只读并失败）。

首次建议手工确认：`workflow_dispatch` 跑一次 `build.yml`（`version=1.0.2`、`publish=true`），看 GHCR 出现 `ghcr.io/<owner>/apt-cacher-ultra:1.0.2`，再 `workflow_dispatch` 跑 `watch-upstream.yml` 确认输出 `action=skip`。

## 上游发新版之后会发生什么

1. 最迟 4 小时内，`watch-upstream.yml` 打出 `v<新版本>` tag（commit 由 `github-actions[bot]` 提交，tag 是附注 tag，message 里带上游 release 链接）。
2. `build.yml` 因 tag 触发：校验 → 构建 → 冒烟 → 推 GHCR → 建 GitHub Release。
3. 服务器下一个小时的 `acu-sync.timer` 把新版本镜像搬进 Harbor。
4. **没有任何东西自动重启你的 apt 缓存服务。** 升级生产服务需要人为决定（DEPLOYMENT.md §8 是步骤）。

如果上游某次 release **没有** `linux-amd64` 资产或没有 `SHA256SUMS`，`watch-upstream.sh` 会输出 `action=blocked`，workflow 失败并说明缺什么；这时用 `Dockerfile.source` 手工构建（已在服务器上验证过：从上游 source tarball 构建，产物 `-version` 报 `1.0.2`）。

## 发布前在本地预演整条流水线

`scripts/ci-rehearsal.sh` 把 `build.yml` 那个 job 除"登录 GHCR / 写 Release 说明"之外的每一步原样跑一遍：解析版本 → 取二进制并按 `SHA256SUMS` 校验 → 从该 tag 的上游默认配置派生容器配置 → 构建 → 按部署形态起容器 → 跑发布门槛的冒烟测试。退出码就是冒烟测试的退出码。

```bash
./scripts/ci-rehearsal.sh                # 版本取上游最新稳定版
./scripts/ci-rehearsal.sh 1.1.0          # 指定版本
KEEP_REHEARSAL=1 ./scripts/ci-rehearsal.sh   # 保留 .rehearsal/ 与本地镜像便于排查
```

用途有三个：上游发了新版但还不想打 tag 时先确认能构建；CI 红了在本地复现；换一台机器时确认它的 Docker 能跑这套镜像。监听端口固定用 poc 的 16789/16790 且绑 loopback，所以在生产缓存机上跑也不会被外部访问、不会和 `:3142`/`:6789` 抢端口。

## 失败模式与查看位置

| 现象 | 在哪看 | 处理 |
|---|---|---|
| Actions 里 `watch` job 红 | run 日志末尾 `blocked: …` | 上游资产不全；走 `Dockerfile.source` |
| `build` job 在 fetch 步骤红 | 该步日志 | 上游改名了资产，或版本号写错 |
| 冒烟测试红 | `smoke-test.sh` 输出的哪一项 FAIL | 按 DEPLOYMENT.md §11 表处理；**不要**绕过门槛强行 publish |
| GHCR 推不上去 | `build-push-action` 步骤 | 检查 package 是否与仓库同名导致权限冲突；`IMAGE_NAME` 换个名字 |
| Harbor 同步失败 | 服务器 `journalctl -u acu-sync.service` | 机器人账号权限、`insecure-registries`、GHCR 限流 |
| 每周 `rebuild-base` 说 base unchanged 但你确实想重建 | run summary | `workflow_dispatch` 手动触发并填 `version` |

Actions 的 cron 在私有仓库上默认可能因"仓库不活跃"被暂停（GitHub 对不活跃私有仓库会禁用 schedule workflow）。这个仓库有 Dependabot 每周动作 + 每 4 小时的 watch 运行，正常不会触发；如果真被禁用，在 Settings → Actions 里重新开启即可。

## 备选：自建 runner（一条命令直推 Harbor）

如果希望构建产物直接进 Harbor（省掉 GHCR 这一跳），在服务器上装 self-hosted runner 并把 `build.yml` 的 `runs-on` 改为 `[self-hosted, linux, amd64]`，`login-action` 换成 `docker login 172.31.0.3:7777`。代价：GitHub 的 job 在内网机器上执行（需要出网装 runner 依赖）、runner 成为新的信任面、构建占用这台机器的资源。当前没选这条路，需要时改动集中在 `build.yml` 的 `runs-on` 与登录步骤。
