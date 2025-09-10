#!/bin/bash

# ==============================================================================
#                      Sing-box Installation Script
# ==============================================================================
# Author: 233boy
# Optimized by: ChatGPT 4o
#
# This script installs Sing-box, an advanced proxy tool, with features like
# GitHub download acceleration and progress display for a better user experience.
#
# Usage:
#   bash install.sh [-f <path> | -l | -p <addr> | -v <ver> | -h]
#
# Options:
#   -f, --core-file <path>          Custom Sing-box binary file path.
#                                   e.g., -f /root/sing-box-linux-amd64.tar.gz
#   -l, --local-install             Install script from current directory.
#   -p, --proxy <addr>              Use proxy for downloads.
#                                   e.g., -p http://127.0.0.1:2333 or -p socks5://127.0.0.1:2333
#   -v, --core-version <ver>        Custom Sing-box version.
#                                   e.g., -v v1.8.13
#   -h, --help                      Show this help message.
#
# ==============================================================================

author=233boy

# bash fonts colors
red='\e[31m'
yellow='\e[33m'
gray='\e[90m'
green='\e[92m'
blue='\e[94m'
magenta='\e[95m'
cyan='\e[96m'
none='\e[0m'
_red() { echo -e "${red}$@${none}"; }
_blue() { echo -e "${blue}$@${none}"; }
_cyan() { echo -e "${cyan}$@${none}"; }
_green() { echo -e "${green}$@${none}"; }
_yellow() { echo -e "${yellow}$@${none}"; }
_magenta() { echo -e "${magenta}$@${none}"; }
_red_bg() { echo -e "\e[41m$@${none}"; }

is_err=$(_red_bg 错误!)
is_warn=$(_red_bg 警告!)

err() {
    echo -e "\n$is_err $@\n" >&2 # 输出到标准错误
    exit_and_del_tmpdir 1
}

warn() {
    echo -e "\n$is_warn $@\n" >&2
}

# root check
[[ $EUID -ne 0 ]] && err "当前非 ${_yellow}ROOT用户${none}，请使用 root 运行此脚本。"

# yum or apt-get, ubuntu/debian/centos
if type -P apt-get &>/dev/null; then
    cmd="apt-get"
elif type -P yum &>/dev/null; then
    cmd="yum"
else
    err "此脚本仅支持 ${_yellow}Ubuntu / Debian / CentOS${none} 系统。"
fi

# systemd check
[[ ! $(type -P systemctl) ]] && {
    err "此系统缺少 ${_yellow}systemctl${none}，请尝试执行：${_yellow}${cmd} update -y; ${cmd} install systemd -y${none} 来修复此错误。"
}

# wget installed or none
is_wget=$(type -P wget)
[[ -z "$is_wget" ]] && {
    msg warn "未检测到 ${_yellow}wget${none}，将尝试安装。如果网络不佳，可能需要手动安装：${_yellow}${cmd} install -y wget${none}"
    install_pkg "wget" # 提前安装 wget
    is_wget=$(type -P wget) # 重新检查
    [[ -z "$is_wget" ]] && err "无法安装或找到 ${_yellow}wget${none}，请手动安装后重试。"
}

# x64, arm64
case $(uname -m) in
amd64 | x86_64)
    is_arch=amd64
    ;;
*aarch64* | *armv8*)
    is_arch=arm64
    ;;
*)
    err "此脚本仅支持 64 位 (amd64/x86_64) 或 ARM64 (aarch64/armv8) 系统架构。"
    ;;
esac

is_core=sing-box
is_core_name=sing-box
is_core_dir=/etc/$is_core
is_core_bin=$is_core_dir/bin/$is_core
is_core_repo=SagerNet/$is_core # sing-box 真正的仓库
is_conf_dir=$is_core_dir/conf
is_log_dir=/var/log/$is_core
is_sh_bin=/usr/local/bin/$is_core
is_sh_dir=$is_core_dir/sh
is_sh_repo=$author/$is_core # 脚本自身的仓库
is_pkg="wget tar" # wget 已经在前面检查过，这里可以作为额外的依赖
is_config_json=$is_core_dir/config.json

# Temporary variable list for consistent tmpdir usage
tmp_var_lists=(
    tmpcore      # Path to downloaded sing-box archive
    tmpsh        # Path to downloaded script archive
    tmpjq        # Path to downloaded jq binary
    is_core_ok   # Flag file indicating sing-box download success
    is_sh_ok     # Flag file indicating script download success
    is_jq_ok     # Flag file indicating jq download success
    is_pkg_ok    # Flag file indicating essential package install success
)

