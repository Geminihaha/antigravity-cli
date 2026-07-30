#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Antigravity CLI (agy) - Google 공식 바이너리 → Termux 변환 스크립트
# =============================================================================
# Google 공식 릴리스(1.1.8+)를 다운로드하여 Termux(Android)에서
# 실행 가능하도록 패치하고 래퍼를 설정합니다.
#
# 적용하는 패치:
#   1. faccessat2(439) → faccessat(48) syscall 패치 (Android seccomp 우회)
#   2. glibc 라이브러리 심볼릭 링크 생성 (libdl, libpthread, librt, libutil)
#   3. libc.so linker script → 실제 ELF 라이브러리로 교체
#   4. Termux 실행 래퍼(agy) 생성 (LD_PRELOAD, DNS, TLS 설정)
#
# 참고: Google이 1.1.8부터 TCMalloc 48-bit VA 문제를 수정하여
#       더 이상 VA39 패치는 필요하지 않습니다.
#
# 사용법:
#   chmod +x install_agy_termux.sh
#   ./install_agy_termux.sh
#
# 옵션:
#   ./install_agy_termux.sh --force    # 기존 설치 덮어쓰기
#   ./install_agy_termux.sh --version  # 특정 버전 지정 (기본: 최신)
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
step()  { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }

FORCE=false
TARGET_VERSION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE=true; shift ;;
        --version) TARGET_VERSION="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# ─── 디렉토리 / 경로 상수 ─────────────────────────────────────────────
HOME_DIR="/data/data/com.termux/files/home"
LOCAL_BIN="${HOME_DIR}/.local/bin"
GLIBC_DIR="/data/data/com.termux/files/usr/glibc/lib"
GLIBC_LD="${GLIBC_DIR}/ld-linux-aarch64.so.1"
GLIBC_LIBC="${GLIBC_DIR}/libc.so.6"
WORK_DIR="${HOME_DIR}/.agy-work"
GITHUB_REPO="google-antigravity/antigravity-cli"

# ─── Step 0: 환경 확인 ────────────────────────────────────────────────
step "Step 0: Termux 환경 확인"

if [[ ! -d /data/data/com.termux/files/usr ]]; then
    error "이 스크립트는 Termux 환경에서만 실행 가능합니다."
    exit 1
fi

info "Termux 환경 확인 완료"

# ─── Step 1: 필요 패키지 설치 ─────────────────────────────────────────
step "Step 1: 필요 패키지 설치"

REQUIRED_PKGS=("python" "curl" "ca-certificates" "patchelf" "resolv-conf" "glibc")
MISSING_PKGS=()

for pkg in "${REQUIRED_PKGS[@]}"; do
    if ! dpkg -s "$pkg" &>/dev/null; then
        MISSING_PKGS+=("$pkg")
    fi
done

if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    info "설치 필요: ${MISSING_PKGS[*]}"
    pkg update -y && pkg install -y "${MISSING_PKGS[@]}"
else
    info "모든 패키지가 이미 설치되어 있습니다 ✓"
fi

# ─── Step 2: glibc 확인 및 라이브러리 설정 ────────────────────────────
step "Step 2: glibc 라이브러리 설정"

if [[ ! -x "${GLIBC_LD}" ]]; then
    error "glibc loader 없음: ${GLIBC_LD}"
    error "pkg install glibc 로 설치해주세요."
    exit 1
fi

# libc.so linker script 백업 및 ELF symlink로 교체
if file "${GLIBC_DIR}/libc.so" 2>/dev/null | grep -q "ASCII text"; then
    info "libc.so linker script 발견 → ELF symlink로 교체"
    cp "${GLIBC_DIR}/libc.so" "${GLIBC_DIR}/libc.so.bak" 2>/dev/null || true
    ln -sfn "${GLIBC_LIBC}" "${GLIBC_DIR}/libc.so"
    info "  libc.so → libc.so.6 ✓"
else
    info "libc.so 이미 ELF 또는 symlink, 건너뜀"
fi

# 누락된 .so 심볼릭 링크 생성
declare -A SO_LINKS=(
    ["libdl.so"]="libdl.so.2"
    ["libpthread.so"]="libpthread.so.0"
    ["librt.so"]="librt.so.1"
    ["libutil.so"]="libutil.so.1"
)

for link in "${!SO_LINKS[@]}"; do
    target="${SO_LINKS[$link]}"
    if [[ ! -e "${GLIBC_DIR}/${link}" ]]; then
        ln -sfn "${GLIBC_DIR}/${target}" "${GLIBC_DIR}/${link}"
        info "  ${link} → ${target} ✓"
    fi
done

info "glibc 라이브러리 설정 완료"

# ─── Step 3: 최신 버전 확인 및 다운로드 ────────────────────────────────
step "Step 3: Google 공식 바이너리 다운로드"

mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

