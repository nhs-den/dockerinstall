#!/usr/bin/env bash
#
# install-docker.sh — Sophisticated Docker CE installer with full pre-flight
# detection.
#
# Detects and reports the environment (OS, architecture, CPU, memory, disk,
# kernel, init system, cgroups, virtualization, privileges, network), checks
# it against a compatibility matrix, and only then installs Docker CE via the
# official Docker repository.
#
# Supports: Ubuntu 20.04+, Debian 11+, RHEL 8/9, Rocky Linux, AlmaLinux,
# Oracle Linux, Amazon Linux 2/2023, Fedora, CentOS Stream 8/9, openSUSE Leap
# 15.x / Tumbleweed, SLES 15, Alpine 3.14+, Arch Linux / Manjaro / EndeavourOS.
#
# Windows and macOS are intentionally NOT supported here — Docker Desktop is
# required on those platforms and cannot be installed by a shell script.
#
# Usage:
#   install-docker.sh                Detect + install (interactive)
#   install-docker.sh --detect-only  Detection report only
#   install-docker.sh --dry-run      Show the plan without changing anything
#   install-docker.sh --json         Machine-readable detection report
#   install-docker.sh --uninstall    Remove Docker (optionally with --purge)
#
set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="1.0.0"
readonly DOCKER_REPO_BASE="https://download.docker.com/linux"

# ---------------------------------------------------------------------------
# Colors / logging
# ---------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" && -z "${NO_COLOR:-0}" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
  C_CYAN=$'\033[0;36m'; C_MAGENTA=$'\033[0;35m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""
  C_CYAN=""; C_MAGENTA=""
fi

log_info()    { printf "%s[i]%s %s\n" "$C_CYAN" "$C_RESET" "$*"; }
log_ok()      { printf "%s[OK]%s %s\n" "$C_GREEN" "$C_RESET" "$*"; }
log_warn()    { printf "%s[warn]%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
log_error()   { printf "%s[err]%s %s\n" "$C_RED" "$C_RESET" "$*" >&2; }
log_note()    { printf "%s[i]%s %s\n" "$C_DIM" "$C_RESET" "$*"; }
section()     { printf "\n%s%s %s%s\n%s" "$C_BOLD" "$C_CYAN" "$*" "$C_RESET" "$C_DIM"; }
rule()        { printf "%s%s%s\n" "$C_DIM" "$(printf '─%.0s' $(seq 1 72))" "$C_RESET"; }
die()         { log_error "$*"; exit 1; }
check_ok()    { printf "%s  ✔  ok   %s%s\n" "$C_GREEN" "$*" "$C_RESET"; }
check_warn()  { printf "%s  ⚠  warn %s%s\n" "$C_YELLOW" "$*" "$C_RESET"; }
check_fail()  { printf "%s  ✖  err  %s%s\n" "$C_RED" "$*" "$C_RESET"; }
check_info()  { printf "%s  ℹ  info %s%s\n" "$C_CYAN" "$*" "$C_RESET"; }

# ---------------------------------------------------------------------------
# Globals (defaults)
# ---------------------------------------------------------------------------
DRY_RUN=false
DETECT_ONLY=false
JSON_REPORT=false
STRICT=false
YES=false
NO_SERVICE=false
UNINSTALL=false
PURGE=false
SKIP_NETWORK_CHECK=false
FROM_DISTRO=false
USE_CONVENIENCE_SCRIPT=false
INSTALL_METHOD="official"

# Detection results
OS_RELEASE_FILE=""
OS_ID=""; OS_NAME=""; OS_ID_LIKE=""; OS_VERSION_ID=""; OS_VERSION=""
OS_VERSION_CODENAME=""; OS_PRETTY_NAME=""
OS_FAMILY="unknown"           # apt | dnf | zypper | apk | pacman | unknown
OS_PKG_MANAGER="unknown"
OS_SUPPORTED=false
OS_REPO_SLUG=""               # slug used in the official repo URL
OS_REPO_MAJOR=""              # major version for rpm-family repos
OS_REPO_CODENAME=""           # codename for apt-family repos
ARCH_ARCH=""; ARCH_BASEARCH=""; ARCH_SUPPORTED=false
CPU_MODEL=""; CPU_CORES="0"
MEM_TOTAL=0; MEM_AVAILABLE=0
DISK_PATH=""; DISK_TOTAL=0; DISK_FREE=0; DISK_MOUNT=""
KERNEL=""; KERNEL_MAJOR=0
INIT_SYSTEM="unknown"
CGROUPS="unknown"
VIRTUALIZATION=""
IS_ROOT=false; SUDO_AVAILABLE=false; INVOKING_USER=""
EXISTING_DOCKER=false; EXISTING_DOCKER_VERSION=""
DOCKER_REPO_REACHABLE=""   # true | false | unknown

_CHECK_LEVEL=(); _CHECK_NAME=(); _CHECK_DETAIL=()
add_check() { _CHECK_LEVEL+=("$1"); _CHECK_NAME+=("$2"); _CHECK_DETAIL+=("$3"); }

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
ver_ge() {  # ver_ge "v1" "v2" → true when v1 >= v2
  local a="$1" b="$2"
  [[ -z "$a" || -z "$b" ]] && return 1
  [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n1)" == "$b" ]]
}

human_bytes() {
  awk -v b="$1" 'BEGIN{
    if (b+0 >= 1099511627776) printf "%.1f TiB", b/1099511627776;
    else if (b+0 >= 1073741824) printf "%.1f GiB", b/1073741824;
    else if (b+0 >= 1048576)   printf "%.1f MiB", b/1048576;
    else if (b+0 >= 1024)      printf "%.1f KiB", b/1024;
    else                       printf "%d B", b;
  }'
}

_nearest_existing() {
  local p="$1"
  while [[ ! -e "$p" ]]; do
    p="$(dirname "$p")"
    if [[ "$p" == "/" ]]; then break; fi
  done
  echo "$p"
}

path_mount() {  # reported mount point of $1 (best effort)
  local p
  p="$(_nearest_existing "$1")"
  df --output=target "$p" 2>/dev/null | tail -n 1 | tr -d ' '
}

path_free_bytes() {  # free bytes on the filesystem backing $1
  local p
  p="$(_nearest_existing "$1")"
  local out
  out="$(df -B1 --output=avail "$p" 2>/dev/null | tail -n 1)"
  out="${out//[^0-9]/}"
  if [[ -z "$out" ]]; then
    out="$(df -B1 "$p" 2>/dev/null | tail -n 1 | awk '{print $4}')"
  fi
  echo "$out"
}

