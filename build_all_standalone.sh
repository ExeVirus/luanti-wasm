#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASE_DIR"

# -----------------------------------------------------------------------------
# Configuration & CLI flags
# -----------------------------------------------------------------------------
export BUILD_KIND="${BUILD_KIND:-release}"   # release | debug | profile
WITH_CURL="${WITH_CURL:-1}"                  # 0 (matches upstream build_all.sh) | 1
ZSTD_OPTS="${ZSTD_OPTS:---ultra -22}"        # e.g. ZSTD_OPTS="-9" for faster dev fsroot packing
FROM_STAGE=""
RECONFIGURE_STAGE=""
CLEAN_BUILD=0

usage() {
  cat << 'EOF'
Usage: ./build_all_standalone.sh [options]

Options:
  --from <stage>         Re-run from <stage> onward (keeps build caches for incremental builds)
  --reconfigure <stage>  Wipe build dir of <stage> and re-run from <stage> onward
  --with-curl            Also build openssl + curl (disabled in upstream build_all.sh)
  --clean-build          Remove build<suffix>/ and recompile deps+luanti (keeps emsdk & sources)
  -h, --help             Show this help

Stages (in order):
  emsdk, sources, [openssl, curl,] zstd, libarchive, webshims, libzip, luanti, fsroot, xterm, www

Environment:
  BUILD_KIND=release|debug|profile   (default: release)
  ZSTD_OPTS="--ultra -22"            (override e.g. ZSTD_OPTS="-9" for faster dev packs)
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --from)
      [[ $# -ge 2 ]] || { echo "Missing argument for --from" >&2; exit 1; }
      FROM_STAGE="$2"; shift 2 ;;
    --reconfigure)
      [[ $# -ge 2 ]] || { echo "Missing argument for --reconfigure" >&2; exit 1; }
      RECONFIGURE_STAGE="$2"; FROM_STAGE="$2"; shift 2 ;;
    --with-curl)
      WITH_CURL=1; shift ;;
    --clean-build)
      CLEAN_BUILD=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

case "$BUILD_KIND" in
  debug)
    export LUANTI_BUILD_TYPE="Debug"
    export COMMON_CFLAGS="-O0 -g -gsource-map"
    export COMMON_LDFLAGS="-sSAFE_HEAP=1 -sASSERTIONS=2"
    export BUILD_SUFFIX="-debug"
    ;;
  profile)
    export LUANTI_BUILD_TYPE="Release"
    export COMMON_CFLAGS="--profiling -O2 -g -gsource-map"
    export COMMON_LDFLAGS=""
    export BUILD_SUFFIX="-profile"
    ;;
  release)
    export LUANTI_BUILD_TYPE="Release"
    export COMMON_CFLAGS="-O2"
    export COMMON_LDFLAGS=""
    export BUILD_SUFFIX=""
    ;;
  *)
    echo "Unknown BUILD_KIND: $BUILD_KIND (expected release|debug|profile)" >&2
    exit 1
    ;;
esac

SOURCES_DIR="$BASE_DIR/sources"
BUILD_DIR="$BASE_DIR/build$BUILD_SUFFIX"
INSTALL_DIR="$BUILD_DIR/install"
WWW_DIR="$BASE_DIR/www"
SHARED_STAMPS="$BASE_DIR/.stamps"
BUILD_STAMPS="$BUILD_DIR/.stamps"

if (( CLEAN_BUILD == 1 )); then
  rm -rf "$BUILD_DIR"
  rm -rf "$BUILD_DIR" "$WWW_DIR"
  rm -f "$SHARED_STAMPS"/cmake-probes-*.cmake
fi

mkdir -p "$SOURCES_DIR" "$BUILD_DIR" "$INSTALL_DIR" "$SHARED_STAMPS" "$BUILD_STAMPS"

NPROC="$(nproc 2>/dev/null || echo 4)"
export MAKEFLAGS="-j$NPROC"

# Keep -O2/-g/-sJSPI out of global CFLAGS/LDFLAGS so CMake try_compile probes
# run at -O0 without Binaryen wasm-opt or JSPI overhead.
export CFLAGS="-pthread -fwasm-exceptions"
export CXXFLAGS="-pthread -fwasm-exceptions"
export LDFLAGS="-pthread -fwasm-exceptions"
export LUANTI_REPO="$SOURCES_DIR/luanti"

CMAKE_GENERATOR="Unix Makefiles"
CMAKE_COMMON_FLAGS=()

