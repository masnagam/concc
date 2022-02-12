EMPTY :=
SPACE := $(EMPTY) $(EMPTY)
SEP := ,

PROJ_DIR := $(shell git rev-parse --show-toplevel)
NPROC := $(shell nproc)

SCALE ?= 1
REMOTES ?=
SSH_PORT ?= 2222
DEBUG_WORKSPACEFS ?= 0
ITERATIONS ?= 10
DOCKER_OPTIONS ?=
RTT_DELAY ?= 0

TOOLS_IMAGE := masnagam/concc-tools
TOOLS_BUILD_OPTIONS ?=
PROJECT := $$(docker compose ps -q project | xargs docker inspect | jq -r '.[].Name[1:]')
WORKERS := $$(docker compose ps -q worker | xargs docker inspect | jq -r '.[].Name[1:]' | tr '\n' ',')
REMOTE_WORKERS := $(subst $(SPACE),$(SEP),$(addsuffix :$(SSH_PORT),$(REMOTES)))
TIME := /usr/bin/time
TIME_CLIENT ?=
TIME_WORKER ?=
TIME_NONDIST ?=
TIME_ICECC ?=
METRICS_DIR := workspace/metrics
METRICS_JSON_PY := ../../scripts/metrics-json.py
METRICS_HTML_PY := ../../scripts/metrics-html.py

RTT_DELAY_CMD := tc qdisc add dev eth0 root netem delay $(RTT_DELAY)

ICECC_SCHED ?= icecc
ICECCD := iceccd -d -m 0 -s $(ICECC_SCHED) && sleep 5

.PHONY: all
all: build

build: local-build

# Project and worker containers will be kept running for debugging.
.PHONY: local-build
local-build: JOBS ?= $$(concc-worker-pool limit)
local-build: buildenv secrets workspace
	$(MAKE) src-clean
	$(MAKE) local-clean
	docker compose up -d --scale worker=$(SCALE) worker project
	docker compose exec project $(RTT_DELAY_CMD)
	docker compose exec worker $(RTT_DELAY_CMD)
	docker compose run --rm client concc -C src -l '$(CONFIGURE_CMD)'
	sudo sh -c 'echo 3 >/proc/sys/vm/drop_caches'
	docker compose run --rm -e CONCC_DEBUG_WORKSPACEFS=$(DEBUG_WORKSPACEFS) client \
	  concc -C src -p $(PROJECT) -w $(WORKERS) --rtt-delay $(RTT_DELAY) \
	  '$(TIME_CLIENT) $(BUILD_CMD)'

