# Powernode Agent — Makefile
#
# Targets:
#   build        cross-compile static binaries for amd64 + arm64 → dist/
#   build-amd64  amd64 only
#   build-arm64  arm64 only
#   test         go test ./...
#   lint         golangci-lint run
#   vet          go vet ./...
#   clean        rm -rf dist/

VERSION    ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
GIT_COMMIT ?= $(shell git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)
BUILD_DATE ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)

LDFLAGS := -s -w \
  -X main.Version=$(VERSION) \
  -X main.GitCommit=$(GIT_COMMIT) \
  -X main.BuildDate=$(BUILD_DATE)

.PHONY: build build-amd64 build-arm64 test lint vet clean

build: build-amd64 build-arm64

build-amd64:
	mkdir -p dist
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
	  -ldflags='$(LDFLAGS)' -trimpath \
	  -o dist/ipn-agent-linux-amd64 \
	  ./cmd/ipn-agent

build-arm64:
	mkdir -p dist
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build \
	  -ldflags='$(LDFLAGS)' -trimpath \
	  -o dist/ipn-agent-linux-arm64 \
	  ./cmd/ipn-agent

test:
	go test -race ./...

lint:
	golangci-lint run

vet:
	go vet ./...

clean:
	rm -rf dist/
