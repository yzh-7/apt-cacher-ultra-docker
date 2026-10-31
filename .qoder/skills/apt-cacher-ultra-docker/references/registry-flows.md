# registry 与 digest 流程

## 为什么要两跳

CI 跑在 GitHub 托管的 runner 上，它到不了内网地址。所以流水线只把镜像发到 GHCR，内网那台机器自己把镜像搬进 Harbor 之类的内网 registry，客户端和服务器都从内网拉。

```
GitHub Actions ──push──> ghcr.io/<owner>/apt-cacher-ultra
                              │  （内网机器每小时同步）
                              v
                    <内网 registry>/<project>/apt-cacher-ultra
                              │  （按 digest 固定拉取）
                              v
                          部署的那台机器
```

## 用哪个引用部署

| 引用 | 稳定性 | 用途 |
|---|---|---|
| `<registry>/<project>@sha256:...` | 不可变 | 正式部署、回滚 |
| `<ver>-b<run>` | 不可变（同一版本每次构建不同） | 审计某一次 CI 产物 |
| `<ver>` | 会被同版本的重建覆盖 | 人类读的版本标识 |
| `latest` | 每次发布都移动 | 试点，不要用于正式 |

换基础镜像时版本号不变、digest 变。所以"升级"和"回滚"都必须比 digest。

## 同步

```bash
scripts/mirror-sync.sh --env-file <path> [--tags "latest 1.0.2"]
```

配置模板 `assets/sync.env.example`。想让服务器不需要任何凭据，就把包保持公开；包改私有就必须填 `GHCR_USER`/`GHCR_TOKEN`（细粒度 PAT，只授 `read:packages`，最短有效期）。

定时器（仓库里 `deploy/acu-sync.service` + `deploy/acu-sync.timer`）在服务器上每小时跑一次同样的脚本，env 文件属 root、权限 `600`。

## 读 digest 的两种办法

明文 HTTP 的 registry：

```bash
curl -fsS -u "$USER:$PASS" -D - -o /dev/null \
  -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
  "http://<registry>/v2/<project>/<image>/manifests/<tag>" | tr -d '\r' |
  awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}'
```

HTTPS 的 registry：

```bash
docker buildx imagetools inspect <ref> --format '{{.Manifest.Digest}}'
```

读镜像里的 label（比如它当初用的是哪个基础镜像 digest）：

```bash
docker buildx imagetools inspect <ref> \
  --format '{{ index .Image.Config.Labels "io.aptcacherultra.docker.base-image-digest" }}'
```

`imagetools` 没有 `--insecure`，也没有 `.Config` 这个字段——两个都真实踩过。

## 包名与仓库名的关系

GHCR 的包名与同名仓库会被 GitHub 关联到同一个包上。若账号里已有一个叫 `apt-cacher-ultra` 的仓库，这个仓库的 `GITHUB_TOKEN` 可能无权写那个包，CI 会在推送那一步失败。仓库建好当天确认一次：包存在、可匿名 `manifests` 请求返回 200。