path_total_bytes() {  # total bytes on the filesystem backing $1
  local p
  p="$(_nearest_existing "$1")"
  local out
  out="$(df -B1 --output=size "$p" 2>/dev/null | tail -n 1)"
  out="${out//[^0-9]/}"
  if [[ -z "$out" ]]; then
    out="$(df -B1 "$p" 2>/dev/null | tail -n 1 | awk '{print $2}')"
  fi
  echo "$out"
}

run() {
  if [[ "$DRY_RUN" == true ]]; then
    log_info "[dry-run] $*"
    return 0
  fi
  "$@"
}

# ---------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------
detect_os() {
  local file
  for file in /etc/os-release /usr/lib/os-release /usr/share/os-release; do
    [[ -r "$file" ]] && { OS_RELEASE_FILE="$file"; break; }
  done

  if [[ -n "$OS_RELEASE_FILE" ]]; then
    local key value
    OS_ID=""; OS_NAME=""; OS_ID_LIKE=""; OS_VERSION_ID=""; OS_VERSION=""
    OS_VERSION_CODENAME=""; OS_PRETTY_NAME=""
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
      [[ -z "$key" ]] && continue
      [[ "$key" =~ ^[A-Za-z0-9_]+$ ]] || continue
      value="${value%$'\r'}"
      value="${value%\"}"; value="${value#\"}"
      value="${value%\'}"; value="${value#\'}"
      printf -v "OS_${key}" '%s' "$value"
    done < "$OS_RELEASE_FILE"
    OS_ID="${OS_ID,,}"
  fi

  if [[ -z "$OS_ID" ]]; then
    if command -v lsb_release >/dev/null 2>&1; then
      OS_ID="$(lsb_release -is 2>/dev/null | tr '[:upper:]' '[:lower:]')"
      OS_PRETTY_NAME="$(lsb_release -is 2>/dev/null) $(lsb_release -rs 2>/dev/null)"
      OS_NAME="$OS_PRETTY_NAME"
      OS_VERSION_ID="$(lsb_release -r 2>/dev/null | cut -d: -f2 | tr -d ' ')"
      OS_VERSION_CODENAME="$(lsb_release -cs 2>/dev/null || true)"
    fi
  fi

  [[ -z "$OS_ID" ]] && OS_ID="unknown"

  # ---------------- family classification ----------------
  local id_like="${OS_ID_LIKE:-}"
  case "$OS_ID" in
    ubuntu|debian|raspbian|raspberrypi|linuxmint|pop|elementary|zorin|mx|kali|neon|deepin|openkylin)
      OS_FAMILY="apt"; OS_PKG_MANAGER="apt" ;;
    rocky|almalinux|fedora|centos|rhel|oracle|amzn|amazon|ol|amzn2|amzn-linux|mountaineer)
      OS_FAMILY="dnf"; OS_PKG_MANAGER="dnf" ;;
    opensuse-leap|opensuse-tumbleweed|sles|opensuse)
      OS_FAMILY="zypper"; OS_PKG_MANAGER="zypper" ;;
    alpine)
      OS_FAMILY="apk"; OS_PKG_MANAGER="apk" ;;
    arch|manjaro|endeavouros|garuda|artix|blackarch|parabola)
      OS_FAMILY="pacman"; OS_PKG_MANAGER="pacman" ;;
    *)
      if [[ "$id_like" == *ubuntu* ]]; then
        OS_FAMILY="apt"; OS_PKG_MANAGER="apt"
      elif [[ "$id_like" == *debian* ]]; then
        OS_FAMILY="apt"; OS_PKG_MANAGER="apt"
      elif [[ "$id_like" == *rhel* || "$id_like" == *centos* || "$id_like" == *fedora* ]]; then
        OS_FAMILY="dnf"; OS_PKG_MANAGER="dnf"
      elif [[ "$id_like" == *opensuse* ]]; then
        OS_FAMILY="zypper"; OS_PKG_MANAGER="zypper"
      elif [[ "$id_like" == *arch* ]]; then
        OS_FAMILY="pacman"; OS_PKG_MANAGER="pacman"
      else
        OS_FAMILY="unknown"; OS_PKG_MANAGER="unknown"
      fi ;;
  esac

  # ---------------- supported check ----------------
  case "$OS_FAMILY" in
    apt|dnf|zypper|apk|pacman) OS_SUPPORTED=true ;;
    *) OS_SUPPORTED=false ;;
  esac

  # ---------------- repo slugs ----------------
  case "$OS_FAMILY" in
    apt)
      case "$OS_ID" in
        ubuntu|linuxmint|pop|elementary|zorin|neon|openkylin)
          OS_REPO_SLUG="ubuntu" ;;
        debian|raspbian|raspberrypi|mx|kali|deepin)
          OS_REPO_SLUG="debian" ;;
        *)
          if [[ "${OS_ID_LIKE:-}" == *ubuntu* ]]; then OS_REPO_SLUG="ubuntu"
          elif [[ "${OS_ID_LIKE:-}" == *debian* ]]; then OS_REPO_SLUG="debian"
          else OS_REPO_SLUG="debian"; fi ;;
      esac
      # codename: CLI override > os-release > lsb_release > map from VERSION_ID
      if [[ -z "$OS_REPO_CODENAME" ]]; then
        OS_REPO_CODENAME="${OS_VERSION_CODENAME:-}"
      fi
      if [[ -z "$OS_REPO_CODENAME" ]] && command -v lsb_release >/dev/null 2>&1; then
        OS_REPO_CODENAME="$(lsb_release -cs 2>/dev/null || true)"
      fi
      if [[ -z "$OS_REPO_CODENAME" ]]; then
        case "$OS_ID" in
          ubuntu)
            case "$OS_VERSION_ID" in
              20.04|20.10) OS_REPO_CODENAME="focal" ;;
              22.04|22.10) OS_REPO_CODENAME="jammy" ;;
              24.04|24.10) OS_REPO_CODENAME="noble" ;;
              *) OS_REPO_CODENAME="" ;;
            esac ;;
          *)
            case "$OS_VERSION_ID" in
              11) OS_REPO_CODENAME="bullseye" ;;
              12) OS_REPO_CODENAME="bookworm" ;;
              13) OS_REPO_CODENAME="trixie" ;;
              *) OS_REPO_CODENAME="" ;;
            esac ;;
        esac
      fi ;;

    dnf)
      case "$OS_ID" in
        rhel)             OS_REPO_SLUG="rhel" ;;
        rocky)            OS_REPO_SLUG="rocky" ;;
        almalinux)        OS_REPO_SLUG="almalinux" ;;
        fedora)           OS_REPO_SLUG="fedora" ;;
        centos)           OS_REPO_SLUG="centos" ;;
        oracle|ol)        OS_REPO_SLUG="oracle" ;;
        amzn|amazon|mountaineer) OS_REPO_SLUG="amazon" ;;
        *)
          if [[ "$id_like" == *rocky* ]]; then OS_REPO_SLUG="rocky"
          elif [[ "$id_like" == *almalinux* ]]; then OS_REPO_SLUG="almalinux"
          elif [[ "$id_like" == *fedora* ]]; then OS_REPO_SLUG="fedora"
          elif [[ "$id_like" == *centos* ]]; then OS_REPO_SLUG="centos"
          elif [[ "$id_like" == *amazon* ]]; then OS_REPO_SLUG="amazon"
          elif [[ "$id_like" == *rhel* ]]; then OS_REPO_SLUG="rhel"
          else OS_REPO_SLUG="rhel"; fi ;;
      esac
      OS_REPO_MAJOR="${OS_VERSION_ID%%.*}" ;;

    zypper)
      case "$OS_ID" in
        opensuse-leap|opensuse) OS_REPO_SLUG="opensuse"; OS_REPO_MAJOR="$OS_VERSION_ID" ;;
        opensuse-tumbleweed)    OS_REPO_SLUG="opensuse"; OS_REPO_MAJOR="tumbleweed" ;;
        sles)                   OS_REPO_SLUG="sles"; OS_REPO_MAJOR="$OS_VERSION_ID" ;;
        *)                      OS_REPO_SLUG="opensuse"; OS_REPO_MAJOR="$OS_VERSION_ID" ;;
      esac ;;

    apk|pacman) OS_REPO_SLUG=""; OS_REPO_MAJOR=""; OS_REPO_CODENAME="" ;;
    *) OS_REPO_SLUG="" ;;
  esac
  return 0
}

