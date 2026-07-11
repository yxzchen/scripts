#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

# Zero-dependency interactive bootstrap for Debian, Ubuntu, and macOS.
#
# Architecture:
#   1. Options register metadata and three callbacks: packages, plan, apply.
#   2. Selected packages are collected and deduplicated before installation.
#   3. The package manager runs once, then idempotent apply callbacks run in order.
#
# Add a future option by defining its callbacks and registering it in
# register_options. The menu, CLI selection, plan, help, and execution dispatcher
# all consume the same registry.

readonly SCRIPT_NAME="${0##*/}"
readonly ZIM_INSTALL_URL="https://raw.githubusercontent.com/zimfw/install/master/install.zsh"
readonly BREW_INSTALL_URL="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
readonly DOTFILES_BASE_URL="${DOTFILES_BASE_URL:-https://raw.githubusercontent.com/yxzchen/scripts/master}"
readonly WARP_PROXY_PORT=40000
readonly WARP_KEY_FINGERPRINT="C068A2B5771775193CBE1F2F6E2DD2174FA1C3BA"

# CLI and runtime state
DRY_RUN=false
CHECK_ONLY=false
SELECT_ARG=""
OS_KIND=""
LINUX_DISTRO=""
LINUX_VERSION=""
LINUX_CODENAME=""
SELECTED_IDS=""
BREW_BIN=""
TEMP_DIR=""
CURRENT_STEP=""
FRP_RELEASE_RESOLVED=false
FRP_RELEASE_PREPARED=false
FRP_RELEASE_DIR=""
FRP_VERSION=""
FRP_ASSET_ARCH=""
DOTFILE_TEMPLATE_DIR=""

# Minimal platform context used by the TUI, self-check, and Homebrew bootstrap.
PLATFORM_LABEL=""
ARCH=""

# Option registry. All arrays use the same index.
OPTION_IDS=()
OPTION_PARENT_IDS=()
OPTION_TITLES=()
OPTION_SUMMARIES=()
OPTION_DETAIL_FNS=()
OPTION_PACKAGE_FNS=()
OPTION_PLAN_FNS=()
OPTION_APPLY_FNS=()

# Package plan, in stable first-seen order.
PLANNED_PACKAGES=()
PLANNED_PACKAGE_GROUPS=()
CURRENT_PACKAGE_GROUP=""

# TUI state
TUI_ACTIVE=false
TUI_CURSOR=0
TUI_EXPANDED_IDS=""
TUI_MESSAGE=""
TUI_VISIBLE_INDICES=()
KEY=""

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Interactively initialize a Debian, Ubuntu, or macOS machine.

Options:
  --dry-run       Print every planned command without changing the machine
  --select LIST   Preselect comma-separated option numbers/IDs, or "all"
  --check         Validate the platform, registry, callbacks, and package plan
  -h, --help      Show this help

Examples:
  ./${SCRIPT_NAME}
  ./${SCRIPT_NAME} --dry-run --select all
  ./${SCRIPT_NAME} --dry-run --select shell,base
  ./${SCRIPT_NAME} --dry-run --select base-terminal,ops-network
  ./${SCRIPT_NAME} --check

Interactive keys:
  Up/Down or j/k   Move between options
  Left/Right or e  Collapse or expand a parent
  Space            Select or deselect
  d / h            Show option details / help
  a / Enter / q    Toggle all / review plan / quit
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

notice() {
  printf '%s\n' "$*"
}

section() {
  CURRENT_STEP="$1"
  printf '\n==> %s\n' "$1"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run)
        DRY_RUN=true
        ;;
      --select)
        [ "$#" -ge 2 ] || die "--select requires a value"
        SELECT_ARG="$2"
        shift
        ;;
      --check)
        CHECK_ONLY=true
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      --)
        shift
        [ "$#" -eq 0 ] || die "positional arguments are not supported"
        break
        ;;
      *)
        die "unknown option: $1 (use --help)"
        ;;
    esac
    shift
  done

  if $CHECK_ONLY && { $DRY_RUN || [ -n "$SELECT_ARG" ]; }; then
    die "--check cannot be combined with --dry-run or --select"
  fi
}

detect_platform() {
  case "$(uname -s)" in
    Linux)
      OS_KIND="linux"
      [ -r /etc/os-release ] || die "cannot read /etc/os-release"
      # shellcheck disable=SC1091
      . /etc/os-release
      LINUX_DISTRO="${ID:-}"
      LINUX_VERSION="${VERSION_ID:-unknown}"
      LINUX_CODENAME="${VERSION_CODENAME:-}"
      case "$LINUX_DISTRO" in
        debian | ubuntu) ;;
        *)
          die "unsupported Linux distribution: ${PRETTY_NAME:-$LINUX_DISTRO};" \
            'only Debian and Ubuntu are supported'
          ;;
      esac
      [ -n "$LINUX_CODENAME" ] || die 'Linux VERSION_CODENAME is required for APT repositories'
      PLATFORM_LABEL="${PRETTY_NAME:-${LINUX_DISTRO} ${LINUX_VERSION}}"
      ;;
    Darwin)
      OS_KIND="macos"
      [ "$(id -u)" -ne 0 ] || die "run this script as your login user, not root, on macOS"
      PLATFORM_LABEL="macOS $(sw_vers -productVersion)"
      ;;
    *)
      die "unsupported operating system: $(uname -s)"
      ;;
  esac

  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    die "do not run the entire script with sudo; run it as ${SUDO_USER}" \
      'and let it request sudo when needed'
  fi
  ARCH="$(uname -m)"
}

# Registry -------------------------------------------------------------------

register_option() {
  [ "$#" -eq 8 ] || die "internal error: register_option expects 8 arguments"
  OPTION_IDS+=("$1")
  OPTION_PARENT_IDS+=("$2")
  OPTION_TITLES+=("$3")
  OPTION_SUMMARIES+=("$4")
  OPTION_DETAIL_FNS+=("$5")
  OPTION_PACKAGE_FNS+=("$6")
  OPTION_PLAN_FNS+=("$7")
  OPTION_APPLY_FNS+=("$8")
}

register_group() {
  [ "$#" -eq 4 ] || die "internal error: register_group expects 4 arguments"
  register_option "$1" "" "$2" "$3" "$4" packages_none plan_none apply_noop
}

register_options() {
  register_option \
    shell "" \
    "Zimfw" \
    "Install and configure Zimfw for the current user." \
    detail_shell packages_shell plan_shell apply_shell

  register_option \
    dotfiles "" \
    "Configuration files" \
    "Download and overwrite the repository-managed Zsh and Git configuration files." \
    detail_dotfiles packages_dotfiles plan_dotfiles apply_dotfiles

  register_option \
    yazi "" \
    "Yazi file manager" \
    "Install the current Yazi terminal file manager and ya helper." \
    detail_yazi packages_yazi plan_yazi apply_yazi

  if [ "$OS_KIND" = "linux" ]; then
    register_group \
      base \
      "Base commands" \
      "Daily commands grouped into core, terminal, and transfer tools." \
      detail_base_group
    register_option \
      base-core base \
      "Core utilities" \
      "Certificates, downloads, file inspection, paging, and locale." \
      detail_base_core packages_base_core plan_base_core apply_base_core
    register_option \
      base-terminal base \
      "Terminal productivity" \
      "Editor, Git, fuzzy search, and structured-text tools." \
      detail_base_terminal packages_base_terminal plan_base_terminal apply_base_terminal
    register_option \
      base-transfer base \
      "Transfer and archives" \
      "File synchronization, archive, and compression commands." \
      detail_base_transfer packages_base_transfer plan_none apply_noop

    register_group \
      ops \
      "Operations tools" \
      "System and network diagnostics." \
      detail_ops_group
    register_option \
      ops-process ops \
      "System diagnostics" \
      "Process inspection, tracing, and system activity monitoring." \
      detail_ops_process packages_ops_process plan_none apply_noop
    register_option \
      ops-network ops \
      "Network diagnostics" \
      "Connectivity, routing, DNS, packet capture, and scanning tools." \
      detail_ops_network packages_ops_network plan_none apply_noop
    register_group \
      dev \
      "Development environment" \
      "Build, performance, C/C++, debugging, and Python toolsets." \
      detail_dev_group
    register_option \
      dev-build dev \
      "Build toolchains" \
      "GCC, Clang/LLVM, CMake, Ninja, Autotools, and ccache." \
      detail_dev_build packages_dev_build plan_none apply_noop
    register_option \
      dev-performance dev \
      "Performance and eBPF" \
      "NUMA, perf, bpftrace, and bpftool tooling." \
      detail_dev_performance packages_dev_performance plan_none apply_noop
    register_option \
      dev-libs dev \
      "C/C++ libraries" \
      "OpenSSL, io_uring, gflags/glog, ncurses, and NUMA headers." \
      detail_dev_libs packages_dev_libs plan_none apply_noop
    register_option \
      dev-quality dev \
      "Testing and static analysis" \
      "Formatting, tests, benchmarks, coverage, and static analysis." \
      detail_dev_quality packages_dev_quality plan_none apply_noop
    register_option \
      dev-debug dev \
      "Debugging" \
      "Native debugging with gdb." \
      detail_dev_debug packages_dev_debug plan_none apply_noop
    register_option \
      dev-python dev \
      "Python workflow" \
      "Python development files, venv, pip, pipx, and pre-commit." \
      detail_dev_python packages_dev_python plan_dev_python apply_dev_python

    register_group \
      frp \
      "FRP" \
      "Install FRP client/server binaries and optional systemd units." \
      detail_frp_group
    register_option \
      frpc frp \
      "FRP client (frpc)" \
      "Install the latest frpc binary from GitHub." \
      detail_frpc packages_frpc plan_frpc apply_frpc
    register_option \
      frpc-systemd frp \
      "frpc systemd service" \
      "Create a frpc configuration template and enable its systemd unit." \
      detail_frpc_systemd packages_none plan_frpc_systemd apply_frpc_systemd
    register_option \
      frps frp \
      "FRP server (frps)" \
      "Install the latest frps binary from GitHub." \
      detail_frps packages_frps plan_frps apply_frps
    register_option \
      frps-systemd frp \
      "frps systemd service" \
      "Create a frps configuration template and enable its systemd unit." \
      detail_frps_systemd packages_none plan_frps_systemd apply_frps_systemd

    register_option \
      warp "" \
      "Cloudflare WARP proxy" \
      "Install Cloudflare WARP and configure its local SOCKS5 proxy." \
      detail_warp packages_warp plan_warp apply_warp
  else
    register_option \
      common "" \
      "Common commands" \
      "Install current Homebrew and commonly used terminal commands." \
      detail_common packages_common plan_common apply_noop

    register_option \
      lima "" \
      "Lima virtualization" \
      "Install Lima virtual machines with Homebrew." \
      detail_lima packages_lima plan_none apply_noop

    register_group \
      frp \
      "FRP" \
      "Install FRP with Homebrew and optionally configure launchd services." \
      detail_frp_group
    register_option \
      frpc frp \
      "FRP client (frpc)" \
      "Install frpc with Homebrew." \
      detail_frpc packages_frpc plan_frpc apply_frpc
    register_option \
      frpc-launchd frp \
      "frpc launchd service" \
      "Prepare the Homebrew launchd service for frpc." \
      detail_frpc_service packages_none plan_frpc_service apply_frpc_service
    register_option \
      frps frp \
      "FRP server (frps)" \
      "Install frps with Homebrew." \
      detail_frps packages_frps plan_frps apply_frps
    register_option \
      frps-launchd frp \
      "frps launchd service" \
      "Prepare the Homebrew launchd service for frps." \
      detail_frps_service packages_none plan_frps_service apply_frps_service
  fi
}