log()  { printf '\n\033[1;34m[build_all]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

trap 'die "Command failed at line $LINENO: $BASH_COMMAND"' ERR

# -----------------------------------------------------------------------------
# Host preflight checks & CMake acceleration
# -----------------------------------------------------------------------------
check_host_tools() {
  local missing=()
  local cmds=(git wget sha256sum tar unzip patch cmake make python3 zstd msgfmt node)
  for c in "${cmds[@]}"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if (( WITH_CURL == 1 )) && ! command -v tclsh >/dev/null 2>&1; then
    missing+=("tclsh")
  fi
  if (( ${#missing[@]} > 0 )); then
    die "Missing required host tools: ${missing[*]}
Install on Ubuntu/Debian with:
  sudo apt-get update && sudo apt-get install -y wget python3 git build-essential cmake tclsh zip zstd gettext patch ca-certificates ninja-build ccache"
  fi

  [[ -r /etc/ssl/certs/ca-certificates.crt ]] || die "Missing /etc/ssl/certs/ca-certificates.crt (install ca-certificates)"

  NODE_FULL_PATH="$(command -v node)"
  local node_ver node_major
  node_ver="$("$NODE_FULL_PATH" --version || true)"
  node_major="${node_ver#v}"
  node_major="${node_major%%.*}"
  if [[ -z "$node_major" ]] || ! [[ "$node_major" =~ ^[0-9]+$ ]] || (( node_major < 24 )); then
    die "Node.js v24+ is required (found: ${node_ver:-none} at $NODE_FULL_PATH)"
  fi
  log "Using Node.js $node_ver ($NODE_FULL_PATH)"

  if command -v ninja >/dev/null 2>&1; then
    CMAKE_GENERATOR="Ninja"
  else
    warn "ninja not found; using Unix Makefiles (install ninja-build for faster CMake builds)"
  fi

  if command -v ccache >/dev/null 2>&1; then
    export EM_COMPILER_WRAPPER="ccache"
  else
    warn "ccache not found (install ccache to speed up rebuilds)"
  fi

  CMAKE_COMMON_FLAGS=(
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    -DCMAKE_BUILD_TYPE="$LUANTI_BUILD_TYPE"
  )
  if [[ "$LUANTI_BUILD_TYPE" == "Release" ]]; then
    CMAKE_COMMON_FLAGS+=(
      -DCMAKE_TRY_COMPILE_CONFIGURATION=Debug
      -DCMAKE_C_FLAGS_DEBUG="-O0"
      -DCMAKE_CXX_FLAGS_DEBUG="-O0"
      -DCMAKE_EXE_LINKER_FLAGS_DEBUG="-O0"
      -DCMAKE_C_FLAGS_RELEASE="$COMMON_CFLAGS -DNDEBUG"
      -DCMAKE_CXX_FLAGS_RELEASE="$COMMON_CFLAGS -DNDEBUG"
      -DCMAKE_EXE_LINKER_FLAGS_RELEASE="$COMMON_LDFLAGS"
    )
  else
    # Debug build: force try_compile to use -O0 without -g/-gsource-map/-sSAFE_HEAP
    CMAKE_COMMON_FLAGS+=(
      -DCMAKE_TRY_COMPILE_CONFIGURATION=Release
      -DCMAKE_C_FLAGS_RELEASE="-O0"
      -DCMAKE_CXX_FLAGS_RELEASE="-O0"
      -DCMAKE_EXE_LINKER_FLAGS_RELEASE="-O0"
      -DCMAKE_C_FLAGS_DEBUG="$COMMON_CFLAGS"
      -DCMAKE_CXX_FLAGS_DEBUG="$COMMON_CFLAGS"
      -DCMAKE_EXE_LINKER_FLAGS_DEBUG="$COMMON_LDFLAGS"
    )
  fi
}

# -----------------------------------------------------------------------------
# Stamp / invalidation / CMake probe cache helpers
# -----------------------------------------------------------------------------
STAGE_ORDER=(emsdk sources webshims)
if (( WITH_CURL == 1 )); then
  STAGE_ORDER+=(openssl curl)
fi
STAGE_ORDER+=(zstd libarchive libzip luanti fsroot xterm www)

stamp_path_for() {
  case "$1" in
    emsdk|sources|xterm) echo "$SHARED_STAMPS/$1.ok" ;;
    *)                   echo "$BUILD_STAMPS/$1.ok" ;;
  esac
}

invalidate_stages() {
  if [[ -n "$RECONFIGURE_STAGE" ]]; then
    case "$RECONFIGURE_STAGE" in
      zstd)       rm -rf "$BUILD_DIR/zstd-build" ;;
      libarchive) rm -rf "$BUILD_DIR/libarchive-build" ;;
      webshims)   rm -rf "$BUILD_DIR/webshims-build" ;;
      libzip)     rm -rf "$BUILD_DIR/libzip-build" ;;
      openssl)    rm -rf "$BUILD_DIR/openssl" ;;
      curl)       rm -rf "$BUILD_DIR/curl-build" "$BUILD_DIR/curl" ;;
      luanti)     rm -rf "$BUILD_DIR/luanti" ;;
      fsroot)     rm -rf "$BUILD_DIR/fsroot" "$BUILD_DIR/certsroot" "$BUILD_DIR/fsroot.tar"* "$BUILD_DIR/certs.tar"* ;;
      www)        rm -rf "$WWW_DIR" ;;
    esac
  fi

  if [[ -n "$FROM_STAGE" ]]; then
    local found=0 s
    for s in "${STAGE_ORDER[@]}"; do
      if [[ "$s" == "$FROM_STAGE" ]]; then
        found=1
      fi
      if (( found == 1 )); then
        rm -f "$(stamp_path_for "$s")"
      fi
    done
    (( found == 1 )) || die "Unknown stage '$FROM_STAGE'. Valid stages: ${STAGE_ORDER[*]}"
  fi
}