# temporary directory setup
tmpdir=$(mktemp -d -t sb-install.XXXXXX)
[[ ! $tmpdir ]] && {
    tmpdir=/tmp/tmp-singbox-install-$RANDOM
    mkdir -p "$tmpdir" || err "无法创建临时目录 $tmpdir"
}

# Set up global temp variables
for i in "${tmp_var_lists[@]}"; do
    export "$i"="$tmpdir/$i"
done

# load bash script.
load() {
    . "$is_sh_dir/src/$1" || err "加载脚本模块 '$1' 失败。"
}

# wget with GitHub acceleration and progress display
_wget() {
    local url="$1"
    local output_file="${@: -1}" # Last argument is the output file
    local custom_opts="${@:2:$(($#-2))}" # All arguments except first and last

    # Apply global proxy if set
    [[ -n "$proxy" ]] && export https_proxy="$proxy" http_proxy="$proxy" no_proxy="localhost,127.0.0.1"

    # GitHub acceleration: use ghproxy.com
    if [[ "$url" =~ ^https://github.com/(.*)$ ]]; then
        url="https://ghproxy.com/$url"
    fi

    msg warn "下载中: ${_cyan}${url}${none}"
    # Remove -q for progress, add --show-progress for simpler output if available (wget 1.16+)
    # Fallback to --progress=bar:force if --show-progress is not supported, or just keep default if both fail
    if wget --help 2>&1 | grep -q '\--show-progress'; then
        if ! wget --no-check-certificate --show-progress -c -T 10 -O "$output_file" "$url" $custom_opts; then
            unset https_proxy http_proxy # Clear proxy on failure
            msg err "下载失败: ${_cyan}${url}${none}. 尝试不使用代理重试..."
            if ! wget --no-check-certificate --show-progress -c -T 10 -O "$output_file" "$url" $custom_opts; then
                err "再次下载失败。请检查网络连接或手动下载。"
            fi
        fi
    else
        # Older wget version without --show-progress
        if ! wget --no-check-certificate --progress=bar:force -c -T 10 -O "$output_file" "$url" $custom_opts; then
            unset https_proxy http_proxy # Clear proxy on failure
            msg err "下载失败: ${_cyan}${url}${none}. 尝试不使用代理重试..."
            if ! wget --no-check-certificate --progress=bar:force -c -T 10 -O "$output_file" "$url" $custom_opts; then
                 err "再次下载失败。请检查网络连接或手动下载。"
            fi
        fi
    fi
     unset https_proxy http_proxy # Clean up proxy
}

# print a message
msg() {
    local type="$1"
    local message="$2"
    local color=""

    case "$type" in
    warn)
        color="$yellow"
        ;;
    err)
        color="$red"
        ;;
    ok)
        color="$green"
        ;;
    *) # Default to info color
        color="$cyan"
        ;;
    esac

    echo -e "${color}$(date +'%T')${none}) ${message}"
}

# show help msg
show_help() {
    echo -e "Usage: $0 [-f xxx | -l | -p xxx | -v xxx | -h]\n"
    echo -e "  -f, --core-file <path>          自定义 $is_core_name 文件路径, e.g., -f /root/$is_core-linux-amd64.tar.gz"
    echo -e "  -l, --local-install             本地获取安装脚本, 使用当前目录"
    echo -e "  -p, --proxy <addr>              使用代理下载, e.g., -p http://127.0.0.1:2333"
    echo -e "  -v, --core-version <ver>        自定义 $is_core_name 版本, e.g., -v v1.8.13"
    echo -e "  -h, --help                      显示此帮助界面\n"
    exit_and_del_tmpdir 0 # Exit successfully after showing help
}

# install dependent pkg
install_pkg() {
    local pkgs_to_install=""
    for i in "$@"; do
        [[ ! $(type -P "$i") ]] && pkgs_to_install="$pkgs_to_install $i"
    done

    if [[ -n "$pkgs_to_install" ]]; then
        msg warn "安装依赖包: ${_yellow}${pkgs_to_install}${none}"
        if ! $cmd install -y $pkgs_to_install &>/dev/null; then
             # Try yum install epel-release for CentOS if initial install fails
            if [[ "$cmd" =~ yum ]]; then
                msg warn "尝试安装 epel-release..."
                yum install epel-release -y &>/dev/null
            fi
            # Update and retry
            msg warn "更新包列表并重试安装..."
            $cmd update -y &>/dev/null
            if ! $cmd install -y $pkgs_to_install &>/dev/null; then
                err "安装依赖包 ${_yellow}${pkgs_to_install}${none} 失败，请尝试手动安装。"
            fi
        fi
        >$is_pkg_ok
    else
        >$is_pkg_ok # No packages needed, mark as OK
    fi
}

