#!/usr/bin/env bash
#
# acme-onekey.sh — acme.sh DNS API 一键申请与管理脚本 (Debian / Ubuntu)
#
# Copyright (C) 2026
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.  See <https://www.gnu.org/licenses/>.

set -o pipefail

VERSION="1.0.0"
ACME_HOME="/root/.acme.sh"
ACME="$ACME_HOME/acme.sh"
SELF_PATH="/usr/local/bin/acme-onekey"
DEFAULT_CERT_ROOT="/etc/acme-onekey/certs"

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[36m'; PLAIN=$'\033[0m'

info()  { echo "${BLUE}[*]${PLAIN} $*"; }
ok()    { echo "${GREEN}[✓]${PLAIN} $*"; }
warn()  { echo "${YELLOW}[!]${PLAIN} $*"; }
err()   { echo "${RED}[×]${PLAIN} $*"; }
die()   { err "$*"; exit 1; }

# ---------------------------------------------------------------- 输入封装
# 支持 `curl ... | bash` 的场景：优先从 /dev/tty 读，保证交互不被管道吃掉。
_read() {  # _read <变量名> <提示语> [-s]
    local __var="$1" __prompt="$2" __silent="${3:-}" __src=/dev/stdin
    [ -r /dev/tty ] && __src=/dev/tty
    if [ "$__silent" = "-s" ]; then
        read -r -s -p "$__prompt" "$__var" < "$__src"
        echo
    else
        read -r -p "$__prompt" "$__var" < "$__src"
    fi
}

ask() {  # ask <变量名> <提示语> [默认值]
    local __var="$1" __prompt="$2" __def="${3:-}" __in=""
    if [ -n "$__def" ]; then
        _read __in "$__prompt [$__def]: "
        [ -z "$__in" ] && __in="$__def"
    else
        _read __in "$__prompt: "
    fi
    printf -v "$__var" '%s' "$__in"
}

ask_secret() {  # ask_secret <变量名> <提示语>
    local __var="$1" __in=""
    _read __in "$2: " -s
    printf -v "$__var" '%s' "$__in"
}

confirm() {  # confirm <提示语> [y|n 默认]  → 返回 0 表示 yes
    local prompt="$1" def="${2:-n}" in="" hint="[y/N]"
    [ "$def" = "y" ] && hint="[Y/n]"
    while :; do
        _read in "$prompt $hint: "
        [ -z "$in" ] && in="$def"
        case "$in" in
            y|Y|yes|YES) return 0 ;;
            n|N|no|NO)   return 1 ;;
            *) warn "请输入 y 或 n" ;;
        esac
    done
}

pause() { local _x; _read _x "按回车返回菜单..."; }

# ---------------------------------------------------------------- 环境检查
require_root() {
    [ "$(id -u)" = "0" ] || die "请用 root 运行：sudo bash $0"
}

check_os() {
    [ -r /etc/os-release ] || die "无法识别系统（缺少 /etc/os-release），本脚本仅支持 Debian / Ubuntu"
    . /etc/os-release
    case "${ID:-}${ID_LIKE:-}" in
        *debian*|*ubuntu*) ok "系统：${PRETTY_NAME:-$ID}" ;;
        *) die "本脚本仅支持 Debian / Ubuntu，当前为 ${PRETTY_NAME:-$ID}" ;;
    esac
    command -v apt-get >/dev/null 2>&1 || die "未找到 apt-get，无法安装依赖"
}