run_stage() {
  local name="$1"
  local fn="$2"
  local extra_check="${3:-}"
  local stamp
  stamp="$(stamp_path_for "$name")"

  if [[ -f "$stamp" ]]; then
    if [[ -z "$extra_check" ]] || eval "$extra_check"; then
      log "Skipping '$name' (already done)"
      return 0
    fi
    warn "Stamp exists for '$name' but expected output is missing; rebuilding '$name'"
    rm -f "$stamp"
  fi

  log "=== Stage: $name ==="
  local t0=$SECONDS
  "$fn"
  date -u +"%Y-%m-%dT%H:%M:%SZ" > "$stamp"
  log "Completed '$name' in $((SECONDS - t0))s"
}

cmake_probe_args() {
  local stage="$1"
  local probe_file="$SHARED_STAMPS/cmake-probes-$stage.cmake"
  if [[ -f "$probe_file" ]]; then
    printf '%s\n' "-C" "$probe_file"
  fi
}

save_cmake_probes() {
  local stage="$1"
  local cache="$2"
  local probe_file="$SHARED_STAMPS/cmake-probes-$stage.cmake"
  [[ -f "$cache" && ! -f "$probe_file" ]] || return 0

  python3 - "$cache" "$probe_file.tmp" << 'PY'
import re, sys

cache_path, out_path = sys.argv[1], sys.argv[2]
internals = {}
pat = re.compile(r'^([A-Za-z0-9_]+):INTERNAL=(.*)$')
with open(cache_path, 'r', encoding='utf-8', errors='replace') as f:
    for line in f:
        m = pat.match(line.rstrip('\n'))
        if m:
            internals[m.group(1)] = m.group(2)

prefixes = (
    'HAVE_', 'SIZEOF_', 'CHECK_', 'CMAKE_HAVE_', 'SAFE_',
    'STRERROR_', 'TIME_WITH_', 'MAJOR_IN_', 'ICONV_', 'POSIX_'
)
keep = {}
for k, v in internals.items():
    if (k.startswith(prefixes) or f'HAVE_{k}' in internals) and ']=]' not in v:
        if k.startswith('CMAKE_') and not k.startswith('CMAKE_HAVE_'):
            continue
        keep[k] = v

with open(out_path, 'w', encoding='utf-8') as out:
    for k in sorted(keep):
        out.write(f'set({k} [=[{keep[k]}]=] CACHE INTERNAL "")\n')
PY
  mv "$probe_file.tmp" "$probe_file"
}

# -----------------------------------------------------------------------------
# Download & source helpers (atomic + idempotent)
# -----------------------------------------------------------------------------
getsource() {
  local url="$1"
  local hsh="$2"
  local filename
  filename="$(basename -- "${url%%\?*}")"
  local dest="$SOURCES_DIR/$filename"

  if [[ -f "$dest" ]]; then
    if sha256sum "$dest" | grep -q "^$hsh"; then
      return 0
    fi
    warn "Existing $filename failed sha256; re-downloading"
    rm -f "$dest"
  fi

  rm -f "$dest.tmp"
  wget "$url" -O "$dest.tmp"
  if ! sha256sum "$dest.tmp" | grep -q "^$hsh"; then
    rm -f "$dest.tmp"
    die "Wrong sha256 checksum for $filename"
  fi
  mv "$dest.tmp" "$dest"
}

strip_ext() {
  local filename="$1"
  case "$filename" in
    *.tar.gz)  echo "${filename%.tar.gz}" ;;
    *.tar.xz)  echo "${filename%.tar.xz}" ;;
    *.tar.bz2) echo "${filename%.tar.bz2}" ;;
    *.tgz)     echo "${filename%.tgz}" ;;
    *.zip)     echo "${filename%.zip}" ;;
    *)         echo "$filename" ;;
  esac
}

unpack_source_once() {
  local prefix="$1"
  local target="$BUILD_DIR/$prefix"

  if [[ -f "$target/.unpacked" ]]; then
    return 0
  fi

  shopt -s nullglob
  local matches=("$SOURCES_DIR/$prefix"*)
  shopt -u nullglob
  (( ${#matches[@]} == 1 )) || die "unpack_source_once $prefix: expected 1 archive in $SOURCES_DIR, found ${#matches[@]}"

  local archive="${matches[0]}"
  local filename dirname
  filename="$(basename -- "$archive")"
  dirname="$(strip_ext "$filename")"

  rm -rf "$target" "$BUILD_DIR/$dirname"
  (
    cd "$BUILD_DIR"
    case "$filename" in
      *.tar.gz|*.tar.bz2|*.tar.xz|*.tgz) tar xf "$archive" ;;
      *.zip)                             unzip -q "$archive" ;;
      *) die "Not sure how to unpack: $filename" ;;
    esac
    [[ -d "$dirname" ]] || die "Unpacking $filename did not produce $dirname"
    if [[ "$dirname" != "$prefix" ]]; then
      mv "$dirname" "$prefix"
    fi
  )
  touch "$target/.unpacked"
}

getrepo() {
  local dirname="$1"
  local url="$2"
  local rev="$3"
  local repo_dir="$SOURCES_DIR/$dirname"

  if [[ ! -d "$repo_dir/.git" ]]; then
    rm -rf "$repo_dir"
    git clone "$url" "$repo_dir"
    git -C "$repo_dir" checkout "$rev"
  fi

  local currev
  currev="$(git -C "$repo_dir" rev-parse HEAD)"
  if [[ "$currev" != "$rev" ]]; then
    if [[ -z "$(git -C "$repo_dir" status --porcelain)" ]]; then
      log "Updating $dirname from $currev to $rev..."
      git -C "$repo_dir" fetch --all --tags
      git -C "$repo_dir" checkout "$rev"
    else
      die "sources/$dirname is at $currev (expected $rev) and has uncommitted changes"
    fi
  fi
}