detect_arch() {
  local raw
  raw="$(uname -m)"
  case "$raw" in
    x86_64|amd64) ARCH_ARCH="x86_64"; ARCH_BASEARCH="x86_64"; ARCH_SUPPORTED=true ;;
    aarch64|arm64) ARCH_ARCH="aarch64"; ARCH_BASEARCH="aarch64"; ARCH_SUPPORTED=true ;;
    armv7l|armv7|armv6l|armv6) ARCH_ARCH="armv7l"; ARCH_BASEARCH="armv7l"; ARCH_SUPPORTED=true ;;
    i686|i386|i586|i486|i486m) ARCH_ARCH="i386"; ARCH_BASEARCH="i386"; ARCH_SUPPORTED=false ;;
    ppc64le|ppc64) ARCH_ARCH="ppc64le"; ARCH_BASEARCH="ppc64le"; ARCH_SUPPORTED=true ;;
    s390x) ARCH_ARCH="s390x"; ARCH_BASEARCH="s390x"; ARCH_SUPPORTED=true ;;
    riscv64) ARCH_ARCH="riscv64"; ARCH_BASEARCH="riscv64"; ARCH_SUPPORTED=true ;;
    *) ARCH_ARCH="$raw"; ARCH_BASEARCH="$raw"; ARCH_SUPPORTED=false ;;
  esac
  return 0
}

detect_cpu() {
  CPU_MODEL="$(awk 'BEGIN{IGNORECASE=1} /^model name/{sub(/^.*:/,""); gsub(/^[ \t]+|[ \t]+$/,""); print; exit}' /proc/cpuinfo 2>/dev/null)"
  [[ -z "$CPU_MODEL" ]] && CPU_MODEL="$(awk 'BEGIN{IGNORECASE=1} /^hardware/{sub(/^.*:/,""); gsub(/^[ \t]+|[ \t]+$/,""); print; exit}' /proc/cpuinfo 2>/dev/null)"
  CPU_MODEL="${CPU_MODEL:-Unknown CPU}"
  CPU_CORES="$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 0)"
  if [[ -z "$CPU_CORES" ]]; then CPU_CORES=0; fi
  return 0
}

detect_memory() {
  MEM_TOTAL=0
  MEM_AVAILABLE=0
  while read -r key val unit; do
    case "$key" in
      MemTotal:)     MEM_TOTAL=$((val * 1024)) ;;
      MemAvailable:) MEM_AVAILABLE=$((val * 1024)) ;;
    esac
  done < /proc/meminfo
  if [[ -z "$MEM_TOTAL" ]]; then MEM_TOTAL=0; fi
  if [[ -z "$MEM_AVAILABLE" ]]; then MEM_AVAILABLE=0; fi
  return 0
}

detect_disk() {
  DISK_PATH="/"
  DISK_MOUNT="$(path_mount "/" 2>/dev/null || true)"
  DISK_TOTAL="$(path_total_bytes "/")"
  DISK_FREE="$(path_free_bytes "/")"
  if [[ -z "$DISK_TOTAL" ]]; then DISK_TOTAL=0; fi
  if [[ -z "$DISK_FREE" ]]; then DISK_FREE=0; fi
  return 0
}

detect_kernel() {
  KERNEL="$(uname -r)"
  local major="${KERNEL%%.*}"
  if [[ "$major" =~ ^[0-9]+$ ]]; then
    KERNEL_MAJOR="$major"
  else
    KERNEL_MAJOR=0
  fi
  return 0
}

detect_init() {
  if [[ -d /run/systemd/system ]]; then
    INIT_SYSTEM="systemd"
  elif command -v rc-service >/dev/null 2>&1; then
    INIT_SYSTEM="openrc"
  elif command -v service >/dev/null 2>&1; then
    INIT_SYSTEM="sysvinit"
  else
    INIT_SYSTEM="unknown"
  fi
  return 0
}

detect_cgroups() {
  if [[ -r /sys/fs/cgroup/cgroup.controllers ]]; then
    CGROUPS="v2"
    if [[ -d /sys/fs/cgroup/memory || -d /sys/fs/cgroup/cpu ]]; then
      CGROUPS="v2 (hybrid: v1 controllers visible)"
    fi
  elif [[ -r /sys/fs/cgroup/memory/memory.limit_in_bytes || -d /sys/fs/cgroup/memory ]]; then
    CGROUPS="v1"
  else
    CGROUPS="unknown"
  fi
  return 0
}

