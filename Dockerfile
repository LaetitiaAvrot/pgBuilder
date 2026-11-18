# syntax=docker/dockerfile:1
#
# PostgreSQL from a local checkout, built with meson on Debian trixie.
# Use compose.yaml rather than calling docker build directly, see README.md.
#
# Targets:
#   dev      hacking environment, source bind mounted, build in a volume
#   runtime  slim image with the binaries built from the checkout

ARG DEBIAN_VERSION=trixie

# ---------------------------------------------------------------------------
# Shared build dependencies
# ---------------------------------------------------------------------------
FROM debian:${DEBIAN_VERSION}-slim AS builddeps

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential meson ninja-build pkg-config bison flex ccache \
      perl python3 gettext \
      libreadline-dev zlib1g-dev libssl-dev libicu-dev \
      libxml2-dev libxslt1-dev libzstd-dev liblz4-dev uuid-dev \
      libperl-dev python3-dev \
    && rm -rf /var/lib/apt/lists/*

# Feature set shared by both targets. Extra options go in PG_MESON_ARGS.
ENV LANG=C.UTF-8 \
    PG_MESON_FEATURES="-Dssl=openssl -Dicu=enabled -Dlz4=enabled \
-Dzstd=enabled -Dlibxml=enabled -Dlibxslt=enabled -Duuid=e2fs \
-Dreadline=enabled -Dzlib=enabled -Dnls=enabled -Dplperl=enabled \
-Dplpython=enabled"

# ---------------------------------------------------------------------------
# Dev target
# Source is bind mounted read-write at /src. Build tree and install live in
# the /work volume, ccache in its own volume, so both survive restarts.
# ---------------------------------------------------------------------------
FROM builddeps AS dev

RUN apt-get update && apt-get install -y --no-install-recommends \
      git gdb valgrind vim less \
      libipc-run-perl \
      xsltproc libxml2-utils docbook-xml docbook-xsl \
    && rm -rf /var/lib/apt/lists/* \
 && useradd -m -u 1000 dev \
 && mkdir -p /work /home/dev/.ccache \
 && chown dev:dev /work /home/dev/.ccache

ENV PGSRC=/src \
    PGBUILD=/work/build \
    PGINSTALL=/work/install \
    CCACHE_DIR=/home/dev/.ccache \
    PATH=/work/install/bin:$PATH

# Postgres refuses to run as root
USER dev
WORKDIR /work
CMD ["bash"]

# ---------------------------------------------------------------------------
# Build stage for the runtime image
# The checkout is bind mounted from the "pgsrc" named context instead of
# copied, so .git never ends up in a layer. Writes to it are discarded.
# The build tree and ccache persist across builds in BuildKit cache mounts,
# so ninja only recompiles and relinks what changed.
# ---------------------------------------------------------------------------
FROM builddeps AS build

ARG PG_MESON_ARGS=""
ENV CCACHE_DIR=/ccache

RUN --mount=type=bind,from=pgsrc,target=/src,rw \
    --mount=type=cache,target=/ccache \
    --mount=type=cache,target=/build \
    if [ -f /src/src/include/pg_config.h ]; then \
      make -C /src distclean >/dev/null; \
    fi \
 && mode= \
 && if [ -f /build/meson-private/coredata.dat ]; then mode=--reconfigure; fi \
 && meson setup $mode /build /src \
      --prefix=/usr/local/pgsql \
      ${PG_MESON_FEATURES} \
      ${PG_MESON_ARGS} \
 && ninja -C /build \
 && DESTDIR=/out meson install -C /build --no-rebuild --quiet

# List the Debian packages providing the shared libraries the build links
# against, so the runtime stage needs no version-specific package names.
RUN find /out -type f \( -name '*.so*' -o -perm -u+x \) -print0 \
    | xargs -0 ldd 2>/dev/null \
    | awk '$2 == "=>" && $3 ~ /^\// { print $3 }' \
    | sort -u \
    | xargs -r realpath \
    | sort -u \
    | while read -r lib; do \
        dpkg -S "$lib" 2>/dev/null || dpkg -S "${lib#/usr}" 2>/dev/null; \
      done \
    | cut -d: -f1 \
    | sort -u > /out/runtime-packages \
 && test -s /out/runtime-packages

# ---------------------------------------------------------------------------
# Runtime target
# ---------------------------------------------------------------------------
FROM debian:${DEBIAN_VERSION}-slim AS runtime

COPY --from=build /out/runtime-packages /tmp/runtime-packages

RUN apt-get update \
 && xargs -a /tmp/runtime-packages \
      apt-get install -y --no-install-recommends gosu ca-certificates \
 && rm -rf /var/lib/apt/lists/* /tmp/runtime-packages \
 && groupadd -r postgres --gid=999 \
 && useradd -r -g postgres --uid=999 -d /var/lib/postgresql -m postgres

COPY --from=build /out/usr/local/pgsql /usr/local/pgsql
COPY --chmod=755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

ENV LANG=C.UTF-8 \
    PATH=/usr/local/pgsql/bin:$PATH \
    PGDATA=/var/lib/postgresql/data \
    PGUSER=postgres \
    PGDATABASE=postgres

VOLUME /var/lib/postgresql/data

# SIGINT is a fast shutdown. SIGTERM would wait for clients to disconnect.
STOPSIGNAL SIGINT

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["postgres"]
