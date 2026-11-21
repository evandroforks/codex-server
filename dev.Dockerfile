FROM rust:1.99.1-bookworm@sha256:e6f2cff35d0f309acf8433b4f05878ed77092602c5065cc81801177da0bb3a9c

RUN apt-get update \
    && apt-get install -y --no-install-recommends clang cmake libasound2-dev libcap-dev python3 \
    && rm -rf /var/lib/apt/lists/* \
    && rustup component add clippy rustfmt rust-src \
    && cargo install --locked just --version 1.51.0

RUN cargo install --locked cargo-nextest --version 0.9.152

# Match .github/actions/setup-rusty-v8, including its committed manifest trust root.
COPY third_party/v8/rusty_v8_152_2_0_release_manifests.sha256 /opt/v8/trusted.sha256
RUN python3 - <<'PY'
import hashlib
from pathlib import Path
import subprocess
import urllib.request

root = Path("/opt/v8")
target = next(line.removeprefix("host: ") for line in
              subprocess.check_output(["rustc", "-vV"], text=True).splitlines()
              if line.startswith("host: "))
profile = "ptrcomp_sandbox_release"
manifest_name = f"rusty_v8_{profile}_{target}.sha256"
base = "https://github.com/openai/codex/releases/download/rusty-v8-v152.2.0/"
trusted = {name: digest for digest, name in
           (line.split() for line in (root / "trusted.sha256").read_text().splitlines())}
manifest = urllib.request.urlopen(base + manifest_name, timeout=120).read()
if hashlib.sha256(manifest).hexdigest() != trusted[manifest_name]:
    raise SystemExit("V8 release manifest checksum mismatch")
checksums = {name: digest for digest, name in
             (line.split() for line in manifest.decode().splitlines())}
artifacts = {
    f"librusty_v8_{profile}_{target}.a.gz": "archive.a.gz",
    f"src_binding_{profile}_{target}.rs": "binding.rs",
}
if checksums.keys() != artifacts.keys():
    raise SystemExit("Unexpected V8 artifact manifest entries")
for name, destination in artifacts.items():
    path = root / destination
    urllib.request.urlretrieve(base + name, path)
    with path.open("rb") as artifact:
        actual = hashlib.file_digest(artifact, "sha256").hexdigest()
    if actual != checksums[name]:
        raise SystemExit(f"V8 artifact checksum mismatch: {name}")
PY

ARG USER_UID=1000
ARG USER_GID=1000
RUN groupadd --gid "${USER_GID}" developer \
    && useradd --uid "${USER_UID}" --gid "${USER_GID}" --create-home developer \
    && mkdir -p /opt/cargo /opt/target /workspace/codex-rs \
    && chown developer:developer /opt/cargo /opt/target /workspace/codex-rs

ENV CARGO_HOME=/opt/cargo \
    CARGO_TARGET_DIR=/opt/target \
    NEXTEST_PROFILE=local \
    RUSTY_V8_ARCHIVE=/opt/v8/archive.a.gz \
    RUSTY_V8_SRC_BINDING_PATH=/opt/v8/binding.rs \
    RUST_MIN_STACK=8388608
USER developer
WORKDIR /workspace/codex-rs

# Mount the checkout at /workspace and writable caches at /opt/cargo and /opt/target.
# Nextest also needs a writable /workspace/codex-rs/target for its run reports.
# Before app-server integration tests, build the workspace's runtime fixtures:
# cargo build --locked -p codex-linux-sandbox -p codex-rmcp-client -p codex-code-mode-host --bins
# Override the default arguments to run tests, for example:
# cargo test --locked -p codex-app-server --lib thread_lifecycle
ENTRYPOINT ["cargo"]
CMD ["nextest", "run", "--locked", "--no-fail-fast", "-p", "codex-app-server"]
