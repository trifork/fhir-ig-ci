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

| Env var       | Default | Purpose                                            |
| ------------- | :-----: | -------------------------------------------------- |
| `SERVER_PORT` | `8080`  | Listener port for the built-in HTTP server         |
| `LOGS`        | `/logs` | Directory where timestamped log files are written  |
| `PUID`/`PGID` |    —    | Force the container user's uid/gid. If unset, the entrypoint adopts the owner of `/workspace`. |

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

## Running the CI locally (multipass, any Linux host)

The GitHub Actions workflow under [.github/workflows/build-and-test.yml](.github/workflows/build-and-test.yml) is a thin wrapper
around `scripts/build.sh` and `scripts/test.sh`, so you can reproduce it
step-for-step on a Linux VM:

```sh
multipass launch --name ig-ci --cpus 4 --memory 8G --disk 20G 24.04
multipass shell ig-ci

# inside the VM
sudo apt-get update
sudo apt-get install -y docker.io docker-buildx git
sudo usermod -aG docker ubuntu && newgrp docker

git clone https://github.com/trifork/fhir-ig-ci.git
cd fhir-ig-ci
./scripts/build.sh --load
./scripts/test.sh
```

Swap `docker.io` for `podman` if you prefer — the scripts auto-detect.

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