detect_virtualization() {
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    VIRTUALIZATION="$(systemd-detect-virt 2>/dev/null || true)"
  fi
  if [[ -z "$VIRTUALIZATION" ]]; then VIRTUALIZATION="unknown"; fi
  return 0
}

detect_privileges() {
  if [[ "$EUID" -eq 0 ]]; then
    IS_ROOT=true
    INVOKING_USER="root"
    SUDO_AVAILABLE=true
  else
    IS_ROOT=false
    SUDO_AVAILABLE=false
    command -v sudo >/dev/null 2>&1 && SUDO_AVAILABLE=true
    if [[ -n "${SUDO_USER:-}" ]]; then
      INVOKING_USER="$SUDO_USER"
    elif [[ -n "${USER:-}" ]]; then
      INVOKING_USER="$USER"
    elif [[ -n "${LOGNAME:-}" ]]; then
      INVOKING_USER="$LOGNAME"
    else
      INVOKING_USER="unknown"
    fi
  fi
  return 0
}

detect_existing_docker() {
  if command -v docker >/dev/null 2>&1; then
    EXISTING_DOCKER=true
    EXISTING_DOCKER_VERSION="$(docker --version 2>/dev/null || echo 'unknown')"
  else
    EXISTING_DOCKER=false
    EXISTING_DOCKER_VERSION=""
  fi
  return 0
}

check_network() {
  if [[ "$SKIP_NETWORK_CHECK" == true ]]; then
    DOCKER_REPO_REACHABLE="unknown"
    return
  fi
  if ! command -v curl >/dev/null 2>&1; then
    DOCKER_REPO_REACHABLE="unknown"
    return
  fi
  local target="${DOCKER_REPO_BASE}/${OS_REPO_SLUG:-ubuntu}/gpg"
  if [[ "$OS_FAMILY" == "apk" || "$OS_FAMILY" == "pacman" ]]; then
    target="https://dl-cdn.alpinelinux.org/alpine/"
    [[ "$OS_FAMILY" == "pacman" ]] && target="https://geo.mirror.pkgbuild.com/"
  fi
  if curl -fsS --connect-timeout 8 --max-time 15 -o /dev/null "$target" 2>/dev/null; then
    DOCKER_REPO_REACHABLE="true"
  elif curl -fsS --connect-timeout 8 --max-time 15 -o /dev/null "https://download.docker.com" 2>/dev/null || \
       curl -fsS --connect-timeout 8 --max-time 15 -o /dev/null "$DOCKER_REPO_BASE" 2>/dev/null; then
    DOCKER_REPO_REACHABLE="true"
  else
    DOCKER_REPO_REACHABLE="false"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Compatibility checks → entries in _CHECK_* arrays
# ---------------------------------------------------------------------------
run_compatibility_checks() {
  _CHECK_LEVEL=(); _CHECK_NAME=(); _CHECK_DETAIL=()

  # OS
  if [[ "$OS_SUPPORTED" == true ]]; then
    add_check ok "OS" "${OS_PRETTY_NAME:-$OS_ID} (ID: $OS_ID, family: $OS_FAMILY)"
  else
    add_check error "OS" "unsupported OS: ${OS_ID:-unknown} — see --use-convenience-script"
  fi

  # EOL / minimum versions
  case "$OS_ID" in
    ubuntu)
      if [[ -n "$OS_VERSION_ID" ]] && ! ver_ge "$OS_VERSION_ID" "20.04"; then
        add_check warn "OS release" "Ubuntu $OS_VERSION_ID is EOL — official repo for it may be gone"
      fi ;;
    debian)
      if [[ -n "$OS_VERSION_ID" ]] && ! ver_ge "$OS_VERSION_ID" "11"; then
        add_check warn "OS release" "Debian $OS_VERSION_ID is below 11 (bullseye) — official repo support is limited"
      fi ;;
    centos)
      if [[ -n "$OS_VERSION_ID" ]] && ! ver_ge "$OS_VERSION_ID" "8"; then
        add_check warn "OS release" "CentOS $OS_VERSION_ID is EOL (post-2024)"
      fi ;;
    rocky|almalinux)
      if [[ -n "$OS_VERSION_ID" ]] && ! ver_ge "$OS_VERSION_ID" "8"; then
        add_check warn "OS release" "$OS_ID $OS_VERSION_ID is below 8 — official repo may not exist"
      fi ;;
    alpine)
      if [[ -n "$OS_VERSION_ID" ]] && ! ver_ge "$OS_VERSION_ID" "3.14"; then
        add_check warn "OS release" "Alpine $OS_VERSION_ID is below 3.14 — official package support is limited"
      fi ;;
  esac

  # Package manager availability
  local pm="$OS_PKG_MANAGER"
  if [[ "$pm" != "unknown" ]]; then
    if command -v "$pm" >/dev/null 2>&1; then
      add_check ok "Package manager" "$pm"
    else
      add_check error "Package manager" "expected '$pm' but it was not found in PATH"
    fi
  fi

  # Architecture
  if [[ "$ARCH_SUPPORTED" == true ]]; then
    if [[ "$OS_FAMILY" == "dnf" && "$ARCH_ARCH" == "armv7l" ]]; then
      add_check warn "Architecture" "armv7l: official dnf repos may not ship packages for this arch — prefer --from-distro"
    else
      add_check ok "Architecture" "$ARCH_ARCH (repo basearch: $ARCH_BASEARCH)"
    fi
  else
    add_check error "Architecture" "unsupported architecture '$ARCH_ARCH'"
  fi

  # Kernel
  if [[ "$KERNEL_MAJOR" -lt 3 ]]; then
    add_check error "Kernel" "$KERNEL — Docker requires >= 3.10 (4.x recommended)"
  elif [[ "$KERNEL_MAJOR" -lt 4 ]]; then
    add_check warn "Kernel" "$KERNEL — kernel 4.x recommended for modern Docker"
  else
    add_check ok "Kernel" "$KERNEL"
  fi

  # CPU
  add_check ok "CPU" "$CPU_MODEL ($CPU_CORES core(s))"

  # Memory
  if [[ "$MEM_TOTAL" -lt 1073741824 ]]; then
    add_check warn "Memory" "$(human_bytes $MEM_TOTAL) total — recommended >= 1 GiB"
  else
    add_check ok "Memory" "$(human_bytes $MEM_TOTAL) total ($(human_bytes $MEM_AVAILABLE) available)"
  fi

  # Disk
  if [[ "$DISK_FREE" -lt 10737418240 ]]; then
    add_check warn "Disk" "$(human_bytes $DISK_FREE) free on / — recommended >= 10 GiB"
  else
    add_check ok "Disk" "$(human_bytes $DISK_FREE) free on / ($(human_bytes $DISK_TOTAL) total, ${DISK_MOUNT:-unknown mount})"
  fi

  # Init / systemd
  case "$INIT_SYSTEM" in
    systemd) add_check ok "Init system" "systemd" ;;
    openrc)  add_check ok "Init system" "OpenRC (alpine-style service manager)" ;;
    sysvinit) add_check warn "Init system" "sysvinit — Docker will be started manually, not auto-enabled" ;;
    *)        add_check warn "Init system" "unknown — Docker will be started manually" ;;
  esac

  # Cgroups
  case "$CGROUPS" in
    v1|v2*)  add_check ok "Cgroups" "$CGROUPS" ;;
    *)
      if [[ -r /sys/fs/cgroup/cgroup.controllers || -d /sys/fs/cgroup/memory ]]; then
        add_check warn "Cgroups" "$CGROUPS — could not detect version, Docker may fail to start"
      else
        add_check error "Cgroups" "cgroup filesystem not found (required for Docker)"
      fi ;;
  esac

  # Virtualization (informational)
  if [[ "$VIRTUALIZATION" == "none" ]]; then
    add_check ok "Virtualization" "not detected — runs bare-metal"
  elif [[ -n "$VIRTUALIZATION" ]]; then
    if [[ "$VIRTUALIZATION" == "docker" || "$VIRTUALIZATION" == "lxc" ]]; then
      add_check warn "Virtualization" "inside $VIRTUALIZATION — nested Docker: verify your kernel allows overlay/userns"
    else
      add_check ok "Virtualization" "$VIRTUALIZATION"
    fi
  fi

  # Privileges
  if [[ "$IS_ROOT" == true ]]; then
    add_check ok "Privilege" "root"
  elif [[ "$SUDO_AVAILABLE" == true ]]; then
    add_check ok "Privilege" "non-root ($INVOKING_USER) with sudo"
  else
    add_check error "Privilege" "non-root ($INVOKING_USER) and sudo is missing — cannot install"
  fi

  # Network
  if [[ "$DOCKER_REPO_REACHABLE" == "true" ]]; then
    add_check ok "Network" "official repository reachable"
  elif [[ "$DOCKER_REPO_REACHABLE" == "false" ]]; then
    add_check warn "Network" "official repository unreachable — install may fail; check your network/proxy"
  else
    add_check info "Network" "skipped or curl missing — install may fail if the network is restricted"
  fi

  # Existing Docker
  if [[ "$EXISTING_DOCKER" == true ]]; then
    add_check warn "Existing Docker" "found: $EXISTING_DOCKER_VERSION — will refresh/upgrade"
  else
    add_check ok "Docker" "not installed (fresh install)"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