validate_registry() {
  local count id seen index callback
  count="${#OPTION_IDS[@]}"
  [ "$count" -gt 0 ] || die "internal error: no options registered"

  if ! {
    [ "${#OPTION_PARENT_IDS[@]}" -eq "$count" ] &&
      [ "${#OPTION_TITLES[@]}" -eq "$count" ] &&
      [ "${#OPTION_SUMMARIES[@]}" -eq "$count" ] &&
      [ "${#OPTION_DETAIL_FNS[@]}" -eq "$count" ] &&
      [ "${#OPTION_PACKAGE_FNS[@]}" -eq "$count" ] &&
      [ "${#OPTION_PLAN_FNS[@]}" -eq "$count" ] &&
      [ "${#OPTION_APPLY_FNS[@]}" -eq "$count" ]
  }; then
    die "internal error: option registry columns have different lengths"
  fi

  seen=""
  index=0
  while [ "$index" -lt "$count" ]; do
    id="${OPTION_IDS[$index]}"
    case "$id" in
      '' | *[!a-z0-9_-]*) die "internal error: invalid option ID: $id" ;;
    esac
    case " $seen " in
      *" $id "*) die "internal error: duplicate option ID: $id" ;;
      *) seen="${seen}${seen:+ }$id" ;;
    esac

    for callback in \
      "${OPTION_DETAIL_FNS[$index]}" \
      "${OPTION_PACKAGE_FNS[$index]}" \
      "${OPTION_PLAN_FNS[$index]}" \
      "${OPTION_APPLY_FNS[$index]}"; do
      declare -F "$callback" >/dev/null || die "internal error: missing callback: $callback"
    done

    if [ -n "${OPTION_PARENT_IDS[$index]}" ]; then
      option_index "${OPTION_PARENT_IDS[$index]}" >/dev/null ||
        die "internal error: missing parent ${OPTION_PARENT_IDS[$index]} for $id"
    fi
    index=$((index + 1))
  done
}

option_index() {
  local wanted index
  wanted="$1"
  index=0
  while [ "$index" -lt "${#OPTION_IDS[@]}" ]; do
    if [ "${OPTION_IDS[$index]}" = "$wanted" ]; then
      printf '%s' "$index"
      return 0
    fi
    index=$((index + 1))
  done
  return 1
}

selection_token_to_id() {
  local token index
  token="$1"
  case "$token" in
    '' | *[!0-9]*)
      option_index "$token" >/dev/null || return 1
      printf '%s' "$token"
      ;;
    *)
      index=$((token - 1))
      [ "$index" -ge 0 ] && [ "$index" -lt "${#OPTION_IDS[@]}" ] || return 1
      printf '%s' "${OPTION_IDS[$index]}"
      ;;
  esac
}

is_selected() {
  case " $SELECTED_IDS " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

has_children() {
  local parent
  for parent in "${OPTION_PARENT_IDS[@]}"; do
    [ "$parent" = "$1" ] && return 0
  done
  return 1
}

selection_state() {
  local id index child_count selected_children
  id="$1"
  if ! has_children "$id"; then
    is_selected "$id" && printf 'all' || printf 'none'
    return
  fi

  child_count=0
  selected_children=0
  index=0
  while [ "$index" -lt "${#OPTION_IDS[@]}" ]; do
    if [ "${OPTION_PARENT_IDS[$index]}" = "$id" ]; then
      child_count=$((child_count + 1))
      is_selected "${OPTION_IDS[$index]}" && selected_children=$((selected_children + 1))
    fi
    index=$((index + 1))
  done

  if [ "$selected_children" -eq 0 ]; then
    printf 'none'
  elif [ "$selected_children" -eq "$child_count" ]; then
    printf 'all'
  else
    printf 'partial'
  fi
}

select_leaf() {
  local dependency
  dependency="$(option_dependency "$1")"
  [ -z "$dependency" ] || select_leaf "$dependency"
  is_selected "$1" || SELECTED_IDS="${SELECTED_IDS}${SELECTED_IDS:+ }$1"
}

option_dependency() {
  case "$1" in
    frpc-systemd | frpc-launchd) printf 'frpc' ;;
    frps-systemd | frps-launchd) printf 'frps' ;;
    *) printf '' ;;
  esac
}

select_id() {
  local id index found_child
  id="$1"
  found_child=false
  index=0
  while [ "$index" -lt "${#OPTION_IDS[@]}" ]; do
    if [ "${OPTION_PARENT_IDS[$index]}" = "$id" ]; then
      select_leaf "${OPTION_IDS[$index]}"
      found_child=true
    fi
    index=$((index + 1))
  done
  $found_child || select_leaf "$id"
}

deselect_id() {
  local dependency id target result index
  target="$1"
  result=""
  for id in $SELECTED_IDS; do
    if [ "$id" = "$target" ]; then
      continue
    fi
    dependency="$(option_dependency "$id")"
    if [ "$dependency" = "$target" ]; then
      continue
    fi
    index="$(option_index "$id")"
    [ "${OPTION_PARENT_IDS[$index]}" = "$target" ] || result="${result}${result:+ }$id"
  done
  SELECTED_IDS="$result"
}

select_all() {
  local id
  SELECTED_IDS=""
  for id in "${OPTION_IDS[@]}"; do
    has_children "$id" || select_leaf "$id"
  done
}

selected_count() {
  local id count
  count=0
  for id in $SELECTED_IDS; do
    count=$((count + 1))
  done
  printf '%s' "$count"
}

selectable_count() {
  local id count
  count=0
  for id in "${OPTION_IDS[@]}"; do
    has_children "$id" || count=$((count + 1))
  done
  printf '%s' "$count"
}

parse_selection() {
  local input item id old_ifs
  input="$(printf '%s' "$1" | tr -d '[:space:]')"
  [ -n "$input" ] || die "no option selected"

  case "$input" in
    all | a | A)
      select_all
      return
      ;;
  esac

  old_ifs="$IFS"
  IFS=,
  # Intentional splitting of the comma-separated CLI value.
  # shellcheck disable=SC2086
  set -- $input
  IFS="$old_ifs"
  for item in "$@"; do
    id="$(selection_token_to_id "$item")" || die "invalid option: $item"
    select_id "$id"
  done
}

# Package catalog ------------------------------------------------------------

package_is_installed() {
  local status
  status="$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)"
  [ "$status" = 'install ok installed' ]
}

package_is_available() {
  local candidate
  candidate="$(
    LC_ALL=C apt-cache policy "$1" 2>/dev/null |
      awk '$1 == "Candidate:" {candidate = $2} END {print candidate}'
  )"
  [ -n "$candidate" ] && [ "$candidate" != '(none)' ]
}

add_package() {
  local package existing
  package="$1"
  case "$package" in
    '' | *' '* | *$'\t'* | *$'\n'*) die "internal error: invalid package name: $package" ;;
  esac
  if [ "${#PLANNED_PACKAGES[@]}" -gt 0 ]; then
    for existing in "${PLANNED_PACKAGES[@]}"; do
      [ "$existing" = "$package" ] && return
    done
  fi
  PLANNED_PACKAGES+=("$package")
  PLANNED_PACKAGE_GROUPS+=("$CURRENT_PACKAGE_GROUP")
}

add_packages() {
  local package
  for package in "$@"; do
    add_package "$package"
  done
}

packages_shell() {
  if [ "$OS_KIND" = "linux" ]; then
    add_package zsh
  fi
}

packages_dotfiles() {
  if [ "$OS_KIND" = "linux" ]; then
    add_packages ca-certificates curl git
  fi
}

packages_yazi() {
  if [ "$OS_KIND" = "linux" ]; then
    add_packages ca-certificates curl jq unzip
  else
    add_package yazi
  fi
}

packages_none() {
  :
}

packages_base_core() {
  add_packages wget file less locales
}

packages_base_terminal() {
  add_packages vim fd-find bat ripgrep jq tree
}

packages_base_transfer() {
  add_packages rsync unzip zip xz-utils
}

packages_ops_process() {
  add_packages procps psmisc lsof strace htop sysstat iotop
}

packages_ops_network() {
  add_packages \
    iputils-ping traceroute mtr-tiny whois \
    tcpdump nmap netcat-openbsd socat iproute2 ethtool
  add_dnsutils_package
}

add_dnsutils_package() {
  if package_is_installed bind9-dnsutils || package_is_installed dnsutils; then
    return
  fi
  if apt-cache show bind9-dnsutils >/dev/null 2>&1; then
    add_package bind9-dnsutils
  else
    add_package dnsutils
  fi
}

packages_dev_performance() {
  add_packages numactl bpftrace
  if [ "$LINUX_DISTRO" = "debian" ]; then
    add_packages bpftool linux-perf
  else
    add_package linux-tools-generic
  fi
}

packages_dev_build() {
  add_packages \
    build-essential autoconf automake \
    clang clangd lld \
    cmake ninja-build pkg-config libtool ccache
}

packages_dev_libs() {
  add_packages \
    libncurses-dev libssl-dev liburing-dev \
    libgoogle-glog-dev libgflags-dev libnuma-dev
}

packages_dev_quality() {
  add_packages clang-format clang-tidy libgtest-dev libbenchmark-dev gcovr cppcheck
}

packages_dev_debug() {
  add_package gdb
}

packages_dev_python() {
  add_packages python3-dev python3-venv python3-pip pipx
}

packages_common() {
  add_packages bat exiftool fd fzf htop ripgrep tree
}

packages_lima() {
  add_package lima
}

packages_frpc() {
  [ "$OS_KIND" = "linux" ] || add_package frpc
}

packages_frps() {
  [ "$OS_KIND" = "linux" ] || add_package frps
}

packages_warp() {
  package_is_installed cloudflare-warp && return
  add_packages ca-certificates curl gnupg
}

build_package_plan() {
  local index id callback
  PLANNED_PACKAGES=()
  PLANNED_PACKAGE_GROUPS=()

  if [ "$OS_KIND" = "linux" ] &&
    {
      is_selected shell || is_selected base-core || is_selected base-terminal ||
        is_selected frpc || is_selected frps
    }; then
    CURRENT_PACKAGE_GROUP="Shared prerequisites"
    if is_selected shell || is_selected base-core || is_selected base-terminal ||
      is_selected frpc || is_selected frps; then
      add_packages ca-certificates curl
    fi
    if is_selected shell || is_selected base-terminal; then
      add_package git
    fi
  fi

  index=0
  while [ "$index" -lt "${#OPTION_IDS[@]}" ]; do
    id="${OPTION_IDS[$index]}"
    if is_selected "$id"; then
      CURRENT_PACKAGE_GROUP="${OPTION_TITLES[$index]}"
      callback="${OPTION_PACKAGE_FNS[$index]}"
      "$callback"
    fi
    index=$((index + 1))
  done
}

