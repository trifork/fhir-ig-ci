# fhir-ig-ci

A container image that bundles everything needed to publish a
[HL7 FHIR Implementation Guide](https://hl7.org/fhir/implementationguide.html):
the [FHIR IG Publisher](https://github.com/HL7/fhir-ig-publisher),
[fsh-sushi](https://github.com/FHIR/sushi), Jekyll, Python 3, Java 21,
and graphviz — on Alpine, built for `linux/amd64` and `linux/arm64`.

The image is meant to be used by mounting an IG source folder, writing the
result to an output folder, and optionally starting a built-in HTTP server for
local preview.

## What's inside

| Tool                | Role                                          |
| ------------------- | --------------------------------------------- |
| OpenJDK 21          | Runtime for the IG Publisher                  |
| FHIR IG Publisher   | Renders the IG (HTML, JSON, QA report, …)     |
| fsh-sushi           | Compiles FSH → FHIR resources                 |
| Jekyll              | Used by the publisher for narrative pages     |
| Python 3            | Built-in HTTP server for local preview        |
| graphviz            | Diagrams rendered by the publisher            |
| `su-exec` + `shadow`| Drops privileges to the mount owner at startup|

Versions are pinned in the [Dockerfile](Dockerfile) via build args
(`IG_PUBLISHER_VERSION`, `SUSHI_VERSION`, `JEKYLL_VERSION`) and are easy to
bump.

## Quick start

Publish an IG (assumes `sushi-config.yaml` / `ig.ini` in the current directory):

```sh
docker run --rm \
  -v "$PWD:/workspace" \
  -v "$PWD/out:/output" \
  ghcr.io/trifork/fhir-ig-ci:latest
```

Publish and capture logs to a host directory:

```sh
docker run --rm \
  -v "$PWD:/workspace" \
  -v "$PWD/out:/output" \
  -v "$PWD/logs:/logs" \
  ghcr.io/trifork/fhir-ig-ci:latest
```

All container output is streamed to the terminal **and** written to a
timestamped file (`logs/fhir-ig-ci-YYYYMMDD-HHMMSS.log`) in the mounted
`/logs` directory. If `/logs` is not mounted the directory is created
inside the container (logs are not persisted after the container exits).

Publish **and** serve the rendered site on port 8080:

```sh
docker run --rm \
  -p 8080:8080 \
  -v "$PWD:/workspace" \
  ghcr.io/trifork/fhir-ig-ci:latest publish-and-serve
```

Serve an already-built IG:

```sh
docker run --rm -p 8080:8080 -v "$PWD:/workspace" \
  ghcr.io/trifork/fhir-ig-ci:latest serve
```

Run `sushi` directly:

```sh
docker run --rm -v "$PWD:/workspace" \
  ghcr.io/trifork/fhir-ig-ci:latest sushi .
```

Print the version of every bundled tool:

```sh
docker run --rm ghcr.io/trifork/fhir-ig-ci:latest versions
```

### Container interface

| Command              | Default | Behaviour                                              |
| -------------------- | :-----: | ------------------------------------------------------ |
| `publish`            |    ✓    | Runs sushi (if applicable) then the IG Publisher       |
| `publish-and-serve`  |         | Publish, then serve `/output` via `python3 -m http.server` |
| `serve`              |         | Serve the existing `/output` (or `/workspace/output`)  |
| `sushi [args]`       |         | Invoke `fsh-sushi` directly                            |
| `jekyll [args]`      |         | Invoke `jekyll` directly                               |
| `versions`           |         | Print versions of every bundled tool                   |
| `shell` / `bash`     |         | Interactive shell inside the container                 |
| *anything else*      |         | Executed verbatim                                      |

| Mount / port | Meaning                                        |
| ------------ | ---------------------------------------------- |
| `/workspace` | IG source (the dir containing `sushi-config.yaml` / `ig.ini`) |
| `/output`    | Destination for rendered site (optional)       |
| `/logs`      | Timestamped log files written here (optional)  |
| `8080/tcp`   | HTTP port used by `serve` / `publish-and-serve`|

| Env var          | Default | Purpose                                            |
| ---------------- | :-----: | -------------------------------------------------- |
| `SERVER_PORT`    | `8080`  | Listener port for the built-in HTTP server         |
| `LOGS`           | `/logs` | Directory where timestamped log files are written  |
| `LOGS_MAX_FILES` |  `10`   | Max log files to keep; oldest are pruned (0 = unlimited) |
| `JAVA_HEAP`      |  `4g`   | JVM max heap passed as `-Xmx` to the IG Publisher  |
| `PUID`/`PGID`    |    —    | Force the container user's uid/gid. If unset, the entrypoint adopts the owner of `/workspace`. |

The entrypoint starts as root, remaps the built-in `ig` user so its uid/gid
matches either `$PUID`/`$PGID` or the owner of the mounted workspace, and then
drops privileges via `su-exec`. This makes bind-mounted output files come out
owned by the host user. Passing `--user` to `docker run` bypasses that logic.

## Building locally

Build a host-arch image and load it into the local engine:

```sh
./scripts/build.sh --load
```

Build a multi-arch image and push it to a registry:

```sh
REGISTRY=ghcr.io/trifork IMAGE_TAG=v0.1.0 \
  ./scripts/build.sh --multi-arch --push
```

Run the same unit tests the CI runs:

```sh
./scripts/test.sh
```

Everything honours `$ENGINE` (auto-detects `docker`, falls back to `podman`),
`$REGISTRY`, `$IMAGE_NAME`, `$IMAGE_TAG`, `$PLATFORMS`, `$CACHE_FROM` and
`$CACHE_TO`.

## Running the CI locally

`scripts/ci-multipass.sh` builds the image and runs the full test suite
inside a [multipass](https://multipass.run) VM, installing multipass
automatically if it is not already present.

```sh
./scripts/ci-multipass.sh
```

Supported hosts:

| OS / distro       | multipass installed via         |
| ----------------- | ------------------------------- |
| macOS             | `brew install --cask multipass` |
| Ubuntu            | `snap install multipass`        |
| Debian            | `snap install multipass`        |
| Linux Mint        | `snap install multipass`        |
| Fedora            | `dnf install snapd` → `snap install multipass` |
| CachyOS / Arch    | AUR (`paru` or `yay`)           |

The script is POSIX-compatible (`#!/bin/sh`) and dispatches to a
per-distro helper in `scripts/ci/`. The VM is created once and reused on
subsequent runs for faster iteration.

### VM configuration

Override defaults with environment variables:

| Variable    | Default | Purpose                          |
| ----------- | :-----: | -------------------------------- |
| `VM_NAME`   | `ig-ci` | Multipass VM name                |
| `VM_CPUS`   | `4`     | vCPUs                            |
| `VM_MEMORY` | `8G`    | RAM                              |
| `VM_DISK`   | `20G`   | Disk                             |

```sh
VM_NAME=my-ig-vm VM_CPUS=2 VM_MEMORY=4G ./scripts/ci-multipass.sh
```

### Manual step-by-step

If you prefer to drive the VM yourself:

```sh
multipass launch --name ig-ci --cpus 4 --memory 8G --disk 20G 24.04
multipass exec ig-ci -- bash -c '
  sudo apt-get install -y docker.io docker-buildx git
  sudo usermod -aG docker ubuntu
'
# then from the host repo root:
COPYFILE_DISABLE=1 tar -czf /tmp/repo.tar.gz --exclude=.git .
multipass transfer /tmp/repo.tar.gz ig-ci:/tmp/repo.tar.gz
multipass exec ig-ci -- bash -c '
  mkdir ~/fhir-ig-ci && tar -xzf /tmp/repo.tar.gz -C ~/fhir-ig-ci
  cd ~/fhir-ig-ci
  sg docker -c "./scripts/build.sh --load"
  sg docker -c "./scripts/test.sh"
'
```

## CI pipeline

Two jobs in [.github/workflows/build-and-test.yml](.github/workflows/build-and-test.yml):

1. **`test`** — builds a single-arch image (loaded into the host daemon) and
   runs `scripts/test.sh` against it. Runs on every push and pull request.
2. **`publish`** — only on pushes to `main` and tag pushes; builds the
   multi-arch manifest, tags it (`sha-<sha>`, branch, version, `latest`),
   and pushes to `ghcr.io/<owner>/fhir-ig-ci`.

## Test fixture

[tests/sample-ig](tests/sample-ig) holds the smallest valid IG that still exercises `fsh-sushi`
end-to-end: a single profile on `Patient`, one instance, and a `sushi-config.yaml`
with `FSHOnly: true`. `scripts/test.sh` copies it into a tempdir and runs
`sushi .`, verifying `fsh-generated/resources/` gets produced.

## License

[GNU Affero General Public License v3.0](LICENSE) — see [LICENSE](LICENSE)
for the full text.
