#!/usr/bin/make -f

PACKAGES_SIMTEST=$(shell go list ./... | grep '/simulation')
VERSION := $(shell echo $(shell git describe --tags) | sed 's/^v//')
COMMIT := $(shell git log -1 --format='%H')
LEDGER_ENABLED ?= true
SDK_PACK := $(shell go list -m github.com/cosmos/cosmos-sdk | sed  's/ /\@/g')

export GO111MODULE = on

# process build tags

build_tags = netgo
ifeq ($(LEDGER_ENABLED),true)
  ifeq ($(OS),Windows_NT)
    GCCEXE = $(shell where gcc.exe 2> NUL)
    ifeq ($(GCCEXE),)
      $(error gcc.exe not installed for ledger support, please install or set LEDGER_ENABLED=false)
    else
      build_tags += ledger
    endif
  else
    UNAME_S = $(shell uname -s)
    ifeq ($(UNAME_S),OpenBSD)
      $(warning OpenBSD detected, disabling ledger support (https://github.com/cosmos/cosmos-sdk/issues/1988))
    else
      GCC = $(shell command -v gcc 2> /dev/null)
      ifeq ($(GCC),)
        $(error gcc not installed for ledger support, please install or set LEDGER_ENABLED=false)
      else
        build_tags += ledger
      endif
    endif
  endif
endif

ifeq ($(WITH_CLEVELDB),yes)
  build_tags += gcc
endif
build_tags += $(BUILD_TAGS)
build_tags := $(strip $(build_tags))

whitespace :=
whitespace += $(whitespace)
comma := ,
build_tags_comma_sep := $(subst $(whitespace),$(comma),$(build_tags))

# process linker flags

ldflags = -X github.com/cosmos/cosmos-sdk/version.Name=gaia \
		  -X github.com/cosmos/cosmos-sdk/version.ServerName=gaiad \
		  -X github.com/cosmos/cosmos-sdk/version.ClientName=gaiacli \
		  -X github.com/cosmos/cosmos-sdk/version.Version=$(VERSION) \
		  -X github.com/cosmos/cosmos-sdk/version.Commit=$(COMMIT) \
		  -X "github.com/cosmos/cosmos-sdk/version.BuildTags=$(build_tags_comma_sep)"

ifeq ($(WITH_CLEVELDB),yes)
  ldflags += -X github.com/cosmos/cosmos-sdk/types.DBBackend=cleveldb
endif
ldflags += $(LDFLAGS)
ldflags := $(strip $(ldflags))

BUILD_FLAGS := -tags "$(build_tags)" -ldflags '$(ldflags)'

# The below include contains the tools target.
include contrib/devtools/Makefile

all: install lint check

build: go.sum
ifeq ($(OS),Windows_NT)
	go build -mod=readonly $(BUILD_FLAGS) -o build/gaiad.exe ./cmd/gaiad
	go build -mod=readonly $(BUILD_FLAGS) -o build/gaiacli.exe ./cmd/gaiacli
else
	go build -mod=readonly $(BUILD_FLAGS) -o build/gaiad ./cmd/gaiad
	go build -mod=readonly $(BUILD_FLAGS) -o build/gaiacli ./cmd/gaiacli
endif

build-linux: go.sum
	LEDGER_ENABLED=false GOOS=linux GOARCH=amd64 $(MAKE) build

build-contract-tests-hooks:
ifeq ($(OS),Windows_NT)
	go build -mod=readonly $(BUILD_FLAGS) -o build/contract_tests.exe ./cmd/contract_tests
else
	go build -mod=readonly $(BUILD_FLAGS) -o build/contract_tests ./cmd/contract_tests
endif

install: go.sum check-ledger
	go install -mod=readonly $(BUILD_FLAGS) ./cmd/gaiad
	go install -mod=readonly $(BUILD_FLAGS) ./cmd/gaiacli

install-debug: go.sum
	go install -mod=readonly $(BUILD_FLAGS) ./cmd/gaiadebug



########################################
### Tools & dependencies

go-mod-cache: go.sum
	@echo "--> Download go modules to local cache"
	@go mod download

go.sum: go.mod
	@echo "--> Ensure dependencies have not been modified"
	@go mod verify

draw-deps:
	@# requires brew install graphviz or apt-get install graphviz
	go get github.com/RobotsAndPencils/goviz
	@goviz -i ./cmd/gaiad -d 2 | dot -Tpng -o dependency-graph.png

clean:
	rm -rf snapcraft-local.yaml build/

distclean: clean
	rm -rf vendor/

########################################
### Testing


check: check-unit check-build
check-all: check check-race check-cover

check-unit:
	@VERSION=$(VERSION) go test -mod=readonly -tags='ledger test_ledger_mock' ./...

check-race:
	@VERSION=$(VERSION) go test -mod=readonly -race -tags='ledger test_ledger_mock' ./...

check-cover:
	@go test -mod=readonly -timeout 30m -race -coverprofile=coverage.txt -covermode=atomic -tags='ledger test_ledger_mock' ./...

check-build: build
	@go test -mod=readonly -p 4 `go list ./cli_test/...` -tags=cli_test


lint: ci-lint
ci-lint:
	golangci-lint run
	find . -name '*.go' -type f -not -path "./vendor*" -not -path "*.git*" | xargs gofmt -d -s
	go mod verify

format:
	find . -name '*.go' -type f -not -path "./vendor*" -not -path "*.git*" -not -path "./client/lcd/statik/statik.go" | xargs gofmt -w -s
	find . -name '*.go' -type f -not -path "./vendor*" -not -path "*.git*" -not -path "./client/lcd/statik/statik.go" | xargs misspell -w
	find . -name '*.go' -type f -not -path "./vendor*" -not -path "*.git*" -not -path "./client/lcd/statik/statik.go" | xargs goimports -w -local github.com/cosmos/cosmos-sdk

benchmark:
	@go test -mod=readonly -bench=. ./...


########################################
### Local validator nodes using docker and docker-compose

build-docker-gaiadnode:
	$(MAKE) -C networks/local

# Run a 4-node testnet locally
localnet-start: localnet-stop
	@if ! [ -f build/node0/gaiad/config/genesis.json ]; then docker run --rm -v $(CURDIR)/build:/gaiad:Z tendermint/gaiadnode testnet --v 4 -o . --starting-ip-address 192.168.10.2 ; fi
	docker-compose up -d

# Stop testnet
localnet-stop:
	docker-compose down

# clean any previous run of contract-tests, initialize gaiad and finally tune the configuration and override genesis to have predictable output
setup-contract-tests-data:
	echo 'Prepare data for the contract tests'
	rm -rf /tmp/contract_tests ; \
	mkdir /tmp/contract_tests ; \
	cp "${GOPATH}/pkg/mod/${SDK_PACK}/client/lcd/swagger-ui/swagger.yaml" /tmp/contract_tests/swagger.yaml ; \
	./build/gaiad init --home /tmp/contract_tests/.gaiad --chain-id lcd contract-tests ; \
	tar -xzf lcd_test/testdata/state.tar.gz -C /tmp/contract_tests/ # this will feed .gaiad and .gaiacli folders with static configuration and addresses

	# Tune config.toml in order to speed up tests, by reducing timeouts
	sed -i.bak -e "s/^timeout_propose = .*/timeout_propose = \"200ms\"/g" /tmp/contract_tests/.gaiad/config/config.toml
	sed -i.bak -e "s/^timeout_propose_delta = .*/timeout_propose_delta = \"200ms\"/g" /tmp/contract_tests/.gaiad/config/config.toml
	sed -i.bak -e "s/^timeout_prevote = .*/timeout_prevote = \"500ms\"/g" /tmp/contract_tests/.gaiad/config/config.toml
	sed -i.bak -e "s/^timeout_prevote_delta = .*/timeout_prevote_delta = \"100ms\"/g" /tmp/contract_tests/.gaiad/config/config.toml
	sed -i.bak -e "s/^timeout_precommit = .*/timeout_precommit = \"200ms\"/g" /tmp/contract_tests/.gaiad/config/config.toml
	sed -i.bak -e "s/^timeout_precommit_delta = .*/timeout_precommit_delta = \"200ms\"/g" /tmp/contract_tests/.gaiad/config/config.toml
	sed -i.bak -e "s/^timeout_commit = .*/timeout_commit = \"500ms\"/g" /tmp/contract_tests/.gaiad/config/config.toml

# start gaiad by using the custom home after having it set up
start-gaia: setup-contract-tests-data
	./build/gaiad --home /tmp/contract_tests/.gaiad start &
	@sleep 2s

# do a transaction, governance proposal, vote and unbound, should run after gaia has started against contract_test home folder
setup-transactions: start-gaia
	@bash ./lcd_test/testdata/setup.sh

# Target made to be called by dredd, it runs the REST server that dredd will test against
run-lcd-contract-tests:
	@echo "Running Gaia LCD for contract tests"
	./build/gaiacli rest-server --laddr tcp://0.0.0.0:8080 --home /tmp/contract_tests/.gaiacli --node http://localhost:26657 --chain-id lcd --trust-node true

# launch dredd after having set it up, at completion dredd will kill the rest server while here we kill gaiad
contract-tests: setup-transactions
	@echo "Running Gaia LCD for contract tests"
	dredd && pkill gaiad

# include simulations
include sims.mk

.PHONY: all build-linux install install-debug \
	go-mod-cache draw-deps clean build \
	setup-transactions setup-contract-tests-data start-gaia run-lcd-contract-tests contract-tests \
	check check-all check-build check-cover check-ledger check-unit check-race

