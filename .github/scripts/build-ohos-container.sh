#!/bin/bash
# Build jy-bun for OHOS aarch64 INSIDE the social4hyq ci-runner container.
#
# Replicates social4hyq bun.rb's install-block environment (Formula/b/bun.rb
# lines 192-256): ohos-cross-libs + ohos-icu scaffolding, LD_LIBRARY_PATH,
# CC/CXX, rust env. Builds OUR jy-bun source (NOT the formula's ohos-bun
# source) with --webkit=local (our pinned WebKit fork at vendor/WebKit).
#
# Why a script, not inline YAML: the env setup is ~80 lines with many brew
# --prefix expansions and symlinks; a heredoc inside docker exec forces
# brittle nested-quoting. A committed script is syntax-checkable (bash -n)
# and mirrors social4hyq's own .github/scripts/build.sh layout.
#
# Preconditions (set up by the workflow before invoking this):
#   - `brew trust social4hyq/core` done → `brew install --only-dependencies`
#     poured llvm@21, ohos-sdk, icu4c@78, bun-bootstrap, openssl@3, cmake, ninja.
#   - rust-nightly resource staged at /data/storage/el2/base/tmp/rust-$RUST_TOOLCHAIN.
#   - WebKit fork checked out at /workspace/bun/vendor/WebKit.
#   - bun install already run (root + src/node-fallbacks).
#
# Signing: NOT done here. The container runs a Linux kernel (not OHOS), so
# unsigned ELFs exec fine (the musl loader does not check .codesign —
# confirmed: cargo reached symbol-relocation before failing on OpenSSL).
# install-bun-ohos.sh signs the final binary on the device at install time.
#
# Run via:
#   docker exec -e RUST_TOOLCHAIN -e NINJA_JOBS "$CONTAINER" \
#     bash /workspace/bun/.github/scripts/build-ohos-container.sh
set -euo pipefail

: "${RUST_TOOLCHAIN:?RUST_TOOLCHAIN must be set (passed via docker exec -e)}"
: "${NINJA_JOBS:=2}"

BREW_PREFIX=$(brew --prefix)
LLVM_PREFIX=$(brew --prefix llvm@21)
SDK_PREFIX=$(brew --prefix ohos-sdk)
ICU_PREFIX=$(brew --prefix icu4c@78)
BUN_BOOT_DIR=$(brew --prefix bun-bootstrap)/bin
RUST_HOME="/data/storage/el2/base/tmp/rust-${RUST_TOOLCHAIN}"
SRC=/workspace/bun
cd "$SRC"

# ── Build environment (bun.rb lines 192-247) ──────────────────────────
# rust cargo NEEDS libssl/libcrypto (brew openssl@3); without it the musl
# loader hits "Error relocating cargo: SSL_get_error: symbol not found" → 127
# (bun.rb line 197-199 documents this exact failure).
# lld from llvm@21 has runtime deps on libxml2/zlib; brew superenv strips
# system lib paths, so inject them explicitly (bun.rb lines 195-199).
export LD_LIBRARY_PATH="$BREW_PREFIX/opt/openssl@3/lib:$BREW_PREFIX/lib/libxml2/lib:$BREW_PREFIX/lib/zlib/lib:${LD_LIBRARY_PATH:-}"
# llvm@21 only ships llvm-strip; bun's build script needs `strip` (bun.rb 201-202).
mkdir -p .bin
ln -sf "$LLVM_PREFIX/bin/llvm-strip" .bin/strip
export PATH="$LLVM_PREFIX/bin:$RUST_HOME/bin:$BUN_BOOT_DIR:$BREW_PREFIX/bin:.bin:${PATH:-}"
# CC/CXX: raw llvm@21 clang (no signing shims — device signs at install time).
export CC="$LLVM_PREFIX/bin/clang"
export CXX="$LLVM_PREFIX/bin/clang++"
export CARGO_HOME=/root/.cargo
export RUSTUP_HOME="$RUST_HOME"
export RUSTUP_TOOLCHAIN="$RUST_TOOLCHAIN"
export OHOS_SDK_ROOT="$SDK_PREFIX"
export OHOS_SYSROOT="$SDK_PREFIX/native/sysroot"
export OHOS_LLVM_PREFIX="$LLVM_PREFIX"      # bun.rb 235
export BUN_INSTALL_IGNORE_SCRIPTS=1
export TMPDIR="/data/storage/el2/base/tmp"  # bun.rb 247 (EL2 tmp, musl tmpfile path)
unset RUSTC_WRAPPER || true                 # bun.rb 230 (clear sccache etc.)
ca_bundle="$BREW_PREFIX/etc/ca-certificates/cert.pem"
[ -f "$ca_bundle" ] && export SSL_CERT_FILE="$ca_bundle" CURL_CA_BUNDLE="$ca_bundle" || true

echo "=== toolchain ==="
rustc --version
cargo --version
clang --version | head -1
"$BUN_BOOT_DIR/bun" --version