# -----------------------------------------------------------------------------
# Stage definitions
# -----------------------------------------------------------------------------
stage_emsdk() {
  rm -f "$SHARED_STAMPS"/cmake-probes-*.cmake
  rm -rf "$BASE_DIR/emsdk"
  git clone https://github.com/emscripten-core/emsdk.git "$BASE_DIR/emsdk"

  (
    cd "$BASE_DIR/emsdk"
    ./emsdk install 6.0.8
    ./emsdk activate 6.0.8

    local p
    for p in \
      emsdk_dirperms.patch \
      emsdk_openat.patch \
      emsdk_libegl.patch \
      emsdk_jspi.patch \
      emsdk_wasmfs_opfs.patch \
      emsdk_wasmfs_opfs_subdir.patch
    do
      patch -p1 < "$BASE_DIR/$p"
    done

    sed -i "s|^NODE_JS = .*|NODE_JS = '$NODE_FULL_PATH'|" .emscripten
    # Clear ports/cache once on fresh emsdk before building patched libhtml5
    ./upstream/emscripten/emcc --clear-cache --clear-ports
    ./upstream/emscripten/embuilder build libhtml5 --force
  )
}

activate_emsdk() {
  [[ -f "$BASE_DIR/emsdk/emsdk_env.sh" ]] || die "emsdk_env.sh missing"
  set +u
  # shellcheck disable=SC1091
  source "$BASE_DIR/emsdk/emsdk_env.sh" >/dev/null
  set -u
  export EMSDK_ROOT="$EMSDK"
  export EMSDK_SYSLIB="${EMSDK_ROOT}/upstream/emscripten/cache/sysroot/lib/wasm32-emscripten"
  export EMSDK_SYSINCLUDE="${EMSDK_ROOT}/upstream/emscripten/cache/sysroot/include"
}

stage_sources() {
  getsource "https://www.libarchive.org/downloads/libarchive-3.6.1.tar.xz" 5a411aceb978f43e626f0c2d1812ddd8807b645ed892453acabd532376c148e6
  getsource "https://github.com/nih-at/libzip/releases/download/v1.11.4/libzip-1.11.4.tar.xz" 8a247f57d1e3e6f6d11413b12a6f28a9d388de110adc0ec608d893180ed7097b

  if (( WITH_CURL == 1 )); then
    getsource "https://www.openssl.org/source/openssl-1.1.1n.tar.gz" 40dceb51a4f6a5275bde0e6bf20ef4b91bfc32ed57c0552e2e8e15463372b17a
    getsource "https://curl.se/download/curl-7.82.0.tar.bz2" 46d9a0400a33408fd992770b04a44a7434b3036f2e8089ac28b57573d59d371f
  fi

  getrepo zstd          "https://github.com/facebook/zstd.git"          f8745da6ff1ad1e7bab384bd1f9d742439278e99
  getrepo webshims      "https://github.com/paradust7/webshims.git"     70653a91c974aa2b20df09a39f858d92e663c1a7
  getrepo luanti        "https://github.com/paradust7/luanti.git"       6f532b5ed03a6aa70091412114b5dde3d33c6f87
  getrepo minetest_game "https://github.com/luanti-org/minetest_game.git" master
}

stage_openssl() {
  rm -rf "$BUILD_DIR/openssl"
  unpack_source_once openssl
  (
    cd "$BUILD_DIR/openssl"
    "$SOURCES_DIR/webshims/src/emsocket/wrap.py" .
    patch -p1 < "$BASE_DIR/openssl.patch"

    export CFLAGS="$COMMON_CFLAGS $CFLAGS -I${INSTALL_DIR}/include -DPEDANTIC"
    export CXXFLAGS="$COMMON_CFLAGS $CXXFLAGS -I${INSTALL_DIR}/include -DPEDANTIC"
    export LDFLAGS="$COMMON_LDFLAGS $LDFLAGS -L${INSTALL_DIR}/lib -lemsocket -sDEFAULT_TO_CXX"

    emconfigure ./Configure linux-generic64 \
      no-asm no-engine no-hw no-weak-ssl-ciphers no-dtls no-shared no-dso \
      -DPEDANTIC --prefix="$INSTALL_DIR" --openssldir=/ssl

    sed -i 's|^CROSS_COMPILE.*$|CROSS_COMPILE=|g' Makefile
    emmake make build_generated
    emmake make libssl.a libcrypto.a
    mkdir -p "$INSTALL_DIR/include" "$INSTALL_DIR/lib"
    cp -r include/openssl "$INSTALL_DIR/include/"
    cp libcrypto.a libssl.a "$INSTALL_DIR/lib/"
  )
}