# Option details and plan callbacks ------------------------------------------

detail_shell() {
  printf 'Purpose\n  Configure the current user with Zsh and Zimfw.\n\n'
  printf 'Packages\n'
  if [ "$OS_KIND" = "linux" ]; then
    printf '  zsh, curl, ca-certificates, and git.\n'
  else
    printf '  Uses the Zsh, curl, and git supplied by the current macOS release.\n'
  fi
  printf '\nConfiguration\n'
  printf '  - Download and run the official current Zimfw installer.\n'
  printf '  - Zimfw backs up an existing .zshrc before prepending its managed block.\n'
  printf '  - Install Zim modules under %s.\n' "${ZIM_HOME:-$HOME/.zim}"
  printf '  - Change the login shell exactly once, after Zimfw is configured.\n'
  printf '  - A complete existing Zimfw installation is left unchanged.\n'
}

plan_shell() {
  printf '    - Install Zimfw under %s for %s\n' "${ZIM_HOME:-$HOME/.zim}" "$(id -un)"
  printf '    - Back up an existing .zshrc before Zimfw prepends its configuration\n'
  printf '    - Change the login shell to Zsh when necessary\n'
}

detail_dotfiles() {
  printf 'Download and overwrite these files in %s:\n\n' "$HOME"
  printf '  .zimrc\n  .zshrc.local\n'
  if [ "$OS_KIND" = "linux" ] && [ "$LINUX_DISTRO" = "ubuntu" ]; then
    printf '  .zshenv\n'
  fi
  printf '  .gitconfig.local\n\n'
  printf 'Existing copies are replaced without backups.\n'
  printf 'If .zshrc does not load .zshrc.local, append an idempotent guarded source line.\n'
  printf 'If .gitconfig does not include .gitconfig.local, add a Git include entry.\n'
  printf 'Refresh Zimfw modules when Zimfw is available.\n'
}

plan_dotfiles() {
  if [ "$OS_KIND" = "linux" ] && [ "$LINUX_DISTRO" = "ubuntu" ]; then
    printf '    - Download four Zsh/Git configuration files from GitHub\n'
    printf '    - Overwrite %s/{.zimrc,.zshrc.local,.zshenv,.gitconfig.local}\n' "$HOME"
  else
    printf '    - Download three Zsh/Git configuration files from GitHub\n'
    printf '    - Overwrite %s/{.zimrc,.zshrc.local,.gitconfig.local}\n' "$HOME"
  fi
  printf '    - Make .zshrc load .zshrc.local when it does not already do so\n'
  printf '    - Make .gitconfig include .gitconfig.local when it does not already do so\n'
  printf '    - Refresh Zimfw modules when Zimfw is available\n'
}

detail_yazi() {
  if [ "$OS_KIND" = "linux" ]; then
    printf 'Download the latest official Yazi release from GitHub, verify the asset\n'
    printf 'digest published by GitHub, and install yazi and ya in /usr/local/bin.\n'
  else
    printf 'Install the current yazi formula with Homebrew.\n'
  fi
}

plan_yazi() {
  if [ "$OS_KIND" = "linux" ]; then
    printf '    - Resolve and download the latest official Yazi GitHub release\n'
    printf '    - Verify its SHA-256 digest and install yazi and ya in /usr/local/bin\n'
  else
    printf '    - Install yazi with Homebrew\n'
  fi
}

detail_base_group() {
  printf 'Select the entire group or choose individual child options:\n\n'
  printf '  Core utilities         Downloads, inspection, paging, and locale.\n'
  printf '  Terminal productivity Editor, Git, search, and structured-text tools.\n'
  printf '  Transfer and archives Synchronization and compression commands.\n'
}

detail_base_core() {
  printf 'Packages\n  ca-certificates, curl, wget, file, less, and locales.\n\n'
  printf 'Configuration\n  Generate and select en_US.UTF-8 only when needed.\n'
}

plan_base_core() {
  printf '    - Generate and select en_US.UTF-8 when needed\n'
}

detail_base_terminal() {
  printf 'Packages\n  vim, git, fd, bat, ripgrep, jq, and tree through APT.\n'
  printf '  The latest fzf release is downloaded separately from GitHub.\n\n'
  printf 'Configuration\n'
  printf '  Provide fd/bat names without overwriting existing commands.\n'
}

plan_base_terminal() {
  printf '    - Download the latest fzf release from GitHub and verify its SHA-256 checksum\n'
  printf '    - Install fzf at /usr/local/bin/fzf when the latest version is not present\n'
  printf '    - Add fd/bat compatibility symlinks only when their destinations are free\n'
}

detail_base_transfer() {
  printf 'Packages\n  rsync, unzip, zip, and xz-utils.\n\n'
  printf 'This option only installs commands and does not change configuration.\n'
}

detail_ops_group() {
  printf 'Select the entire group or choose individual child options:\n\n'
  printf '  System diagnostics  Process inspection, tracing, and activity monitoring.\n'
  printf '  Network diagnostics Connectivity, routing, DNS, and packets.\n\n'
  printf 'No child option enables a daemon or persistent service.\n'
}

detail_ops_process() {
  printf 'Packages\n  procps, psmisc, lsof, strace, htop, sysstat, and iotop.\n'
}

detail_ops_network() {
  printf 'Packages\n  ping, DNS tools, traceroute, mtr, whois, tcpdump, nmap,\n'
  printf '  netcat, socat, iproute2, and ethtool.\n'
  printf '  DNS tools use bind9-dnsutils when available, with dnsutils as fallback.\n'
}

detail_dev_performance() {
  printf 'Packages\n  numactl, bpftrace, bpftool, and perf.\n\n'
  printf 'The kernel tools package is selected separately for Debian and Ubuntu.\n'
  printf 'Some commands require root privileges or matching kernel features at runtime.\n'
}

detail_dev_group() {
  printf 'Select the entire group or choose individual child options:\n\n'
  printf '  Build toolchains       Compilers and build systems.\n'
  printf '  Performance and eBPF  NUMA, perf, bpftrace, and bpftool.\n'
  printf '  C/C++ libraries       Common backend headers and libraries.\n'
  printf '  Testing and analysis  Formatting, tests, coverage, and analysis.\n'
  printf '  Debugging              Native debugging with gdb.\n'
  printf '  Python workflow        Python, pipx, and pre-commit.\n'
}

detail_dev_build() {
  printf 'Packages\n  GCC/build-essential, Clang/LLVM, CMake, Ninja, Autotools,\n'
  printf '  pkg-config, libtool, and ccache.\n'
}

detail_dev_libs() {
  printf 'Packages\n  OpenSSL, io_uring, gflags/glog, ncurses, and NUMA headers.\n'
}

detail_dev_quality() {
  printf 'Packages\n  clang-format, clang-tidy, GoogleTest, Google Benchmark,\n'
  printf '  gcovr, and cppcheck.\n'
}

detail_dev_debug() {
  printf 'Packages\n  gdb.\n'
}

detail_dev_python() {
  printf 'Packages\n  Python development files, venv, pip, and pipx.\n\n'
  printf 'Configuration\n'
  printf '  Install pre-commit through pipx and configure its binary directory.\n'
  printf '  The pipx binary directory is added to ~/.zshrc.\n'
}

plan_dev_python() {
  printf '    - Ensure the pipx binary directory is on PATH in ~/.zshrc\n'
  printf '    - Install pre-commit with pipx when it is not already present\n'
}

detail_frp_group() {
  printf 'Select binaries independently and optionally add their platform services:\n\n'
  printf '  FRP client (frpc)  Install the client binary.\n'
  printf '  FRP server (frps)  Install the server binary.\n'
  if [ "$OS_KIND" = "linux" ]; then
    printf '  systemd services   Create config/unit and enable without starting.\n\n'
  else
    printf '  launchd services   Use the service definitions supplied by Homebrew.\n\n'
  fi
  printf 'Selecting a service automatically selects its corresponding binary.\n'
}

detail_frpc() {
  if [ "$OS_KIND" = "linux" ]; then
    printf 'Download the latest frpc release from GitHub, verify its SHA-256 checksum,\n'
    printf 'and install the binary at /usr/local/bin/frpc.\n'
  else
    printf 'Install the current frpc formula and its default configuration with Homebrew.\n'
  fi
}

plan_frpc() {
  if [ "$OS_KIND" = "linux" ]; then
    printf '    - Download and verify the latest frpc release from GitHub\n'
    printf '    - Install frpc at /usr/local/bin/frpc\n'
  else
    printf '    - Install frpc and its default configuration with Homebrew\n'
  fi
}

detail_frps() {
  if [ "$OS_KIND" = "linux" ]; then
    printf 'Download the latest frps release from GitHub, verify its SHA-256 checksum,\n'
    printf 'and install the binary at /usr/local/bin/frps.\n'
  else
    printf 'Install the current frps formula and its default configuration with Homebrew.\n'
  fi
}

plan_frps() {
  if [ "$OS_KIND" = "linux" ]; then
    printf '    - Download and verify the latest frps release from GitHub\n'
    printf '    - Install frps at /usr/local/bin/frps\n'
  else
    printf '    - Install frps and its default configuration with Homebrew\n'
  fi
}

detail_frpc_systemd() {
  printf 'Create /etc/frp/frpc.toml only when missing and install frpc.service.\n'
  printf 'The unit is enabled but not started. Edit the TOML file, then run:\n\n'
  printf '  sudo systemctl start frpc.service\n'
}

plan_frpc_systemd() {
  printf '    - Create /etc/frp/frpc.toml when missing\n'
  printf '    - Install and enable frpc.service without starting it\n'
}

detail_frps_systemd() {
  printf 'Create /etc/frp/frps.toml only when missing and install frps.service.\n'
  printf 'The unit is enabled but not started. Edit the TOML file, then run:\n\n'
  printf '  sudo systemctl start frps.service\n'
}

plan_frps_systemd() {
  printf '    - Create /etc/frp/frps.toml when missing\n'
  printf '    - Install and enable frps.service without starting it\n'
}

detail_frpc_service() {
  printf 'Create and enable a user launchd agent using the Homebrew frpc formula.\n'
  printf 'The agent is not loaded in the current login session.\n'
  printf 'Edit the Homebrew etc/frp/frpc.toml file, then run:\n\n'
  printf '  brew services start frpc\n\n'
  printf 'This starts frpc and registers it to launch when the user logs in.\n'
}

plan_frpc_service() {
  printf '    - Install and enable the frpc user launchd agent\n'
  printf '    - Leave it stopped until its configuration has been edited\n'
}