install_deps() {
    local need=()
    command -v curl    >/dev/null 2>&1 || need+=(curl)
    command -v socat   >/dev/null 2>&1 || need+=(socat)
    command -v openssl >/dev/null 2>&1 || need+=(openssl)
    command -v crontab >/dev/null 2>&1 || need+=(cron)
    [ -d /etc/ssl/certs ] || need+=(ca-certificates)

    if [ ${#need[@]} -gt 0 ]; then
        info "安装依赖：${need[*]}"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y >/dev/null 2>&1
        apt-get install -y "${need[@]}" || die "依赖安装失败，请检查网络或软件源"
    fi
    ok "依赖就绪 (curl socat openssl cron ca-certificates)"

    # 续期依赖 cron 守护进程常驻
    if ! systemctl is-active --quiet cron 2>/dev/null; then
        systemctl enable --now cron >/dev/null 2>&1
    fi
    if systemctl is-active --quiet cron 2>/dev/null; then
        ok "cron 服务运行中（自动续期依赖它）"
    else
        warn "cron 服务未运行，自动续期可能失效，请手动检查：systemctl status cron"
    fi
}

# ---------------------------------------------------------------- acme.sh
acme_installed() { [ -x "$ACME" ]; }

install_acme() {
    if acme_installed; then
        ok "acme.sh 已安装：$("$ACME" --version 2>/dev/null | tail -n1)"
        return 0
    fi
    local email=""
    echo
    info "acme.sh 需要一个注册邮箱（CA 用它发送证书到期提醒，不会公开）"
    while :; do
        ask email "请输入邮箱"
        case "$email" in
            *@*.*) break ;;
            *) warn "邮箱格式不正确" ;;
        esac
    done

    info "正在安装 acme.sh ..."
    curl -fsSL https://get.acme.sh | sh -s email="$email" || die "acme.sh 安装失败"
    acme_installed || die "acme.sh 安装后未找到 $ACME"

    "$ACME" --set-default-ca --server letsencrypt >/dev/null 2>&1
    "$ACME" --upgrade --auto-upgrade >/dev/null 2>&1
    ok "acme.sh 安装完成，默认 CA = Let's Encrypt，已开启自动升级"
}

install_self() {
    # 把脚本自身放到 PATH，方便以后直接敲 acme-onekey 进管理菜单
    local src
    src="$(readlink -f "${BASH_SOURCE[0]}")"
    [ "$src" = "$SELF_PATH" ] && return 0
    if [ -e "$SELF_PATH" ] && ! grep -q "acme-onekey.sh" "$SELF_PATH" 2>/dev/null; then
        warn "$SELF_PATH 已存在且不是本脚本，跳过安装快捷命令"
        return 0
    fi
    install -m 0755 "$src" "$SELF_PATH" 2>/dev/null \
        && ok "快捷命令已安装，以后直接运行：${GREEN}acme-onekey${PLAIN}"
}

# ---------------------------------------------------------------- 校验
valid_domain() {
    [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]
}