# 최신 릴리스 태그 가져오기
if [[ -z "${TARGET_VERSION}" ]]; then
    info "최신 릴리스 버전 확인 중..."
    LATEST_TAG=$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" 2>/dev/null | \
        grep '"tag_name"' | head -1 | sed 's/.*"tag_name"\s*:\s*"\([^"]*\)".*/\1/')
    
    if [[ -z "${LATEST_TAG}" ]]; then
        error "릴리스 정보를 가져올 수 없습니다."
        exit 1
    fi
    TARGET_VERSION="${LATEST_TAG}"
fi

info "대상 버전: ${TARGET_VERSION}"

DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/${TARGET_VERSION}/agy_cli_linux_arm64.tar.gz"
ARCHIVE_FILE="agy_cli_linux_arm64_${TARGET_VERSION}.tar.gz"

if [[ -f "${ARCHIVE_FILE}" ]] && [[ "${FORCE}" != "true" ]]; then
    info "이미 다운로드됨: ${ARCHIVE_FILE}"
else
    info "다운로드: ${DOWNLOAD_URL}"
    if ! curl -fSL --progress-bar -o "${ARCHIVE_FILE}" "${DOWNLOAD_URL}"; then
        error "다운로드 실패"
        exit 1
    fi
fi

# 압축 해제
info "압축 해제..."
mkdir -p "extract_${TARGET_VERSION}"
tar -xzf "${ARCHIVE_FILE}" -C "extract_${TARGET_VERSION}"
BINARY_SRC=$(find "extract_${TARGET_VERSION}" -type f -name "antigravity" -o -name "agy" | head -1)

if [[ -z "${BINARY_SRC}" ]]; then
    error "압축 파일에서 바이너리를 찾을 수 없습니다."
    ls -laR "extract_${TARGET_VERSION}/"
    exit 1
fi

info "바이너리 추출: ${BINARY_SRC} ($(du -h "${BINARY_SRC}" | cut -f1))"
cp "${BINARY_SRC}" ./antigravity_original

# ─── Step 4: faccessat2 → faccessat 패치 ──────────────────────────────
step "Step 4: faccessat2 syscall 패치"

PATCHED_BIN="./antigravity_patched"

# Python 패치 스크립트 생성 (faccessat2 only)
cat > patch_faccessat2.py << 'PYEOF'
"""faccessat2(439) → faccessat(48) syscall patch for Android/Termux."""
import shutil, struct, sys, hashlib
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])

print(f"Input:  {src}")
print(f"SHA256: {hashlib.sha256(src.read_bytes()).hexdigest()}")

shutil.copyfile(src, dst)
data = bytearray(dst.read_bytes())

def get(off):
    return struct.unpack_from("<I", data, off)[0]

def put(off, word):
    struct.pack_into("<I", data, off, word)

# Go's faccessat2 syscall wrapper pattern:
#   mov x5, xzr       (AA1F03E5)
#   mov x6, xzr       (AA1F03E6)
#   mov x0, #439      (D28036E0)  ← 439 = 0x1B7 = faccessat2
#   bl  syscall       (94000000+)
#
# → mov x0, #48       (D2800600)  ← 48 = 0x30 = faccessat
count = 0
for off in range(0, len(data) - 12, 4):
    if (
        get(off) == 0xAA1F03E5
        and get(off + 4) == 0xAA1F03E6
        and get(off + 8) == 0xD28036E0
        and (get(off + 12) & 0xFC000000) == 0x94000000
    ):
        put(off + 8, 0xD2800600)
        count += 1
        print(f"  Patched faccessat2 at offset 0x{off:x}")

dst.write_bytes(data)
dst.chmod(0o755)
print(f"Output: {dst}")
print(f"SHA256: {hashlib.sha256(dst.read_bytes()).hexdigest()}")
print(f"Patches applied: {count}")
if count == 0:
    print("WARNING: No faccessat2 pattern found! Binary may already be patched or changed.")
PYEOF

python3 patch_faccessat2.py ./antigravity_original "${PATCHED_BIN}"
info "패치 완료: ${PATCHED_BIN}"

# ─── Step 5: 설치 ─────────────────────────────────────────────────────
step "Step 5: 설치"

mkdir -p "${LOCAL_BIN}"

# 패치된 바이너리 설치
cp "${PATCHED_BIN}" "${LOCAL_BIN}/agy.va39"
chmod +x "${LOCAL_BIN}/agy.va39"

# Termux 래퍼(agy) 생성
cat > "${LOCAL_BIN}/agy" << 'WREOF'
#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Antigravity CLI (agy) - Termux Wrapper
# =============================================================================
# Google 공식 agy (glibc Linux 바이너리)를 Termux(Android)에서 실행합니다.
#
# 처리:
#   - LD_PRELOAD 제거 (Bionic → glibc 충돌 방지)
#   - GODEBUG=netdns=go (Go 순수 DNS 리졸버)
#   - SSL_CERT_FILE (Termux CA 인증서 경로)
#   - proot /etc/resolv.conf 바인딩
# =============================================================================

set -euo pipefail

