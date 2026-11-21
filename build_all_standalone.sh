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
  emsdk, sources, webshims, [openssl, curl,] zstd, libarchive, libzip, luanti, mapgen_editor, fsroot, xterm, monaco, www

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
STAGE_ORDER+=(zstd libarchive libzip luanti mapgen_editor fsroot xterm monaco www)

stamp_path_for() {
  case "$1" in
    emsdk|sources|xterm|monaco) echo "$SHARED_STAMPS/$1.ok" ;;
    *)                          echo "$BUILD_STAMPS/$1.ok" ;;
  esac
}

invalidate_stages() {
  if [[ -n "$RECONFIGURE_STAGE" ]]; then
    case "$RECONFIGURE_STAGE" in
      zstd)          rm -rf "$BUILD_DIR/zstd-build" ;;
      libarchive)    rm -rf "$BUILD_DIR/libarchive-build" ;;
      webshims)      rm -rf "$BUILD_DIR/webshims-build" ;;
      libzip)        rm -rf "$BUILD_DIR/libzip-build" ;;
      openssl)       rm -rf "$BUILD_DIR/openssl" ;;
      curl)          rm -rf "$BUILD_DIR/curl-build" "$BUILD_DIR/curl" ;;
      luanti)        rm -rf "$BUILD_DIR/luanti" ;;
      mapgen_editor) rm -rf "$BUILD_DIR/mapgen_editor" ;;
      fsroot)        rm -rf "$BUILD_DIR/fsroot" "$BUILD_DIR/certsroot" "$BUILD_DIR/fsroot.tar"* "$BUILD_DIR/certs.tar"* ;;
      monaco)        rm -rf "$SOURCES_DIR/monaco" ;;
      www)           rm -rf "$WWW_DIR" ;;
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

    # Only build/install the static library; shared libarchive.so fails against non-PIC libz.a
    cmake --build . -j"$NPROC" --target archive_static
    mkdir -p "$INSTALL_DIR/include" "$INSTALL_DIR/lib"
    cp -f libarchive/libarchive.a "$INSTALL_DIR/lib/libarchive.a"
    cp -f "$BUILD_DIR/libarchive/libarchive/archive.h" "$INSTALL_DIR/include/"
    cp -f "$BUILD_DIR/libarchive/libarchive/archive_entry.h" "$INSTALL_DIR/include/"
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
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_TOOLS=OFF \
        -DBUILD_REGRESS=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_DOC=OFF \
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

