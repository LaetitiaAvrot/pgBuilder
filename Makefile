# Shortcuts for the dev and runtime containers. Run "make" for the list.
#
# Variables:
#   PGSRC          postgres checkout, default ../postgresql
#   PG_REPO        where "make src" clones from
#   PG_CLONE_ARGS  extra git clone options, default a blobless partial clone
#   PG_USER       runtime superuser, default postgres
#   PG_DATABASE    runtime database, default PG_USER
#   PG_MESON_ARGS  extra meson options, for example "-Dllvm=enabled"
#   TEST_ARGS      arguments for meson test, for example "--suite regress"

# Personal settings, not committed. See config.mk.example.
-include config.mk

PGSRC ?= ../postgresql
override PGSRC := $(abspath $(PGSRC))
PG_REPO ?= https://git.postgresql.org/git/postgresql.git
PG_CLONE_ARGS ?= --filter=blob:none
PG_USER ?= postgres
PG_DATABASE ?= $(PG_USER)
PG_MESON_ARGS ?=
TEST_ARGS ?=
export PGSRC PG_USER PG_DATABASE PG_MESON_ARGS

COMPOSE := docker compose
DEV_RUN := $(COMPOSE) run --rm dev bash -c

# Debug build with assertions and TAP tests, reconfigures if already set up
DEV_SETUP := mode=; \
  [ -f "$$PGBUILD/meson-private/coredata.dat" ] && mode=--reconfigure; \
  meson setup $$mode "$$PGBUILD" "$$PGSRC" --prefix="$$PGINSTALL" \
    --buildtype=debug -Dcassert=true -Dtap_tests=enabled \
    $$PG_MESON_FEATURES $(PG_MESON_ARGS)

.DEFAULT_GOAL := help
.PHONY: help src check-src dev-image dev shell setup build test docs tmp \
        dev-clean runtime-image up psql logs stop down reset clean

help: ## Show this list
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) \
	  | awk -F ':.*## ' '{ printf "  %-14s %s\n", $$1, $$2 }'

src: ## Clone postgres into PGSRC if it is not there yet
	@if [ -f "$(PGSRC)/meson.build" ]; then \
	  echo "Using existing checkout in $(PGSRC)"; \
	elif [ -e "$(PGSRC)" ] && [ -n "$$(ls -A "$(PGSRC)")" ]; then \
	  echo "$(PGSRC) exists but is not a postgres checkout."; \
	  exit 1; \
	else \
	  git clone $(PG_CLONE_ARGS) $(PG_REPO) "$(PGSRC)"; \
	fi

check-src:
	@[ -f "$(PGSRC)/meson.build" ] || { \
	  echo "No postgres checkout in $(PGSRC)."; \
	  echo "Run: make src"; \
	  echo "Or point to yours: make <target> PGSRC=/path/to/postgresql"; \
	  exit 1; }

# ---------------------------------------------------------------------------
# Dev
# ---------------------------------------------------------------------------

dev-image: check-src ## Build the dev image
	$(COMPOSE) build dev

shell: check-src ## Open a shell in the dev container
	$(COMPOSE) run --rm dev

dev: shell

setup: check-src ## Configure the debug build (meson setup)
	$(DEV_RUN) '$(DEV_SETUP)'

build: check-src ## Compile and install, configuring first if needed
	$(DEV_RUN) '[ -f "$$PGBUILD/build.ninja" ] || { $(DEV_SETUP); } \
	  && ninja -C "$$PGBUILD" install'

test: build ## Run the tests (TEST_ARGS="--suite regress")
	$(DEV_RUN) 'meson test -C "$$PGBUILD" --print-errorlogs $(TEST_ARGS)'

docs: check-src ## Build the HTML documentation
	$(DEV_RUN) 'ninja -C "$$PGBUILD" docs'

tmp: check-src ## Throwaway cluster on the dev build, deleted when psql exits
	$(DEV_RUN) 'd=$$(mktemp -d /work/tmpcluster.XXXXXX) \
	  && initdb -D "$$d/data" -A trust --no-sync >"$$d/initdb.log" \
	  && pg_ctl -D "$$d/data" -l "$$d/server.log" -w \
	       -o "-k $$d -h localhost" start >/dev/null \
	  && psql -h "$$d" postgres; \
	  pg_ctl -D "$$d/data" -m immediate stop >/dev/null 2>&1; \
	  rm -rf "$$d"'

dev-clean: ## Delete the dev build tree, install and ccache volumes
	$(COMPOSE) rm -f -s dev
	docker volume rm -f pgbuilder_pgwork pgbuilder_ccache

# ---------------------------------------------------------------------------
# Runtime
# ---------------------------------------------------------------------------

runtime-image: check-src ## Build the runtime image from the checkout
	$(COMPOSE) build runtime

up: check-src ## Build if needed and start the runtime container
	$(COMPOSE) up -d --build runtime

psql: ## Open psql in the runtime container
	$(COMPOSE) exec runtime psql

logs: ## Follow the runtime server logs
	$(COMPOSE) logs -f runtime

stop: ## Stop the runtime container, keep its data
	$(COMPOSE) stop runtime

down: ## Remove the runtime container, keep its data
	$(COMPOSE) down

reset: ## Remove the runtime container and its data
	$(COMPOSE) down -v

# ---------------------------------------------------------------------------
# Everything
# ---------------------------------------------------------------------------

clean: reset dev-clean ## Remove containers, volumes and images
	docker image rm -f pg-dev pg-runtime