GLIBC_DIR="/data/data/com.termux/files/usr/glibc/lib"
GLIBC_LD="${GLIBC_DIR}/ld-linux-aarch64.so.1"
AGY_BIN="/data/data/com.termux/files/home/.local/bin/agy.va39"
RESOLV_CONF="/data/data/com.termux/files/usr/etc/resolv.conf"
CERT_FILE="/data/data/com.termux/files/usr/etc/tls/cert.pem"

# 바이너리 존재 확인
if [[ ! -x "${AGY_BIN}" ]]; then
    echo "[agy] Error: agy.va39 not found at ${AGY_BIN}" >&2
    echo "[agy] Run the installer or place the patched binary there." >&2
    exit 1
fi

if [[ ! -x "${GLIBC_LD}" ]]; then
    echo "[agy] Error: glibc loader not found at ${GLIBC_LD}" >&2
    echo "[agy] Install glibc: pkg install glibc" >&2
    exit 1
fi

# 환경 정리
unset LD_PRELOAD
unset LD_LIBRARY_PATH
export GODEBUG=netdns=go
export SSL_CERT_FILE="${CERT_FILE}"

# proot으로 /etc/resolv.conf 바인딩 (DNS)
PROOT_BIND=""
if command -v proot &>/dev/null && [[ -f "${RESOLV_CONF}" ]]; then
    PROOT_BIND="-b ${RESOLV_CONF}:/etc/resolv.conf"
fi

exec /data/data/com.termux/files/usr/bin/proot \
    ${PROOT_BIND} \
    "${GLIBC_LD}" --library-path "${GLIBC_DIR}" \
    "${AGY_BIN}" "$@"
WREOF

chmod +x "${LOCAL_BIN}/agy"

info "래퍼 생성: ${LOCAL_BIN}/agy"
info "바이너리:   ${LOCAL_BIN}/agy.va39 ($(du -h "${LOCAL_BIN}/agy.va39" | cut -f1))"

# ─── Step 6: PATH 및 Shell 설정 ───────────────────────────────────────
step "Step 6: Shell 설정"

BASHRC="${HOME_DIR}/.bashrc"

# PATH 추가
if [[ ":$PATH:" != *":${LOCAL_BIN}:"* ]]; then
    echo 'export PATH="$HOME/.local/bin:$HOME/bin:$PATH"' >> "${BASHRC}"
    export PATH="${LOCAL_BIN}:${HOME_DIR}/bin:${PATH}"
    info "PATH에 ${LOCAL_BIN} 추가됨"
fi

# agy/a 함수 (hash -r 포함)
if ! grep -q "# ─── Antigravity CLI" "${BASHRC}" 2>/dev/null; then
    cat >> "${BASHRC}" << 'BASHEOF'

# ─── Antigravity CLI (agy) ────────────────────────────────────────
agy() {
  hash -r
  command agy "$@"
}

alias a=agy
# ──────────────────────────────────────────────────────────────────
BASHEOF
    info ".bashrc에 agy 함수 등록됨"
else
    info ".bashrc에 이미 등록되어 있음"
fi

hash -r 2>/dev/null || true

# ─── Step 7: 검증 ────────────────────────────────────────────────────
step "Step 7: 설치 검증"

echo ""
if VERSION_OUTPUT=$("${LOCAL_BIN}/agy" --version 2>&1); then
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "  ✅ 설치 성공! 버전: ${VERSION_OUTPUT}"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
else
    error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    error "  ❌ 실행 실패: ${VERSION_OUTPUT}"
    error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    echo ""
    echo "=== 진단 정보 ==="
    echo "래퍼:"
    file "${LOCAL_BIN}/agy"
    echo ""
    echo "바이너리:"
    file "${LOCAL_BIN}/agy.va39"
    echo ""
    echo "glibc 로더:"
    ls -la "${GLIBC_LD}"
    echo ""
    echo "glibc 라이브러리:"
    ls -la "${GLIBC_DIR}/libc.so" "${GLIBC_DIR}/libdl.so" "${GLIBC_DIR}/libpthread.so" "${GLIBC_DIR}/librt.so" 2>&1
    echo ""
    echo "resolv.conf:"
    test -f /data/data/com.termux/files/usr/etc/resolv.conf && echo "  존재함" || echo "  없음! pkg install resolv-conf"
    echo ""
    echo "SSL_CERT_FILE:"
    test -f /data/data/com.termux/files/usr/etc/tls/cert.pem && echo "  존재함" || echo "  없음! pkg install ca-certificates"
    exit 1
fi

echo ""
info "🔧 사용 명령어:"
info "   agy --version    버전 확인"
info "   agy --help       도움말"
info "   agy              대화형 CLI 시작"
info "   a                짧은 별칭"
echo ""
info "📁 설치된 파일:"
info "   래퍼:     ${LOCAL_BIN}/agy"
info "   바이너리: ${LOCAL_BIN}/agy.va39"
info "   작업폴더: ${WORK_DIR}/"
echo ""
info "🔄 다음 버전 업데이트 시:"
info "   ./install_agy_termux.sh --force"
echo ""