# ── Scaffold ohos-cross-libs (bun.rb lines 204-219) ────────────────────
# bun flags.ts expects ohosCrossLibs to contain libcxx/include/v1/ and
# libcxxabi/include/. llvm@21 ships aarch64-linux-ohos cross runtimes
# (__1 ABI — same as self-hosted Harmonybrew, NOT the old self-compiled __n1).
CROSS=build/ohos-cross-libs
rm -rf "$CROSS"
mkdir -p "$CROSS/libcxx/include" "$CROSS/libcxxabi" \
         "$CROSS/libcxx/lib" "$CROSS/libcxxabi/lib" "$CROSS/libunwind/lib"
ln -sf "$LLVM_PREFIX/include/aarch64-linux-ohos/c++/v1" "$CROSS/libcxx/include/v1"
ln -sf "$LLVM_PREFIX/include/aarch64-linux-ohos/c++/v1" "$CROSS/libcxxabi/include"
ln -sf "$LLVM_PREFIX/lib/aarch64-linux-ohos/libc++.a"    "$CROSS/libcxx/lib/libc++.a"
ln -sf "$LLVM_PREFIX/lib/aarch64-linux-ohos/libc++abi.a" "$CROSS/libcxxabi/lib/libc++abi.a"
ln -sf "$LLVM_PREFIX/lib/aarch64-linux-ohos/libunwind.a" "$CROSS/libunwind/lib/libunwind.a"
if [ ! -e "$CROSS/libcxx/include/v1/__config_site" ]; then
  echo "ERROR: llvm@21 aarch64-linux-ohos cross headers missing."
  echo "  looked for: $LLVM_PREFIX/include/aarch64-linux-ohos/c++/v1/__config_site"
  echo "  llvm@21 include dirs:"; ls "$LLVM_PREFIX/include/" 2>/dev/null | head -20
  exit 1
fi
echo "=== cross-libs OK (ABI __1, from llvm@21) ==="

# ── Scaffold ohos-icu (bun.rb lines 119-135) ───────────────────────────
# config.ts:1013 defaults ohosIcuDir=<cwd>/build/ohos-icu/target;
# webkit.ts:472 resolves hostBin=<ohosIcuDir>/../host/bin for ICU data tools
# (genrb/genccode/gencmn/pkgdata) — WebKit CMake needs these under
# --webkit=local (from-source WebKit, not the bun-webkit bottle).
ICU_TARGET=build/ohos-icu/target
ICU_HOST=build/ohos-icu/host
mkdir -p "$ICU_TARGET/include" "$ICU_TARGET/lib" "$ICU_HOST/bin"
ln -sf "$ICU_PREFIX/include/unicode" "$ICU_TARGET/include/unicode"
for a in libicudata.a libicui18n.a libicuuc.a; do
  ln -sf "$ICU_PREFIX/lib/$a" "$ICU_TARGET/lib/$a"
done
for t in genrb genccode gencmn pkgdata; do
  [ -x "$ICU_PREFIX/bin/$t" ] && ln -sf "$ICU_PREFIX/bin/$t" "$ICU_HOST/bin/$t" || true
done
echo "=== ohos-icu OK (from icu4c@78) ==="

# ── Configure (webkit=local, --configure-only) ────────────────────────
echo "=== configure (webkit=local, --configure-only) ==="
"$BUN_BOOT_DIR/bun" scripts/build.ts \
  --profile=release \
  --os=ohos \
  --arch=aarch64 \
  --webkit=local \
  --build-dir=build/release-ohos \
  --ohos-sdk-root="$OHOS_SDK_ROOT" \
  --ohos-sysroot="$OHOS_SYSROOT" \
  --configure-only 2>&1 | tee /tmp/build.log

# ── Generate WebKit build.ninja ───────────────────────────────────────
echo "=== configure-WebKit ==="
ninja -C build/release-ohos configure-WebKit -j1 2>&1 | tee -a /tmp/build.log

# WebKit CMake FindThreads bug: -lpthreads → -lpthread. Universal (not
# llvm-22-specific); the from-source WebKit build under --webkit=local hits it.
if [ -f build/release-ohos/deps/WebKit/build.ninja ]; then
  sed -i 's/-lpthreads/-lpthread/g' build/release-ohos/deps/WebKit/build.ninja
fi

# ── Build ─────────────────────────────────────────────────────────────
echo "=== build (ninja bun, -j${NINJA_JOBS}) ==="
set +e
ninja -C build/release-ohos bun -j"${NINJA_JOBS}" 2>&1 | tee -a /tmp/build.log
rc=${PIPESTATUS[0]}
set -e
if [ "$rc" -ne 0 ]; then
  echo "=== build failed (rc=$rc) ==="
  grep -inE 'error\[|error:|fatal error|undefined reference|ld: error|FAILED:' /tmp/build.log | head -50 || true
  tail -80 /tmp/build.log || true
  exit 1
fi

echo "=== build OK ==="
OUT=build/release-ohos/bun
[ -f "$OUT" ] || OUT=build/release-ohos/bun-profile
ls -lh "$OUT"