valid_path() {
    local p="$1"
    [[ "$p" = /* ]] || return 1
    [[ "$p" =~ [[:space:]] ]] && return 1
    case "$p" in
        /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var) return 1 ;;
    esac
    return 0
}

cert_dir_of() { echo "$ACME_HOME/$1_ecc"; }

cert_exists() { [ -f "$(cert_dir_of "$1")/$1.cer" ]; }

# 从 acme.sh 自己的域名配置里取部署路径（唯一真相来源，不另存状态文件）
conf_value() {  # conf_value <域名> <键名>
    local conf="$(cert_dir_of "$1")/$1.conf" v
    [ -f "$conf" ] || return 1
    v="$(grep -m1 "^$2=" "$conf" | cut -d= -f2-)"
    v="${v%\'}"; v="${v#\'}"
    [ -n "$v" ] && echo "$v"
}

installed_domains() {
    local d
    for d in "$ACME_HOME"/*_ecc; do
        [ -d "$d" ] || continue
        d="$(basename "$d")"
        echo "${d%_ecc}"
    done
}

domain_count() { installed_domains | grep -c . 2>/dev/null | tr -d ' '; }

# acme.sh 存的是 CA 的 directory URL，这里翻回人类可读的名字
current_ca() {
    local u
    u="$(grep -m1 '^DEFAULT_ACME_SERVER=' "$ACME_HOME/account.conf" 2>/dev/null | cut -d= -f2- | tr -d "'")"
    case "$u" in
        *letsencrypt*) echo "Let's Encrypt" ;;
        *zerossl*)     echo "ZeroSSL" ;;
        *buypass*)     echo "Buypass" ;;
        "")            echo "Let's Encrypt（默认）" ;;
        *)             echo "$u" ;;
    esac
}

# 取域名的部署目录，未部署时返回非 0
deploy_dir_of() {
    local k
    k="$(conf_value "$1" Le_RealKeyPath)" || return 1
    [ -n "$k" ] || return 1
    dirname "$k"
}

# ---------------------------------------------------------------- DNS 凭据
has_saved() { grep -q "^SAVED_$1=" "$ACME_HOME/account.conf" 2>/dev/null; }

# 设置 DNS_HOOK / DNS_LABEL，并 export 所需凭据环境变量。
# acme.sh 首次签发时会把这些变量存进 account.conf，之后续期自动读取，无需再输入。
collect_creds() {
    local choice
    echo
    echo "  选择域名解析服务商（DNS API 托管模式）："
    echo "   1) Cloudflare"
    echo "   2) 阿里云 DNS"
    echo "   3) 腾讯云 DNSPod（Tencent Cloud API 密钥）"
    echo "   4) DNSPod 国内版（DNSPod 独立 Token）"
    echo "   0) 返回"
    ask choice "请选择"

    local vars=()
    case "$choice" in
        1)
            DNS_LABEL="Cloudflare"; DNS_HOOK="dns_cf"
            local m
            echo "   1) API Token（推荐，权限最小化）"
            echo "   2) Global API Key + 账号邮箱"
            ask m "认证方式" "1"
            if [ "$m" = "2" ]; then
                vars=(CF_Key CF_Email)
                reuse_or_ask "${vars[@]}" || return 1
            else
                vars=(CF_Token)
                if reuse_or_ask "${vars[@]}"; then :; else return 1; fi
                if [ "$CRED_REUSED" != "1" ]; then
                    local acc zone
                    ask acc  "Cloudflare Account ID（可留空）"
                    ask zone "Cloudflare Zone ID（可留空）"
                    [ -n "$acc" ]  && export CF_Account_ID="$acc"
                    [ -n "$zone" ] && export CF_Zone_ID="$zone"
                fi
            fi
            ;;
        2)
            DNS_LABEL="阿里云 DNS"; DNS_HOOK="dns_ali"
            vars=(Ali_Key Ali_Secret)
            reuse_or_ask "${vars[@]}" || return 1
            ;;
        3)
            DNS_LABEL="腾讯云 DNSPod"; DNS_HOOK="dns_tencent"
            vars=(Tencent_SecretId Tencent_SecretKey)
            reuse_or_ask "${vars[@]}" || return 1
            ;;
        4)
            DNS_LABEL="DNSPod"; DNS_HOOK="dns_dp"
            vars=(DP_Id DP_Key)
            reuse_or_ask "${vars[@]}" || return 1
            ;;
        0) return 1 ;;
        *) warn "无效选择"; return 1 ;;
    esac
    ok "解析商：$DNS_LABEL（hook: $DNS_HOOK）"
    return 0
}

# 已保存过的凭据默认复用，避免重复粘贴（也避免把旧凭据覆盖成错的）
reuse_or_ask() {
    local all_saved=1 v val
    CRED_REUSED=0
    for v in "$@"; do has_saved "$v" || all_saved=0; done
    if [ "$all_saved" = "1" ]; then
        if confirm "检测到已保存的 $DNS_LABEL 凭据（$*），复用它？" "y"; then
            CRED_REUSED=1
            return 0
        fi
    fi
    for v in "$@"; do
        while :; do
            case "$v" in
                *Email) ask val "请输入 $v" ;;
                *Key|*Secret|*Token|*SecretKey) ask_secret val "请输入 $v（输入不回显）" ;;
                *) ask val "请输入 $v" ;;
            esac
            [ -n "$val" ] && break
            warn "$v 不能为空"
        done
        export "$v=$val"
    done
    return 0
}

# ---------------------------------------------------------------- 路径防呆
# 返回 0 表示 CERT_DIR 可用
choose_cert_dir() {  # choose_cert_dir <域名>
    local domain="$1" p files=() f owner
    while :; do
        ask p "证书存放目录" "$DEFAULT_CERT_ROOT/$domain"
        if ! valid_path "$p"; then
            warn "路径非法：必须是绝对路径、不含空格、且不能是 / 或系统顶级目录"
            continue
        fi
        p="${p%/}"

        # 防呆 1：该路径是否已被其它域名的部署配置占用
        owner="$(grep -rl "Le_RealFullChainPath='$p/fullchain.cer'" "$ACME_HOME"/*_ecc/*.conf 2>/dev/null | head -n1)"
        if [ -n "$owner" ]; then
            local od; od="$(basename "$(dirname "$owner")")"; od="${od%_ecc}"
            if [ "$od" != "$domain" ]; then
                err "该路径已被域名 $od 使用，请换一个目录"
                continue
            fi
        fi

        # 防呆 2：目录里已经有证书文件 → 默认不覆盖
        files=()
        for f in private.key fullchain.cer cert.cer ca.cer; do
            [ -e "$p/$f" ] && files+=("$f")
        done
        if [ ${#files[@]} -gt 0 ]; then
            warn "目录 $p 已存在文件：${files[*]}"
            local c
            echo "   1) 换一个目录（推荐）"
            echo "   2) 我确认要覆盖这些文件"
            echo "   0) 取消本次操作"
            ask c "请选择" "1"
            case "$c" in
                1) continue ;;
                2) confirm "覆盖后原文件无法恢复，确认？" "n" || continue ;;
                *) return 1 ;;
            esac
        fi

        if [ ! -d "$p" ]; then
            mkdir -p "$p" || { err "创建目录失败：$p"; continue; }
        fi
        chmod 700 "$p" 2>/dev/null
        CERT_DIR="$p"
        return 0
    done
}

deploy_cert() {  # deploy_cert <域名> <目录> <reloadcmd>
    local domain="$1" dir="$2" reload="$3"
    local args=(--install-cert -d "$domain" --ecc
        --key-file       "$dir/private.key"
        --fullchain-file "$dir/fullchain.cer"
        --cert-file      "$dir/cert.cer"
        --ca-file        "$dir/ca.cer")
    [ -n "$reload" ] && args+=(--reloadcmd "$reload")
    "$ACME" "${args[@]}"
}

ask_reloadcmd() {  # 结果写入 RELOAD_CMD
    local cmd=""
    echo
    info "续期成功后可自动重载服务（留空表示不执行任何命令）"
    echo "   常见：systemctl reload nginx / systemctl restart caddy / docker restart xray"
    ask cmd "重载命令"
    RELOAD_CMD="$cmd"
}

# ---------------------------------------------------------------- 主功能
issue_cert() {
    local domain wildcard=0 force=0
    echo
    while :; do
        ask domain "请输入主域名（如 example.com）"
        domain="$(echo "$domain" | tr 'A-Z' 'a-z' | tr -d ' ')"
        domain="${domain#\*.}"
        if valid_domain "$domain"; then break; fi
        warn "域名格式不正确"
    done

    # 防呆：已经签过就别默认重签，免得白白消耗 CA 频率限制
    if cert_exists "$domain"; then
        warn "域名 $domain 已有证书："
        printf '    下次续期：%s\n' "$(conf_value "$domain" Le_NextRenewTimeStr || echo 未知)"
        printf '    部署路径：%s\n' "$(deploy_dir_of "$domain" || echo '（未部署）')"
        local c
        echo "   1) 取消（推荐，续期由 cron 自动完成）"
        echo "   2) 强制重新签发（--force，注意 CA 有频率限制）"
        echo "   3) 只重新部署到新路径，不重新签发"
        ask c "请选择" "1"
        case "$c" in
            2) force=1 ;;
            3) redeploy_cert "$domain"; return ;;
            *) return ;;
        esac
    fi

    confirm "是否同时签发泛域名 *.$domain ？" "y" && wildcard=1

    collect_creds || return

    choose_cert_dir "$domain" || { warn "已取消"; return; }
    ask_reloadcmd

    echo
    echo "  ──────────── 请确认 ────────────"
    echo "   域名      : $domain$([ $wildcard = 1 ] && echo " + *.$domain")"
    echo "   解析商    : $DNS_LABEL"
    echo "   存放目录  : $CERT_DIR"
    echo "   重载命令  : ${RELOAD_CMD:-（无）}"
    echo "   密钥类型  : ECC secp256r1"
    echo "   CA        : $(current_ca)"
    echo "  ────────────────────────────────"
    confirm "确认开始申请？" "y" || { warn "已取消"; return; }

    local args=(--issue --dns "$DNS_HOOK" -d "$domain" -k ec-256)
    [ $wildcard = 1 ] && args+=(-d "*.$domain")
    [ $force = 1 ] && args+=(--force)

    echo
    info "正在申请证书，DNS 记录生效需要等待，请耐心（通常 1~3 分钟）..."
    if ! "$ACME" "${args[@]}"; then
        err "证书申请失败。常见原因：API 密钥权限不足、域名不在该账号下、DNS 尚未生效。"
        warn "可加 --debug 手动重试排查：$ACME --issue --dns $DNS_HOOK -d $domain --debug"
        pause; return
    fi

    if ! deploy_cert "$domain" "$CERT_DIR" "$RELOAD_CMD"; then
        err "证书已签发，但部署到 $CERT_DIR 失败，请在菜单 5 重新部署"
        pause; return
    fi

    echo
    ok "证书签发并部署完成"
    echo "   私钥      : $CERT_DIR/private.key"
    echo "   完整证书链: $CERT_DIR/fullchain.cer"
    echo "   证书      : $CERT_DIR/cert.cer"
    echo "   中间证书  : $CERT_DIR/ca.cer"
    echo
    ok "自动续期已生效：acme.sh 的 cron 每天检查，到期前自动续签、复制到上述路径并执行重载命令"
    pause
}

list_certs() {
    echo
    if [ -z "$(installed_domains)" ]; then
        warn "还没有任何证书"
        pause; return
    fi
    "$ACME" --list
    echo
    info "各域名部署路径与重载命令："
    local d p r
    while read -r d; do
        [ -z "$d" ] && continue
        p="$(deploy_dir_of "$d")" || p="（未部署，可用菜单 5 部署）"
        r="$(conf_value "$d" Le_ReloadCmd || true)"
        echo "   $d"
        echo "      目录: $p"
        echo "      重载: ${r:-（无）}"
    done <<< "$(installed_domains)"
    pause
}

select_domain() {  # 结果写入 SELECTED_DOMAIN，返回 1 表示无证书/取消
    local list=() i=1 c
    while read -r d; do [ -n "$d" ] && list+=("$d"); done <<< "$(installed_domains)"
    if [ ${#list[@]} -eq 0 ]; then
        warn "还没有任何证书"
        return 1
    fi
    echo
    for d in "${list[@]}"; do
        echo "   $i) $d"
        i=$((i+1))
    done
    echo "   0) 返回"
    ask c "请选择域名"
    [ "$c" = "0" ] && return 1
    if ! [[ "$c" =~ ^[0-9]+$ ]] || [ "$c" -gt ${#list[@]} ] || [ "$c" -lt 1 ]; then
        warn "无效选择"; return 1
    fi
    SELECTED_DOMAIN="${list[$((c-1))]}"
    return 0
}

renew_cert() {
    local c
    echo
    echo "   1) 检查并续期全部证书（未到期的会跳过，等同 cron 的行为）"
    echo "   2) 强制续期指定域名（忽略剩余天数，注意 CA 频率限制）"
    echo "   0) 返回"
    ask c "请选择" "1"
    case "$c" in
        1)
            "$ACME" --cron
            ok "已执行一次续期检查"
            ;;
        2)
            select_domain || return
            confirm "强制续期 $SELECTED_DOMAIN ？" "n" || return
            if "$ACME" --renew -d "$SELECTED_DOMAIN" --ecc --force; then
                ok "$SELECTED_DOMAIN 续期完成，新证书已按原配置复制到部署目录"
            else
                err "续期失败，请检查 DNS API 凭据是否仍然有效"
            fi
            ;;
        *) return ;;
    esac
    pause
}

redeploy_cert() {  # 可带域名参数
    local domain="${1:-}"
    if [ -z "$domain" ]; then
        select_domain || return
        domain="$SELECTED_DOMAIN"
    fi
    local old=""
    old="$(deploy_dir_of "$domain")" && info "当前部署目录：$old" || old=""

    choose_cert_dir "$domain" || { warn "已取消"; return; }
    ask_reloadcmd
    if deploy_cert "$domain" "$CERT_DIR" "$RELOAD_CMD"; then
        ok "已部署到 $CERT_DIR，后续自动续期会复制到这里"
        if [ -n "$old" ] && [ "$old" != "$CERT_DIR" ]; then
            warn "旧目录 $old 的文件仍然保留，确认新路径可用后可自行删除"
        fi
    else
        err "部署失败"
    fi
    pause
}

revoke_cert() {
    select_domain || return
    local domain="$SELECTED_DOMAIN" dir=""
    dir="$(deploy_dir_of "$domain")" || dir=""
    echo
    warn "即将吊销并删除 $domain 的证书，此操作不可撤销"
    confirm "确认继续？" "n" || { warn "已取消"; return; }

    "$ACME" --revoke -d "$domain" --ecc 2>/dev/null || warn "吊销请求失败（可能证书已过期），继续删除本地记录"
    "$ACME" --remove -d "$domain" --ecc >/dev/null 2>&1
    rm -rf "$(cert_dir_of "$domain")"
    ok "已从 acme.sh 移除 $domain，自动续期随之停止"

    if [ -n "$dir" ] && [ -d "$dir" ]; then
        if confirm "是否一并删除部署目录 $dir 下的证书文件？" "n"; then
            rm -f "$dir/private.key" "$dir/fullchain.cer" "$dir/cert.cer" "$dir/cert.pem" "$dir/ca.cer"
            rmdir "$dir" 2>/dev/null
            ok "已删除 $dir 下的证书文件"
        else
            info "保留 $dir，请注意其中证书不会再更新"
        fi
    fi
    pause
}

cron_status() {
    echo
    if crontab -l 2>/dev/null | grep -q "acme.sh --cron"; then
        ok "自动续期任务已存在："
        crontab -l 2>/dev/null | grep "acme.sh" | sed 's/^/   /'
    else
        err "未找到 acme.sh 的 cron 任务，自动续期不会发生"
        if confirm "现在修复（重新安装 cron 任务）？" "y"; then
            "$ACME" --install-cronjob && ok "cron 任务已恢复"
        fi
    fi
    echo
    if systemctl is-active --quiet cron 2>/dev/null; then
        ok "cron 服务运行中"
    else
        err "cron 服务未运行"
        confirm "现在启动？" "y" && systemctl enable --now cron && ok "已启动"
    fi
    echo
    info "acme.sh 默认每天检查一次，证书剩余不足 30 天时自动续签"
    info "续期日志：$ACME_HOME/acme.sh.log"
    pause
}

change_ca() {
    local c
    echo
    info "当前默认 CA：$(current_ca)"
    echo "   1) Let's Encrypt（默认，免费，90 天）"
    echo "   2) ZeroSSL（需邮箱注册，90 天）"
    echo "   3) Buypass（180 天）"
    echo "   0) 返回"
    ask c "请选择" "0"
    case "$c" in
        1) "$ACME" --set-default-ca --server letsencrypt && ok "已切换到 Let's Encrypt" ;;
        2) "$ACME" --set-default-ca --server zerossl     && ok "已切换到 ZeroSSL" ;;
        3) "$ACME" --set-default-ca --server buypass     && ok "已切换到 Buypass" ;;
        *) return ;;
    esac
    warn "切换只影响之后新签发的证书，已有证书续期仍走原 CA"
    pause
}

update_acme() {
    echo
    "$ACME" --upgrade && ok "acme.sh 已更新到 $("$ACME" --version 2>/dev/null | tail -n1)"
    pause
}

uninstall_all() {
    echo
    err "卸载将删除 acme.sh、其 cron 任务和 $ACME_HOME 下的全部证书与账户信息"
    confirm "确认卸载？" "n" || { warn "已取消"; return; }
    confirm "再次确认：所有证书都会失去自动续期能力，继续？" "n" || { warn "已取消"; return; }

    "$ACME" --uninstall >/dev/null 2>&1
    rm -rf "$ACME_HOME"
    ok "acme.sh 已卸载（各部署目录里的证书文件保留，但不会再更新）"
    if confirm "同时删除本脚本的快捷命令 $SELF_PATH ？" "n"; then
        rm -f "$SELF_PATH"; ok "已删除"
    fi
    pause
}

# ---------------------------------------------------------------- 菜单
menu() {
    while :; do
        clear 2>/dev/null
        echo "${GREEN}================================================${PLAIN}"
        echo "  acme.sh DNS API 一键脚本 (Debian/Ubuntu)  v$VERSION"
        echo "  acme.sh: $(acme_installed && "$ACME" --version 2>/dev/null | tail -n1 || echo 未安装)"
        echo "  已签发 : $(domain_count) 个域名 | CA: $(current_ca)"
        echo "${GREEN}================================================${PLAIN}"
        echo "   1) 申请新证书（DNS API 托管）"
        echo "   2) 查看已签发证书"
        echo "   3) 续期证书（全部检查 / 强制单个）"
        echo "   4) 吊销并删除证书"
        echo "   5) 修改证书存放路径 / 重载命令"
        echo "   6) 检查自动续期任务（cron）"
        echo "   7) 切换默认 CA"
        echo "   8) 更新 acme.sh"
        echo "   9) 卸载 acme.sh"
        echo "   0) 退出"
        echo
        local c; ask c "请选择"
        case "$c" in
            1) issue_cert ;;
            2) list_certs ;;
            3) renew_cert ;;
            4) revoke_cert ;;
            5) redeploy_cert ;;
            6) cron_status ;;
            7) change_ca ;;
            8) update_acme ;;
            9) uninstall_all ;;
            0) echo; exit 0 ;;
            *) warn "无效选择"; sleep 1 ;;
        esac
    done
}

main() {
    require_root
    check_os
    install_deps
    install_acme
    install_self
    menu
}

main "$@"