detail_frps_service() {
  printf 'Create and enable a user launchd agent using the Homebrew frps formula.\n'
  printf 'The agent is not loaded in the current login session.\n'
  printf 'Edit the Homebrew etc/frp/frps.toml file, then run:\n\n'
  printf '  brew services start frps\n\n'
  printf 'This starts frps and registers it to launch when the user logs in.\n'
}

plan_frps_service() {
  printf '    - Install and enable the frps user launchd agent\n'
  printf '    - Leave it stopped until its configuration has been edited\n'
}

detail_warp() {
  printf "Install cloudflare-warp from Cloudflare's signed APT repository.\n\n"
  printf 'Configuration\n'
  printf '  - Register a consumer WARP client when no registration exists.\n'
  printf '  - Use local SOCKS5 proxy mode on 127.0.0.1:%s.\n' "$WARP_PROXY_PORT"
  printf '  - Connect WARP after configuration.\n\n'
  printf 'Service behavior\n'
  printf '  The official package enables and starts warp-svc.service during installation.\n'
  printf '  The script also ensures that service remains enabled and running.\n'
}

plan_warp() {
  if package_is_installed cloudflare-warp; then
    printf '    - cloudflare-warp is already installed; skip its APT repository refresh\n'
  else
    printf "    - Install Cloudflare's current APT signing key and repository\n"
    printf '    - Refresh APT metadata and install cloudflare-warp\n'
  fi
  printf '    - Enable and start warp-svc.service\n'
  printf '    - Register WARP when needed and configure SOCKS5 on 127.0.0.1:%s\n' \
    "$WARP_PROXY_PORT"
  printf '    - Connect the WARP proxy\n'
}

plan_none() {
  :
}

detail_common() {
  printf 'Purpose\n  Provide current Homebrew and a focused set of modern terminal commands.\n\n'
  printf 'Bootstrap\n  Download the official current Homebrew installer when brew is absent.\n\n'
  printf 'Shell integration\n'
  printf '  Add brew shellenv to ~/.zprofile once, for Apple Silicon or Intel.\n\n'
  printf 'Formulae\n  bat, exiftool, fd, fzf, htop, ripgrep, and tree.\n'
}

detail_lima() {
  printf 'Install the current Lima formula with Homebrew.\n'
  printf 'Virtual machines and templates are not created or changed.\n'
}

plan_common() {
  find_brew
  if [ -n "$BREW_BIN" ]; then
    printf '    - Reuse Homebrew at %s\n' "$BREW_BIN"
  else
    printf '    - Download and run the official current Homebrew installer\n'
  fi
  printf '    - Add brew shellenv to ~/.zprofile once\n'
}

apply_noop() {
  :
}

# TUI ------------------------------------------------------------------------

toggle_id() {
  if [ "$(selection_state "$1")" = all ]; then
    deselect_id "$1"
  else
    select_id "$1"
  fi
}

toggle_all() {
  if [ "$(selected_count)" -eq "$(selectable_count)" ]; then
    SELECTED_IDS=""
  else
    select_all
  fi
}

rebuild_visible_indices() {
  local index parent
  TUI_VISIBLE_INDICES=()
  index=0
  while [ "$index" -lt "${#OPTION_IDS[@]}" ]; do
    parent="${OPTION_PARENT_IDS[$index]}"
    if [ -z "$parent" ] || is_group_expanded "$parent"; then
      TUI_VISIBLE_INDICES+=("$index")
    fi
    index=$((index + 1))
  done
}

is_group_expanded() {
  case " $TUI_EXPANDED_IDS " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

collapse_group() {
  local expanded result
  result=""
  for expanded in $TUI_EXPANDED_IDS; do
    [ "$expanded" = "$1" ] || result="${result}${result:+ }$expanded"
  done
  TUI_EXPANDED_IDS="$result"
}

move_tui_cursor() {
  local delta position total
  delta="$1"
  rebuild_visible_indices
  total="${#TUI_VISIBLE_INDICES[@]}"
  position=0
  while [ "$position" -lt "$total" ]; do
    [ "${TUI_VISIBLE_INDICES[$position]}" -eq "$TUI_CURSOR" ] && break
    position=$((position + 1))
  done
  if [ "$delta" -lt 0 ]; then
    position=$(((position + total - 1) % total))
  else
    position=$(((position + 1) % total))
  fi
  TUI_CURSOR="${TUI_VISIBLE_INDICES[$position]}"
}

expand_current_group() {
  local id
  id="${OPTION_IDS[$TUI_CURSOR]}"
  if has_children "$id" && ! is_group_expanded "$id"; then
    TUI_EXPANDED_IDS="${TUI_EXPANDED_IDS}${TUI_EXPANDED_IDS:+ }$id"
  fi
}

collapse_current_group() {
  local id parent
  id="${OPTION_IDS[$TUI_CURSOR]}"
  parent="${OPTION_PARENT_IDS[$TUI_CURSOR]}"
  if [ -n "$parent" ]; then
    collapse_group "$parent"
    TUI_CURSOR="$(option_index "$parent")"
  elif is_group_expanded "$id"; then
    collapse_group "$id"
  fi
}

cleanup_tui() {
  if $TUI_ACTIVE; then
    # Restore the primary screen without leaving menu repaints in command output.
    printf '\033[?25h\033[?1049l'
    TUI_ACTIVE=false
  fi
}

read_key() {
  local remainder
  KEY=""
  IFS= read -rsn1 KEY || return 1
  if [ "$KEY" = $'\033' ]; then
    remainder=""
    # Bash 3.2 (the macOS system Bash) only accepts integral read timeouts.
    IFS= read -rsn2 -t 1 remainder || true
    KEY="${KEY}${remainder}"
  fi
}

draw_menu() {
  local indicator index indent marker parent pointer position state title total summary
  rebuild_visible_indices
  total="${#TUI_VISIBLE_INDICES[@]}"
  summary="${OPTION_SUMMARIES[$TUI_CURSOR]}"

  printf '\033[2J\033[H'
  printf '\033[1mMachine Setup\033[0m\n'
  printf '%s | %s\n' "$PLATFORM_LABEL" "$ARCH"
  printf '\nChoose what to configure. Use \033[1mSpace\033[0m to select or deselect.\n\n'

  position=0
  while [ "$position" -lt "$total" ]; do
    index="${TUI_VISIBLE_INDICES[$position]}"
    state="$(selection_state "${OPTION_IDS[$index]}")"
    case "$state" in
      all) marker='[x]' ;;
      partial) marker='[-]' ;;
      *) marker='[ ]' ;;
    esac
    parent="${OPTION_PARENT_IDS[$index]}"
    if [ -n "$parent" ]; then
      indent='    '
    else
      indent=''
    fi
    pointer=' '
    if [ "$index" -eq "$TUI_CURSOR" ]; then
      pointer='>'
      title="\033[1;36m${OPTION_TITLES[$index]}\033[0m"
    elif has_children "${OPTION_IDS[$index]}"; then
      title="\033[1m${OPTION_TITLES[$index]}\033[0m"
    else
      title="${OPTION_TITLES[$index]}"
    fi
    if has_children "${OPTION_IDS[$index]}"; then
      if is_group_expanded "${OPTION_IDS[$index]}"; then
        indicator='v'
      else
        indicator='>'
      fi
      title="${title}  ${indicator}"
    fi
    printf '  %s%s %s  %b\n' "$indent" "$pointer" "$marker" "$title"
    position=$((position + 1))
  done

  printf '\n\033[2m%s\033[0m\n' "$summary"
  printf '\nSelected options: %s/%s\n' "$(selected_count)" "$(selectable_count)"
  if [ -n "$TUI_MESSAGE" ]; then
    printf '\033[1;33m%s\033[0m\n' "$TUI_MESSAGE"
  else
    printf '\n'
  fi
  printf '\n\033[2mMove: Up/Down  Tree: Left/Right  Toggle: Space\n'
  printf 'd details  h help  a all  Enter continue  q quit\033[0m'
}

wait_for_key() {
  printf '\n\n\033[2mPress any key to return...\033[0m'
  read_key || die "input closed"
}

show_tui_help() {
  printf '\033[2J\033[H'
  printf '\033[1mSelection Help\033[0m\n\n'
  printf '  Up / Down, j / k   Move between configuration options\n'
  printf '  Left / Right, e    Collapse or expand a parent option\n'
  printf '  Space              Select or deselect the highlighted option\n'
  printf '                     A parent toggles all of its child options\n'
  printf '  a                  Select all options; press again to clear all\n'
  printf '  d                  View details for the highlighted option\n'
  printf '  Enter              Build and review the installation plan\n'
  printf '  q                  Quit without making changes\n\n'
  printf 'Nothing is installed from this screen. The next screen shows one deduplicated\n'
  printf 'package transaction plus every configuration change, followed by a final\n'
  printf 'confirmation. Dry-run mode prints commands without executing them.\n'
  wait_for_key
}

show_option_details() {
  local callback
  callback="${OPTION_DETAIL_FNS[$TUI_CURSOR]}"
  printf '\033[2J\033[H'
  printf '\033[1m%s\033[0m\n\n' "${OPTION_TITLES[$TUI_CURSOR]}"
  "$callback"
  wait_for_key
}

choose_options() {
  local current_id
  if [ -n "$SELECT_ARG" ]; then
    printf 'Preselected: %s\n' "$SELECT_ARG"
    parse_selection "$SELECT_ARG"
    return
  fi

  if ! { [ -t 0 ] && [ -t 1 ]; }; then
    die "interactive selection requires a terminal; use --select for non-interactive runs"
  fi
  TUI_ACTIVE=true
  # Keep menu repainting isolated from subsequent plan and command output.
  printf '\033[?1049h\033[?25l'

  while true; do
    draw_menu
    read_key || die "input closed"
    current_id="${OPTION_IDS[$TUI_CURSOR]}"

    case "$KEY" in
      $'\033[A' | k | K)
        move_tui_cursor -1
        TUI_MESSAGE=""
        ;;
      $'\033[B' | j | J)
        move_tui_cursor 1
        TUI_MESSAGE=""
        ;;
      $'\033[C' | e | E)
        expand_current_group
        TUI_MESSAGE=""
        ;;
      $'\033[D')
        collapse_current_group
        TUI_MESSAGE=""
        ;;
      ' ')
        toggle_id "$current_id"
        TUI_MESSAGE=""
        ;;
      a | A)
        toggle_all
        TUI_MESSAGE=""
        ;;
      d | D)
        show_option_details
        TUI_MESSAGE=""
        ;;
      h | H | '?')
        show_tui_help
        TUI_MESSAGE=""
        ;;
      q | Q)
        cleanup_tui
        printf '\nCancelled.\n'
        exit 0
        ;;
      '')
        if [ -z "$SELECTED_IDS" ]; then
          TUI_MESSAGE="Select at least one option before continuing."
        else
          cleanup_tui
          return
        fi
        ;;
    esac
  done
}

# Planning and confirmation --------------------------------------------------

