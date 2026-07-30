# Antigravity CLI (`agy`) on Termux (Android)

> **최종 업데이트**: 2025-07-30
> **테스트 버전**: Google 공식 `1.1.8` (linux_arm64)

---

## 개요

[Google Antigravity CLI](https://antigravity.google/cli) (`agy`)는 공식적으로 Linux, macOS, Windows 바이너리만 제공하며, Android/Termux는 지원하지 않습니다.

이 문서는 **Google 공식 linux_arm64 바이너리를 Termux(Android)에서 직접 실행**하기 위한 분석, 패치 방법, 설치 자동화 과정을 기록합니다.

---

## 실제 바이너리 구조

공식 릴리스 `agy_cli_linux_arm64.tar.gz` 안에는 `antigravity` 라는 단일 바이너리가 들어있습니다:

| 속성 | 값 |
|------|-----|
| 타입 | `ELF 64-bit LSB pie executable, ARM aarch64` |
| 인터프리터 | `/lib/ld-linux-aarch64.so.1` (glibc) |
| 필요 라이브러리 | `libresolv.so.2`, `libpthread.so.0`, `libm.so.6`, `libdl.so.2`, `librt.so.1`, `libc.so.6` |
| 크기 | 약 172MB (1.1.8 기준) |
| 빌드 | Go, Google 내부 빌드 |

> **참고**: `wallentx/antigravity-cli-termux`는 이 바이너리를 미리 패치하여 Termux용 standalone 패키지로 제공하는 서드파티 저장소입니다.

---

## Termux에서 실행 시 발생하는 문제들

### 1. ✅ TCMalloc 48-bit VA (1.1.7 이하)

```
MmapAligned() failed - unable to allocate with tag
TCMalloc assumes a 48-bit virtual address space size
FATAL ERROR: Out of memory trying to allocate internal tcmalloc data
```

- **원인**: Android 커널이 39-bit userspace VA만 제공하는 경우, 48-bit를 가정한 TCMalloc이 실패
- **1.1.8**: Google이 내부적으로 수정하여 **더 이상 발생하지 않음** 🎉
- **1.1.7 이하**: `patch_agy_va39.py` 로 TCMalloc 상수 패치 필요 (ubfx #42→#35, 랜덤 마스크 48→39bit 등)

### 2. ✅ faccessat2 syscall 차단

```
SIGSYS: bad system call
syscall.faccessat2
```

- **원인**: Go의 `os/exec.LookPath`가 `faccessat2`(syscall 439)를 호출, Android seccomp이 차단
- **해결**: `faccessat2`(439) → `faccessat`(48) 로 패치
- **영향**: 1.1.8에서도 여전히 발생 → **패치 필요**

### 3. ✅ libc.so 링커 스크립트

```
error while loading shared libraries: libc.so: invalid ELF header
```

- **원인**: Termux glibc의 `libc.so`가 ASCII linker script (`GROUP (...)` 지시문)로 되어 있음
- **해결**: `libc.so` → `libc.so.6` 심볼릭 링크로 교체

### 4. ✅ LD_PRELOAD 충돌

```
version `LIBC' not found (required by libtermux-exec-ld-preload.so)
```

- **원인**: Termux가 Bionic용 `libtermux-exec-ld-preload.so`를 `LD_PRELOAD`로 주입
- **해결**: 래퍼에서 `unset LD_PRELOAD; unset LD_LIBRARY_PATH`

### 5. ✅ 누락된 .so 심볼릭 링크

```
error while loading shared libraries: libdl.so: cannot open shared object file
```

- **원인**: Termux glibc에 `libdl.so.2`만 있고 `libdl.so` 심볼릭 링크 없음
- **해결**: `libdl.so → libdl.so.2`, `libpthread.so → libpthread.so.0`, `librt.so → librt.so.1`, `libutil.so → libutil.so.1`

### 6. ✅ DNS / TLS

- **DNS**: `GODEBUG=netdns=go`로 Go 순수 리졸버 사용 → `proot` 불필요
- **TLS**: `SSL_CERT_FILE=/data/data/com.termux/files/usr/etc/tls/cert.pem`

---

## faccessat2 패치 상세

Go의 `faccessat2` syscall wrapper는 다음과 같은 ARM64 instruction 패턴을 가집니다:

```asm
mov x5, xzr        ; AA 1F 03 E5
mov x6, xzr        ; AA 1F 03 E6
mov x0, #439       ; D2 80 36 E0   ← syscall number 439 (faccessat2)
bl  syscall        ; 94 xx xx xx
```

패치 후:

```asm
mov x5, xzr        ; AA 1F 03 E5
mov x6, xzr        ; AA 1F 03 E6
mov x0, #48        ; D2 80 06 00   ← syscall number 48 (faccessat)
bl  syscall        ; 94 xx xx xx
```

Python 패치 코드:

```python
# offset 0~2: AA1F03E5, AA1F03E6  → 그대로
# offset 8:     D28036E0           → D2800600
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
```

---

## 최종 파일 레이아웃

```
~/.local/bin/
  ├── agy              ← 셸 래퍼 (glibc 로더 + 환경 설정)
  └── agy.va39         ← 패치된 Google 공식 바이너리 (172MB)

/usr/glibc/lib/
  ├── ld-linux-aarch64.so.1   ← glibc 로더 (약 236KB)
  ├── libc.so                 → libc.so.6 (symlink, linker script 대체)
  ├── libdl.so                → libdl.so.2 (symlink)
  ├── libpthread.so           → libpthread.so.0 (symlink)
  ├── librt.so                → librt.so.1 (symlink)
  └── libutil.so              → libutil.so.1 (symlink)
```

---

## 래퍼 (`agy`) 코드

```bash
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

GLIBC_DIR="/data/data/com.termux/files/usr/glibc/lib"
GLIBC_LD="${GLIBC_DIR}/ld-linux-aarch64.so.1"
AGY_BIN="/data/data/com.termux/files/home/.local/bin/agy.va39"
CERT_FILE="/data/data/com.termux/files/usr/etc/tls/cert.pem"

# glibc 로더 덮어쓰기 방지
LOADER_SIZE=$(stat -c%s "${GLIBC_LD}" 2>/dev/null || echo 0)
if [[ "${LOADER_SIZE}" -gt 1000000 ]]; then
    echo "[agy] Error: glibc loader overwritten by antigravity binary!" >&2
    echo "[agy] Fix: pkg reinstall glibc" >&2
    exit 1
fi

# Bionic → glibc 충돌 방지
unset LD_PRELOAD
unset LD_LIBRARY_PATH

# DNS / TLS
export GODEBUG=netdns=go
export SSL_CERT_FILE="${CERT_FILE}"

exec "${GLIBC_LD}" --library-path "${GLIBC_DIR}" "${AGY_BIN}" "$@"
```

---

## 설치 방법

### 빠른 설치 (wallentx standalone)

```bash
curl -fsSL https://raw.githubusercontent.com/wallentx/antigravity-cli-termux/dev/install.sh | bash
```

> 서드파티 저장소. 이미 패치된 바이너리 제공. 버전 업데이트 지연 가능성 있음.

### 직접 설치 (Google 공식 → Termux 변환)

```bash
bash install_agy_termux.sh
```

옵션:

| 옵션 | 설명 |
|------|------|
| `--force` | 기존 설치 덮어쓰기 + 재다운로드 |
| `--version X.Y.Z` | 특정 버전 지정 (기본: 최신) |

---

## 업데이트 방법

```bash
# 최신 버전으로 업데이트
bash install_agy_termux.sh --force
```

---

## 문제 해결

### glibc 로더가 antigravity 바이너리로 덮어쓰기됨

**증상**: `proot error: execve(...): No such file or directory` 또는 로더 실행 불가

**확인**:
```bash
stat -c%s /data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1
# 정상: ~241,440 bytes
# 비정상: ~179,457,944 bytes (antigravity 바이너리)
```

**복구**:
```bash
# 방법 1: .old 백업에서 복원
cp /data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1.*.old \
   /data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1

# 방법 2: glibc 재설치
pkg reinstall glibc
```

### DNS / 네트워크 오류

```bash
# resolver 설정 확인
pkg install resolv-conf
test -f /data/data/com.termux/files/usr/etc/resolv.conf

# CA 인증서 확인
pkg install ca-certificates
test -f /data/data/com.termux/files/usr/etc/tls/cert.pem
```

### 진단 명령어

```bash
# 버전 확인
agy --version

# 바이너리 상태
file ~/.local/bin/agy.va39
readelf -d ~/.local/bin/agy.va39 | grep NEEDED

# glibc 상태
file /data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1
ls -la /data/data/com.termux/files/usr/glibc/lib/lib{c,dl,pthread,rt,util}.so*
```

---

## 버전별 호환성

| 버전 | TCMalloc 패치 | faccessat2 패치 | 비고 |
|------|:---:|:---:|------|
| 1.1.7 | 필요 | 필요 | wallentx standalone 사용 가능 |
| 1.1.8 | **불필요** ✅ | 필요 | Google이 TCMalloc 수정 |
| 이후 | 확인 필요 | 대부분 필요 | `google_malloc` 섹션 재확인 필요 |

---

## 참고 자료

- **원본 가이드**: https://gist.github.com/Brajesh2022/e42160d29b55417db6c18c52dd1d6d37
- **TCMalloc 분석**: https://github.com/google-antigravity/antigravity-cli/issues/64
- **wallentx 저장소**: https://github.com/wallentx/antigravity-cli-termux
- **공식 CLI**: https://antigravity.google/cli
- **Google Antigravity**: https://github.com/google-antigravity/antigravity-cli
