#!/usr/bin/env bash
set -euo pipefail
set -E

# -----------------------------
# UI / LOG STYLE (makepkg-like)
# -----------------------------

msg() {
    printf "\033[1;34m==>\033[0m \033[1;37m%s\033[0m\n" "$*"
}

msg2() {
    printf "\033[1;34m==>\033[0m \033[1;32m%s\033[0m \033[1;37m%s\033[0m\n" \
        "$1" "$2"
}

warn() {
    printf "\033[1;33m==> WARNING:\033[0m %s\n" "$*"
}

error() {
    printf "\033[1;31m==> ERROR:\033[0m %s\n" "$*"
}

trap 'echo "[ERROR] phase=${PHASE:-unknown} line=$LINENO cmd=$BASH_COMMAND" >&2' ERR

# -----------------------------
# CONFIG
# -----------------------------
SRC_DIR="${PWD}"
BUILD_DIR="${SRC_DIR}/build"
INSTALL_PREFIX="/usr"
STEAM_DIR="${STEAM_DIR:-}"
JOBS="$(nproc)"

for d in \
    "$HOME/.local/share/Steam" \
    "$HOME/.steam/steam" \
    "$HOME/.var/app/com.valvesoftware.Steam/data/Steam" \
    "$HOME/snap/steam/common/.steam/steam"; do
    if [[ -d "$d" ]]; then
        STEAM_DIR="$d"
        break
    fi
done

[[ -n "$STEAM_DIR" ]] || {
    msg "Steam not found"
    exit 1
}

msg "Steam root: $STEAM_DIR"

# -----------------------------
# FLAGS
# -----------------------------
CMAKE_FLAGS=(
    -G Ninja
    -S "${SRC_DIR}"
    -B "${BUILD_DIR}"
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON
    -DFOSSILIZE_VULKAN_LAYER=ON
    -DFOSSILIZE_CLI=ON
    -DFOSSILIZE_TESTS=OFF
    -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX"
)

BUILD_FLAGS=(
    --build "${BUILD_DIR}"
    --parallel "${JOBS}"
)

run_sudo() {
    sudo "$@"
}

# -----------------------------
# GIT SUBMODULES
# -----------------------------
PHASE="init"

msg2 "[1/6]" "Syncing submodules..."
git submodule update --init --recursive --checkout

msg2 "[2/6]" "Checking repo state..."
BUILD_MODE="${BUILD_MODE:-release}"

STATUS="$(git status --porcelain)"

if [[ "$BUILD_MODE" == "release" ]]; then
    if [[ -n "$STATUS" ]]; then
        error "Repo not clean:"
        error "$STATUS"
        exit 1
    fi
else
    warn "[DEV MODE] Skipping git cleanliness check"
fi

msg2 "[OK]" "Repo is clean and deterministic"

# -----------------------------
# BUILD
# -----------------------------
msg2 "[3/6]" "Configuring..."
PHASE="configure"
cmake "${CMAKE_FLAGS[@]}"

msg2 "[4/6]" "Building..."
PHASE="build"
cmake "${BUILD_FLAGS[@]}"

msg2 "[5/6]" "Installing system artifacts..."
PHASE="install"

run_sudo cmake --install "${BUILD_DIR}"

# -----------------------------
# STEAM CUSTOM WRAPPER
# -----------------------------
msg2 "[6/6]" "Installing steam-custom wrapper..."
PHASE="wrapper"

run_sudo tee /usr/local/bin/steam-custom >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

export VK_LAYER_PATH="/usr/share/vulkan/implicit_layer.d"
export VK_INSTANCE_LAYERS="VK_LAYER_fossilize"

MODE="steam"
ARGS=()

for arg in "$@"; do
    case "$arg" in
        --native) MODE="native" ;;
        *) ARGS+=("$arg") ;;
    esac
done

STEAM_BIN="$(command -v steam || true)"
STEAM_NATIVE_BIN="$(command -v steam-native || true)"

[[ -n "$STEAM_BIN" ]] || {
    echo "steam not found"
    exit 1
}

case "$MODE" in
    native)
        exec "${STEAM_NATIVE_BIN:-$STEAM_BIN}" "${ARGS[@]}"
        ;;
    *)
        exec "$STEAM_BIN" "${ARGS[@]}"
        ;;
esac

EOF

run_sudo chmod +x /usr/local/bin/steam-custom

msg "Done."