print_report() {
  printf "\n%s%s%s\n" "$C_BOLD" "# $SCRIPT_NAME v$SCRIPT_VERSION" "$C_RESET"
  rule
  section "Environment report"
  local i
  for i in "${!_CHECK_LEVEL[@]}"; do
    case "${_CHECK_LEVEL[$i]}" in
      ok)    check_ok   "${_CHECK_NAME[$i]}: ${_CHECK_DETAIL[$i]}" ;;
      warn)  check_warn "${_CHECK_NAME[$i]}: ${_CHECK_DETAIL[$i]}" ;;
      error) check_fail "${_CHECK_NAME[$i]}: ${_CHECK_DETAIL[$i]}" ;;
      info)  check_info "${_CHECK_NAME[$i]}: ${_CHECK_DETAIL[$i]}" ;;
    esac
  done
  rule
}

collect_json_data() {
  # Build JSON via python3 to avoid quoting bugs.
  if ! command -v python3 >/dev/null 2>&1; then
    log_error "Python3 is required for --json output (not found in PATH)"
    exit 1
  fi
  export DET_SCRIPT_NAME="$SCRIPT_NAME"
  export DET_VERSION="$SCRIPT_VERSION"
  export DET_OS_ID="$OS_ID" DET_OS_NAME="$OS_PRETTY_NAME" DET_OS_FAMILY="$OS_FAMILY"
  export DET_OS_PKG_MANAGER="$OS_PKG_MANAGER" DET_OS_VERSION_ID="$OS_VERSION_ID"
  export DET_OS_VERSION_CODENAME="$OS_VERSION_CODENAME" DET_OS_SUPPORTED="$OS_SUPPORTED"
  export DET_OS_REPO_SLUG="$OS_REPO_SLUG" DET_OS_REPO_MAJOR="$OS_REPO_MAJOR"
  export DET_OS_REPO_CODENAME="$OS_REPO_CODENAME"
  export DET_ARCH_ARCH="$ARCH_ARCH" DET_ARCH_BASEARCH="$ARCH_BASEARCH" DET_ARCH_SUPPORTED="$ARCH_SUPPORTED"
  export DET_CPU_MODEL="$CPU_MODEL" DET_CPU_CORES="$CPU_CORES"
  export DET_MEM_TOTAL="$MEM_TOTAL" DET_MEM_AVAILABLE="$MEM_AVAILABLE"
  export DET_DISK_TOTAL="$DISK_TOTAL" DET_DISK_FREE="$DISK_FREE" DET_DISK_MOUNT="$DISK_MOUNT"
  export DET_KERNEL="$KERNEL" DET_INIT="$INIT_SYSTEM" DET_CGROUPS="$CGROUPS"
  export DET_VIRT="$VIRTUALIZATION"
  export DET_IS_ROOT="$IS_ROOT" DET_SUDO="$SUDO_AVAILABLE" DET_INVOKING_USER="$INVOKING_USER"
  export DET_EXISTING_DOCKER="$EXISTING_DOCKER" DET_EXISTING_DOCKER_VERSION="$EXISTING_DOCKER_VERSION"
  export DET_DOCKER_REPO_REACHABLE="$DOCKER_REPO_REACHABLE"
  export DET_KERNEL_MAJOR="$KERNEL_MAJOR"
  python3 - <<'PY'
import json, os
def g(k, d=""):
    return os.environ.get("DET_" + k, d)
def bf(k, d=False):
    v = g(k)
    return v in ("true", "1", "yes")
checks = []
for i in range(int(g("CHECK_COUNT", "0"))):
    checks.append({
        "level": g(f"CHECK_{i}_LEVEL"),
        "name": g(f"CHECK_{i}_NAME"),
        "detail": g(f"CHECK_{i}_DETAIL"),
    })
report = {
    "tool": "install-docker.sh",
    "version": g("VERSION"),
    "generated_at": __import__("time").strftime("%Y-%m-%dT%H:%M:%S"),
    "os": {
        "id": g("OS_ID"),
        "name": g("OS_NAME"),
        "family": g("OS_FAMILY"),
        "package_manager": g("OS_PKG_MANAGER"),
        "version": g("OS_VERSION_ID"),
        "codename": g("OS_VERSION_CODENAME"),
        "supported": bf("OS_SUPPORTED"),
        "repo_slug": g("OS_REPO_SLUG"),
        "repo_major": g("OS_REPO_MAJOR"),
        "repo_codename": g("OS_REPO_CODENAME"),
    },
    "architecture": {
        "arch": g("ARCH_ARCH"),
        "repo_basearch": g("ARCH_BASEARCH"),
        "supported": bf("ARCH_SUPPORTED"),
    },
    "cpu": {"model": g("CPU_MODEL"), "cores": int(g("CPU_CORES", "0"))},
    "memory": {"total_bytes": int(g("MEM_TOTAL", "0")), "available_bytes": int(g("MEM_AVAILABLE", "0"))},
    "disk": {"total_bytes": int(g("DISK_TOTAL", "0")), "free_bytes": int(g("DISK_FREE", "0")), "mount": g("DISK_MOUNT")},
    "kernel": {"version": g("KERNEL"), "major": int(g("KERNEL_MAJOR", "0"))},
    "init_system": g("INIT"),
    "cgroups": g("CGROUPS"),
    "virtualization": g("VIRT"),
    "privileges": {"is_root": bf("IS_ROOT"), "sudo_available": bf("SUDO"), "invoking_user": g("INVOKING_USER")},
    "network": {"repo_reachable": g("DOCKER_REPO_REACHABLE")},
    "existing_docker": {"present": bf("EXISTING_DOCKER"), "version": g("EXISTING_DOCKER_VERSION")},
    "checks": checks,
}
print(json.dumps(report, indent=2, ensure_ascii=False))
PY
}

