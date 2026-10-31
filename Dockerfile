# apt-cacher-ultra container image.
#
# Upstream (https://github.com/linsomniac/apt-cacher-ultra) ships a .deb, a
# systemd unit and a standalone static Go binary — no production container
# image. It does run this same daemon in a container for its own e2e suite
# (e2e/Dockerfile.cache in that repo), which is the pattern this file follows.
#
# Nothing here needs a toolchain: the release asset is a statically linked,
# CGO-disabled Linux/amd64 binary (SQLite via modernc.org/sqlite, OpenPGP via
# ProtonMail/go-crypto), so there is no glibc, no gnupg and no shell tooling to
# carry. ca-certificates is the only runtime dependency — Go's crypto/x509 reads
# /etc/ssl/certs/ca-certificates.crt to verify upstream repositories.
#
# The binary must be present in the build context; scripts/fetch-upstream.sh
# downloads it and verifies it against upstream's SHA256SUMS asset.

ARG BASE_IMAGE=alpine:3.24
FROM ${BASE_IMAGE}

# Re-declared after FROM: an ARG declared before FROM is not in scope in the
# build stage, and the labels below reference it.
ARG BASE_IMAGE
ARG ACU_VERSION=unknown
ARG BUILD_DATE=unknown
ARG VCS_REF=unknown
ARG BASE_IMAGE_RESOLVED=unknown

LABEL org.opencontainers.image.title="apt-cacher-ultra" \
      org.opencontainers.image.description="Robust apt repository cache (upstream binary, containerized)" \
      org.opencontainers.image.version="${ACU_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.source="https://github.com/linsomniac/apt-cacher-ultra" \
      org.opencontainers.image.documentation="https://github.com/linsomniac/apt-cacher-ultra/blob/main/docs/configuration.md" \
      org.opencontainers.image.licenses="CC0-1.0" \
      io.aptcacherultra.docker.base-image="${BASE_IMAGE}" \
      io.aptcacherultra.docker.base-image-digest="${BASE_IMAGE_RESOLVED}"

RUN apk add --no-cache ca-certificates

# uid/gid 113:112 match the user the upstream .deb creates. Keeping the same
# numeric identity means an existing cache directory (including the MITM CA under
# <dir>/ca) does not have to be chowned when moving between the .deb and the
# container. If your host uses a different uid, override with `user:` in compose
# and chown the cache directory to match.
RUN addgroup -g 112 -S acu \
 && adduser -u 113 -G acu -S -D -H \
      -u 113 -h /var/lib/apt-cacher-ultra -s /sbin/nologin acu

COPY apt-cacher-ultra /usr/local/bin/apt-cacher-ultra
RUN chmod 0755 /usr/local/bin/apt-cacher-ultra \
 && mkdir -p /etc/apt-cacher-ultra /var/lib/apt-cacher-ultra \
 && chown -R 113:112 /var/lib/apt-cacher-ultra \
 # Fail the build rather than ship a binary that does not run on this base.
 && /usr/local/bin/apt-cacher-ultra --version

USER 113:112

# The cache directory must be a writable volume: it holds the SQLite database,
# the blob pool, and the MITM CA that clients already trust. Never let it land
# on a small root filesystem.
VOLUME ["/var/lib/apt-cacher-ultra"]
EXPOSE 3142 6789

# alpine ships busybox wget, so the health check adds no packages.
# The daemon has no health subcommand (only -config, -print-apt-conf, -version),
# so this probes the admin listener's /healthz: it requires [admin] enabled=true
# and the same port this image was configured with. Deployments that disable the
# admin listener or move it off 6789 must override healthcheck in compose — the
# example compose files here do exactly that.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD wget -qO- http://127.0.0.1:6789/healthz >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/usr/local/bin/apt-cacher-ultra", "-config", "/etc/apt-cacher-ultra/config.toml"]