stage_mapgen_editor() {
  local ME_DIR="$BUILD_DIR/mapgen_editor"
  local WORLD_DIR="$ME_DIR/world"
  local MOD_DIR="$WORLD_DIR/worldmods/mapgen_edit"

  rm -rf "$ME_DIR"
  mkdir -p "$MOD_DIR"

  # 1. Preconfigured dummy-backend singlenode minetest_game world
  cat > "$WORLD_DIR/world.mt" << 'EOF'
gameid = minetest_game
backend = dummy
player_backend = dummy
auth_backend = dummy
mod_storage_backend = dummy
creative_mode = true
enable_damage = false
EOF

  cat > "$WORLD_DIR/map_meta.txt" << 'EOF'
mg_name = singlenode
seed = 1337
chunksize = 5
water_level = 1
mg_flags = nocaves, nodungeons, light, decorations, biomes
[end_of_params]
EOF

  # 2. mapgen_edit mod definition
  cat > "$MOD_DIR/mod.conf" << 'EOF'
name = mapgen_edit
description = Live-reloading mapgen editor via world mapgen.lua and IPC
depends = default
EOF

  # 3. Starter mapgen (reuses data_buf so Lua allocates 0 new tables per chunk)
  cat > "$MOD_DIR/default_mapgen.lua" << 'EOF'
-- Live Mapgen Editor (runs on async mapgen threads)
-- Press Ctrl+S in the Monaco editor to hot-reload and regenerate the world.

local c_stone = core.get_content_id("default:stone")
local c_dirt  = core.get_content_id("default:dirt")
local c_grass = core.get_content_id("default:dirt_with_grass")
local c_sand  = core.get_content_id("default:sand")
local c_water = core.get_content_id("default:water_source")
local data_buf = {}

core.register_on_generated(function(vm, minp, maxp, blockseed)
	local emin, emax = vm:get_emerged_area()
	local area = VoxelArea:new({ MinEdge = emin, MaxEdge = emax })
	local data = vm:get_data(data_buf)

	local sea_level = 2

	for z = minp.z, maxp.z do
		for x = minp.x, maxp.x do
			local h = math.floor(
				4
				+ 7 * math.sin(x * 0.045) * math.cos(z * 0.045)
				+ 3 * math.sin((x + z) * 0.11)
			)

			local top_y = math.max(h, sea_level)
			local y0 = math.max(minp.y, -48)
			local y1 = math.min(maxp.y, top_y)

			for y = y0, y1 do
				local vi = area:index(x, y, z)
				if y <= h then
					if y == h then
						data[vi] = (h <= sea_level + 1) and c_sand or c_grass
					elseif y >= h - 3 then
						data[vi] = (h <= sea_level + 1) and c_sand or c_dirt
					else
						data[vi] = c_stone
					end
				elseif y <= sea_level then
					data[vi] = c_water
				end
			end
		end
	end

	vm:set_data(data)
end)
EOF

  # 4. Mapgen thread script (runs in each async emerge Lua state)
  cat > "$MOD_DIR/mapgen_env.lua" << 'EOF'
local active_version = -1
local active_hash = ""
local active_fn = nil
local seen_version = -1
local gc_chunks = 0

local function compile_mapgen(code)
	local chunk, syntax_err = loadstring(code, "@mapgen.lua")
	if not chunk then
		return nil, "Syntax error: " .. tostring(syntax_err)
	end

	local captured_fn = nil
	local core_proxy = setmetatable({
		register_on_generated = function(fn)
			if type(fn) ~= "function" then
				error("register_on_generated expects a function", 2)
			end
			captured_fn = fn
		end,
	}, { __index = core })

	local env = setmetatable({
		core = core_proxy,
		minetest = core_proxy,
	}, { __index = _G })

	setfenv(chunk, env)
	local ok, ret = pcall(chunk)
	if not ok then
		return nil, "Init error: " .. tostring(ret)
	end

	local fn = captured_fn
	if not fn and type(ret) == "function" then
		fn = ret
	end
	if not fn and type(env.generate) == "function" then
		fn = env.generate
	end
	if type(fn) ~= "function" then
		return nil, "mapgen.lua must call core.register_on_generated(fn), define generate(vm, minp, maxp, blockseed), or return a function"
	end
	return fn, nil
end

core.register_on_generated(function(vm, minp, maxp, blockseed)
	local pkt = core.ipc_get("mapgen_edit:script")
	if pkt and pkt.version ~= seen_version then
		seen_version = pkt.version
		local new_fn, err = compile_mapgen(pkt.code)
		if new_fn then
			active_fn = new_fn
			active_version = pkt.version
			active_hash = pkt.hash or ""
			core.ipc_set("mapgen_edit:status", {
				version = pkt.version,
				hash = active_hash,
				ok = true,
			})
		else
			-- Keep existing active_fn intact!
			core.log("error", "[mapgen_edit] " .. tostring(err))
			core.ipc_set("mapgen_edit:status", {
				version = pkt.version,
				hash = active_hash,
				ok = false,
				error = tostring(err),
			})
		end
	end

	if active_fn then
		local ok, run_err = pcall(active_fn, vm, minp, maxp, blockseed)
		if not ok then
			core.log("error", "[mapgen_edit] Runtime error: " .. tostring(run_err))
			core.ipc_set("mapgen_edit:status", {
				version = active_version,
				hash = active_hash,
				ok = false,
				error = "Runtime error: " .. tostring(run_err),
			})
		end
	end

	-- Keep Lua GC heap tight across all 4 emerge threads even if user omits a buffer in vm:get_data()
	gc_chunks = gc_chunks + 1
	if gc_chunks >= 4 then
		gc_chunks = 0
		collectgarbage("collect")
	else
		collectgarbage("step", 256)
	end
end)
EOF

  # 5. Main thread controller (nonce + file polling, IPC publish, full-chunk delete_area + bounded emerge_area)
  cat > "$MOD_DIR/init.lua" << 'EOF'
local modpath = core.get_modpath("mapgen_edit")
local worldpath = core.get_worldpath()
local mapgen_path = worldpath .. "/mapgen.lua"
local nonce_path = worldpath .. "/mapgen_nonce.txt"
local status_path = worldpath .. "/mapgen_status.json"
local default_path = modpath .. "/default_mapgen.lua"

core.register_mapgen_script(modpath .. "/mapgen_env.lua")

local function read_file(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local data = f:read("*a")
	f:close()
	return data
end

local function write_file(path, data)
	local f, err = io.open(path, "wb")
	if not f then
		return false, err
	end
	f:write(data)
	f:close()
	return true
end

-- Pure arithmetic Adler-32 + length (matches JS codeHash exactly)
local function code_hash(str)
	local a, b = 1, 0
	local MOD = 65521
	for i = 1, #str do
		a = (a + string.byte(str, i)) % MOD
		b = (b + a) % MOD
	end
	return string.format("%08x:%d", b * 65536 + a, #str)
end

local function json_escape(s)
	s = tostring(s or "")
	s = s:gsub("\\", "\\\\")
	s = s:gsub('"', '\\"')
	s = s:gsub("\n", "\\n")
	s = s:gsub("\r", "\\r")
	s = s:gsub("\t", "\\t")
	return s
end

local function write_status(tbl)
	local err_val = tbl.error and ('"' .. json_escape(tbl.error) .. '"') or "null"
	local json = string.format(
		'{"version":%d,"hash":"%s","nonce":"%s","ok":%s,"error":%s,"ts":%d}\n',
		tonumber(tbl.version) or 0,
		json_escape(tbl.hash or ""),
		json_escape(tbl.nonce or ""),
		tbl.ok and "true" or "false",
		err_val,
		os.time()
	)
	write_file(status_path, json)
end

-- Align to exact 80-node mapchunk boundaries (chunksize = 5, offset = -32)
local function chunk_snap_down(v)
	return math.floor((v + 32) / 80) * 80 - 32
end

local function chunk_snap_up(v)
	return math.floor((v + 32) / 80) * 80 + 47
end

local visited_min = { x = -112, y = -112, z = -112 }
local visited_max = { x =  127, y =  127, z =  127 }

local function expand_visited(pos, r)
	r = r or 128
	visited_min.x = math.min(visited_min.x, chunk_snap_down(pos.x - r))
	visited_min.y = math.min(visited_min.y, chunk_snap_down(math.max(-112, pos.y - 80)))
	visited_min.z = math.min(visited_min.z, chunk_snap_down(pos.z - r))
	visited_max.x = math.max(visited_max.x, chunk_snap_up(pos.x + r))
	visited_max.y = math.max(visited_max.y, chunk_snap_up(math.min(127, pos.y + 80)))
	visited_max.z = math.max(visited_max.z, chunk_snap_up(pos.z + r))
end

local function regenerate_world(radius_override)
	local emerge_r = tonumber(radius_override) or 48
	emerge_r = math.min(emerge_r, 96)

	local players = core.get_connected_players()
	local centers = {}
	if #players > 0 then
		for _, p in ipairs(players) do
			local pos = p:get_pos()
			expand_visited(pos, 128)
			table.insert(centers, pos)
		end
	else
		table.insert(centers, { x = 0, y = 16, z = 0 })
	end

	-- Delete visited/generated mapblocks so DummyMap frees old RAM and clients re-request fresh chunks
	core.delete_area(
		{
			x = chunk_snap_down(visited_min.x),
			y = chunk_snap_down(visited_min.y),
			z = chunk_snap_down(visited_min.z),
		},
		{
			x = chunk_snap_up(visited_max.x),
			y = chunk_snap_up(visited_max.y),
			z = chunk_snap_up(visited_max.z),
		}
	)

	-- Eagerly emerge a tight region around the player; Luanti streams outer chunks up to viewing_range
	for _, c in ipairs(centers) do
		local minp = {
			x = chunk_snap_down(c.x - emerge_r),
			y = chunk_snap_down(math.max(-32, c.y - 48)),
			z = chunk_snap_down(c.z - emerge_r),
		}
		local maxp = {
			x = chunk_snap_up(c.x + emerge_r),
			y = chunk_snap_up(math.min(47, c.y + 32)),
			z = chunk_snap_up(c.z + emerge_r),
		}
		core.emerge_area(minp, maxp, function(_, _, calls_remaining)
			if calls_remaining == 0 then
				core.chat_send_all("[mapgen_edit] Regenerated mapchunks.")
			end
		end)
	end
end

-- Seed world mapgen.lua from default_mapgen.lua if absent
local initial_code = read_file(mapgen_path)
if not initial_code or initial_code == "" then
	initial_code = read_file(default_path) or ""
	if initial_code ~= "" then
		write_file(mapgen_path, initial_code)
	end
end

local current_version = 0
local last_raw_code = ""
local last_nonce = read_file(nonce_path) or ""
local last_reported_status_ver = -1
local last_reported_error = ""

local function apply_code(code, nonce, force_regen)
	if not code or code == "" then
		return
	end
	local h = code_hash(code)

	local chunk, syntax_err = loadstring(code, "@mapgen.lua")
	if not chunk then
		local msg = "Syntax error: " .. tostring(syntax_err)
		core.log("error", "[mapgen_edit] " .. msg)
		core.chat_send_all("[mapgen_edit] " .. msg .. " (keeping previous mapgen)")
		write_status({
			version = current_version,
			hash = h,
			nonce = nonce or "",
			ok = false,
			error = msg,
		})
		return
	end

	current_version = current_version + 1
	core.ipc_set("mapgen_edit:script", {
		version = current_version,
		hash = h,
		code = code,
	})
	write_status({
		version = current_version,
		hash = h,
		nonce = nonce or "",
		ok = true,
		error = nil,
	})

	if force_regen then
		core.chat_send_all(string.format("[mapgen_edit] Reloaded mapgen v%d; regenerating...", current_version))
		regenerate_world()
	end
end

if initial_code ~= "" then
	last_raw_code = initial_code
	apply_code(initial_code, last_nonce, false)
end

local poll_timer = 0
core.register_globalstep(function(dtime)
	poll_timer = poll_timer + dtime
	if poll_timer < 0.2 then
		return
	end
	poll_timer = 0

	for _, p in ipairs(core.get_connected_players()) do
		expand_visited(p:get_pos(), 128)
	end

	local code = read_file(mapgen_path)
	local nonce = read_file(nonce_path) or ""
	local code_changed = (code and code ~= "" and code ~= last_raw_code)
	local nonce_changed = (nonce ~= "" and nonce ~= last_nonce)

	if (code_changed or nonce_changed) and code and code ~= "" then
		last_raw_code = code
		last_nonce = nonce
		apply_code(code, nonce, true)
	end

	local st = core.ipc_get("mapgen_edit:status")
	if st and (st.version ~= last_reported_status_ver or (st.error or "") ~= last_reported_error) then
		last_reported_status_ver = st.version or -1
		last_reported_error = st.error or ""
		write_status({
			version = st.version,
			hash = st.hash,
			nonce = last_nonce,
			ok = st.ok,
			error = st.error,
		})
		if not st.ok and st.error then
			core.chat_send_all("[mapgen_edit] " .. st.error .. " (keeping previous mapgen)")
		end
	end
end)

core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	local privs = core.get_player_privs(name)
	privs.fly = true
	privs.fast = true
	privs.noclip = true
	core.set_player_privs(name, privs)

	local p = player:get_pos()
	if math.abs(p.x) < 2 and math.abs(p.z) < 2 and p.y < 16 then
		player:set_pos({ x = 0, y = 24, z = 0 })
	end
	core.chat_send_player(name, "[mapgen_edit] Edit mapgen.lua on the right pane and press Ctrl+S to hot-reload. Commands: /regen, /reload_mapgen")
end)

core.register_chatcommand("regen", {
	params = "[radius]",
	description = "Delete mapblocks and regenerate around player",
	func = function(_, param)
		local r = tonumber(param)
		regenerate_world(r)
		return true, "Regenerating mapblocks..."
	end,
})

core.register_chatcommand("reload_mapgen", {
	description = "Force re-read of mapgen.lua and regenerate",
	func = function()
		local code = read_file(mapgen_path)
		if not code or code == "" then
			return false, "mapgen.lua is empty or missing"
		end
		last_raw_code = code
		apply_code(code, last_nonce, true)
		return true, "Reloaded mapgen.lua"
	end,
})
EOF

  # 6. Left-pane iframe target (auto-launches directly into mapgen_world)
  cat > "$ME_DIR/luanti.html" << 'HTML'
<!doctype html>
<html lang="en-us">
  <head>
    <script src="coi-serviceworker.js"></script>
    <meta charset="utf-8">
    <meta http-equiv="Content-Type" content="text/html; charset=utf-8">
    <title>Luanti Mapgen Viewport</title>
    <style>
      * { box-sizing: border-box; }
      html, body {
        margin: 0;
        padding: 0;
        width: 100%;
        height: 100%;
        overflow: hidden;
        background: radial-gradient(circle at top, #171d26 0%, #0b0e13 70%);
        color: #e6edf3;
        font-family: system-ui, -apple-system, Segoe UI, Roboto, sans-serif;
      }
      #load_screen {
        width: 100%;
        height: 100%;
        display: flex;
        align-items: center;
        justify-content: center;
        padding: 24px;
      }
      .load-card {
        width: 100%;
        max-width: 440px;
        background: rgba(22, 27, 34, 0.92);
        border: 1px solid #2d3643;
        border-radius: 10px;
        padding: 22px 24px;
        box-shadow: 0 18px 48px rgba(0, 0, 0, 0.55);
      }
      .load-header {
        display: flex;
        align-items: center;
        gap: 12px;
        margin-bottom: 14px;
      }
      .spinner {
        width: 22px;
        height: 22px;
        border: 3px solid #2b3544;
        border-top-color: #3b82f6;
        border-radius: 50%;
        animation: spin 0.85s linear infinite;
        flex: 0 0 22px;
      }
      @keyframes spin { to { transform: rotate(360deg); } }
      .load-title {
        font-size: 16px;
        font-weight: 700;
        letter-spacing: 0.01em;
      }
      .load-subtitle {
        font-size: 12px;
        color: #94a3b8;
        margin-top: 2px;
      }
      .progress-row {
        display: flex;
        justify-content: space-between;
        font-size: 12px;
        color: #cbd5e1;
        margin-bottom: 6px;
      }
      .progress-track {
        width: 100%;
        height: 10px;
        background: #0f1318;
        border: 1px solid #28313e;
        border-radius: 999px;
        overflow: hidden;
      }
      .progress-fill {
        width: 4%;
        height: 100%;
        background: linear-gradient(90deg, #2563eb, #22c55e);
        transition: width 0.18s ease-out;
      }
      .load-hint {
        margin-top: 10px;
        font-size: 11px;
        color: #7d899b;
        line-height: 1.4;
      }
      .log-toggle {
        margin-top: 12px;
        background: none;
        border: 0;
        padding: 0;
        color: #60a5fa;
        font-size: 11px;
        cursor: pointer;
      }
      .log-toggle:hover { text-decoration: underline; }
      #temporary_console {
        margin-top: 8px;
        padding: 8px 10px;
        background: #0a0d11;
        border: 1px solid #222a35;
        border-radius: 6px;
        font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
        font-size: 11px;
        line-height: 1.35;
        color: #94a3b8;
        max-height: 140px;
        overflow-y: auto;
        display: none;
      }
      #temporary_console.open { display: block; }
      #temporary_console pre {
        margin: 1px 0;
        white-space: pre-wrap;
        word-break: break-word;
      }
    </style>
  </head>
  <body>
    <div id="load_screen">
      <div class="load-card">
        <div class="load-header">
          <div class="spinner" id="load_spinner"></div>
          <div>
            <div class="load-title">Luanti Mapgen Viewport</div>
            <div class="load-subtitle" id="load_phase">Starting WebAssembly runtime...</div>
          </div>
        </div>
        <div class="progress-row">
          <span id="load_detail">Initializing...</span>
          <span id="load_pct">0%</span>
        </div>
        <div class="progress-track">
          <div class="progress-fill" id="load_fill"></div>
        </div>
        <div class="load-hint">
          First run unpacks game assets into browser storage (OPFS). Subsequent reloads reuse the cache and start much faster.
        </div>
        <button type="button" class="log-toggle" id="log_toggle">Show startup log</button>
        <div id="temporary_console" class="console"></div>
      </div>
    </div>

    <script type="text/javascript" src="%__RELEASE_UUID__%/launcher.js"></script>
    <script type="text/javascript">
      // Completely prevent Escape from ever reaching Luanti/SDL2 so the pause menu cannot open.
      // Browser pointer-lock exit still works natively at the OS/browser level.
      window.sendEscapeKey = function () {};
      const blockAllEscape = (e) => {
        if (e.code === 'Escape' || e.key === 'Escape' || e.keyCode === 27) {
          e.preventDefault();
          e.stopImmediatePropagation();
          e.stopPropagation();
        }
      };
      window.addEventListener('keydown', blockAllEscape, true);
      window.addEventListener('keyup', blockAllEscape, true);
      window.addEventListener('keypress', blockAllEscape, true);
      document.addEventListener('keydown', blockAllEscape, true);
      document.addEventListener('keyup', blockAllEscape, true);

      // Forward Ctrl+S / Cmd+S from Luanti viewport to Monaco Save & Reload
      window.addEventListener('keydown', (e) => {
        if ((e.ctrlKey || e.metaKey) && !e.altKey && e.code === 'KeyS') {
          e.preventDefault();
          e.stopImmediatePropagation();
          if (window.parent) {
            window.parent.postMessage({ type: 'mapgen-trigger-save' }, '*');
          }
        }
      }, true);

      const loadPhase = document.getElementById('load_phase');
      const loadDetail = document.getElementById('load_detail');
      const loadPct = document.getElementById('load_pct');
      const loadFill = document.getElementById('load_fill');
      const tcon = document.getElementById('temporary_console');
      const logToggle = document.getElementById('log_toggle');

      logToggle.addEventListener('click', () => {
        const open = tcon.classList.toggle('open');
        logToggle.textContent = open ? 'Hide startup log' : 'Show startup log';
      });

      const MAX_LOG_LINES = 120;
      function tcon_print(prefix, line) {
        if (prefix) {
          for (const child of tcon.childNodes) {
            if (child.nodeName === 'PRE' && child.innerText.startsWith(prefix)) {
              child.innerText = prefix + line;
              return;
            }
          }
        }
        const p = document.createElement('pre');
        p.innerText = prefix + line;
        tcon.appendChild(p);
        while (tcon.childNodes.length > MAX_LOG_LINES) {
          tcon.removeChild(tcon.firstChild);
        }
        tcon.scrollTop = tcon.scrollHeight;
      }

      // Weighted overall progress across wasm -> download -> OPFS unpack -> launch
      let overallPct = 2;
      function setProgress(pct, phase, detail) {
        overallPct = Math.max(overallPct, Math.min(100, Math.round(pct)));
        loadFill.style.width = overallPct + '%';
        loadPct.textContent = overallPct + '%';
        if (phase) loadPhase.textContent = phase;
        if (detail) loadDetail.textContent = detail;
      }

      const mtl = new LuantiLauncher();
      const args = LuantiArgs.fromQueryString(window.location.search);
      mtl.addPacks(args.packs);

      mtl.onprint = (text) => tcon_print('', text);
      mtl.onprogress = (name, progress) => {
        const p = Math.max(0, Math.min(1, progress || 0));
        if (name === 'wasm_module') {
          setProgress(5 + p * 15, 'Loading WebAssembly engine...', `Engine dependencies (${Math.round(p * 100)}%)`);
        } else if (name === 'download:base') {
          setProgress(20 + p * 25, 'Downloading game assets...', `Downloading base.pack (${Math.round(p * 100)}%)`);
        } else if (name === 'install:base') {
          setProgress(45 + p * 50, 'Unpacking assets to browser storage...', `Writing files (${Math.round(p * 100)}%) — first run only`);
        } else if (name === 'download:certs' || name === 'install:certs') {
          setProgress(95 + p * 3, 'Finalizing certificates...', `${name} (${Math.round(p * 100)}%)`);
        }
        tcon_print(`Task ${name} : `, `${Math.round(p * 100)}%`);
      };
      mtl.onerror = (err) => {
        loadPhase.textContent = 'Startup error';
        loadDetail.textContent = String(err);
        loadFill.style.background = '#ef4444';
        tcon.classList.add('open');
        tcon_print('', 'FATAL ERROR: ' + err);
      };
      mtl.onexit = (status) => {
        tcon_print('', `Luanti exited with status ${status}. Reload to restart.`);
      };

      mtl.onready = async () => {
        setProgress(20, 'Checking browser storage...', 'Preparing packs...');
        try {
          if (!mtl.isPersistent() && window.parent) {
            window.parent.postMessage({ type: 'luanti-no-opfs' }, '*');
          }

          // Wait for base & certs packs before switching away from the load screen
          await Promise.all([mtl.addPack('base'), mtl.addPack('certs')]);
          setProgress(98, 'Launching singlenode world...', 'Configuring mapgen_world...');

          if (mtl.isPersistent() && window.parent && typeof window.parent.__ensureMapgenFile === 'function') {
            await window.parent.__ensureMapgenFile();
          }

          let worldPath = '/luanti/worlds/mapgen_world';
          try {
            const worlds = await mtl.listWorlds();
            const found = worlds.find(
              (w) => w.dir === 'mapgen_world' || w.name === 'mapgen_world' || (w.path && w.path.endsWith('/mapgen_world'))
            );
            if (found && found.path) worldPath = found.path;
          } catch (e) {
            console.warn('listWorlds fallback:', e);
          }

          const launchArgs = LuantiArgs.fromQueryString(window.location.search);
          launchArgs.gameid = 'minetest_game';
          launchArgs.world = worldPath;
          launchArgs.name = launchArgs.name || 'builder';
          launchArgs.go = true;

          // Keep client/emerge queues bounded so WASM stays well under its 1.875 GB heap cap
          mtl.overrideConf('viewing_range', 65);
          mtl.overrideConf('max_block_send_distance', 4);
          mtl.overrideConf('max_block_generate_distance', 4);
          mtl.overrideConf('client_mapblock_limit', 1000);
          mtl.overrideConf('emergequeue_limit_total', 48);
          mtl.overrideConf('emergequeue_limit_diskonly', 12);
          mtl.overrideConf('emergequeue_limit_generate', 12);
          mtl.overrideConf('free_move', 'true');
          mtl.overrideConf('fast_move', 'true');
          mtl.overrideConf('noclip', 'true');

          mtl.overrideConf('num_emerge_threads', 4);
          mtl.overrideConf('mg_name', 'singlenode');
          mtl.overrideConf('creative_mode', 'true');
          mtl.overrideConf('enable_damage', 'false');
          mtl.overrideConf('secure.trusted_mods', 'mapgen_edit');

          try {
            const lang = await mtl.initialLang();
            mtl.setLang(lang || getDefaultLanguage());
          } catch (_) {
            mtl.setLang(getDefaultLanguage());
          }

          setProgress(100, 'Starting Luanti...', 'Ready');
          mtl.launch(launchArgs);
        } catch (err) {
          loadPhase.textContent = 'Auto-launch error';
          loadDetail.textContent = err && err.message ? err.message : String(err);
          tcon.classList.add('open');
          tcon_print('', 'Auto-launch error: ' + (err && err.message ? err.message : err));
        }
      };
    </script>
  </body>
</html>
HTML

  # 7. Split-screen IDE index.html (Luanti left + Monaco + Presets + Working History right)
  cat > "$ME_DIR/index.html" << 'HTML'
<!doctype html>
<html lang="en-us">
  <head>
    <script src="coi-serviceworker.js"></script>
    <meta charset="utf-8">
    <meta http-equiv="Content-Type" content="text/html; charset=utf-8">
    <title>Luanti WASM Mapgen Editor</title>
    <style>
      * { box-sizing: border-box; }
      html, body {
        margin: 0;
        padding: 0;
        width: 100%;
        height: 100%;
        overflow: hidden;
        background: #14171c;
        color: #e6edf3;
        font-family: system-ui, -apple-system, Segoe UI, Roboto, sans-serif;
      }
      #app {
        display: flex;
        width: 100vw;
        height: 100vh;
      }
      #left-pane {
        width: 50%;
        height: 100%;
        background: #000;
        position: relative;
        min-width: 240px;
      }
      #luanti-frame {
        width: 100%;
        height: 100%;
        border: 0;
        display: block;
      }
      #divider {
        width: 5px;
        height: 100%;
        background: #252b34;
        cursor: col-resize;
        flex: 0 0 5px;
        transition: background 0.15s;
      }
      #divider:hover, #divider.dragging {
        background: #3b82f6;
      }
      #right-pane {
        flex: 1;
        min-width: 340px;
        height: 100%;
        display: flex;
        flex-direction: column;
        background: #1e1e1e;
      }
      #toolbar {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: 6px;
        padding: 8px 10px;
        background: #181a1f;
        border-bottom: 1px solid #2d323b;
      }
      .btn {
        background: #2b313b;
        color: #e6edf3;
        border: 1px solid #3c4452;
        border-radius: 4px;
        padding: 5px 10px;
        font-size: 12px;
        cursor: pointer;
        white-space: nowrap;
      }
      .btn:hover:not(:disabled) { background: #373f4d; }
      .btn:disabled { opacity: 0.45; cursor: not-allowed; }
      .btn-primary {
        background: #2563eb;
        border-color: #3b82f6;
        color: #fff;
        font-weight: 600;
      }
      .btn-primary:hover:not(:disabled) { background: #1d4ed8; }
      .btn-warn {
        background: #7c2d12;
        border-color: #9a3412;
      }
      .btn-warn:hover:not(:disabled) { background: #9a3412; }
      .spacer { flex: 1; }
      #status-pill {
        font-size: 11px;
        font-weight: 600;
        padding: 3px 8px;
        border-radius: 999px;
        background: #2b313b;
        color: #cbd5e1;
      }
      #status-pill.ok { background: #14532d; color: #86efac; }
      #status-pill.err { background: #7f1d1d; color: #fca5a5; }
      #status-pill.busy { background: #78350f; color: #fde68a; }
      #error-banner {
        display: none;
        padding: 8px 12px;
        background: #450a0a;
        border-bottom: 1px solid #991b1b;
        color: #fecaca;
        font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
        font-size: 12px;
        white-space: pre-wrap;
        max-height: 110px;
        overflow-y: auto;
      }
      #editor-body {
        flex: 1;
        min-height: 0;
        display: flex;
      }
      #monaco-container {
        flex: 1;
        min-width: 0;
        height: 100%;
      }
      #history-pane {
        width: 215px;
        flex: 0 0 215px;
        border-left: 1px solid #2d323b;
        background: #16181d;
        display: flex;
        flex-direction: column;
        min-height: 0;
      }
      #history-header {
        padding: 8px 10px;
        font-size: 11px;
        font-weight: 700;
        text-transform: uppercase;
        letter-spacing: 0.04em;
        color: #94a3b8;
        border-bottom: 1px solid #2d323b;
        display: flex;
        align-items: center;
        justify-content: space-between;
      }
      #history-list {
        flex: 1;
        overflow-y: auto;
        padding: 6px;
        display: flex;
        flex-direction: column;
        gap: 6px;
      }
      .hist-item {
        text-align: left;
        background: #20242c;
        border: 1px solid #2e3440;
        border-radius: 4px;
        padding: 7px 8px;
        color: #e2e8f0;
        cursor: pointer;
        font-size: 11px;
        transition: border-color 0.12s, background 0.12s;
      }
      .hist-item:hover {
        background: #282d37;
        border-color: #475569;
      }
      .hist-item.active {
        border-color: #22c55e;
        background: #162920;
      }
      .hist-meta {
        display: flex;
        justify-content: space-between;
        font-weight: 600;
        margin-bottom: 3px;
        color: #f8fafc;
      }
      .hist-time { color: #94a3b8; font-weight: 400; }
      .hist-preview {
        color: #94a3b8;
        font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
        font-size: 10px;
        white-space: nowrap;
        overflow: hidden;
        text-overflow: ellipsis;
      }
    </style>
  </head>
  <body>
    <div id="app">
      <div id="left-pane">
        <iframe id="luanti-frame"></iframe>
      </div>
      <div id="divider" title="Drag to resize"></div>
      <div id="right-pane">
        <div id="toolbar">
          <button id="btn-save" class="btn btn-primary" title="Save mapgen.lua and regenerate (Ctrl+S)">Save &amp; Reload</button>
          <button id="btn-revert" class="btn btn-warn" disabled title="Revert to previous working mapgen">Revert Last Working</button>
          <button class="btn preset-btn" data-preset="waterworld">Waterworld Example</button>
          <button class="btn preset-btn" data-preset="lavaworld">Lavaworld Example</button>
          <button class="btn preset-btn" data-preset="city">City Generator Example</button>
          <span class="spacer"></span>
          <span id="status-pill" class="busy">Initializing...</span>
        </div>
        <div id="error-banner"></div>
        <div id="editor-body">
          <div id="monaco-container"></div>
          <aside id="history-pane">
            <div id="history-header">
              <span>Working History</span>
              <span id="history-count">0</span>
            </div>
            <div id="history-list"></div>
          </aside>
        </div>
      </div>
    </div>

    <script src="%__RELEASE_UUID__%/monaco/vs/loader.js"></script>
    <script>
      const PRESETS = {
        starter: {
          label: 'Rolling Islands',
          code: `-- Live Mapgen Editor (runs on async mapgen threads)
-- Press Ctrl+S in the Monaco editor to hot-reload and regenerate the world.

local c_stone = core.get_content_id("default:stone")
local c_dirt  = core.get_content_id("default:dirt")
local c_grass = core.get_content_id("default:dirt_with_grass")
local c_sand  = core.get_content_id("default:sand")
local c_water = core.get_content_id("default:water_source")
local data_buf = {}

core.register_on_generated(function(vm, minp, maxp, blockseed)
\tlocal emin, emax = vm:get_emerged_area()
\tlocal area = VoxelArea:new({ MinEdge = emin, MaxEdge = emax })
\tlocal data = vm:get_data(data_buf)

\tlocal sea_level = 2

\tfor z = minp.z, maxp.z do
\t\tfor x = minp.x, maxp.x do
\t\t\tlocal h = math.floor(
\t\t\t\t4
\t\t\t\t+ 7 * math.sin(x * 0.045) * math.cos(z * 0.045)
\t\t\t\t+ 3 * math.sin((x + z) * 0.11)
\t\t\t)

\t\t\tlocal top_y = math.max(h, sea_level)
\t\t\tlocal y0 = math.max(minp.y, -48)
\t\t\tlocal y1 = math.min(maxp.y, top_y)

\t\t\tfor y = y0, y1 do
\t\t\t\tlocal vi = area:index(x, y, z)
\t\t\t\tif y <= h then
\t\t\t\t\tif y == h then
\t\t\t\t\t\tdata[vi] = (h <= sea_level + 1) and c_sand or c_grass
\t\t\t\t\telseif y >= h - 3 then
\t\t\t\t\t\tdata[vi] = (h <= sea_level + 1) and c_sand or c_dirt
\t\t\t\t\telse
\t\t\t\t\t\tdata[vi] = c_stone
\t\t\t\t\tend
\t\t\t\telseif y <= sea_level then
\t\t\t\t\tdata[vi] = c_water
\t\t\t\tend
\t\t\tend
\t\tend
\tend

\tvm:set_data(data)
end)
`
        },
        waterworld: {
          label: 'Waterworld Example',
          code: `-- Waterworld Example: deep ocean, sandy atolls, and glowing underwater reefs

local c_stone = core.get_content_id("default:stone")
local c_sand  = core.get_content_id("default:sand")
local c_grass = core.get_content_id("default:dirt_with_grass")
local c_water = core.get_content_id("default:water_source")
local c_glass = core.get_content_id("default:glass")
local c_mese  = core.get_content_id("default:meselamp")
local data_buf = {}

core.register_on_generated(function(vm, minp, maxp, blockseed)
\tlocal emin, emax = vm:get_emerged_area()
\tlocal area = VoxelArea:new({ MinEdge = emin, MaxEdge = emax })
\tlocal data = vm:get_data(data_buf)

\tlocal sea_level = 10

\tfor z = minp.z, maxp.z do
\t\tfor x = minp.x, maxp.x do
\t\t\tlocal wave = math.sin(x * 0.035) * math.cos(z * 0.035)
\t\t\tlocal atoll = math.sin(x * 0.08 + 1.2) + math.cos(z * 0.08 - 0.7)
\t\t\tlocal floor_y = math.floor(-6 + 10 * wave + 5 * atoll)

\t\t\t-- Occasional glass & meselamp ocean domes
\t\t\tlocal dx = (x % 48) - 24
\t\t\tlocal dz = (z % 48) - 24
\t\t\tlocal dome_r2 = dx * dx + dz * dz
\t\t\tlocal dome_top = (dome_r2 <= 64) and (floor_y + math.floor(math.sqrt(64 - dome_r2))) or -999

\t\t\tlocal top_y = math.max(floor_y, sea_level, dome_top)
\t\t\tlocal y0 = math.max(minp.y, -48)
\t\t\tlocal y1 = math.min(maxp.y, top_y)

\t\t\tfor y = y0, y1 do
\t\t\t\tlocal vi = area:index(x, y, z)
\t\t\t\tif y <= floor_y then
\t\t\t\t\tif y == floor_y and floor_y > sea_level + 1 then
\t\t\t\t\t\tdata[vi] = c_grass
\t\t\t\t\telseif y >= floor_y - 3 then
\t\t\t\t\t\tdata[vi] = c_sand
\t\t\t\t\telse
\t\t\t\t\t\tdata[vi] = c_stone
\t\t\t\t\tend
\t\t\t\telseif y <= dome_top then
\t\t\t\t\tif y == dome_top then
\t\t\t\t\t\tdata[vi] = (dome_r2 <= 2) and c_mese or c_glass
\t\t\t\t\tend
\t\t\t\telseif y <= sea_level then
\t\t\t\t\tdata[vi] = c_water
\t\t\t\tend
\t\t\tend
\t\tend
\tend

\tvm:set_data(data)
end)
`
        },
        lavaworld: {
          label: 'Lavaworld Example',
          code: `-- Lavaworld Example: volcanic obsidian spires over a glowing lava sea

local c_obsidian = core.get_content_id("default:obsidian")
local c_dstone   = core.get_content_id("default:desert_stone")
local c_cobble   = core.get_content_id("default:cobble")
local c_lava     = core.get_content_id("default:lava_source")
local c_mese     = core.get_content_id("default:meselamp")
local data_buf = {}

core.register_on_generated(function(vm, minp, maxp, blockseed)
\tlocal emin, emax = vm:get_emerged_area()
\tlocal area = VoxelArea:new({ MinEdge = emin, MaxEdge = emax })
\tlocal data = vm:get_data(data_buf)

\tlocal lava_level = 0

\tfor z = minp.z, maxp.z do
\t\tfor x = minp.x, maxp.x do
\t\t\tlocal ridge = math.abs(math.sin(x * 0.05) + math.cos(z * 0.05))
\t\t\tlocal spire = math.max(0, math.sin(x * 0.13) * math.cos(z * 0.13)) ^ 2
\t\t\tlocal h = math.floor(-8 + 14 * ridge + 22 * spire)
\t\t\tlocal has_vein = ((x * 73856093 + z * 19349663) % 97) == 0

\t\t\tlocal top_y = math.max(h, lava_level)
\t\t\tlocal y0 = math.max(minp.y, -48)
\t\t\tlocal y1 = math.min(maxp.y, top_y)

\t\t\tfor y = y0, y1 do
\t\t\t\tlocal vi = area:index(x, y, z)
\t\t\t\tif y <= h then
\t\t\t\t\tif y == h and has_vein and h > lava_level then
\t\t\t\t\t\tdata[vi] = c_mese
\t\t\t\t\telseif y >= h - 2 then
\t\t\t\t\t\tdata[vi] = c_obsidian
\t\t\t\t\telseif y >= h - 6 then
\t\t\t\t\t\tdata[vi] = c_dstone
\t\t\t\t\telse
\t\t\t\t\t\tdata[vi] = c_cobble
\t\t\t\t\tend
\t\t\t\telseif y <= lava_level then
\t\t\t\t\tdata[vi] = c_lava
\t\t\t\tend
\t\t\tend
\t\tend
\tend

\tvm:set_data(data)
end)
`
        },
        city: {
          label: 'City Generator Example',
          code: `-- City Generator Example: deterministic avenues, sidewalks, and skyscrapers

local c_stone      = core.get_content_id("default:stone")
local c_obsidian   = core.get_content_id("default:obsidian")
local c_cobble     = core.get_content_id("default:cobble")
local c_brick      = core.get_content_id("default:brick")
local c_stonebrick = core.get_content_id("default:stonebrick")
local c_steel      = core.get_content_id("default:steelblock")
local c_glass      = core.get_content_id("default:glass")
local c_mese       = core.get_content_id("default:meselamp")
local c_grass      = core.get_content_id("default:dirt_with_grass")
local data_buf = {}

local function cell_hash(cx, cz)
\tlocal n = math.sin(cx * 127.1 + cz * 311.7) * 43758.5453123
\treturn n - math.floor(n)
end

core.register_on_generated(function(vm, minp, maxp, blockseed)
\tlocal emin, emax = vm:get_emerged_area()
\tlocal area = VoxelArea:new({ MinEdge = emin, MaxEdge = emax })
\tlocal data = vm:get_data(data_buf)

\tlocal CELL = 24
\tlocal ROAD = 6

\tfor z = minp.z, maxp.z do
\t\tlocal cz = math.floor(z / CELL)
\t\tlocal lz = z % CELL
\t\tfor x = minp.x, maxp.x do
\t\t\tlocal cx = math.floor(x / CELL)
\t\t\tlocal lx = x % CELL

\t\t\tlocal is_road = (lx < ROAD) or (lz < ROAD)
\t\t\tlocal is_sidewalk = (not is_road) and (lx == ROAD or lz == ROAD or lx == CELL - 1 or lz == CELL - 1)
\t\t\tlocal rnd = cell_hash(cx, cz)
\t\t\tlocal is_park = (rnd < 0.18)

\t\t\tlocal b_height = 0
\t\t\tif (not is_road) and (not is_sidewalk) and (not is_park) then
\t\t\t\tb_height = 8 + math.floor(rnd * 36)
\t\t\t\tb_height = b_height - (b_height % 4) + 1
\t\t\tend

\t\t\tlocal lamp_top = (is_road and ((lx == 0 and lz == 0) or (lx == ROAD - 1 and lz == ROAD - 1))) and 5 or 0
\t\t\tlocal wall_mat = (rnd > 0.65) and c_steel or ((rnd > 0.4) and c_stonebrick or c_brick)
\t\t\tlocal is_wall = (lx == ROAD + 1 or lx == CELL - 2 or lz == ROAD + 1 or lz == CELL - 2)

\t\t\tlocal top_y = math.max(1, b_height, lamp_top)
\t\t\tlocal y0 = math.max(minp.y, -16)
\t\t\tlocal y1 = math.min(maxp.y, top_y)

\t\t\tfor y = y0, y1 do
\t\t\t\tlocal vi = area:index(x, y, z)
\t\t\t\tif y <= 0 then
\t\t\t\t\tdata[vi] = c_stone
\t\t\t\telseif y == 1 then
\t\t\t\t\tif is_road then
\t\t\t\t\t\tdata[vi] = c_obsidian
\t\t\t\t\telseif is_sidewalk then
\t\t\t\t\t\tdata[vi] = c_cobble
\t\t\t\t\telseif is_park then
\t\t\t\t\t\tdata[vi] = c_grass
\t\t\t\t\telse
\t\t\t\t\t\tdata[vi] = c_stonebrick
\t\t\t\t\tend
\t\t\t\telseif lamp_top > 0 and y <= lamp_top then
\t\t\t\t\tdata[vi] = (y == lamp_top) and c_mese or c_steel
\t\t\t\telseif b_height > 0 and y <= b_height then
\t\t\t\t\tlocal floor_y = (y - 1) % 4
\t\t\t\t\tif y == b_height then
\t\t\t\t\t\tdata[vi] = (lx == math.floor(CELL / 2) and lz == math.floor(CELL / 2)) and c_mese or c_stonebrick
\t\t\t\t\telseif is_wall then
\t\t\t\t\t\tif floor_y == 2 or floor_y == 3 then
\t\t\t\t\t\t\tlocal corner = (lx == ROAD + 1 or lx == CELL - 2) and (lz == ROAD + 1 or lz == CELL - 2)
\t\t\t\t\t\t\tdata[vi] = corner and wall_mat or c_glass
\t\t\t\t\t\telse
\t\t\t\t\t\t\tdata[vi] = wall_mat
\t\t\t\t\t\tend
\t\t\t\t\telseif floor_y == 0 then
\t\t\t\t\t\tdata[vi] = (lx == math.floor(CELL / 2) and lz == math.floor(CELL / 2)) and c_mese or c_stonebrick
\t\t\t\t\tend
\t\t\t\tend
\t\t\tend
\t\tend
\tend

\tvm:set_data(data)
end)
`
        }
      };

      const HISTORY_KEY = 'luanti_mapgen_working_history_v1';
      const MAX_HISTORY = 50;

      const statusPill = document.getElementById('status-pill');
      const errorBanner = document.getElementById('error-banner');
      const btnSave = document.getElementById('btn-save');
      const btnRevert = document.getElementById('btn-revert');
      const historyList = document.getElementById('history-list');
      const historyCount = document.getElementById('history-count');
      const leftPane = document.getElementById('left-pane');
      const divider = document.getElementById('divider');
      const luantiFrame = document.getElementById('luanti-frame');

      let editor = null;
      let workingHistory = [];
      let activeHash = null;
      let pendingSave = null; // { hash, nonce, code, label }
      let saveCounter = 0;

      window.addEventListener('message', (e) => {
        if (!e.data) return;
        if (e.data.type === 'mapgen-trigger-save') {
          if (editor) saveMapgen(editor.getValue(), 'Manual Save');
          return;
        }
        if (e.data.type === 'luanti-no-opfs') {
          setStatus('err', 'OPFS Inactive');
          errorBanner.style.display = 'block';
          errorBanner.innerHTML = '';
          const msg = document.createTextNode(
            'Luanti launched in memory-only mode (live mapgen.lua sync requires OPFS). '
          );
          const btn = document.createElement('button');
          btn.className = 'btn btn-primary';
          btn.style.marginLeft = '8px';
          btn.textContent = 'Reload with ?storage=auto';
          btn.onclick = () => {
            const p = new URLSearchParams(window.location.search);
            p.set('storage', 'auto');
            window.location.search = p.toString();
          };
          errorBanner.appendChild(msg);
          errorBanner.appendChild(btn);
        }
      });

      window.addEventListener('keydown', (e) => {
        if ((e.ctrlKey || e.metaKey) && !e.altKey && e.code === 'KeyS') {
          e.preventDefault();
          if (editor) saveMapgen(editor.getValue(), 'Manual Save');
        }
      }, true);

      luantiFrame.src = 'luanti.html' + window.location.search;

      // Pure arithmetic Adler-32 + byte length (matches Lua code_hash)
      function codeHash(str) {
        const bytes = new TextEncoder().encode(str);
        let a = 1, b = 0;
        const MOD = 65521;
        for (let i = 0; i < bytes.length; i++) {
          a = (a + bytes[i]) % MOD;
          b = (b + a) % MOD;
        }
        return (((b * 65536 + a) >>> 0).toString(16).padStart(8, '0')) + ':' + bytes.length;
      }

      function setStatus(kind, text) {
        statusPill.className = kind;
        statusPill.textContent = text;
      }

      function showError(msg) {
        if (!msg) {
          errorBanner.style.display = 'none';
          errorBanner.textContent = '';
        } else {
          errorBanner.style.display = 'block';
          errorBanner.textContent = msg + ' (Previous working mapgen kept active)';
        }
      }

      function loadHistory() {
        try {
          const raw = localStorage.getItem(HISTORY_KEY);
          workingHistory = raw ? JSON.parse(raw) : [];
          if (!Array.isArray(workingHistory)) workingHistory = [];
        } catch (_) {
          workingHistory = [];
        }
        renderHistory();
      }

      function persistHistory() {
        try {
          localStorage.setItem(HISTORY_KEY, JSON.stringify(workingHistory.slice(0, MAX_HISTORY)));
        } catch (_) {}
      }

      function pushWorkingVersion(code, hash, label, version) {
        if (workingHistory.length > 0 && workingHistory[0].hash === hash) {
          activeHash = hash;
          renderHistory();
          return;
        }
        const entry = {
          hash,
          code,
          label: label || 'Saved',
          version: version || (workingHistory.length + 1),
          time: new Date().toLocaleTimeString(),
        };
        workingHistory.unshift(entry);
        if (workingHistory.length > MAX_HISTORY) {
          workingHistory.length = MAX_HISTORY;
        }
        activeHash = hash;
        persistHistory();
        renderHistory();
      }

      function renderHistory() {
        historyCount.textContent = String(workingHistory.length);
        btnRevert.disabled = workingHistory.length < 2;
        historyList.innerHTML = '';

        workingHistory.forEach((item, idx) => {
          const el = document.createElement('button');
          el.className = 'hist-item' + (item.hash === activeHash ? ' active' : '');
          const firstLine = (item.code.split('\n').find((l) => l.trim().length > 0) || '').trim();

          const meta = document.createElement('div');
          meta.className = 'hist-meta';
          const title = document.createElement('span');
          title.textContent = `#${workingHistory.length - idx} ${item.label}`;
          const tm = document.createElement('span');
          tm.className = 'hist-time';
          tm.textContent = item.time;
          meta.appendChild(title);
          meta.appendChild(tm);

          const prev = document.createElement('div');
          prev.className = 'hist-preview';
          prev.textContent = firstLine;

          el.appendChild(meta);
          el.appendChild(prev);
          el.addEventListener('click', () => {
            if (!editor) return;
            editor.setValue(item.code);
            saveMapgen(item.code, `Restore (${item.label})`);
          });
          historyList.appendChild(el);
        });
      }

      async function getWorldDir() {
        if (!navigator.storage || typeof navigator.storage.getDirectory !== 'function') {
          throw new Error('OPFS (navigator.storage.getDirectory) is not available in this browser');
        }
        const root = await navigator.storage.getDirectory();
        const luantiDir = await root.getDirectoryHandle('luanti', { create: true });
        const worldsDir = await luantiDir.getDirectoryHandle('worlds', { create: true });
        return await worldsDir.getDirectoryHandle('mapgen_world', { create: true });
      }

      async function writeOpfsFileWithRetry(dirHandle, name, content) {
        const fh = await dirHandle.getFileHandle(name, { create: true });
        let lastErr = null;
        for (let attempt = 0; attempt < 15; attempt++) {
          try {
            const writable = await fh.createWritable({ keepExistingData: false });
            await writable.write(content);
            await writable.close();
            return;
          } catch (err) {
            lastErr = err;
            await new Promise((r) => setTimeout(r, 30));
          }
        }
        throw lastErr || new Error('Failed writing ' + name);
      }

      async function readOpfsText(dirHandle, name) {
        try {
          const fh = await dirHandle.getFileHandle(name, { create: false });
          const file = await fh.getFile();
          return await file.text();
        } catch (_) {
          return null;
        }
      }

      // Called by luanti.html before launching Luanti
      window.__ensureMapgenFile = async function () {
        const dir = await getWorldDir();
        const existing = await readOpfsText(dir, 'mapgen.lua');
        if (existing && existing.trim().length > 0) {
          return existing;
        }
        const starter = PRESETS.starter.code;
        await writeOpfsFileWithRetry(dir, 'mapgen.lua', starter);
        return starter;
      };

      async function saveMapgen(code, label) {
        const hash = codeHash(code);
        const nonce = `${++saveCounter}:${Date.now()}`;
        pendingSave = { hash, nonce, code, label: label || 'Manual Save' };
        setStatus('busy', 'Saving & compiling...');
        try {
          const dir = await getWorldDir();
          await writeOpfsFileWithRetry(dir, 'mapgen.lua', code);
          await writeOpfsFileWithRetry(dir, 'mapgen_nonce.txt', nonce);
        } catch (err) {
          setStatus('err', 'OPFS write failed');
          showError('Failed to write mapgen.lua to OPFS: ' + (err.message || err));
        }
      }

      // Poll mapgen_status.json written by Luanti's mapgen_edit mod
      let lastSeenStatusKey = '';
      async function pollStatus() {
        try {
          const dir = await getWorldDir();
          const raw = await readOpfsText(dir, 'mapgen_status.json');
          if (raw) {
            const st = JSON.parse(raw);
            const key = `${st.version}|${st.hash}|${st.nonce || ''}|${st.ok}|${st.error || ''}`;
            if (key !== lastSeenStatusKey) {
              lastSeenStatusKey = key;
              if (st.ok) {
                showError(null);
                setStatus('ok', `Active v${st.version}`);
                if (pendingSave && pendingSave.hash === st.hash) {
                  pushWorkingVersion(pendingSave.code, st.hash, pendingSave.label, st.version);
                  pendingSave = null;
                } else if (workingHistory.length === 0 && editor) {
                  const cur = editor.getValue();
                  if (codeHash(cur) === st.hash) {
                    pushWorkingVersion(cur, st.hash, 'Initial', st.version);
                  }
                }
              } else {
                setStatus('err', 'Compile/Runtime Error');
                showError(st.error || 'Unknown mapgen error');
                if (pendingSave && pendingSave.hash === st.hash) {
                  pendingSave = null;
                }
              }
            }
          }
        } catch (_) {}
        setTimeout(pollStatus, 250);
      }

      // Resizable split divider
      let dragging = false;
      divider.addEventListener('mousedown', (e) => {
        e.preventDefault();
        dragging = true;
        divider.classList.add('dragging');
        luantiFrame.style.pointerEvents = 'none';
      });
      window.addEventListener('mousemove', (e) => {
        if (!dragging) return;
        const pct = Math.min(80, Math.max(20, (e.clientX / window.innerWidth) * 100));
        leftPane.style.width = pct + '%';
      });
      window.addEventListener('mouseup', () => {
        if (!dragging) return;
        dragging = false;
        divider.classList.remove('dragging');
        luantiFrame.style.pointerEvents = '';
        if (editor) editor.layout();
        if (luantiFrame.contentWindow && typeof luantiFrame.contentWindow.fixGeometry === 'function') {
          luantiFrame.contentWindow.fixGeometry(true);
        }
      });

      // Buttons
      btnSave.addEventListener('click', () => {
        if (!editor) return;
        saveMapgen(editor.getValue(), 'Manual Save');
      });

      btnRevert.addEventListener('click', () => {
        if (!editor || workingHistory.length < 2) return;
        const target = workingHistory.find((h) => h.hash !== activeHash) || workingHistory[1];
        if (!target) return;
        editor.setValue(target.code);
        saveMapgen(target.code, `Revert (${target.label})`);
      });

      document.querySelectorAll('.preset-btn').forEach((btn) => {
        btn.addEventListener('click', () => {
          const preset = PRESETS[btn.dataset.preset];
          if (!preset || !editor) return;
          if (!window.confirm(`Overwrite current mapgen.lua with "${preset.label}"?`)) {
            return;
          }
          editor.setValue(preset.code);
          saveMapgen(preset.code, preset.label);
        });
      });

      // Boot Monaco Editor from local %__RELEASE_UUID__%/monaco/vs
      loadHistory();
      require.config({ paths: { vs: '%__RELEASE_UUID__%/monaco/vs' } });
      require(['vs/editor/editor.main'], async () => {
        let initialCode = PRESETS.starter.code;
        try {
          initialCode = await window.__ensureMapgenFile();
        } catch (err) {
          setStatus('err', 'OPFS unavailable');
          showError(err.message || String(err));
        }

        editor = monaco.editor.create(document.getElementById('monaco-container'), {
          value: initialCode,
          language: 'lua',
          theme: 'vs-dark',
          automaticLayout: true,
          minimap: { enabled: false },
          fontSize: 13,
          tabSize: 4,
          insertSpaces: false,
        });

        editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, () => {
          saveMapgen(editor.getValue(), 'Manual Save');
        });

        const initHash = codeHash(initialCode);
        pendingSave = { hash: initHash, nonce: 'init', code: initialCode, label: 'Initial' };
        if (workingHistory.length === 0) {
          pushWorkingVersion(initialCode, initHash, 'Initial', 1);
        } else {
          activeHash = initHash;
          renderHistory();
        }

        setStatus('busy', 'Waiting for Luanti...');
        pollStatus();
      });
    </script>
  </body>