# download file
download() {
    local type="$1"
    local link=""
    local name=""
    local tmpfile=""
    local is_ok_flag=""

    case "$type" in
    core)
        [[ -z "$is_core_ver" ]] && is_core_ver=$(_wget -qO- "https://api.github.com/repos/${is_core_repo}/releases/latest?v=$RANDOM" | grep tag_name | grep -E -o 'v([0-9.]+)' | head -n 1)
        [[ -z "$is_core_ver" ]] && err "获取 ${is_core_name} 最新版本失败，请检查网络或稍后重试。"
        # Remove 'v' prefix for filename
        local core_version_no_v="${is_core_ver//v/}"
        link="https://github.com/${is_core_repo}/releases/download/${is_core_ver}/${is_core}-${core_version_no_v}-linux-${is_arch}.tar.gz"
        name=$is_core_name
        tmpfile=$tmpcore
        is_ok_flag=$is_core_ok
        ;;
    sh)
        link=https://github.com/${is_sh_repo}/releases/latest/download/code.tar.gz
        name="$is_core_name 脚本"
        tmpfile=$tmpsh
        is_ok_flag=$is_sh_ok
        ;;
    jq)
        link=https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-$is_arch
        name="jq"
        tmpfile=$tmpjq
        is_ok_flag=$is_jq_ok
        ;;
    *)
        err "未知的下载类型: $type"
        ;;
    esac

    if [[ -n "$link" ]]; then
        if _wget "$link" "$tmpfile"; then
            mv -f "$tmpfile" "$is_ok_flag" || err "移动文件 $tmpfile 到 $is_ok_flag 失败。"
        else
            err "下载 ${name} 失败: ${link}"
        fi
    fi
}

# get server ip
get_ip() {
    # Prefer IPv4 for trace output
    export "$(_wget -4 -qO- https://one.one.one.one/cdn-cgi/trace 2>/dev/null | grep ip=)" &>/dev/null
    [[ -z "$ip" ]] && export "$(_wget -6 -qO- https://one.one.one.one/cdn-cgi/trace 2>/dev/null | grep ip=)" &>/dev/null
    unset https_proxy http_proxy # Clean up proxy after use

    if [[ -z "$ip" ]]; then
        msg warn "无法通过 one.one.one.one 获取服务器 IP，尝试 ip.sb"
        export ip="$(_wget -4 -qO- https://ip.sb 2>/dev/null || _wget -6 -qO- https://ip.sb 2>/dev/null)"
    fi
     if [[ -z "$ip" ]]; then
        msg err "获取服务器 IP 失败，这可能会影响配置生成。"
        # Do not exit here, continue if possible, but log warning.
    fi
}

# check background tasks status
check_status() {
    local is_fail=0

    # dependent pkg install fail
    [[ ! -f "$is_pkg_ok" ]] && {
        msg err "安装依赖包失败，请尝试手动安装后重试：${_cyan}${cmd} update -y; ${cmd} install -y ${is_pkg}${none}"
        is_fail=1
    }

    # download file status
    if [[ -z "$is_wget" ]]; then # If wget was not installed successfully earlier
        msg err "wget 未安装或未找到，无法下载文件。"
         is_fail=1
    else
        [[ ! $is_core_file && ! -f "$is_core_ok" ]] && {
            msg err "下载 ${is_core_name} 失败。"
            is_fail=1
        }
        [[ ! "$local_install" && ! -f "$is_sh_ok" ]] && {
            msg err "下载 ${is_core_name} 脚本失败。"
            is_fail=1
        }
        [[ "$jq_not_found" && ! -f "$is_jq_ok" ]] && {
            msg err "下载 jq 失败。"
            is_fail=1
        }
    fi

    # found fail status, remove tmp dir and exit.
    [[ $is_fail -eq 1 ]] && {
        exit_and_del_tmpdir 1
    }
}