print_package_list() {
  local index group package previous_group
  previous_group=""
  index=0
  while [ "$index" -lt "${#PLANNED_PACKAGES[@]}" ]; do
    package="${PLANNED_PACKAGES[$index]}"
    if [ "$OS_KIND" = "linux" ] && package_is_installed "$package"; then
      index=$((index + 1))
      continue
    fi
    group="${PLANNED_PACKAGE_GROUPS[$index]}"
    if [ "$group" != "$previous_group" ]; then
      printf '      %s:\n' "$group"
      previous_group="$group"
    fi
    printf '        %s\n' "$package"
    index=$((index + 1))
  done
}

pending_package_count() {
  local count package
  if [ "$OS_KIND" != "linux" ]; then
    printf '%s' "${#PLANNED_PACKAGES[@]}"
    return
  fi

  count=0
  for package in "${PLANNED_PACKAGES[@]}"; do
    package_is_installed "$package" || count=$((count + 1))
  done
  printf '%s' "$count"
}

preview_plan() {
  local callback has_changes id index marker parent pending_packages state
  printf '\nInstallation plan\n\n'
  printf '  Selected options\n'
  index=0
  while [ "$index" -lt "${#OPTION_IDS[@]}" ]; do
    id="${OPTION_IDS[$index]}"
    parent="${OPTION_PARENT_IDS[$index]}"
    state="$(selection_state "$id")"
    if [ -z "$parent" ] && has_children "$id" && [ "$state" != none ]; then
      [ "$state" = all ] && marker='[x]' || marker='[-]'
      printf '    %s %s\n' "$marker" "${OPTION_TITLES[$index]}"
    elif [ -z "$parent" ] && is_selected "$id"; then
      printf '    [x] %s\n' "${OPTION_TITLES[$index]}"
    elif [ -n "$parent" ] && is_selected "$id"; then
      printf '        [x] %s\n' "${OPTION_TITLES[$index]}"
    fi
    index=$((index + 1))
  done

  if [ "${#PLANNED_PACKAGES[@]}" -gt 0 ]; then
    printf '\n  Package transaction\n'
    pending_packages="$(pending_package_count)"
    if [ "$OS_KIND" = "linux" ] && [ "$pending_packages" -eq 0 ]; then
      printf '    - All required APT packages are already installed\n'
      printf '    - Skip APT metadata refresh and package installation\n'
    elif [ "$OS_KIND" = "linux" ]; then
      printf '    - Refresh APT metadata once\n'
      printf '    - Install missing packages in one deduplicated APT transaction:\n'
      print_package_list
    else
      printf '    - Update Homebrew once\n'
      printf '    - Install all formulae in one deduplicated Homebrew transaction:\n'
      print_package_list
    fi
  fi

  has_changes=false
  index=0
  while [ "$index" -lt "${#OPTION_IDS[@]}" ]; do
    id="${OPTION_IDS[$index]}"
    callback="${OPTION_PLAN_FNS[$index]}"
    if is_selected "$id" && [ "$callback" != plan_none ]; then
      if ! $has_changes; then
        printf '\n  Configuration changes\n'
        has_changes=true
      fi
      printf '  [%s]\n' "${OPTION_TITLES[$index]}"
      "$callback"
    fi
    index=$((index + 1))
  done
  if ! $has_changes; then
    printf '\n  Configuration changes\n    - None\n'
  fi

  if $DRY_RUN; then
    printf '\n  Mode: dry run (no changes will be made)\n'
  fi
  printf '\n'
}

confirm_plan() {
  local answer
  printf 'Proceed with this plan? [y/N] '
  IFS= read -r answer || die "input closed"
  case "$answer" in
    y | Y | yes | YES | Yes) ;;
    *) notice 'Cancelled.'; exit 0 ;;
  esac
}

# Execution primitives -------------------------------------------------------

print_command() {
  local argument
  printf '+'
  for argument in "$@"; do
    printf ' %q' "$argument"
  done
  printf '\n'
}

run() {
  print_command "$@"
  $DRY_RUN || "$@"
}

run_as_root() {
  local all_value http_value https_value no_value
  local -a display_command proxy_environment
  http_value="${http_proxy:-${HTTP_PROXY:-}}"
  https_value="${https_proxy:-${HTTPS_PROXY:-}}"
  all_value="${all_proxy:-${ALL_PROXY:-}}"
  no_value="${no_proxy:-${NO_PROXY:-}}"
  proxy_environment=()
  display_command=()

  if [ "$(id -u)" -ne 0 ]; then
    display_command+=(sudo)
  fi
  display_command+=(env)

  if [ -n "$http_value" ]; then
    proxy_environment+=("http_proxy=${http_value}" "HTTP_PROXY=${http_value}")
    display_command+=("http_proxy=<preserved>" "HTTP_PROXY=<preserved>")
  fi
  if [ -n "$https_value" ]; then
    proxy_environment+=("https_proxy=${https_value}" "HTTPS_PROXY=${https_value}")
    display_command+=("https_proxy=<preserved>" "HTTPS_PROXY=<preserved>")
  fi
  if [ -n "$all_value" ]; then
    proxy_environment+=("all_proxy=${all_value}" "ALL_PROXY=${all_value}")
    display_command+=("all_proxy=<preserved>" "ALL_PROXY=<preserved>")
  fi
  if [ -n "$no_value" ]; then
    proxy_environment+=("no_proxy=${no_value}" "NO_PROXY=${no_value}")
    display_command+=("no_proxy=<preserved>" "NO_PROXY=<preserved>")
  fi

  if [ "${#proxy_environment[@]}" -eq 0 ]; then
    if [ "$(id -u)" -eq 0 ]; then
      run "$@"
    else
      run sudo "$@"
    fi
    return
  fi

  display_command+=("$@")
  print_command "${display_command[@]}"
  if ! $DRY_RUN; then
    if [ "$(id -u)" -eq 0 ]; then
      env "${proxy_environment[@]}" "$@"
    else
      sudo env "${proxy_environment[@]}" "$@"
    fi
  fi
}

ensure_temp_dir() {
  if [ -z "$TEMP_DIR" ]; then
    TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${SCRIPT_NAME}.XXXXXX")"
    chmod 700 "$TEMP_DIR"
  fi
}

download_file() {
  local url destination
  url="$1"
  destination="$2"
  run curl \
    --fail --show-error --silent --location \
    --connect-timeout 10 --retry 3 \
    --proto '=https' --tlsv1.2 \
    "$url" -o "$destination"
}

fzf_asset_arch() {
  case "$(dpkg --print-architecture)" in
    amd64) printf 'linux_amd64' ;;
    arm64) printf 'linux_arm64' ;;
    armhf) printf 'linux_armv7' ;;
    armel) printf 'linux_armv5' ;;
    ppc64el) printf 'linux_ppc64le' ;;
    riscv64) printf 'linux_riscv64' ;;
    s390x) printf 'linux_s390x' ;;
    loong64) printf 'linux_loong64' ;;
    *) die "unsupported architecture for fzf: $(dpkg --print-architecture)" ;;
  esac
}

install_fzf_latest() {
  local archive archive_name asset_arch checksum_file checksum_name
  local current_version effective_url expected_hash actual_hash tag version
  asset_arch="$(fzf_asset_arch)"

  if $DRY_RUN; then
    printf '+ resolve latest release from %q\n' 'https://github.com/junegunn/fzf/releases/latest'
    printf '+ download fzf-<latest>-%s.tar.gz and checksums to <secure-temporary-directory>\n' \
      "$asset_arch"
    printf '+ verify fzf archive SHA-256 checksum\n'
    printf '+ install fzf /usr/local/bin/fzf\n'
    return
  fi

  print_command curl \
    --fail --show-error --silent --location --head \
    --connect-timeout 10 --retry 3 \
    --proto '=https' --tlsv1.2 \
    --output /dev/null --write-out '%{url_effective}' \
    'https://github.com/junegunn/fzf/releases/latest'
  effective_url="$(
    curl \
      --fail --show-error --silent --location --head \
      --connect-timeout 10 --retry 3 \
      --proto '=https' --tlsv1.2 \
      --output /dev/null --write-out '%{url_effective}' \
      'https://github.com/junegunn/fzf/releases/latest'
  )"
  tag="${effective_url##*/}"
  version="${tag#v}"
  case "$tag" in
    v[0-9]*) ;;
    *) die "could not determine the latest fzf version from: $effective_url" ;;
  esac

  current_version="$(fzf --version 2>/dev/null | awk '{print $1}' || true)"
  if [ "$current_version" = "$version" ]; then
    notice "fzf ${version} is already installed; skipping."
    return
  fi

  ensure_temp_dir
  archive_name="fzf-${version}-${asset_arch}.tar.gz"
  checksum_name="fzf_${version}_checksums.txt"
  archive="${TEMP_DIR}/${archive_name}"
  checksum_file="${TEMP_DIR}/${checksum_name}"
  download_file \
    "https://github.com/junegunn/fzf/releases/download/${tag}/${archive_name}" \
    "$archive"
  download_file \
    "https://github.com/junegunn/fzf/releases/download/${tag}/${checksum_name}" \
    "$checksum_file"

  expected_hash="$(awk -v name="$archive_name" '$2 == name {print $1; exit}' "$checksum_file")"
  actual_hash="$(sha256sum "$archive" | awk '{print $1}')"
  if [ "${#expected_hash}" -ne 64 ] || [ "$actual_hash" != "$expected_hash" ]; then
    die "SHA-256 verification failed for ${archive_name}"
  fi
  notice "Verified SHA-256 for ${archive_name}."

  run tar -xzf "$archive" -C "$TEMP_DIR"
  run_as_root install -m 0755 "${TEMP_DIR}/fzf" /usr/local/bin/fzf
}

yazi_asset_arch() {
  case "$(dpkg --print-architecture)" in
    amd64) printf 'x86_64' ;;
    arm64) printf 'aarch64' ;;
    i386) printf 'i686' ;;
    riscv64) printf 'riscv64gc' ;;
    *) die "unsupported architecture for Yazi: $(dpkg --print-architecture)" ;;
  esac
}