# collect checks for JSON
collect_json_from_report() {
  local i
  export DET_CHECK_COUNT="${#_CHECK_LEVEL[@]}"
  for i in "${!_CHECK_LEVEL[@]}"; do
    export "DET_CHECK_${i}_LEVEL=${_CHECK_LEVEL[$i]}"
    export "DET_CHECK_${i}_NAME=${_CHECK_NAME[$i]}"
    export "DET_CHECK_${i}_DETAIL=${_CHECK_DETAIL[$i]}"
  done
}

# ---------------------------------------------------------------------------
# Installers
# ---------------------------------------------------------------------------
SUDO=""
setup_sudo() {
  if [[ "$EUID" -eq 0 ]]; then
    SUDO=""
  else
    SUDO="sudo"
  fi
}

install_apt() {
  local slug="$1" codename="$2" method="$3"
  if [[ "$method" == "official" ]]; then
    section "Installing via official apt repository ($slug / $codename)"
  else
    section "Installing via distro packages (apt)"
  fi

  if [[ "$method" == "official" ]]; then
    local dpkg_arch
    dpkg_arch="$(dpkg --print-architecture 2>/dev/null || echo "$ARCH_BASEARCH")"
    run $SUDO apt-get update
    run $SUDO apt-get install -y ca-certificates curl gnupg
    run $SUDO install -m 0755 -d /etc/apt/keyrings
    run $SUDO bash -c "curl -fsSL '${DOCKER_REPO_BASE}/${slug}/gpg' | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
    run $SUDO chmod a+r /etc/apt/keyrings/docker.gpg
    run $SUDO bash -c "echo 'deb [arch=${dpkg_arch} signed-by=/etc/apt/keyrings/docker.gpg] ${DOCKER_REPO_BASE}/${slug}/ ${codename} stable' > /etc/apt/sources.list.d/docker.list"
    run $SUDO apt-get update
    run $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    run $SUDO apt-get update
    run $SUDO apt-get install -y docker.io
    log_note "docker.io installed — the compose plugin is not part of the Debian/Ubuntu package"
  fi
}

install_dnf() {
  local slug="$1" major="$2" method="$3"
  if [[ "$method" == "official" ]]; then
    section "Installing via official dnf repository ($slug / $major)"
  else
    section "Installing via distro packages (dnf)"
  fi

  if [[ "$method" == "official" ]]; then
    run $SUDO dnf -y install "dnf-plugins-core"
    run $SUDO bash -c "printf '%s\n' '[docker-ce]' 'name=Docker CE Repository - \$basearch' 'baseurl=${DOCKER_REPO_BASE}/${slug}/${major}/\$basearch/stable' 'enabled=1' 'gpgcheck=1' 'gpgkey=${DOCKER_REPO_BASE}/${slug}/gpg' > /etc/yum.repos.d/docker-ce.repo"
    run $SUDO dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    run $SUDO dnf -y install docker
    log_note "docker installed — the compose plugin is not part of the distro package"
  fi
}

install_zypper() {
  local slug="$1" major="$2" method="$3"
  if [[ "$method" == "official" ]]; then
    section "Installing via official zypper repository ($slug / $major)"
  else
    section "Installing via distro packages (zypper)"
  fi

  if [[ "$method" == "official" ]]; then
    local arch url
    arch="$(uname -m)"
    if [[ "$slug" == "opensuse" && "$major" == "tumbleweed" ]]; then
      url="${DOCKER_REPO_BASE}/opensuse/tumbleweed/${arch}/stable"
    elif [[ "$slug" == "opensuse" ]]; then
      url="${DOCKER_REPO_BASE}/opensuse/leap/${major}/${arch}/stable"
    else
      url="${DOCKER_REPO_BASE}/${slug}/${major}/${arch}/stable"
    fi
    run $SUDO zypper --gpg-auto-import-keys refresh
    run $SUDO zypper addrepo --gpgcheck "$url" docker-ce
    run $SUDO zypper refresh
    run $SUDO zypper install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    run $SUDO zypper install -y docker
  fi
}

install_apk() {
  section "Installing via Alpine package manager (apk)"
  run $SUDO apk update
  run $SUDO apk add --no-cache docker
}

install_pacman() {
  section "Installing via Arch package manager (pacman)"
  run $SUDO pacman -Sy --noconfirm docker
}