# parameters check
pass_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -f | --core-file)
            if [[ -z "$2" ]]; then
                err "($1) 缺少必需参数, 正确使用示例: [$1 /root/$is_core-linux-amd64.tar.gz]"
            elif [[ ! -f "$2" ]]; then
                err "($2) 不是一个常规的文件，请检查路径。"
            fi
            is_core_file=$(realpath "$2") # Use realpath for absolute path
            shift 2
            ;;
        -l | --local-install)
            if [[ ! -f "${PWD}/src/core.sh" || ! -f "${PWD}/$is_core.sh" ]]; then
                err "当前目录 (${PWD}) 非完整的脚本目录，本地安装模式需要脚本文件存在。"
            fi
            local_install=1
            shift 1
            ;;
        -p | --proxy)
            if [[ -z "$2" ]]; then
                err "($1) 缺少必需参数, 正确使用示例: [$1 http://127.0.0.1:2333 or -p socks5://127.0.0.1:2333]"
            fi
            proxy="$2"
            shift 2
            ;;
        -v | --core-version)
            if [[ -z "$2" ]]; then
                err "($1) 缺少必需参数, 正确使用示例: [$1 v1.8.13]"
            fi
            is_core_ver="v${2//v/}" # Ensure 'v' prefix
            shift 2
            ;;
        -h | --help)
            show_help
            ;;
        *)
            echo -e "\n${is_err} ($1) 为未知参数...\n"
            show_help
            ;;
        esac
    done
    [[ "$is_core_ver" && "$is_core_file" ]] && {
        err "无法同时自定义 ${is_core_name} 版本和 ${is_core_name} 文件，请选择一种方式。"
    }
}

# exit and remove tmpdir
exit_and_del_tmpdir() {
    local exit_code="${1:-1}" # Default to 1 for error exit
    if [[ -d "$tmpdir" ]]; then
        msg warn "清理临时文件和目录: ${tmpdir}"
        rm -rf "$tmpdir"
    fi

    if [[ "$exit_code" -ne 0 ]]; then
        msg err "安装过程出现错误。"
        echo -e "反馈问题) https://github.com/${is_sh_repo}/issues"
    else
        msg ok "${is_core_name} 安装/配置成功!"
        echo -e "\n可以通过 ${_green}${is_core} ${none} 命令管理 ${is_core_name}."
        echo -e "例如: ${_green}${is_core} status${none}, ${_green}${is_core} start${none}, ${_green}${is_core} restart${none}, ${_green}${is_core} stop${none}"
        echo -e "配置文件位于: ${_green}${is_conf_dir}/config.json${none}"
    fi
    exit "$exit_code"
}