</html>
HTML

  # Changing mapgen_editor invalidates fsroot (world/mod/conf) and www (index/luanti HTML)
  rm -f "$(stamp_path_for fsroot)" "$(stamp_path_for www)"
}

stage_fsroot() {
  (
    cd "$BUILD_DIR"
    rm -rf fsroot
    mkdir fsroot
    cp -a "luanti-install" fsroot/luanti

    if [[ ! -d "$SOURCES_DIR/minetest_game" ]]; then
      log "Cloning minetest_game..."
      git clone --depth 1 https://github.com/luanti-org/minetest_game.git "$SOURCES_DIR/minetest_game"
    fi

    (
      cd fsroot/luanti
      rm -rf bin unix
      mkdir -p bin cache games worlds
      echo "This is here to ensure bin exists" > bin/readme.txt

      log "Installing minetest_game into games/minetest_game..."
      mkdir -p games/minetest_game
      tar -C "$SOURCES_DIR/minetest_game" --exclude=".git" -cf - . | tar -C games/minetest_game -xf -

      # Trim unused docs and non-English locales to significantly reduce OPFS file-creation count
      rm -rf doc games/devtest
      if [[ -d locale ]]; then
        find locale -mindepth 1 -maxdepth 1 ! -name 'en*' -exec rm -rf {} +
      fi

      log "Installing preconfigured mapgen_world + mapgen_edit mod..."
      mkdir -p worlds/mapgen_world
      cp -a "$BUILD_DIR/mapgen_editor/world/." worlds/mapgen_world/

      cat > cache/common.conf << 'EOF'
update_last_checked = disabled
no_mtg_notification = true
no_keycode_migration_warning = true
default_game = minetest_game
sqlite_synchronous = 0
mg_name = singlenode
num_emerge_threads = 4
viewing_range = 65
max_block_send_distance = 4
max_block_generate_distance = 4
client_mapblock_limit = 1000
emergequeue_limit_total = 48
emergequeue_limit_diskonly = 12
emergequeue_limit_generate = 12
creative_mode = true
enable_damage = false
secure.trusted_mods = mapgen_edit
EOF
    )

    rm -rf certsroot
    mkdir -p certsroot/etc/ssl/certs certsroot/ssl/certs
    cat /etc/ssl/certs/ca-certificates.crt > certsroot/etc/ssl/certs/ca-certificates.crt
    cat /etc/ssl/certs/ca-certificates.crt > certsroot/ssl/cert.pem
    cp certsroot/ssl/cert.pem certsroot/ssl/certs/ca-certificates.crt

    rm -f fsroot.tar certs.tar fsroot.tar.zst certs.tar.zst
    tar cf fsroot.tar -C fsroot .
    tar cf certs.tar -C certsroot .
    # shellcheck disable=SC2086
    zstd -f -T0 $ZSTD_OPTS fsroot.tar
    # shellcheck disable=SC2086
    zstd -f -T0 $ZSTD_OPTS certs.tar

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

stage_monaco() {
  local MONACO_VERSION="0.52.2"
  local MONACO_URL="https://registry.npmjs.org/monaco-editor/-/monaco-editor-$MONACO_VERSION.tgz"
  local MONACO_TGZ="$SOURCES_DIR/monaco-editor-$MONACO_VERSION.tgz"
  local EXPECTED_SHA512_B64="GEQWEZmfkOGLdd3XK8ryrfWz3AIP8YymVXiPHEdewrUq7mh0qrKrfHLNCXcbB6sTnMLnOZ3ztSiKcciFUkIJwQ=="

  verify_monaco_sha512() {
    python3 - "$1" "$EXPECTED_SHA512_B64" << 'PY'
import base64, hashlib, sys
path, expected = sys.argv[1], sys.argv[2]
h = hashlib.sha512()
with open(path, 'rb') as f:
    for chunk in iter(lambda: f.read(1024 * 1024), b''):
        h.update(chunk)
got = base64.b64encode(h.digest()).decode('ascii')
sys.exit(0 if got == expected else 1)
PY
  }

  if [[ -f "$MONACO_TGZ" ]] && ! verify_monaco_sha512 "$MONACO_TGZ"; then
    warn "Existing monaco-editor-$MONACO_VERSION.tgz failed sha512; re-downloading"
    rm -f "$MONACO_TGZ"
  fi

  if [[ ! -f "$MONACO_TGZ" ]]; then
    rm -f "$MONACO_TGZ.tmp"
    wget "$MONACO_URL" -O "$MONACO_TGZ.tmp"
    verify_monaco_sha512 "$MONACO_TGZ.tmp" || { rm -f "$MONACO_TGZ.tmp"; die "Wrong sha512 integrity for monaco-editor-$MONACO_VERSION.tgz"; }
    mv "$MONACO_TGZ.tmp" "$MONACO_TGZ"
  fi

  local MONACO_DIR="$SOURCES_DIR/monaco"
  rm -rf "$MONACO_DIR"
  mkdir -p "$MONACO_DIR"
  tar xzf "$MONACO_TGZ" -C "$MONACO_DIR" --strip-components=2 "package/min/vs"
  tar xzf "$MONACO_TGZ" -C "$MONACO_DIR" --strip-components=1 "package/LICENSE"
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
  apply_substitutions coi-serviceworker.js  "$WWW_DIR/coi-serviceworker.js"
  apply_substitutions htaccess_release      "$RELEASE_DIR/.htaccess"
  apply_substitutions launcher.js           "$RELEASE_DIR/launcher.js"
  apply_substitutions worker.js             "$RELEASE_DIR/worker.js"
  apply_substitutions lockworker.js         "$RELEASE_DIR/lockworker.js"
  apply_substitutions htaccess_packs        "$PACKS_DIR/.htaccess"

  sed "s/%__RELEASE_UUID__%/$RELEASE_UUID/g" "$BUILD_DIR/mapgen_editor/index.html"  > "$WWW_DIR/index.html"
  sed "s/%__RELEASE_UUID__%/$RELEASE_UUID/g" "$BUILD_DIR/mapgen_editor/luanti.html" > "$WWW_DIR/luanti.html"

  cp -a "$SOURCES_DIR/xterm" "$RELEASE_DIR/xterm"
  mkdir -p "$RELEASE_DIR/monaco"
  cp -a "$SOURCES_DIR/monaco/vs" "$RELEASE_DIR/monaco/vs"
  cp -f "$SOURCES_DIR/monaco/LICENSE" "$RELEASE_DIR/monaco/LICENSE" 2>/dev/null || true
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
run_stage mapgen_editor stage_mapgen_editor '[[ -f "$BUILD_DIR/mapgen_editor/index.html" && -f "$BUILD_DIR/mapgen_editor/world/worldmods/mapgen_edit/init.lua" ]]'
run_stage fsroot     stage_fsroot     '[[ -f "$BUILD_DIR/fsroot.tar.zst" && -f "$BUILD_DIR/certs.tar.zst" ]]'
run_stage xterm      stage_xterm      '[[ -f "$SOURCES_DIR/xterm/xterm.js" ]]'
run_stage monaco     stage_monaco     '[[ -f "$SOURCES_DIR/monaco/vs/loader.js" ]]'
run_stage www        stage_www        '[[ -f "$WWW_DIR/index.html" && -f "$WWW_DIR/luanti.html" ]]'

log "All done! Output is in $WWW_DIR"