stage_curl() {
  unpack_source_once curl
  if [[ ! -f "$BUILD_DIR/curl/.wrapped" ]]; then
    "$SOURCES_DIR/webshims/src/emsocket/wrap.py" "$BUILD_DIR/curl"
    touch "$BUILD_DIR/curl/.wrapped"
  fi
  (
    mkdir -p "$BUILD_DIR/curl-build"
    cd "$BUILD_DIR/curl-build"

    export CFLAGS="$CFLAGS -I${INSTALL_DIR}/include --use-port=zlib"
    export CXXFLAGS="$CXXFLAGS -I${INSTALL_DIR}/include --use-port=zlib"
    export LDFLAGS="$LDFLAGS -L${INSTALL_DIR}/lib -lemsocket -sDEFAULT_TO_CXX --use-port=zlib"

    if [[ ! -f CMakeCache.txt ]]; then
      local PROBE_ARGS=()
      mapfile -t PROBE_ARGS < <(cmake_probe_args curl)
      emcmake cmake -G "$CMAKE_GENERATOR" ${PROBE_ARGS[@]+"${PROBE_ARGS[@]}"} "${CMAKE_COMMON_FLAGS[@]}" \
        -DCURL_ZLIB=ON \
        -DOPENSSL_SSL_LIBRARY="$INSTALL_DIR/lib/libssl.a" \
        -DOPENSSL_CRYPTO_LIBRARY="$INSTALL_DIR/lib/libcrypto.a" \
        -DOPENSSL_INCLUDE_DIR="$INSTALL_DIR/include" \
        -DBUILD_CURL_EXE=OFF \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
        "$BUILD_DIR/curl"
      save_cmake_probes curl CMakeCache.txt
    fi
    cmake --build . -j"$NPROC"
    cmake --install .
  )
}

stage_zstd() {
  (
    mkdir -p "$BUILD_DIR/zstd-build"
    cd "$BUILD_DIR/zstd-build"

    # zstd makefile cannot handle MAKEFLAGS parallelism safely
    export MAKEFLAGS=""
    export CFLAGS="$CFLAGS -D_POSIX_SOURCE=1"
    export CXXFLAGS="$CXXFLAGS -D_POSIX_SOURCE=1"

    if [[ ! -f CMakeCache.txt ]]; then
      local PROBE_ARGS=()
      mapfile -t PROBE_ARGS < <(cmake_probe_args zstd)
      emcmake cmake -G "$CMAKE_GENERATOR" ${PROBE_ARGS[@]+"${PROBE_ARGS[@]}"} "${CMAKE_COMMON_FLAGS[@]}" \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
        -DBUILD_SHARED_LIBS=OFF \
        -DZSTD_BUILD_SHARED=OFF \
        -DZSTD_BUILD_STATIC=ON \
        "$SOURCES_DIR/zstd/build/cmake"
      save_cmake_probes zstd CMakeCache.txt
    fi
    if [[ "$CMAKE_GENERATOR" == "Ninja" ]]; then
      cmake --build . -j"$NPROC"
    else
      cmake --build .
    fi
    cmake --install .
  )
}

stage_libarchive() {
  unpack_source_once libarchive
  (
    mkdir -p "$BUILD_DIR/libarchive-build"
    cd "$BUILD_DIR/libarchive-build"

    export CFLAGS="$CFLAGS --use-port=zlib"
    export CXXFLAGS="$CXXFLAGS --use-port=zlib"
    export LDFLAGS="$LDFLAGS -L${INSTALL_DIR}/lib --use-port=zlib"

    if [[ ! -f CMakeCache.txt ]]; then
      local PROBE_ARGS=()
      mapfile -t PROBE_ARGS < <(cmake_probe_args libarchive)
      # libarchive 3.6.1 defines both `archive` and `archive_static` outputting libarchive.a,
      # which Ninja rejects at generate time; use Unix Makefiles and build them sequentially.
      emcmake cmake -G "Unix Makefiles" ${PROBE_ARGS[@]+"${PROBE_ARGS[@]}"} "${CMAKE_COMMON_FLAGS[@]}" \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
        -DCMAKE_PREFIX_PATH="$INSTALL_DIR" \
        -DZSTD_INCLUDE_DIR="$INSTALL_DIR/include" \
        -DZSTD_LIBRARY="$INSTALL_DIR/lib/libzstd.a" \
        -DBUILD_SHARED_LIBS=OFF \
        -DENABLE_TAR=OFF -DENABLE_TAR_SHARED=OFF \
        -DENABLE_CAT=OFF -DENABLE_CAT_SHARED=OFF \
        -DENABLE_CPIO=OFF -DENABLE_CPIO_SHARED=OFF \
        -DPOSIX_REGEX_LIB=LIBC \
        -DENABLE_XATTR=OFF -DENABLE_ACL=OFF \
        -DENABLE_NETTLE=OFF -DENABLE_LZO=OFF -DENABLE_CNG=OFF -DENABLE_LZ4=OFF \
        -DENABLE_LIBXML2=OFF -DENABLE_EXPAT=OFF \
        -DENABLE_ZSTD=ON -DENABLE_ZLIB=ON -DENABLE_TEST=OFF \
        "$BUILD_DIR/libarchive"
      save_cmake_probes libarchive CMakeCache.txt
    fi
    cmake --build . -j"$NPROC" --target archive
    cmake --build . -j"$NPROC" --target archive_static
    cmake --install .
  )
}