# main installation logic
main() {
    # Check for existing installation to prevent accidental re-install
    if [[ -f "$is_sh_bin" && -d "$is_core_dir/bin" && -d "$is_sh_dir" && -d "$is_conf_dir" ]]; then
        err "检测到 ${is_core_name} 已安装。如需重新安装，请使用 ${_green}${is_core} reinstall ${none} 命令。"
    fi

    # Parse command-line arguments
    [[ $# -gt 0 ]] && pass_args "$@"

    # Show welcome message
    clear
    echo
    echo "........... ${is_core_name} script by ${author} .........."
    echo "           (优化 by ChatGPT 4o)"
    echo

    # Start installing...
    msg warn "开始安装..."
    [[ -n "$is_core_ver" ]] && msg warn "${_cyan}${is_core_name} 版本: ${yellow}$is_core_ver${none}"
    [[ -n "$proxy" ]] && msg warn "使用代理: ${_yellow}$proxy${none}"

    # Create temporary directory (already done by mktemp -d)

    # If is_core_file is provided, use it directly
    if [[ -n "$is_core_file" ]]; then
        cp -f "$is_core_file" "$is_core_ok" || err "复制自定义 ${is_core_name} 文件失败。"
        msg warn "${_yellow}${is_core_name} 文件使用 > $is_core_file${none}"
    fi

    # If local_install, mark script download as successful
    if [[ "$local_install" == 1 ]]; then
        >$is_sh_ok
        msg warn "${_yellow}本地获取安装脚本 > $PWD ${none}"
    fi

    # Set NTP (Network Time Protocol) for accurate time
    timedatectl set-ntp true &>/dev/null
    [[ $? -ne 0 ]] && msg warn "无法设置系统 NTP 时间同步, 可能需要手动设置。"

    # Install dependent packages in background
    install_pkg $is_pkg &
    local pkg_pid=$!

    # Check and download jq
    if type -P jq &>/dev/null; then
        >$is_jq_ok
         msg ok "jq 已安装."
    else
        jq_not_found=1
        download jq &
        local jq_pid=$!
    fi

    # Download core and script in background if not local/custom
    [[ ! "$is_core_file" ]] && download core &
    local core_pid=$!
    [[ ! "$local_install" ]] && download sh &
    local sh_pid=$!

    # Get server IP in background
    get_ip &
    local ip_pid=$!

    # Wait for all background tasks to complete
    wait "$pkg_pid" "$jq_pid" "$core_pid" "$sh_pid" "$ip_pid"

    # Check the status of all background tasks
    check_status

    # Test $is_core_file if provided, verify content
    if [[ -n "$is_core_file" ]]; then
        mkdir -p "$tmpdir/testzip" || err "无法创建临时解压目录。"
        tar zxf "$is_core_ok" --strip-components 1 -C "$tmpdir/testzip" &>/dev/null || err "${is_core_name} 文件 ${is_core_file} 无法解压，文件可能损坏或格式不正确。"
        [[ ! -f "$tmpdir/testzip/$is_core" ]] && err "${is_core_name} 文件 ${is_core_file} 解压后未发现 ${is_core} 可执行文件，请检查文件内容。"
    fi
     if [[ -z "$ip" ]]; then
        msg err "获取服务器 IP 失败，部分配置可能无法正常生成。"
    fi

    # Create script directory
    msg warn "创建脚本目录: ${is_sh_dir}"
    mkdir -p "$is_sh_dir" || err "无法创建脚本目录 ${is_sh_dir}"

    # Copy script files
    if [[ "$local_install" == 1 ]]; then
        cp -rf "$PWD"/* "$is_sh_dir" || err "复制本地脚本文件失败。"
    else
        tar zxf "$is_sh_ok" -C "$is_sh_dir" || err "解压脚本文件失败。"
    fi

    # Create core binary directory and copy files
    msg warn "创建 ${is_core_name} 二进制目录: ${is_core_dir}/bin"
    mkdir -p "$is_core_dir/bin" || err "无法创建 ${is_core_name} 二进制目录。"
    if [[ -n "$is_core_file" ]]; then
        cp -rf "$tmpdir/testzip"/* "$is_core_dir/bin" || err "复制 ${is_core_name} 文件到安装目录失败。"
    else
        tar zxf "$is_core_ok" --strip-components 1 -C "$is_core_dir/bin" || err "解压 ${is_core_name} 文件到安装目录失败。"
    fi

    # Add aliases to root's bashrc
    echo "alias sb=\"$is_sh_bin\"" >>/root/.bashrc
    echo "alias $is_core=\"$is_sh_bin\"" >>/root/.bashrc
    msg ok "已为 root 用户添加 ${_cyan}sb${none} 和 ${_cyan}${is_core}${none} 命令别名。新的 shell 会话中生效。"

    # Link core command to /usr/local/bin
    ln -sf "$is_sh_dir/$is_core.sh" "$is_sh_bin" || err "创建 ${is_core_name} 命令软链接失败。"
    ln -sf "$is_sh_dir/$is_core.sh" "${is_sh_bin/$is_core/sb}" || err "创建 sb 命令软链接失败。"

    # Move jq binary if downloaded
    if [[ "$jq_not_found" == 1 ]]; then
        mv -f "$is_jq_ok" /usr/bin/jq || err "移动 jq 可执行文件失败。"
        msg ok "jq 已成功安装到 /usr/bin/jq ."
    fi

    # Set executable permissions
    chmod +x "$is_core_bin" "$is_sh_bin" /usr/bin/jq "${is_sh_bin/$is_core/sb}" || err "设置可执行权限失败。"

    # Create log directory
    msg warn "创建日志目录: ${is_log_dir}"
    mkdir -p "$is_log_dir" || err "无法创建日志目录 ${is_log_dir}"

    # Show tips and generate config
    msg ok "准备生成配置文件和服务..."

    # Create systemd service
    load systemd.sh
    is_new_install=1 # Mark as new install for systemd script
    install_service "$is_core" &>/dev/null || err "配置 ${is_core_name} systemd 服务失败。"

    # Create config directory
    mkdir -p "$is_conf_dir" || err "无法创建配置文件目录 ${is_conf_dir}"

    # Load core script and generate a reality config (example)
    load core.sh
    msg ok "生成默认 Reality 配置..."
    add reality || err "生成 Reality 配置失败。"

    # Remove tmp dir and exit successfully.
    exit_and_del_tmpdir 0 # success
}

# Start the main execution flow.
main "$@"