install_convenience_script() {
  section "Installing via official convenience script (get.docker.com)"
  log_warn "The get.docker.com convenience script is unpinned and unsupported for production use — consider a supported distro"
  run $SUDO bash -c "curl -fsSL https://get.docker.com | bash --ignore-os-interface-check"
}

install() {
  setup_sudo
  if [[ "$FROM_DISTRO" == true ]]; then
    INSTALL_METHOD="distro"
  else
    INSTALL_METHOD="official"
  fi

  # unsupported OS/arch fallback
  if [[ "$OS_SUPPORTED" == false || "$ARCH_SUPPORTED" == false ]]; then
    if [[ "$USE_CONVENIENCE_SCRIPT" == true ]]; then
      log_warn "Unsupported OS/arch detected — falling back to the official convenience script"
      install_convenience_script
      return
    fi
    die "Unsupported OS or architecture. Use --use-convenience-script to try the official convenience script."
  fi

  local slug="$OS_REPO_SLUG" major="$OS_REPO_MAJOR" codename="$OS_REPO_CODENAME"

  case "$OS_FAMILY" in
    apt)
      if [[ -z "$codename" ]]; then
        die "Could not determine the Debian/Ubuntu codename — pass --codename <name> (e.g. bookworm)"
      fi
      install_apt "$slug" "$codename" "$([[ "$FROM_DISTRO" == true ]] && echo distro || echo official)" ;;
    dnf)
      install_dnf "$slug" "$major" "$([[ "$FROM_DISTRO" == true ]] && echo distro || echo official)" ;;
    zypper)
      install_zypper "$slug" "$major" "$([[ "$FROM_DISTRO" == true ]] && echo distro || echo official)" ;;
    apk)
      install_apk ;;
    pacman)
      install_pacman ;;
    *)
      die "No installer for distro family '$OS_FAMILY'. Use --use-convenience-script to try the official convenience script." ;;
  esac
}

# ---------------------------------------------------------------------------
# Post-install
# ---------------------------------------------------------------------------
post_install() {
  local docker_cmd_suffix=""

  section "Configuring Docker"

  # docker group
  if [[ "$EUID" -ne 0 && "$INVOKING_USER" != "root" && "$INVOKING_USER" != "unknown" ]]; then
    run $SUDO groupadd -f docker
    run $SUDO usermod -aG docker "$INVOKING_USER"
    log_note "User '$INVOKING_USER' added to the docker group — log out/in for it to take effect"
  elif [[ "$EUID" -ne 0 ]]; then
    log_note "Could not determine invoking user — add yourself to the docker group manually"
  fi

  # service
  if [[ "$NO_SERVICE" == false ]]; then
    case "$INIT_SYSTEM" in
      systemd)
        run $SUDO systemctl daemon-reload
        run $SUDO systemctl enable docker
        run $SUDO systemctl restart docker
        ;;
      openrc)
        run $SUDO rc-update add docker default 2>/dev/null || true
        run $SUDO rc-service docker start 2>/dev/null || true
        ;;
      sysvinit|*)
        log_note "Start the docker service manually (e.g. 'service docker start')"
        ;;
    esac
  fi

  # verification
  section "Verifying the installation"
  if [[ "$DRY_RUN" == true ]]; then
    log_info "[dry-run] would run: docker info"
    log_info "[dry-run] would run: docker compose version"
  else
    local info_cmd=()
    if [[ "$EUID" -ne 0 ]]; then
      info_cmd=($SUDO docker info)
    else
      info_cmd=(docker info)
    fi
    if "${info_cmd[@]}" >/dev/null 2>&1; then
      log_ok "docker info: OK"
    else
      log_warn "docker info failed — check the service (e.g. 'systemctl status docker')"
      log_warn "You may need to log in again to use your docker group membership"
    fi
    local compose_cmd=()
    if [[ "$EUID" -ne 0 ]]; then
      compose_cmd=($SUDO docker compose version)
      if [[ -z "$SUDO" ]]; then compose_cmd=(docker compose version); fi
    else
      compose_cmd=(docker compose version)
    fi
    if "${compose_cmd[@]}" >/dev/null 2>&1; then
      log_ok "docker compose plugin: OK"
    else
      log_note "docker compose plugin not found in PATH"
    fi
  fi

  # summary
  section "Summary"
  echo "  OS            : ${OS_PRETTY_NAME:-$OS_ID} ($OS_ID $OS_VERSION_ID)"
  if [[ "$INSTALL_METHOD" == "distro" ]]; then
    echo "  Install method: $OS_FAMILY (distro packages)"
  else
    echo "  Install method: $OS_FAMILY (official Docker repo)"
  fi
  echo "  Init system   : $INIT_SYSTEM"
  echo "  Cgroups       : $CGROUPS"
  echo "  Virtualization: $VIRTUALIZATION"
  if [[ "$DRY_RUN" == true ]]; then
    log_note "This was a dry run — nothing was changed"
  else
    log_ok "Docker is installed and configured"
  fi
  echo
  log_info "Try it:"
  log_info "  docker run hello-world"
  log_info "  docker compose version"
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
uninstall() {
  section "Docker uninstallation plan"
  setup_sudo

  if [[ "$IS_ROOT" == false && "$SUDO_AVAILABLE" == false ]]; then
    die "Cannot uninstall without root or sudo"
  fi

  log_warn "This will remove Docker from the system"
  if [[ "$PURGE" == true ]]; then
    log_warn "This WILL also delete all Docker data (/var/lib/docker) — backups are your responsibility"
  fi

  local answer
  if [[ "$DRY_RUN" != true ]]; then
    if [[ "$YES" != true ]]; then
      if [[ ! -t 0 ]]; then
        die "Non-interactive: use --yes to confirm (and --purge for /var/lib/docker removal)"
      fi
      read -r -p "Continue with uninstall? [y/N] " answer
      [[ "$answer" =~ ^[Yy](es)?$ ]] || die "Aborted"
    fi
  fi

  # stop/disable
  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    run $SUDO systemctl disable --now docker 2>/dev/null || true
  elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
    run $SUDO rc-service docker stop 2>/dev/null || true
    run $SUDO rc-update del docker default 2>/dev/null || true
  else
    log_note "Stop the docker service manually if it is running"
  fi

  case "$OS_FAMILY" in
    apt)
      run $SUDO apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker.io || true
      run $SUDO rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.gpg
      ;;
    dnf)
      run $SUDO dnf -y remove docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker || true
      run $SUDO rm -f /etc/yum.repos.d/docker-ce.repo
      ;;
    zypper)
      run $SUDO zypper remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || true
      run $SUDO zypper removerepo docker-ce 2>/dev/null || true
      ;;
    apk)
      run $SUDO apk del docker 2>/dev/null || true
      ;;
    pacman)
      run $SUDO pacman -Rns --noconfirm docker || true
      ;;
  esac

  if [[ "$PURGE" == true ]]; then
    if [[ "$DRY_RUN" != true && "$YES" != true ]]; then
      echo
      read -r -p "WARNING: this deletes ALL Docker data in /var/lib/docker. Type 'yes' to confirm: " answer
      [[ "$answer" == "yes" ]] || die "Aborted"
    fi
    run $SUDO rm -rf /var/lib/docker
    if [[ "$DRY_RUN" == true ]]; then
      log_note "[dry-run] Docker data would be removed"
    else
      log_ok "Docker data removed"
    fi
  else
    log_note "Docker data kept at /var/lib/docker — use --purge to remove it"
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log_note "[dry-run] Would uninstall Docker — nothing was changed"
  else
    log_ok "Docker uninstalled"
  fi
}