install_yazi_latest() {
  local actual_hash api_response archive archive_name asset_arch current_version
  local effective_url expected_digest expected_hash extract_dir tag version ya_binary yazi_binary
  asset_arch="$(yazi_asset_arch)"

  if $DRY_RUN; then
    printf '+ resolve latest release from %q\n' 'https://github.com/sxyazi/yazi/releases/latest'
    printf '+ download yazi-%s-unknown-linux-gnu.zip and release metadata\n' "$asset_arch"
    printf '+ verify Yazi archive SHA-256 digest\n'
    printf '+ install yazi and ya in /usr/local/bin\n'
    return
  fi

  print_command curl \
    --fail --show-error --silent --location --head \
    --connect-timeout 10 --retry 3 \
    --proto '=https' --tlsv1.2 \
    --output /dev/null --write-out '%{url_effective}' \
    'https://github.com/sxyazi/yazi/releases/latest'
  effective_url="$(
    curl \
      --fail --show-error --silent --location --head \
      --connect-timeout 10 --retry 3 \
      --proto '=https' --tlsv1.2 \
      --output /dev/null --write-out '%{url_effective}' \
      'https://github.com/sxyazi/yazi/releases/latest'
  )"
  tag="${effective_url##*/}"
  version="${tag#v}"
  case "$tag" in
    v[0-9]*) ;;
    *) die "could not determine the latest Yazi version from: $effective_url" ;;
  esac

  current_version="$(yazi --version 2>/dev/null | awk '{print $2}' || true)"
  if [ "$current_version" = "$version" ] && command -v ya >/dev/null 2>&1; then
    notice "Yazi ${version} is already installed; skipping."
    return
  fi

  ensure_temp_dir
  archive_name="yazi-${asset_arch}-unknown-linux-gnu.zip"
  archive="${TEMP_DIR}/${archive_name}"
  api_response="${TEMP_DIR}/yazi-release.json"
  extract_dir="${TEMP_DIR}/yazi-extract"
  download_file \
    "https://github.com/sxyazi/yazi/releases/download/${tag}/${archive_name}" \
    "$archive"
  download_file \
    "https://api.github.com/repos/sxyazi/yazi/releases/tags/${tag}" \
    "$api_response"

  expected_digest="$(
    jq -r --arg name "$archive_name" \
      '.assets[] | select(.name == $name) | .digest' "$api_response"
  )"
  expected_hash="${expected_digest#sha256:}"
  actual_hash="$(sha256sum "$archive" | awk '{print $1}')"
  if [ "$expected_digest" = "$expected_hash" ] ||
    [ "${#expected_hash}" -ne 64 ] || [ "$actual_hash" != "$expected_hash" ]; then
    die "SHA-256 verification failed for ${archive_name}"
  fi
  notice "Verified SHA-256 for ${archive_name}."

  mkdir -p "$extract_dir"
  run unzip -q "$archive" -d "$extract_dir"
  yazi_binary="$(find "$extract_dir" -type f -name yazi -print -quit)"
  ya_binary="$(find "$extract_dir" -type f -name ya -print -quit)"
  [ -n "$yazi_binary" ] && [ -n "$ya_binary" ] ||
    die 'Yazi archive did not contain both yazi and ya binaries'
  run_as_root install -m 0755 "$yazi_binary" /usr/local/bin/yazi
  run_as_root install -m 0755 "$ya_binary" /usr/local/bin/ya
}

frp_asset_arch() {
  case "$(dpkg --print-architecture)" in
    amd64) printf 'amd64' ;;
    arm64) printf 'arm64' ;;
    armhf) printf 'arm_hf' ;;
    armel) printf 'arm' ;;
    loong64) printf 'loong64' ;;
    riscv64) printf 'riscv64' ;;
    *) die "unsupported architecture for FRP: $(dpkg --print-architecture)" ;;
  esac
}

resolve_frp_release() {
  local effective_url tag
  $FRP_RELEASE_RESOLVED && return
  FRP_ASSET_ARCH="$(frp_asset_arch)"

  if $DRY_RUN; then
    printf '+ resolve latest release from %q\n' 'https://github.com/fatedier/frp/releases/latest'
    FRP_VERSION='<latest>'
    FRP_RELEASE_RESOLVED=true
    return
  fi

  print_command curl \
    --fail --show-error --silent --location --head \
    --connect-timeout 10 --retry 3 \
    --proto '=https' --tlsv1.2 \
    --output /dev/null --write-out '%{url_effective}' \
    'https://github.com/fatedier/frp/releases/latest'
  effective_url="$(
    curl \
      --fail --show-error --silent --location --head \
      --connect-timeout 10 --retry 3 \
      --proto '=https' --tlsv1.2 \
      --output /dev/null --write-out '%{url_effective}' \
      'https://github.com/fatedier/frp/releases/latest'
  )"
  tag="${effective_url##*/}"
  FRP_VERSION="${tag#v}"
  case "$tag" in
    v[0-9]*) ;;
    *) die "could not determine the latest FRP version from: $effective_url" ;;
  esac
  FRP_RELEASE_RESOLVED=true
}

prepare_frp_release() {
  local archive archive_name checksum_file expected_hash actual_hash release_name
  $FRP_RELEASE_PREPARED && return
  resolve_frp_release
  release_name="frp_${FRP_VERSION}_linux_${FRP_ASSET_ARCH}"

  if $DRY_RUN; then
    printf '+ download %s.tar.gz and FRP checksums to <secure-temporary-directory>\n' \
      "$release_name"
    printf '+ verify FRP archive SHA-256 checksum\n'
    printf '+ extract %s.tar.gz\n' "$release_name"
    FRP_RELEASE_DIR="<secure-temporary-directory>/${release_name}"
    FRP_RELEASE_PREPARED=true
    return
  fi

  ensure_temp_dir
  archive_name="${release_name}.tar.gz"
  archive="${TEMP_DIR}/${archive_name}"
  checksum_file="${TEMP_DIR}/frp_sha256_checksums.txt"
  download_file \
    "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${archive_name}" \
    "$archive"
  download_file \
    "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_sha256_checksums.txt" \
    "$checksum_file"

  expected_hash="$(awk -v name="$archive_name" '$2 == name {print $1; exit}' "$checksum_file")"
  actual_hash="$(sha256sum "$archive" | awk '{print $1}')"
  if [ "${#expected_hash}" -ne 64 ] || [ "$actual_hash" != "$expected_hash" ]; then
    die "SHA-256 verification failed for ${archive_name}"
  fi
  notice "Verified SHA-256 for ${archive_name}."

  run tar -xzf "$archive" -C "$TEMP_DIR"
  FRP_RELEASE_DIR="${TEMP_DIR}/${release_name}"
  FRP_RELEASE_PREPARED=true
}

install_frp_component() {
  local component current_version
  component="$1"
  resolve_frp_release
  current_version="$("$component" --version 2>/dev/null | awk '{print $1}' || true)"
  if ! $DRY_RUN && [ "$current_version" = "$FRP_VERSION" ]; then
    notice "${component} ${FRP_VERSION} is already installed; skipping."
    return
  fi

  prepare_frp_release
  if $DRY_RUN; then
    printf '+ install %s /usr/local/bin/%s\n' "$component" "$component"
  else
    run_as_root install -m 0755 \
      "${FRP_RELEASE_DIR}/${component}" "/usr/local/bin/${component}"
  fi
}

find_brew() {
  BREW_BIN=""
  if command -v brew >/dev/null 2>&1; then
    BREW_BIN="$(command -v brew)"
  elif [ -x /opt/homebrew/bin/brew ]; then
    BREW_BIN=/opt/homebrew/bin/brew
  elif [ -x /usr/local/bin/brew ]; then
    BREW_BIN=/usr/local/bin/brew
  fi
}

prepare_privileges() {
  $DRY_RUN && return

  if [ "$OS_KIND" = "linux" ] && [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "sudo is required; install it or run directly as root"
    section 'Validate administrator access'
    run sudo -v
  elif [ "$OS_KIND" = "macos" ] &&
    {
      is_selected common || is_selected lima || is_selected yazi ||
        is_selected frpc || is_selected frps
    }; then
    find_brew
    if [ -z "$BREW_BIN" ]; then
      command -v sudo >/dev/null 2>&1 || die "sudo is required to bootstrap Homebrew"
      section 'Validate administrator access'
      run sudo -v
    fi
  fi
}

install_homebrew() {
  local installer
  find_brew
  if [ -n "$BREW_BIN" ]; then
    notice "Homebrew is already installed at ${BREW_BIN}; skipping bootstrap."
    return
  fi

  if $DRY_RUN; then
    printf '+ download %q to <secure-temporary-file>\n' "$BREW_INSTALL_URL"
    printf '+ env NONINTERACTIVE=1 /bin/bash <secure-temporary-file>\n'
    if [ "$ARCH" = "arm64" ]; then
      BREW_BIN=/opt/homebrew/bin/brew
    else
      BREW_BIN=/usr/local/bin/brew
    fi
    return
  fi

  ensure_temp_dir
  installer="${TEMP_DIR}/homebrew-install.sh"
  download_file "$BREW_INSTALL_URL" "$installer"
  run env NONINTERACTIVE=1 /bin/bash "$installer"
  find_brew
  [ -n "$BREW_BIN" ] || die "Homebrew installer finished but brew was not found"
}

configure_brew_shellenv() {
  local line
  line="eval \"\$(${BREW_BIN} shellenv)\""
  if [ -f "$HOME/.zprofile" ] && grep -Fqx "$line" "$HOME/.zprofile"; then
    notice 'Homebrew shell environment is already configured; skipping.'
  elif $DRY_RUN; then
    printf '+ append %q to %q\n' "$line" "$HOME/.zprofile"
  else
    printf '\n%s\n' "$line" >>"$HOME/.zprofile"
    notice "Added Homebrew shell environment to ${HOME}/.zprofile."
  fi
  if ! $DRY_RUN; then
    eval "$("$BREW_BIN" shellenv)"
  fi
}

install_planned_packages() {
  local package
  local -a available_packages missing_packages
  [ "${#PLANNED_PACKAGES[@]}" -gt 0 ] || return 0

  if [ "$OS_KIND" = "linux" ]; then
    missing_packages=()
    for package in "${PLANNED_PACKAGES[@]}"; do
      package_is_installed "$package" || missing_packages+=("$package")
    done
    if [ "${#missing_packages[@]}" -eq 0 ]; then
      notice 'All required APT packages are already installed; skipping APT refresh.'
      return
    fi

    section 'Install packages'
    run_as_root apt-get update
    available_packages=()
    for package in "${missing_packages[@]}"; do
      if package_is_available "$package"; then
        available_packages+=("$package")
      else
        warn "APT package is unavailable on this system; skipping: $package"
      fi
    done
    if [ "${#available_packages[@]}" -eq 0 ]; then
      notice 'No missing APT packages are available for this system; skipping installation.'
      return
    fi
    run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "${available_packages[@]}"
  else
    section 'Install packages'
    install_homebrew
    configure_brew_shellenv
    run "$BREW_BIN" update
    run env HOMEBREW_NO_AUTO_UPDATE=1 "$BREW_BIN" install "${PLANNED_PACKAGES[@]}"
  fi
}

# Idempotent option apply callbacks ------------------------------------------

zsh_path() {
  local path
  path="$(command -v zsh || true)"
  if [ -z "$path" ] && $DRY_RUN; then
    if [ "$OS_KIND" = "linux" ]; then
      path=/usr/bin/zsh
    else
      path=/bin/zsh
    fi
  fi
  [ -n "$path" ] || die "zsh was not found after package installation"
  printf '%s' "$path"
}

install_zimfw() {
  local zim_home zimrc installer shell_path
  zim_home="${ZIM_HOME:-$HOME/.zim}"
  zimrc="${ZIM_CONFIG_FILE:-$HOME/.zimrc}"
  shell_path="$(zsh_path)"

  if [ -f "${zim_home}/zimfw.zsh" ] && [ -f "$zimrc" ]; then
    if [ ! -f "${zim_home}/init.zsh" ]; then
      if $DRY_RUN; then
        # $1 is expanded later by the spawned Zsh.
        # shellcheck disable=SC2016
        printf '+ zsh -c %q -- %q\n' 'source "$1" init -q' "${zim_home}/zimfw.zsh"
      else
        run zsh -c 'source "$1" init -q' -- "${zim_home}/zimfw.zsh"
      fi
    else
      notice 'Zimfw is already installed; skipping.'
    fi
    return
  fi

  if [ -e "$zim_home" ]; then
    die "${zim_home} exists but is not a complete Zimfw installation; inspect or remove it manually"
  fi

  if $DRY_RUN; then
    printf '+ download %q to <secure-temporary-file>\n' "$ZIM_INSTALL_URL"
    printf '+ env SHELL=%q zsh <secure-temporary-file>\n' "$shell_path"
    return
  fi

  ensure_temp_dir
  installer="${TEMP_DIR}/zim-install.zsh"
  download_file "$ZIM_INSTALL_URL" "$installer"
  # Zimfw normally calls chsh itself. Supplying the selected Zsh path keeps shell
  # mutation in configure_login_shell, where it is planned and executed once.
  run env SHELL="$shell_path" zsh "$installer"
}

configure_login_shell() {
  local current shell_path
  shell_path="$(zsh_path)"
  if [ "$OS_KIND" = "linux" ]; then
    current="$(getent passwd "$(id -un)" | awk -F: '{print $7}')"
  else
    current="${SHELL:-}"
  fi

  if [ "$current" = "$shell_path" ] ||
    { [ -e "$current" ] && [ -e "$shell_path" ] && [ "$current" -ef "$shell_path" ]; }; then
    notice "Login shell is already ${current}; skipping."
    return
  fi

  if ! $DRY_RUN && ! shell_is_allowed "$shell_path"; then
    die "refusing to use ${shell_path} because it is not listed in /etc/shells"
  fi

  if [ "$OS_KIND" = "linux" ]; then
    run_as_root chsh -s "$shell_path" "$(id -un)"
  else
    run chsh -s "$shell_path"
  fi
}

shell_is_allowed() {
  local shell_path allowed
  shell_path="$1"
  [ -r /etc/shells ] || return 1
  while IFS= read -r allowed; do
    case "$allowed" in
      '' | '#'* ) continue ;;
    esac
    if [ "$allowed" = "$shell_path" ] ||
      { [ -e "$allowed" ] && [ -e "$shell_path" ] && [ "$allowed" -ef "$shell_path" ]; }; then
      return 0
    fi
  done </etc/shells
  return 1
}