stage_webshims() {
  (
    mkdir -p "$BUILD_DIR/webshims-build"
    cd "$BUILD_DIR/webshims-build"

    if [[ ! -f CMakeCache.txt ]]; then
      local PROBE_ARGS=()
      mapfile -t PROBE_ARGS < <(cmake_probe_args webshims)
      emcmake cmake -G "$CMAKE_GENERATOR" ${PROBE_ARGS[@]+"${PROBE_ARGS[@]}"} "${CMAKE_COMMON_FLAGS[@]}" \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
        "$SOURCES_DIR/webshims"
      save_cmake_probes webshims CMakeCache.txt
    fi
    cmake --build . -j"$NPROC"
    cmake --install .
  )
}

stage_libzip() {
  unpack_source_once libzip
  (
    mkdir -p "$BUILD_DIR/libzip-build"
    cd "$BUILD_DIR/libzip-build"

    export CPPFLAGS="${CPPFLAGS-} -I${INSTALL_DIR}/include --use-port=zlib"
    export CFLAGS="$CFLAGS --use-port=zlib"
    export LDFLAGS="$LDFLAGS -L${INSTALL_DIR}/lib --use-port=zlib"

    if [[ ! -f CMakeCache.txt ]]; then
      local PROBE_ARGS=()
      mapfile -t PROBE_ARGS < <(cmake_probe_args libzip)
      emcmake cmake -G "$CMAKE_GENERATOR" ${PROBE_ARGS[@]+"${PROBE_ARGS[@]}"} "${CMAKE_COMMON_FLAGS[@]}" \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
        "$BUILD_DIR/libzip"
      save_cmake_probes libzip CMakeCache.txt
    fi
    cmake --build . -j"$NPROC"
    cmake --install .
  )
}

stage_luanti() {
  (
    mkdir -p "$BUILD_DIR/luanti"
    cd "$BUILD_DIR/luanti"

    local EMSDK_PORTS="--use-port=zlib --use-port=libjpeg --use-port=libpng --use-port=freetype --use-port=ogg --use-port=vorbis --use-port=sqlite3"
    local EMSDK_COMPILE="-sUSE_SDL=2 $EMSDK_PORTS"
    local EMSDK_CANVAS="-sPROXY_TO_PTHREAD=1 -sOFFSCREENCANVAS_SUPPORT=1 -sJSPI"
    local EMSDK_MODULE="-sINCOMING_MODULE_JS_API=mainScriptUrlOrBlob,canvas,monitorRunDependencies,preRun,postRun,print,printErr,setStatus,onFullScreen"
    
    local CURL_LINK_FLAGS=""
    local CURL_CMAKE_FLAGS=()
    if (( WITH_CURL == 1 )); then
      CURL_LINK_FLAGS="-lcurl -lssl -lcrypto"
      CURL_CMAKE_FLAGS=(
        -DENABLE_CURL=ON
        -DCURL_INCLUDE_DIR="$INSTALL_DIR/include"
        -DCURL_LIBRARY="$INSTALL_DIR/lib/libcurl.a"
      )
    else
      CURL_CMAKE_FLAGS=(-DENABLE_CURL=OFF)
    fi

    local EMSDK_LINK="$EMSDK_COMPILE $EMSDK_CANVAS $EMSDK_MODULE -sPTHREAD_POOL_SIZE=22 -s EXPORTED_RUNTIME_METHODS=ccall,cwrap -s INITIAL_MEMORY=2013265920 -sMIN_WEBGL_VERSION=2 -sUSE_WEBGL2 -sWASMFS=1 -L$INSTALL_DIR/lib -larchive -lzstd $CURL_LINK_FLAGS -lemsocket -lwebsocket.js"

    export CFLAGS="$CFLAGS $EMSDK_COMPILE"
    export CXXFLAGS="$CXXFLAGS $EMSDK_COMPILE"
    export LDFLAGS="$LDFLAGS $EMSDK_COMPILE"

    local LUANTI_LINKER_FLAG_VAR
    if [[ "$LUANTI_BUILD_TYPE" == "Release" ]]; then
      LUANTI_LINKER_FLAG_VAR="-DCMAKE_EXE_LINKER_FLAGS_RELEASE=$COMMON_LDFLAGS $EMSDK_LINK"
    else
      LUANTI_LINKER_FLAG_VAR="-DCMAKE_EXE_LINKER_FLAGS_DEBUG=$COMMON_LDFLAGS $EMSDK_LINK"
    fi

    if [[ ! -f dummy.o ]]; then
      echo > dummy.c
      emcc -c dummy.c -o dummy.o
    fi
    local DUMMY_OBJECT="$(pwd)/dummy.o"
    mkdir -p dummy_dir
    local DUMMY_INCLUDE_DIR="$(pwd)/dummy_dir"

    if [[ ! -f CMakeCache.txt ]]; then
      local PROBE_ARGS=()
      mapfile -t PROBE_ARGS < <(cmake_probe_args luanti)
      emcmake cmake -G "$CMAKE_GENERATOR" ${PROBE_ARGS[@]+"${PROBE_ARGS[@]}"} "${CMAKE_COMMON_FLAGS[@]}" \
        "$LUANTI_LINKER_FLAG_VAR" \
        -DCMAKE_VERBOSE_MAKEFILE=ON \
        -DENABLE_SYSTEM_GMP=OFF \
        -DENABLE_GETTEXT=TRUE \
        -DRUN_IN_PLACE=TRUE \
        -DENABLE_GLES=TRUE \
        -DENABLE_UPDATE_CHECKER=0 \
        -DINSTALL_DEVTEST=TRUE \
        "${CURL_CMAKE_FLAGS[@]}" \
        -DFREETYPE_LIBRARY="$DUMMY_OBJECT" \
        -DPNG_LIBRARY="$DUMMY_OBJECT" \
        -DVORBISFILE_LIBRARY="$DUMMY_OBJECT" \
        -DSQLITE3_LIBRARY="$DUMMY_OBJECT" \
        -DOPENGLES2_INCLUDE_DIR="$DUMMY_INCLUDE_DIR" \
        -DOPENGLES2_LIBRARY="$DUMMY_OBJECT" \
        -DZSTD_LIBRARY="$INSTALL_DIR/lib/libzstd.a" \
        -DZSTD_INCLUDE_DIR="$INSTALL_DIR/include" \
        -DEGL_LIBRARY="$DUMMY_OBJECT" \
        -DEGL_INCLUDE_DIR="$DUMMY_INCLUDE_DIR" \
        -DCMAKE_INSTALL_PREFIX="$BUILD_DIR/luanti-install" \
        -DLIBZIP_LIBRARY="$INSTALL_DIR/lib/libzip.a" \
        -DLIBZIP_INCLUDE_DIR="$INSTALL_DIR/include" \
        "$SOURCES_DIR/luanti"
      save_cmake_probes luanti CMakeCache.txt
    fi

    rm -rf "$BUILD_DIR/luanti-install"
    cmake --build . -j"$NPROC"
    cmake --install . --prefix "$BUILD_DIR/luanti-install"
    rm -f "$(stamp_path_for fsroot)" "$(stamp_path_for www)"
  )
}