# ---------------------------------------------------------------------------
# Preflight / confirmation
# ---------------------------------------------------------------------------
confirm() {
  [[ "$YES" == true ]] && return 0
  if [[ ! -t 0 ]]; then
    log_warn "stdin is not a TTY — use --yes/-y to confirm non-interactively"
    return 1
  fi
  echo
  echo "  About to install Docker CE on ${OS_PRETTY_NAME:-$OS_ID}"
  echo "  • method   : $OS_FAMILY"
  echo "  • packages : docker-ce, docker-ce-cli, containerd.io, plugins"
  echo "  • init     : $INIT_SYSTEM"
  echo
  read -r -p "Continue? [y/N] " answer
  [[ "$answer" =~ ^[Yy](es)?$ ]]
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
usage() {
  cat <<USAGE
$SCRIPT_NAME v$SCRIPT_VERSION — automated Docker CE installer with pre-flight detection

USAGE:
  $SCRIPT_NAME [OPTIONS]

OPTIONS:
  --detect-only            Print the detection report and exit (no changes)
  --dry-run                Print the installation plan without changing anything
  --json                   Print the detection report as JSON (requires python3)
  --strict                 Treat any warning as fatal
  --yes, -y                Skip the confirmation prompt (required for non-TTY)
  --no-service             Do not enable/start the docker service
  --from-distro            Use distro packages instead of the official Docker repo
                          (apt: docker.io, dnf: docker) — not for zypper/apk/pacman
  --skip-network-check     Skip the repository reachability check
  --codename <name>        Override the apt repo codename (e.g. bookworm)
  --use-convenience-script Fallback to get.docker.com on unsupported OS/arch
  --uninstall              Remove Docker (optionally with --purge)
  --purge                  With --uninstall: also delete /var/lib/docker
  --version                Print version and exit
  --help, -h               Show this help

EXIT CODES:
  0  Success (or detect-only report generated)
  1  Detection failed, unsupported configuration, or install failed
  2  Strict mode: warnings were present

SUPPORTED:
  Ubuntu 20.04+, Debian 11+, RHEL 8/9, Rocky Linux, AlmaLinux, Oracle Linux,
  Amazon Linux 2/2023, Fedora, CentOS Stream 8/9, openSUSE Leap 15.x/Tumbleweed,
  SLES 15, Alpine 3.14+, Arch Linux / Manjaro / EndeavourOS.

NOT SUPPORTED: Windows, macOS (use Docker Desktop), FreeBSD, generic Linux
  distributions without the listed structures.

EXAMPLES:
  $SCRIPT_NAME --detect-only
  $SCRIPT_NAME --dry-run --yes
  $SCRIPT_NAME --strict
  $SCRIPT_NAME --uninstall --purge --yes
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --detect-only) DETECT_ONLY=true ;;
      --dry-run) DRY_RUN=true ;;
      --json) JSON_REPORT=true ;;
      --strict) STRICT=true ;;
      --yes|-y) YES=true ;;
      --no-service) NO_SERVICE=true ;;
      --from-distro) FROM_DISTRO=true ;;
      --skip-network-check) SKIP_NETWORK_CHECK=true ;;
      --codename)
        shift
        [[ -n "${1:-}" ]] || die "--codename requires a value (e.g. bookworm)"
        OS_REPO_CODENAME="$1" ;;
      --use-convenience-script) USE_CONVENIENCE_SCRIPT=true ;;
      --uninstall) UNINSTALL=true ;;
      --purge) PURGE=true ;;
      --version|-v) echo "$SCRIPT_VERSION"; exit 0 ;;
      --help|-h) usage; exit 0 ;;
      --) shift; break ;;
      *) log_error "Unknown option: $1"; usage >&2; exit 1 ;;
    esac
    shift || true
  done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"

  detect_os
  detect_arch
  detect_cpu
  detect_memory
  detect_disk
  detect_kernel
  detect_init
  detect_cgroups
  detect_virtualization
  detect_privileges
  detect_existing_docker
  check_network
  run_compatibility_checks

  # strict-ish gate: OS/arch/package-manager errors are fatal even without --strict
  local has_error=false has_warn=false
  local i
  for i in "${!_CHECK_LEVEL[@]}"; do
    [[ "${_CHECK_LEVEL[$i]}" == "error" ]] && has_error=true
    [[ "${_CHECK_LEVEL[$i]}" == "warn" ]] && has_warn=true
  done

  collect_json_from_report

  if [[ "$JSON_REPORT" == true ]]; then
    collect_json_data
    if [[ "$has_error" == true ]]; then
      exit 1
    fi
    if [[ "$STRICT" == true && "$has_warn" == true ]]; then
      exit 2
    fi
    exit 0
  fi

  print_report

  if [[ "$has_error" == true ]]; then
    log_error "Detection failed — fix the errors above or use --use-convenience-script"
    exit 1
  fi

  if [[ "$STRICT" == true && "$has_warn" == true ]]; then
    log_error "Strict mode: warnings detected — aborting"
    exit 2
  fi

  if [[ "$DETECT_ONLY" == true ]]; then
    log_ok "Detection complete — nothing was changed"
    exit 0
  fi

  if [[ "$UNINSTALL" == true ]]; then
    uninstall
    exit 0
  fi

  if [[ "$DRY_RUN" == false ]]; then
    confirm || die "Confirmation declined (use --yes to skip the prompt)"
  fi

  install

  if [[ "$UNINSTALL" != true ]]; then
    post_install
  fi

  exit 0
}

main "$@"