apply_shell() {
  section 'Configure Zsh and Zimfw'
  install_zimfw
  configure_login_shell
}

prepare_dotfile_templates() {
  local filename
  local -a filenames
  ensure_temp_dir
  DOTFILE_TEMPLATE_DIR="${TEMP_DIR}/dotfiles"
  mkdir -p "$DOTFILE_TEMPLATE_DIR"
  filenames=(.zimrc .zshrc.local .gitconfig.local)
  if [ "$OS_KIND" = "linux" ] && [ "$LINUX_DISTRO" = "ubuntu" ]; then
    filenames+=(.zshenv)
  fi
  for filename in "${filenames[@]}"; do
    download_file "${DOTFILES_BASE_URL}/${filename}" \
      "${DOTFILE_TEMPLATE_DIR}/${filename}"
  done
}

zshrc_loads_local() {
  [ -f "$1" ] && grep -Eq '^[[:space:]]*[^#[:space:]].*\.zshrc\.local' "$1"
}

gitconfig_includes_local() {
  local include includes
  [ -f "$1" ] || return 1
  includes="$(git config --file "$1" --get-all include.path 2>/dev/null || true)"
  while IFS= read -r include; do
    case "$include" in
      \~/.gitconfig.local | \$HOME/.gitconfig.local | .gitconfig.local | \
        ./.gitconfig.local | "$HOME/.gitconfig.local") return 0 ;;
    esac
  done <<<"$includes"
  return 1
}

apply_dotfiles() {
  local filename gitconfig local_loader source_dir target_dir zim_home zimfw zimfw_install
  local -a filenames
  section 'Install configuration files'
  prepare_dotfile_templates
  source_dir="$DOTFILE_TEMPLATE_DIR"
  target_dir="$HOME"
  gitconfig="${target_dir}/.gitconfig"
  # These expressions are expanded later by the target Zsh process.
  # shellcheck disable=SC2016
  local_loader='[[ -r "$HOME/.zshrc.local" ]] && source "$HOME/.zshrc.local"'
  # shellcheck disable=SC2016
  zimfw_install='source "$1" install -q'

  filenames=(.zimrc .zshrc.local .gitconfig.local)
  if [ "$OS_KIND" = "linux" ] && [ "$LINUX_DISTRO" = "ubuntu" ]; then
    filenames+=(.zshenv)
  fi
  for filename in "${filenames[@]}"; do
    run install -m 0644 "${source_dir}/${filename}" "${target_dir}/${filename}"
  done

  if zshrc_loads_local "${target_dir}/.zshrc"; then
    notice "${target_dir}/.zshrc already loads .zshrc.local; leaving it unchanged."
  elif $DRY_RUN; then
    printf '+ append .zshrc.local loader to %q\n' "${target_dir}/.zshrc"
  else
    printf '\n%s\n%s\n' \
      '# Load custom Zsh configuration.' \
      "$local_loader" >>"${target_dir}/.zshrc"
    notice "Added .zshrc.local loader to ${target_dir}/.zshrc."
  fi

  if gitconfig_includes_local "$gitconfig"; then
    notice "${gitconfig} already includes .gitconfig.local; leaving it unchanged."
  elif $DRY_RUN; then
    printf '+ git config --file %q --add include.path %q\n' \
      "$gitconfig" .gitconfig.local
  else
    run git config --file "$gitconfig" --add include.path .gitconfig.local
    notice "Added .gitconfig.local include to ${gitconfig}."
  fi

  zim_home="${ZIM_HOME:-${target_dir}/.zim}"
  zimfw="${zim_home}/zimfw.zsh"
  if [ -f "$zimfw" ] || { $DRY_RUN && is_selected shell; }; then
    if $DRY_RUN; then
      printf '+ env ZIM_HOME=%q ZIM_CONFIG_FILE=%q zsh -c %q -- %q\n' \
        "$zim_home" "${target_dir}/.zimrc" "$zimfw_install" "$zimfw"
    else
      run env ZIM_HOME="$zim_home" ZIM_CONFIG_FILE="${target_dir}/.zimrc" \
        zsh -c "$zimfw_install" -- "$zimfw"
    fi
  fi
}

apply_yazi() {
  section 'Install Yazi file manager'
  if [ "$OS_KIND" = "linux" ]; then
    install_yazi_latest
  else
    notice 'Yazi was installed in the Homebrew package transaction.'
  fi
}

ensure_system_symlink() {
  local source destination actual
  source="$1"
  destination="$2"

  if [ -L "$destination" ]; then
    actual="$(readlink "$destination")"
    if [ "$actual" = "$source" ]; then
      notice "${destination} already points to ${source}; skipping."
    else
      warn "${destination} points to ${actual}; leaving it unchanged"
    fi
  elif [ -e "$destination" ]; then
    warn "${destination} already exists; leaving it unchanged"
  elif [ -e "$source" ] || $DRY_RUN; then
    run_as_root ln -s "$source" "$destination"
  else
    warn "${source} was not installed; cannot create ${destination}"
  fi
}

apply_base_core() {
  section 'Configure locale'
  if locale -a 2>/dev/null | grep -Eiq '^en_US\.utf-?8$'; then
    notice 'en_US.UTF-8 locale is already generated; skipping.'
  else
    if grep -Eq '^[[:space:]]*#[[:space:]]*en_US\.UTF-8[[:space:]]+UTF-8[[:space:]]*$' \
      /etc/locale.gen; then
      run_as_root sed -i -E \
        's/^[[:space:]]*#[[:space:]]*(en_US\.UTF-8[[:space:]]+UTF-8)[[:space:]]*$/\1/' \
        /etc/locale.gen
    elif ! grep -Eq '^[[:space:]]*en_US\.UTF-8[[:space:]]+UTF-8[[:space:]]*$' \
      /etc/locale.gen; then
      die 'en_US.UTF-8 is missing from /etc/locale.gen'
    fi
    run_as_root locale-gen
    if ! $DRY_RUN && ! locale -a 2>/dev/null | grep -Eiq '^en_US\.utf-?8$'; then
      die 'locale-gen completed but en_US.UTF-8 is still unavailable'
    fi
  fi

  if [ -r /etc/default/locale ] && grep -Fqx 'LANG=en_US.UTF-8' /etc/default/locale; then
    notice 'Default locale is already en_US.UTF-8; skipping.'
  else
    run_as_root env LC_ALL=C LANG=C update-locale LANG=en_US.UTF-8
  fi
}

apply_base_terminal() {
  section 'Configure terminal tools'
  install_fzf_latest
  command -v fd >/dev/null 2>&1 || ensure_system_symlink /usr/bin/fdfind /usr/local/bin/fd
  command -v bat >/dev/null 2>&1 || ensure_system_symlink /usr/bin/batcat /usr/local/bin/bat
}

ensure_line_in_file() {
  local line file parent
  line="$1"
  file="$2"
  parent="$(dirname "$file")"

  if [ -f "$file" ] && grep -Fqx "$line" "$file"; then
    notice "${file} already contains the required PATH entry; skipping."
  elif $DRY_RUN; then
    printf '+ append %q to %q\n' "$line" "$file"
  else
    [ -d "$parent" ] || run mkdir -p "$parent"
    printf '\n%s\n' "$line" >>"$file"
    notice "Added the pipx binary directory to ${file}."
  fi
}

apply_dev_python() {
  local pipx_bin_dir path_line zshrc
  section 'Configure development tools'
  pipx_bin_dir="${PIPX_BIN_DIR:-$HOME/.local/bin}"
  zshrc="$HOME/.zshrc"
  path_line="export PATH=\"\$PATH:${pipx_bin_dir}\""
  ensure_line_in_file "$path_line" "$zshrc"

  if command -v pre-commit >/dev/null 2>&1 || [ -x "${pipx_bin_dir}/pre-commit" ]; then
    notice 'pre-commit is already installed; skipping.'
  else
    run pipx install pre-commit
  fi
}