stage_fsroot() {
  (
    cd "$BUILD_DIR"
    rm -rf fsroot
    mkdir fsroot
    cp -a "luanti-install" fsroot/luanti

    # Fallback: ensure minetest_game is available even if stage_sources was skipped
    if [[ ! -d "$SOURCES_DIR/minetest_game" ]]; then
      log "Cloning minetest_game..."
      git clone --depth 1 https://github.com/luanti-org/minetest_game.git "$SOURCES_DIR/minetest_game"
    fi

    (
      cd fsroot/luanti
      rm -rf bin unix
      mkdir -p bin cache games
      echo "This is here to ensure bin exists" > bin/readme.txt

      # 1. Install minetest_game (excluding .git to keep the pack small)
      log "Installing minetest_game into games/minetest_game..."
      mkdir -p games/minetest_game
      tar -C "$SOURCES_DIR/minetest_game" --exclude=".git" -cf - . | tar -C games/minetest_game -xf -

      # 2. Install devtest (if present in luanti source)
      if [[ -d "$SOURCES_DIR/luanti/games/devtest" ]]; then
        log "Installing devtest into games/devtest..."
        mkdir -p games/devtest
        tar -C "$SOURCES_DIR/luanti/games/devtest" --exclude=".git" -cf - . | tar -C games/devtest -xf -
      fi

      # 3. Configure default settings for WebAssembly
      cat > cache/common.conf << 'EOF'
update_last_checked = disabled
no_mtg_notification = true
no_keycode_migration_warning = true
default_game = minetest_game
sqlite_synchronous = 0
EOF
    )

    # Prepare SSL certificates
    rm -rf certsroot
    mkdir -p certsroot/etc/ssl/certs certsroot/ssl/certs
    cat /etc/ssl/certs/ca-certificates.crt > certsroot/etc/ssl/certs/ca-certificates.crt
    cat /etc/ssl/certs/ca-certificates.crt > certsroot/ssl/cert.pem
    cp certsroot/ssl/cert.pem certsroot/ssl/certs/ca-certificates.crt

    # Pack archives with zstd
    rm -f fsroot.tar certs.tar fsroot.tar.zst certs.tar.zst
    tar cf fsroot.tar -C fsroot .
    tar cf certs.tar -C certsroot .
    # shellcheck disable=SC2086
    zstd -f -T0 $ZSTD_OPTS fsroot.tar
    # shellcheck disable=SC2086
    zstd -f -T0 $ZSTD_OPTS certs.tar

    # Invalidate stage_www so the new base.pack is immediately copied to www/
    rm -f "$(stamp_path_for www)"
  )
}

stage_xterm() {
  local XTERM_VERSION="6.0.0"
  local XTERM_FIT_VERSION="0.11.0"

  getsource "https://registry.npmjs.org/@xterm/xterm/-/xterm-$XTERM_VERSION.tgz" \
    908e66e04af6c8dc6b00dd3b54de088e2e81e5ed866284fd6c2fb3c2d1c7a3f6
  getsource "https://registry.npmjs.org/@xterm/addon-fit/-/addon-fit-$XTERM_FIT_VERSION.tgz" \
    26003b4517a132b64e4ff228fd88a5fda3fff5e606c76093f6dcff772e9ecec0

  local XTERM_DIR="$SOURCES_DIR/xterm"
  rm -rf "$XTERM_DIR"
  mkdir -p "$XTERM_DIR"

  tar xzf "$SOURCES_DIR/xterm-$XTERM_VERSION.tgz" -O "package/lib/xterm.js" > "$XTERM_DIR/xterm.js"
  tar xzf "$SOURCES_DIR/xterm-$XTERM_VERSION.tgz" -O "package/css/xterm.css" > "$XTERM_DIR/xterm.css"
  tar xzf "$SOURCES_DIR/xterm-$XTERM_VERSION.tgz" -O "package/LICENSE" > "$XTERM_DIR/LICENSE.xterm"
  tar xzf "$SOURCES_DIR/addon-fit-$XTERM_FIT_VERSION.tgz" -O "package/lib/addon-fit.js" > "$XTERM_DIR/addon-fit.js"
  tar xzf "$SOURCES_DIR/addon-fit-$XTERM_FIT_VERSION.tgz" -O "package/LICENSE" > "$XTERM_DIR/LICENSE.addon-fit"
}

