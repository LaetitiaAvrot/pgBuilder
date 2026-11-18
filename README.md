# pgBuilder

Hack on PostgreSQL in a container: build your local checkout with meson on
Debian trixie, run the tests, debug with gdb, and get a slim runtime image of
your build.

> **For development only.** The runtime image uses `trust` authentication:
> no password, superuser access for anyone who can connect. It only listens
> on localhost inside the container, but never expose it or use it for real
> data.

## Quick start

You need Docker with Compose and a PostgreSQL checkout. By default it is
looked for in `../postgresql`.

```sh
make src        # clone PostgreSQL into ../postgresql if it is not there
make build      # configure, compile and install a debug build
make tmp        # psql on a throwaway cluster running your build
```

Already have a checkout elsewhere? Skip `make src` and pass its location:
`make build PGSRC=$HOME/src/postgresql`. See [Settings](#settings) to keep it
in `config.mk`.

## Most useful commands

Run `make` to list every command.

| Command | What it does |
| --- | --- |
| `make src` | Clone PostgreSQL into `PGSRC` if it is missing. |
| `make build` | Compile and install your changes. Configures the first time. |
| `make test` | Run all tests, regression and TAP. |
| `make test TEST_ARGS="--suite regress"` | Run only some tests, much faster. |
| `make tmp` | Throwaway cluster on your build, deleted when psql exits. |
| `make shell` | Shell in the dev container, for gdb, meson or git. |
| `make up` | Build the runtime image from your checkout and start it. |
| `make psql` | psql in the runtime container. |
| `make reset` | Remove the runtime container and its data. |
| `make clean` | Remove all containers, volumes and images. |

A typical loop: edit on the host, `make build`, try it with `make tmp`, then
`make test` before sending a patch.

## Settings

| Variable | Default | Meaning |
| --- | --- | --- |
| `PGSRC` | `../postgresql` | PostgreSQL checkout. Nothing is written to it, except by `make src` when it clones. |
| `PG_REPO` | `https://git.postgresql.org/git/postgresql.git` | Where `make src` clones from. |
| `PG_CLONE_ARGS` | `--filter=blob:none` | Extra `git clone` options for `make src`, for example `--depth 1`. |
| `PG_USER` | `postgres` | Runtime superuser. |
| `PG_DATABASE` | same as `PG_USER` | Runtime database, created on first start. |
| `PG_MESON_ARGS` | | Extra meson options, for example `-Dllvm=enabled`. |
| `TEST_ARGS` | | Arguments for `meson test`. |

Set them on the command line (`make build PGSRC=$HOME/src/postgresql`), or keep
them in `config.mk`, which is not committed:

```sh
cp config.mk.example config.mk
```

`PG_USER` and `PG_DATABASE` are only used when the runtime data volume is
created. Run `make reset` after changing them.

## How it works

One `Dockerfile` with two targets, driven by `compose.yaml` and the
`Makefile`.

### Dev

- The checkout is bind mounted at `/src`.
- The build tree, install and ccache live in named volumes, so builds stay
  incremental across sessions, and macOS bind mount slowness only affects
  reading the source.
- The build is `--buildtype=debug` with assertions and TAP tests.
- Everything runs as the `dev` user, because Postgres refuses to run as
  root. gdb can attach to backends (`SYS_PTRACE` is enabled).
- `$PGINSTALL/bin` is on the `PATH` inside the container.

Meson refuses a checkout that contains an in-tree autoconf build. Run
`make distclean` in the checkout if needed.

### Runtime

- The checkout is bind mounted into the build, never copied, so `.git` does
  not end up in an image layer.
- ccache persists between builds in a BuildKit cache mount, so rebuilds
  after a change are fast.
- The final image only contains the installed binaries and the Debian
  packages they link against, detected automatically.
- On first start, the entrypoint creates `PG_USER` as superuser without
  password and `PG_DATABASE`, with `trust` on the local socket and loopback
  only, and listens on `localhost` only. Connect with `make psql`:
  publishing the port would not work.
- `docker stop` uses `SIGINT`, a fast shutdown.

For a debug runtime build:

```sh
make up PG_MESON_ARGS="-Dcassert=true --buildtype=debug"
```

## Features

Enabled in both targets: OpenSSL, ICU, LZ4, zstd, libxml, libxslt, uuid
(e2fs), readline, zlib, NLS, PL/Perl and PL/Python. The list is
`PG_MESON_FEATURES` in the `Dockerfile`.

Not enabled: LLVM (JIT), LDAP, Kerberos, SELinux. To add one, add its `-dev`
package to the `builddeps` stage and its meson option to `PG_MESON_ARGS`.
The runtime stage picks up the new libraries by itself.

If a newer PostgreSQL needs a new dependency, `meson setup` will say which
one. Add the matching `-dev` package to `builddeps`.

## Files

| File | Purpose |
| --- | --- |
| `Makefile` | The commands above. |
| `compose.yaml` | The `dev` and `runtime` services and their volumes. |
| `Dockerfile` | `builddeps`, `dev`, `build` and `runtime` stages. |
| `docker-entrypoint.sh` | First-start setup for the runtime image. |
| `config.mk.example` | Template for your personal settings. |

## License

[PostgreSQL License](LICENSE).