create_frp_config() {
  local component destination template
  component="$1"
  destination="/etc/frp/${component}.toml"
  if [ -e "$destination" ]; then
    notice "${destination} already exists; leaving it unchanged."
    return
  fi

  if $DRY_RUN; then
    printf '+ create %q with an editable FRP configuration template\n' "$destination"
    return
  fi

  ensure_temp_dir
  template="${TEMP_DIR}/${component}.toml"
  case "$component" in
    frpc)
      printf '%s\n' \
        'serverAddr = "127.0.0.1"' \
        'serverPort = 7000' \
        '' \
        '# [[proxies]]' \
        '# name = "ssh"' \
        '# type = "tcp"' \
        '# localIP = "127.0.0.1"' \
        '# localPort = 22' \
        '# remotePort = 6000' >"$template"
      ;;
    frps)
      printf '%s\n' \
        'bindPort = 7000' \
        '' \
        '# auth.method = "token"' \
        '# auth.token = "replace-me"' >"$template"
      ;;
    *) die "internal error: unsupported FRP component: $component" ;;
  esac
  run_as_root install -d -m 0755 /etc/frp
  run_as_root install -m 0640 "$template" "$destination"
}

install_frp_systemd_unit() {
  local component description destination service unit
  component="$1"
  service="${component}.service"
  destination="/etc/systemd/system/${service}"
  case "$component" in
    frpc) description='FRP client' ;;
    frps) description='FRP server' ;;
    *) die "internal error: unsupported FRP component: $component" ;;
  esac

  if $DRY_RUN; then
    printf '+ install managed systemd unit %q\n' "$destination"
    printf '+ sudo systemctl daemon-reload\n'
    printf '+ sudo systemctl enable %s\n' "$service"
    printf '  Edit /etc/frp/%s.toml, then run: sudo systemctl start %s\n' \
      "$component" "$service"
    return
  fi

  command -v systemctl >/dev/null 2>&1 || die "systemctl is required for ${service}"
  ensure_temp_dir
  unit="${TEMP_DIR}/${service}"
  printf '%s\n' \
    '[Unit]' \
    "Description=${description}" \
    'Wants=network-online.target' \
    'After=network-online.target' \
    '' \
    '[Service]' \
    'Type=simple' \
    "ExecStart=/usr/local/bin/${component} -c /etc/frp/${component}.toml" \
    'Restart=on-failure' \
    'RestartSec=5s' \
    '' \
    '[Install]' \
    'WantedBy=multi-user.target' >"$unit"

  if [ -f "$destination" ] && cmp -s "$unit" "$destination"; then
    notice "${destination} is already current; skipping replacement."
  else
    run_as_root install -m 0644 "$unit" "$destination"
  fi
  run_as_root systemctl daemon-reload
  run_as_root systemctl enable "$service"
  notice "Enabled ${service} without starting it."
  notice "Edit /etc/frp/${component}.toml, then run: sudo systemctl start ${service}"
}

homebrew_prefix() {
  find_brew
  [ -n "$BREW_BIN" ] || die 'Homebrew was not found after package installation'
  if $DRY_RUN && [ ! -x "$BREW_BIN" ]; then
    [ "$ARCH" = "arm64" ] && printf '/opt/homebrew' || printf '/usr/local'
  else
    "$BREW_BIN" --prefix
  fi
}

prepare_frp_launchd_service() {
  local agent_dir component config destination label plist prefix
  component="$1"
  prefix="$(homebrew_prefix)"
  config="${prefix}/etc/frp/${component}.toml"
  label="homebrew.mxcl.${component}"
  agent_dir="${HOME}/Library/LaunchAgents"
  destination="${agent_dir}/${label}.plist"

  if $DRY_RUN; then
    printf '+ create and install launchd agent at %q\n' "$destination"
    printf '+ launchctl enable %q\n' "gui/$(id -u)/${label}"
  else
    [ -f "$config" ] || die "Homebrew did not create the expected FRP config: $config"
    ensure_temp_dir
    plist="${TEMP_DIR}/${label}.plist"
    printf '%s\n' \
      '<?xml version="1.0" encoding="UTF-8"?>' \
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
      '<plist version="1.0">' \
      '<dict>' \
      '  <key>Label</key>' \
      "  <string>${label}</string>" \
      '  <key>ProgramArguments</key>' \
      '  <array>' \
      "    <string>${prefix}/opt/${component}/bin/${component}</string>" \
      '    <string>-c</string>' \
      "    <string>${config}</string>" \
      '  </array>' \
      '  <key>RunAtLoad</key>' \
      '  <true/>' \
      '  <key>KeepAlive</key>' \
      '  <true/>' \
      '  <key>StandardOutPath</key>' \
      "  <string>${prefix}/var/log/${component}.log</string>" \
      '  <key>StandardErrorPath</key>' \
      "  <string>${prefix}/var/log/${component}.log</string>" \
      '</dict>' \
      '</plist>' >"$plist"
    run plutil -lint "$plist"
    run mkdir -p "$agent_dir" "${prefix}/var/log"
    run install -m 0644 "$plist" "$destination"
    run launchctl enable "gui/$(id -u)/${label}"
  fi

  notice "Edit ${config}, then run: ${BREW_BIN} services start ${component}"
  notice "That command starts ${component} and registers it to launch at login."
}

install_cloudflare_warp() {
  local arch dearmored fingerprint key source
  arch="$(dpkg --print-architecture)"
  case "$arch" in
    amd64 | arm64) ;;
    *) die "unsupported architecture for Cloudflare WARP: $arch" ;;
  esac
  if package_is_installed cloudflare-warp; then
    notice 'cloudflare-warp is already installed; skipping its APT repository refresh.'
    run_as_root systemctl enable --now warp-svc.service
    return
  fi
  ensure_temp_dir
  key="${TEMP_DIR}/cloudflare-warp-key.gpg"
  dearmored="${TEMP_DIR}/cloudflare-warp-archive-keyring.gpg"
  source="${TEMP_DIR}/cloudflare-client.list"

  if $DRY_RUN; then
    printf '+ download and verify Cloudflare WARP APT signing key\n'
    printf '+ install keyring at /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg\n'
  else
    download_file 'https://pkg.cloudflareclient.com/pubkey.gpg' "$key"
    fingerprint="$(
      gpg --batch --show-keys --with-colons "$key" |
        awk -F: '$1 == "fpr" {print $10; exit}'
    )"
    [ "$fingerprint" = "$WARP_KEY_FINGERPRINT" ] ||
      die "unexpected Cloudflare WARP signing key fingerprint: ${fingerprint:-missing}"
    run gpg --batch --yes --dearmor --output "$dearmored" "$key"
    run_as_root install -m 0644 "$dearmored" \
      /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  fi

  printf 'deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] ' >"$source"
  printf 'https://pkg.cloudflareclient.com/ %s main\n' "$LINUX_CODENAME" >>"$source"
  run_as_root install -m 0644 "$source" /etc/apt/sources.list.d/cloudflare-client.list
  run_as_root apt-get update
  run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y cloudflare-warp
  run_as_root systemctl enable --now warp-svc.service
}

configure_cloudflare_warp_proxy() {
  if $DRY_RUN; then
    run warp-cli --accept-tos registration new
  elif warp-cli --accept-tos registration show >/dev/null 2>&1; then
    notice 'Cloudflare WARP is already registered; keeping the existing registration.'
  else
    run warp-cli --accept-tos registration new
  fi
  run warp-cli --accept-tos mode proxy
  run warp-cli --accept-tos proxy port "$WARP_PROXY_PORT"
  run warp-cli --accept-tos connect
  notice "Cloudflare WARP SOCKS5 proxy is listening on 127.0.0.1:${WARP_PROXY_PORT}."
}

apply_frpc() {
  section 'Install FRP client'
  if [ "$OS_KIND" = "linux" ]; then
    install_frp_component frpc
  else
    notice 'frpc was installed in the Homebrew package transaction.'
  fi
}

apply_frpc_systemd() {
  section 'Configure frpc systemd service'
  create_frp_config frpc
  install_frp_systemd_unit frpc
}

apply_frps() {
  section 'Install FRP server'
  if [ "$OS_KIND" = "linux" ]; then
    install_frp_component frps
  else
    notice 'frps was installed in the Homebrew package transaction.'
  fi
}

apply_frps_systemd() {
  section 'Configure frps systemd service'
  create_frp_config frps
  install_frp_systemd_unit frps
}

apply_frpc_service() {
  section 'Prepare frpc launchd service'
  prepare_frp_launchd_service frpc
}

apply_frps_service() {
  section 'Prepare frps launchd service'
  prepare_frp_launchd_service frps
}

apply_warp() {
  section 'Install Cloudflare WARP'
  install_cloudflare_warp
  section 'Configure Cloudflare WARP proxy'
  configure_cloudflare_warp_proxy
}

apply_selected_options() {
  local index id callback
  index=0
  while [ "$index" -lt "${#OPTION_IDS[@]}" ]; do
    id="${OPTION_IDS[$index]}"
    if is_selected "$id"; then
      callback="${OPTION_APPLY_FNS[$index]}"
      "$callback"
    fi
    index=$((index + 1))
  done
}

execute_plan() {
  prepare_privileges
  install_planned_packages
  apply_selected_options
  CURRENT_STEP=""

  printf '\nInitialization %s.\n' "$($DRY_RUN && printf 'dry run completed' || printf 'completed')"
  if ! $DRY_RUN && is_selected shell; then
    notice 'Start a new login shell to use the Zsh configuration.'
  fi
}

# Validation and cleanup -----------------------------------------------------

run_self_check() {
  local original_selection checked_package_count id package seen
  original_selection="$SELECTED_IDS"
  select_all
  build_package_plan

  seen=""
  for package in "${PLANNED_PACKAGES[@]}"; do
    case " $seen " in
      *" $package "*) die "self-check failed: duplicate planned package: $package" ;;
      *) seen="${seen}${seen:+ }$package" ;;
    esac
  done
  for id in $SELECTED_IDS; do
    option_index "$id" >/dev/null || die "self-check failed: unregistered selection: $id"
  done

  [ "${#PLANNED_PACKAGE_GROUPS[@]}" -eq "${#PLANNED_PACKAGES[@]}" ] ||
    die 'self-check failed: package/group registry length mismatch'

  checked_package_count="${#PLANNED_PACKAGES[@]}"
  SELECTED_IDS="$original_selection"
  build_package_plan
  printf 'Self-check passed: %s registry entries, %s selectable options, ' \
    "${#OPTION_IDS[@]}" "$(selectable_count)"
  printf '%s unique packages, %s on %s.\n' \
    "$checked_package_count" "$ARCH" "$PLATFORM_LABEL"
}

cleanup() {
  local exit_code
  exit_code=$?
  cleanup_tui
  if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
    rm -rf "$TEMP_DIR"
  fi
  if [ "$exit_code" -ne 0 ] && [ -n "$CURRENT_STEP" ]; then
    warn "stopped during: ${CURRENT_STEP}"
  fi
  return "$exit_code"
}

handle_signal() {
  exit 130
}

main() {
  [ -n "${BASH_VERSION:-}" ] || die 'Bash is required'
  [ "${BASH_VERSINFO[0]}" -ge 3 ] || die 'Bash 3.2 or newer is required'
  trap cleanup EXIT
  trap handle_signal INT TERM

  parse_args "$@"
  detect_platform
  register_options
  validate_registry

  if $CHECK_ONLY; then
    run_self_check
    exit 0
  fi

  choose_options
  build_package_plan
  preview_plan
  confirm_plan
  execute_plan
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