# Project and worker containers will be kept running for debugging.
.PHONY: remote-build
remote-build: JOBS ?= $$(concc-worker-pool limit)
remote-build: buildenv secrets workspace
	$(MAKE) src-clean
	for REMOTE in $(REMOTES); \
	do \
	  docker -H ssh://$$REMOTE stop $(REMOTE_CONTAINER) || true; \
	  LOCAL_IMAGE=$$(docker image ls -q $(BUILDENV)); \
	  REMOTE_IMAGE=$$(docker -H ssh://$$REMOTE image ls -q $(BUILDENV)); \
	  if [ "$$LOCAL_IMAGE" != "$$REMOTE_IMAGE" ]; \
	  then \
	    docker -H ssh://$$REMOTE image rm -f $(BUILDENV); \
	    docker save $(BUILDENV) | docker -H ssh://$$REMOTE load; \
	  fi \
	done
	# FIXME(masnagam/concc#1): remove SYS_ADMIN
	for REMOTE in $(REMOTES); \
	do \
	  docker -H ssh://$$REMOTE run --name $(REMOTE_CONTAINER) --rm --init -d \
	    --device /dev/fuse --tmpfs /run --tmpfs /tmp -p $(SSH_PORT):22/tcp \
	    --cap-add SYS_ADMIN --security-opt apparmor:unconfined $(DOCKER_OPTIONS) \
	    --cap-add NET_ADMIN \
	    $(BUILDENV) concc-worker; \
	done
	docker compose up -d project
	docker compose exec project $(RTT_DELAY_CMD)
	for REMOTE in $(REMOTES); \
	do \
	  docker -H ssh://$$REMOTE exec $(REMOTE_CONTAINER) $(RTT_DELAY_CMD); \
	done
	docker compose run --rm client concc -C src -l '$(CONFIGURE_CMD)'
	sudo sh -c 'echo 3 >/proc/sys/vm/drop_caches'
	docker compose run --rm -e CONCC_DEBUG_WORKSPACEFS=$(DEBUG_WORKSPACEFS) client \
	  concc -C src -p $(shell uname -n):$(SSH_PORT) -w $(REMOTE_WORKERS) \
	  --rtt-delay $(RTT_DELAY) '$(TIME_CLIENT) $(BUILD_CMD)'

.PHONY: nondist-build
nondist-build: JOBS ?= $(NPROC)
nondist-build: buildenv secrets workspace
	$(MAKE) src-clean
	docker compose run --rm client concc -C src -l '$(NONDIST_CONFIGURE_CMD)'
	sudo sh -c 'echo 3 >/proc/sys/vm/drop_caches'
	docker compose run --rm client \
	  concc -C src -l '$(TIME_NONDIST) $(NONDIST_BUILD_CMD)'

.PHONY: icecc-build
icecc-build: JOBS ?= 32
icecc-build: buildenv secrets workspace
	$(MAKE) src-clean
	docker compose run --rm client concc -C src -l '$(ICECC_CONFIGURE_CMD)'
	sudo sh -c 'echo 3 >/proc/sys/vm/drop_caches'
	docker compose run --rm client \
	  concc -C src -l '$(ICECCD) && $(TIME_ICECC) $(ICECC_BUILD_CMD)'

# Project and worker containers will be kept running for debugging.
.PHONY: check
check: build
	docker compose run --rm client \
	  concc -C src -p $(PROJECT) -w $(WORKERS) '$(CHECK_CMD)'

METRICS_HTML_HBS := ../metrics.html.hbs
CONCC_METRICS_FILES := $(addprefix $(METRICS_DIR)/,client.json worker.json)
NONDIST_METRICS_FILES := $(addprefix $(METRICS_DIR)/,nondist.json)
METRICS_FILES := $(CONCC_METRICS_FILES) $(NONDIST_METRICS_FILES)

.PHONY: metrics
metrics: $(METRICS_DIR)/index.html

.PHONY: concc-metrics
concc-metrics: $(CONCC_METRICS_FILES)

.PHONY: nondist-metrics
nondist-metrics: $(NONDIST_METRICS_FILES)

$(METRICS_DIR)/index.html: $(METRICS_HTML_PY) $(METRICS_FILES)
	cat $(METRICS_FILES) | python3 $(METRICS_HTML_PY) >$@

$(METRICS_DIR)/client.times $(METRICS_DIR)/worker.times: | $(METRICS_DIR)
	@for i in $(shell seq $(ITERATIONS)); \
	do \
	  $(MAKE) -e build \
	    TIME_CLIENT='$(TIME) -v -a -o /$(METRICS_DIR)/client.times' \
	    TIME_WORKER='$(TIME) -v -a -o /$(METRICS_DIR)/worker.times'; \
	done

$(METRICS_DIR)/nondist.times: | $(METRICS_DIR)
	@for i in $(shell seq $(ITERATIONS)); \
	do \
	  $(MAKE) -e nondist-build \
	    TIME_NONDIST='$(TIME) -v -a -o /$(METRICS_DIR)/nondist.times'; \
	done

$(METRICS_DIR)/%.json: $(METRICS_DIR)/%.times $(METRICS_JSON_PY)
	cat $< | python3 $(METRICS_JSON_PY) $(basename $(notdir $<)) >$@

# You NEED to run `docker image prune` if you want to remove dangling images.
.PHONY: clean-all
clean-all: src-clean local-clean remote-clean
	$(MAKE) secrets-clean
	rm -rf workspace
	docker image rm -f $(BUILDENV)
	docker image rm -f $(TOOLS_IMAGE)

.PHONY: clean
clean: src-clean local-clean

.PHONY: src-clean
src-clean:
	-$(SRC_CLEAN_CMD)

.PHONY: local-clean
local-clean:
	docker compose down -v

.PHONY: remote-clean
remote-clean:
	for REMOTE in $(REMOTES); \
	do \
	  docker -H ssh://$$REMOTE stop $(REMOTE_CONTAINER) || true; \
	done
	for REMOTE in $(REMOTES); \
	do \
	  docker -H ssh://$$REMOTE image rm -f $(BUILDENV); \
	done

.PHONY: metrics-clean
metrics-clean:
	rm -rf workspace/metrics

.PHONY: buildenv
buildenv: concc-tools
	docker buildx build -t $(BUILDENV) $(BUILDENV_BUILD_OPTIONS) .

.PHONY: concc-tools
concc-tools:
	$(MAKE) -C ../../docker BUILD_OPTIONS=$(TOOLS_BUILD_OPTIONS)

.PHONY: secrets
secrets: users.conf password

.PHONY: secrets-clean
secrets-clean:
	rm -rf users.conf password

users.conf: password
	echo "concc:$(shell cat $<):$(shell id -u):$(shell id -g):workspace" >$@

password:
	echo 'concc' >$@

workspace/metrics: | workspace
	mkdir workspace/metrics