stage_www() {
  local SEEDFILE RELEASE_UUID RELEASE_DIR PACKS_DIR
  SEEDFILE="$(mktemp)"
  dd status=none if=/dev/urandom bs=64 count=1 > "$SEEDFILE"
  RELEASE_UUID="$(md5sum -b "$SEEDFILE" | cut -b -12)"
  rm -f "$SEEDFILE"

  RELEASE_DIR="$WWW_DIR/$RELEASE_UUID"
  PACKS_DIR="$RELEASE_DIR/packs"

  log "Installing release $RELEASE_UUID into $WWW_DIR"
  rm -rf "$WWW_DIR"
  mkdir -p "$RELEASE_DIR" "$PACKS_DIR"

  cp "$BUILD_DIR/luanti/bin/luanti.js" "$RELEASE_DIR/"
  cp "$BUILD_DIR/luanti/bin/luanti.wasm" "$RELEASE_DIR/"
  if [[ -f "$BUILD_DIR/luanti/bin/luanti.wasm.map" ]]; then
    cp "$BUILD_DIR/luanti/bin/luanti.wasm.map" "$RELEASE_DIR/"
  fi

  apply_substitutions() {
    sed "s/%__RELEASE_UUID__%/$RELEASE_UUID/g" "$BASE_DIR/static/$1" > "$2"
  }

  apply_substitutions htaccess_toplevel     "$WWW_DIR/.htaccess"
  apply_substitutions index.html            "$WWW_DIR/index.html"
  apply_substitutions coi-serviceworker.js  "$WWW_DIR/coi-serviceworker.js"
  apply_substitutions htaccess_release      "$RELEASE_DIR/.htaccess"
  apply_substitutions launcher.js           "$RELEASE_DIR/launcher.js"
  apply_substitutions worker.js             "$RELEASE_DIR/worker.js"
  apply_substitutions lockworker.js         "$RELEASE_DIR/lockworker.js"
  apply_substitutions htaccess_packs        "$PACKS_DIR/.htaccess"

  cp -a "$SOURCES_DIR/xterm" "$RELEASE_DIR/xterm"
  cp "$BUILD_DIR/fsroot.tar.zst" "$PACKS_DIR/base.pack"
  cp "$BUILD_DIR/certs.tar.zst" "$PACKS_DIR/certs.pack"

  if [[ -f "$BASE_DIR/deploy.sh" ]]; then
    "$BASE_DIR/deploy.sh" "$RELEASE_UUID"
  fi
}

# -----------------------------------------------------------------------------
# Main execution
# -----------------------------------------------------------------------------
check_host_tools
invalidate_stages

run_stage emsdk      stage_emsdk      '[[ -f "$BASE_DIR/emsdk/emsdk_env.sh" ]]'
activate_emsdk
run_stage sources stage_sources '[[ -d "$SOURCES_DIR/luanti/.git" && -d "$SOURCES_DIR/minetest_game/.git" && -d "$SOURCES_DIR/webshims/.git" && -d "$SOURCES_DIR/zstd/.git" ]]'

run_stage webshims   stage_webshims   '[[ -f "$INSTALL_DIR/lib/libemsocket.a" ]]'

if (( WITH_CURL == 1 )); then
  run_stage openssl  stage_openssl    '[[ -f "$INSTALL_DIR/lib/libssl.a" && -f "$INSTALL_DIR/lib/libcrypto.a" ]]'
  run_stage curl     stage_curl       '[[ -f "$INSTALL_DIR/lib/libcurl.a" ]]'
fi

run_stage zstd       stage_zstd       '[[ -f "$INSTALL_DIR/lib/libzstd.a" ]]'
run_stage libarchive stage_libarchive '[[ -f "$INSTALL_DIR/lib/libarchive.a" ]]'
run_stage libzip     stage_libzip     '[[ -f "$INSTALL_DIR/lib/libzip.a" ]]'
run_stage luanti     stage_luanti     '[[ -f "$BUILD_DIR/luanti/bin/luanti.wasm" && -d "$BUILD_DIR/luanti-install" ]]'
run_stage fsroot     stage_fsroot     '[[ -f "$BUILD_DIR/fsroot.tar.zst" && -f "$BUILD_DIR/certs.tar.zst" ]]'
run_stage xterm      stage_xterm      '[[ -f "$SOURCES_DIR/xterm/xterm.js" ]]'
run_stage www        stage_www        '[[ -f "$WWW_DIR/index.html" ]]'

log "All done! Output is in $WWW_DIR"