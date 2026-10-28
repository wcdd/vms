#!/usr/bin/env bash
#==============================================================================
#  sbvm.sh  --  sing-box  VMess + WebSocket  管理脚本 (无域名 / 纯 IP 模式)
#
#  用法:  bash sbvm.sh        首次运行
#         sbvm                安装后可直接用这个短命令
#
#  设计目标: 稳定优先
#    * 极简配置(只有 inbounds + 一个 direct 出站),不使用任何已废弃字段
#    * 任何改动前先 sing-box check,失败自动回滚
#    * 重启后自动探活,起不来自动回滚到上一版配置
#    * systemd 自愈 + 无重启次数限制
#    * 自动处理 ufw / firewalld / iptables 放行
#==============================================================================

set -o pipefail

#--------------------------------- 全局变量 ----------------------------------
SB_DIR="/etc/sing-box"
SB_CONF="${SB_DIR}/config.json"
SB_META="${SB_DIR}/sbvm.env"
SB_BACKUP="${SB_DIR}/backup"
SB_BIN="/usr/local/bin/sing-box"
SB_DATA="/var/lib/sing-box"
SB_UNIT="/etc/systemd/system/sing-box.service"
SB_SVC="sing-box"
SELF_PATH="/usr/local/bin/sbvm"

FALLBACK_VER="1.11.0"      # 所有在线获取版本号的方式都失败时的兜底版本

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLU=$'\033[36m'
BLD=$'\033[1m';  RST=$'\033[0m'

#--------------------------------- 输出函数 ----------------------------------
msg()  { echo -e "${BLU}[*]${RST} $*"; }
ok()   { echo -e "${GRN}[✓]${RST} $*"; }
warn() { echo -e "${YEL}[!]${RST} $*"; }
err()  { echo -e "${RED}[×]${RST} $*"; }
hr()   { echo -e "${BLU}------------------------------------------------------------${RST}"; }
pause(){ echo; read -r -p "按回车键返回菜单..." _; }

need_root() {
  if [[ $EUID -ne 0 ]]; then
    err "请用 root 运行:  sudo bash $0"
    exit 1
  fi
}

#------------------------------ 系统 / 依赖检测 -------------------------------
detect_os() {
  if   [[ -f /etc/os-release ]]; then . /etc/os-release; OS_ID="${ID,,}"
  else OS_ID="unknown"; fi

  if   command -v apt-get >/dev/null 2>&1; then PKG="apt"
  elif command -v dnf     >/dev/null 2>&1; then PKG="dnf"
  elif command -v yum     >/dev/null 2>&1; then PKG="yum"
  elif command -v apk     >/dev/null 2>&1; then PKG="apk"
  elif command -v pacman  >/dev/null 2>&1; then PKG="pacman"
  else PKG="none"; fi
}

pkg_install() {
  local pkgs="$*"
  case "$PKG" in
    apt)    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $pkgs >/dev/null 2>&1 ;;
    dnf)    dnf install -y -q $pkgs >/dev/null 2>&1 ;;
    yum)    yum install -y -q $pkgs >/dev/null 2>&1 ;;
    apk)    apk add --no-cache $pkgs >/dev/null 2>&1 ;;
    pacman) pacman -Sy --noconfirm $pkgs >/dev/null 2>&1 ;;
    *)      return 1 ;;
  esac
}

# jq 装不上时,直接抓官方静态二进制
install_jq_static() {
  local a
  case "$(uname -m)" in
    x86_64|amd64) a="amd64" ;;
    aarch64|arm64) a="arm64" ;;
    armv7l|armv7)  a="armhf" ;;
    i386|i686)     a="i386"  ;;
    *) return 1 ;;
  esac
  curl -fsSL --retry 3 --max-time 60 \
    -o /usr/local/bin/jq \
    "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-${a}" || return 1
  chmod +x /usr/local/bin/jq
  command -v jq >/dev/null 2>&1
}

DEPS_STAMP="/var/tmp/.sbvm_optdeps_tried"

ensure_deps() {
  local missing=() c
  command -v curl >/dev/null 2>&1 || missing+=("curl")
  command -v tar  >/dev/null 2>&1 || missing+=("tar")
  command -v jq   >/dev/null 2>&1 || missing+=("jq")
  command -v ss   >/dev/null 2>&1 || missing+=("iproute2")

  if [[ ${#missing[@]} -gt 0 ]]; then
    msg "正在安装必需依赖: ${missing[*]}"
    local list="${missing[*]}"
    # iproute2 在 RHEL 系叫 iproute
    [[ "$PKG" =~ ^(dnf|yum)$ ]] && list="${list//iproute2/iproute}"
    pkg_install $list

    if ! command -v jq >/dev/null 2>&1; then
      warn "包管理器装 jq 失败,尝试下载官方静态二进制..."
      install_jq_static || { err "jq 是必需依赖,请手动安装后重试。"; exit 1; }
    fi
    for c in curl tar; do
      command -v "$c" >/dev/null 2>&1 || { err "缺少必需依赖: $c,请手动安装后重试。"; exit 1; }
    done
    ok "必需依赖就绪"
  fi

  # qrencode 是可选的,只尝试装一次,失败就不再重复拖慢每次启动
  if ! command -v qrencode >/dev/null 2>&1 && [[ ! -f "$DEPS_STAMP" ]]; then
    pkg_install qrencode
    touch "$DEPS_STAMP" 2>/dev/null
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)   ARCH="amd64" ;;
    aarch64|arm64)  ARCH="arm64" ;;
    armv7l|armv7)   ARCH="armv7" ;;
    armv6l)         ARCH="armv6" ;;
    i386|i686)      ARCH="386"   ;;
    s390x)          ARCH="s390x" ;;
    riscv64)        ARCH="riscv64" ;;
    *) err "不支持的 CPU 架构: $(uname -m)"; exit 1 ;;
  esac
}

#------------------------------ meta 读写 ------------------------------------
load_meta() {
  LISTEN_ADDR="::"; OVERRIDE_IP=""; CUR_VER=""
  [[ -f "$SB_META" ]] && . "$SB_META"
  [[ -z "$LISTEN_ADDR" ]] && LISTEN_ADDR="::"
}

save_meta() {
  mkdir -p "$SB_DIR"
  cat > "$SB_META" <<EOF
# sbvm 脚本自身的设置,可手动编辑
LISTEN_ADDR="${LISTEN_ADDR}"
OVERRIDE_IP="${OVERRIDE_IP}"
CUR_VER="${CUR_VER}"
EOF
}

#------------------------------ 公网 IP 获取 ---------------------------------
get_public_ip() {
  if [[ -n "$OVERRIDE_IP" ]]; then echo "$OVERRIDE_IP"; return; fi
  local ip u
  for u in "https://api.ipify.org" "https://ipv4.icanhazip.com" "https://ifconfig.me/ip"; do
    ip="$(curl -fsS4 --max-time 6 "$u" 2>/dev/null | tr -d '\r\n ')"
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && { echo "$ip"; return; }
  done
  for u in "https://api64.ipify.org" "https://ipv6.icanhazip.com"; do
    ip="$(curl -fsS6 --max-time 6 "$u" 2>/dev/null | tr -d '\r\n ')"
    [[ "$ip" == *:* ]] && { echo "$ip"; return; }
  done
  # 最后退回本机默认路由地址
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')"
  [[ -n "$ip" ]] && { echo "$ip"; return; }
  echo "你的服务器IP"
}

#------------------------------ 防火墙处理 -----------------------------------
fw_backend() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
    echo "ufw"
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    echo "firewalld"
  elif command -v iptables >/dev/null 2>&1; then
    echo "iptables"
  else
    echo "none"
  fi
}

fw_persist() {
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1
  elif [[ -d /etc/iptables ]] && command -v iptables-save >/dev/null 2>&1; then
    iptables-save > /etc/iptables/rules.v4 2>/dev/null
    command -v ip6tables-save >/dev/null 2>&1 && ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
  elif command -v service >/dev/null 2>&1 && [[ -f /etc/sysconfig/iptables ]]; then
    service iptables save >/dev/null 2>&1
  fi
}

fw_open() {
  local p="$1"
  case "$(fw_backend)" in
    ufw)
      ufw allow "${p}/tcp" >/dev/null 2>&1 ;;
    firewalld)
      firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1
      firewall-cmd --reload >/dev/null 2>&1 ;;
    iptables)
      iptables -C INPUT -p tcp --dport "$p" -j ACCEPT >/dev/null 2>&1 || \
        iptables -I INPUT -p tcp --dport "$p" -j ACCEPT >/dev/null 2>&1
      if command -v ip6tables >/dev/null 2>&1 && [[ -e /proc/net/if_inet6 ]]; then
        ip6tables -C INPUT -p tcp --dport "$p" -j ACCEPT >/dev/null 2>&1 || \
          ip6tables -I INPUT -p tcp --dport "$p" -j ACCEPT >/dev/null 2>&1
      fi
      fw_persist ;;
  esac
}

fw_close() {
  local p="$1"
  case "$(fw_backend)" in
    ufw)
      ufw delete allow "${p}/tcp" >/dev/null 2>&1 ;;
    firewalld)
      firewall-cmd --permanent --remove-port="${p}/tcp" >/dev/null 2>&1
      firewall-cmd --reload >/dev/null 2>&1 ;;
    iptables)
      while iptables -C INPUT -p tcp --dport "$p" -j ACCEPT >/dev/null 2>&1; do
        iptables -D INPUT -p tcp --dport "$p" -j ACCEPT >/dev/null 2>&1 || break
      done
      if command -v ip6tables >/dev/null 2>&1; then
        while ip6tables -C INPUT -p tcp --dport "$p" -j ACCEPT >/dev/null 2>&1; do
          ip6tables -D INPUT -p tcp --dport "$p" -j ACCEPT >/dev/null 2>&1 || break
        done
      fi
      fw_persist ;;
  esac
}

#------------------------------ 内核安装 / 升级 -------------------------------
latest_version() {
  local v
  # 方式一: GitHub API
  v="$(curl -fsSL --max-time 10 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null \
       | jq -r '.tag_name // empty' 2>/dev/null | sed 's/^v//')"
  [[ "$v" =~ ^[0-9]+\.[0-9]+ ]] && { echo "$v"; return; }
  # 方式二: 解析 releases/latest 的 302 跳转
  v="$(curl -fsSLI --max-time 10 -o /dev/null -w '%{url_effective}' \
       https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null \
       | sed 's#.*/tag/v\?##')"
  [[ "$v" =~ ^[0-9]+\.[0-9]+ ]] && { echo "$v"; return; }
  # 方式三: 兜底
  echo "$FALLBACK_VER"
}

download_core() {
  local ver="$1" tmpd pkg url
  tmpd="$(mktemp -d)" || return 1
  pkg="sing-box-${ver}-linux-${ARCH}.tar.gz"
  url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/${pkg}"

  msg "下载: ${url}"
  if ! curl -fL --retry 3 --retry-delay 2 --max-time 180 -o "${tmpd}/${pkg}" "$url"; then
    err "下载失败。可能是版本号不存在或网络不通。"
    rm -rf "$tmpd"; return 1
  fi

  if ! tar -xzf "${tmpd}/${pkg}" -C "$tmpd"; then
    err "解压失败,文件可能损坏。"; rm -rf "$tmpd"; return 1
  fi

  local newbin
  newbin="$(find "$tmpd" -type f -name 'sing-box' | head -n1)"
  [[ -z "$newbin" ]] && { err "压缩包里没找到 sing-box 可执行文件。"; rm -rf "$tmpd"; return 1; }

  chmod +x "$newbin"
  if ! "$newbin" version >/dev/null 2>&1; then
    err "新下载的二进制无法执行(架构可能不匹配)。"; rm -rf "$tmpd"; return 1
  fi

  # 备份旧内核以便回滚
  [[ -f "$SB_BIN" ]] && cp -f "$SB_BIN" "${SB_BIN}.bak"
  install -m 755 "$newbin" "$SB_BIN"
  rm -rf "$tmpd"
  CUR_VER="$ver"
  ok "sing-box $("$SB_BIN" version | head -n1)"
  return 0
}

write_unit() {
  cat > "$SB_UNIT" <<'EOF'
[Unit]
Description=sing-box service (managed by sbvm)
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/var/lib/sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=/usr/local/bin/sing-box -D /var/lib/sing-box -c /etc/sing-box/config.json run
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5s
StartLimitIntervalSec=0
LimitNOFILE=1048576
LimitNPROC=512

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$SB_SVC" >/dev/null 2>&1
}

init_config() {
  mkdir -p "$SB_DIR" "$SB_DATA" "$SB_BACKUP"
  chmod 700 "$SB_DIR"
  if [[ -f "$SB_CONF" ]]; then
    if jq -e '.inbounds' "$SB_CONF" >/dev/null 2>&1; then
      warn "检测到已有配置,保留不动。"
      return 0
    else
      warn "已有配置文件无法解析,已备份为 config.json.broken"
      mv -f "$SB_CONF" "${SB_BACKUP}/config.json.broken.$(date +%s)"
    fi
  fi
  cat > "$SB_CONF" <<'EOF'
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
  chmod 600 "$SB_CONF"
  ok "初始化配置完成"
}

#------------------------------ 配置应用 / 回滚 -------------------------------
# 用法: apply_config <新配置的临时文件>
apply_config() {
  local tmp="$1" stamp rollback
  stamp="$(date +%Y%m%d-%H%M%S)"

  if ! "$SB_BIN" check -c "$tmp" 2>/tmp/sbvm_check.log; then
    err "配置校验未通过,已放弃本次修改。错误信息:"
    sed 's/^/    /' /tmp/sbvm_check.log
    rm -f "$tmp"
    return 1
  fi

  mkdir -p "$SB_BACKUP"
  rollback="${SB_BACKUP}/config.json.${stamp}"
  [[ -f "$SB_CONF" ]] && cp -f "$SB_CONF" "$rollback"

  local n_in
  n_in="$(jq '.inbounds | length' "$tmp" 2>/dev/null)"

  mv -f "$tmp" "$SB_CONF"
  chmod 600 "$SB_CONF"

  # 一个节点都不剩时,sing-box 没有存在意义,直接停服,
  # 否则下面的"起不来就回滚"会把刚删掉的节点又装回去
  if [[ "$n_in" == "0" ]]; then
    systemctl stop "$SB_SVC" >/dev/null 2>&1
    warn "当前已无任何节点,服务已停止。新增节点后会自动重新启动。"
    return 0
  fi

  systemctl restart "$SB_SVC" >/dev/null 2>&1
  sleep 2

  if ! systemctl is-active --quiet "$SB_SVC"; then
    err "sing-box 重启后未能正常运行,正在自动回滚..."
    if [[ -f "$rollback" ]]; then
      cp -f "$rollback" "$SB_CONF"
      systemctl restart "$SB_SVC" >/dev/null 2>&1
      sleep 1
      systemctl is-active --quiet "$SB_SVC" && ok "已回滚到上一版配置。" || err "回滚后仍未启动,请用菜单 [14] 诊断。"
    fi
    journalctl -u "$SB_SVC" -n 20 --no-pager 2>/dev/null | sed 's/^/    /'
    return 1
  fi

  # 只保留最近 30 份备份
  ls -1t "${SB_BACKUP}"/config.json.* 2>/dev/null | tail -n +31 | xargs -r rm -f
  return 0
}

#------------------------------ 工具函数 -------------------------------------
gen_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  elif [[ -x "$SB_BIN" ]]; then
    "$SB_BIN" generate uuid
  else
    python3 -c 'import uuid;print(uuid.uuid4())' 2>/dev/null
  fi
}

gen_path() {
  local h
  h="$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  echo "/${h}"
}

port_in_use() {           # port_in_use <端口> [排除的端口]
  local p="$1" skip="$2"
  [[ -n "$skip" && "$p" == "$skip" ]] && return 1
  ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$" && return 0
  jq -e --argjson p "$p" '[.inbounds[]?|select(.listen_port==$p)]|length>0' "$SB_CONF" >/dev/null 2>&1 && return 0
  return 1
}

rand_port() {
  local p
  for _ in $(seq 1 50); do
    p=$(( RANDOM % 40000 + 20000 ))
    port_in_use "$p" || { echo "$p"; return; }
  done
  echo 28388
}

installed() { [[ -x "$SB_BIN" && -f "$SB_CONF" ]]; }

require_installed() {
  if ! installed; then
    err "还没有安装,请先在主菜单选择 [1] 安装。"
    return 1
  fi
  return 0
}

# 把所有 vmess+ws 入站读进数组: N_PORT / N_UUID / N_PATH / N_NAME / N_TAG
load_nodes() {
  N_PORT=(); N_UUID=(); N_PATH=(); N_NAME=(); N_TAG=()
  local line
  while IFS=$'\t' read -r a b c d e; do
    [[ -z "$a" ]] && continue
    N_PORT+=("$a"); N_UUID+=("$b"); N_PATH+=("$c"); N_NAME+=("$d"); N_TAG+=("$e")
  done < <(jq -r '
      .inbounds[]?
      | select(.type=="vmess" and (.transport.type? // "")=="ws")
      | [ (.listen_port|tostring),
          (.users[0].uuid // ""),
          (.transport.path // "/"),
          (.users[0].name // "node"),
          (.tag // "") ]
      | @tsv' "$SB_CONF" 2>/dev/null)
  NODE_COUNT=${#N_PORT[@]}
}

#------------------------------ 分享链接生成 ---------------------------------
vmess_link() {           # vmess_link <ip> <port> <uuid> <path> <name>
  local ip="$1" port="$2" uuid="$3" path="$4" name="$5" j
  j="$(jq -cn --arg ps "$name" --arg add "$ip" --arg port "$port" \
              --arg id "$uuid" --arg path "$path" \
        '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",scy:"auto",
          net:"ws",type:"none",host:"",path:$path,tls:"",sni:"",alpn:"",fp:""}')"
  printf 'vmess://%s' "$(printf '%s' "$j" | base64 | tr -d '\n')"
}

singbox_outbound() {     # 前置机若也是 sing-box,直接抄这段
  local ip="$1" port="$2" uuid="$3" path="$4" name="$5"
  jq -n --arg tag "to-${name}" --arg srv "$ip" --argjson p "$port" \
        --arg id "$uuid" --arg path "$path" \
    '{type:"vmess",tag:$tag,server:$srv,server_port:$p,uuid:$id,
      security:"auto",alter_id:0,
      transport:{type:"ws",path:$path}}'
}

xray_outbound() {        # 前置机若是 Xray/V2Ray
  local ip="$1" port="$2" uuid="$3" path="$4" name="$5"
  jq -n --arg tag "to-${name}" --arg srv "$ip" --argjson p "$port" \
        --arg id "$uuid" --arg path "$path" \
    '{tag:$tag,protocol:"vmess",
      settings:{vnext:[{address:$srv,port:$p,
        users:[{id:$id,alterId:0,security:"auto"}]}]},
      streamSettings:{network:"ws",security:"none",
        wsSettings:{path:$path}}}'
}

print_node_detail() {    # print_node_detail <索引>
  local i="$1" ip link
  ip="$(get_public_ip)"
  hr
  echo -e "${BLD}节点备注:${RST} ${N_NAME[$i]}"
  echo -e "${BLD}地址(add):${RST} ${ip}"
  echo -e "${BLD}端口(port):${RST} ${N_PORT[$i]}"
  echo -e "${BLD}用户ID(uuid):${RST} ${N_UUID[$i]}"
  echo -e "${BLD}额外ID(alterId):${RST} 0"
  echo -e "${BLD}加密方式:${RST} auto"
  echo -e "${BLD}传输协议(network):${RST} ws"
  echo -e "${BLD}路径(path):${RST} ${N_PATH[$i]}"
  echo -e "${BLD}伪装域名(host):${RST} (留空)"
  echo -e "${BLD}TLS:${RST} 关闭"
  hr
  link="$(vmess_link "$ip" "${N_PORT[$i]}" "${N_UUID[$i]}" "${N_PATH[$i]}" "${N_NAME[$i]}")"
  echo -e "${GRN}分享链接:${RST}"
  echo "$link"
  echo
  if command -v qrencode >/dev/null 2>&1; then
    read -r -p "显示二维码? [y/N]: " q
    [[ "$q" =~ ^[Yy]$ ]] && qrencode -t ANSIUTF8 "$link"
  fi
  echo
  echo -e "${GRN}前置机是 sing-box 时的出站配置:${RST}"
  singbox_outbound "$ip" "${N_PORT[$i]}" "${N_UUID[$i]}" "${N_PATH[$i]}" "${N_NAME[$i]}"
  echo
  echo -e "${GRN}前置机是 Xray/V2Ray 时的出站配置:${RST}"
  xray_outbound "$ip" "${N_PORT[$i]}" "${N_UUID[$i]}" "${N_PATH[$i]}" "${N_NAME[$i]}"
}

#================================ 菜单动作 ===================================

act_install() {
  detect_arch
  if installed; then
    warn "检测到已安装 sing-box ($("$SB_BIN" version 2>/dev/null | head -n1))"
    read -r -p "重装内核(配置会保留)? [y/N]: " a
    [[ ! "$a" =~ ^[Yy]$ ]] && return 0
  fi

  local ver
  read -r -p "指定版本号(直接回车=自动获取最新稳定版): " ver
  if [[ -z "$ver" ]]; then
    msg "正在查询最新版本..."
    ver="$(latest_version)"
  fi
  ver="${ver#v}"
  msg "目标版本: ${ver}"

  download_core "$ver" || return 1

  [[ -e /proc/net/if_inet6 ]] && LISTEN_ADDR="::" || LISTEN_ADDR="0.0.0.0"
  save_meta

  init_config
  write_unit

  # 安装自身为 sbvm 短命令
  local me; me="$(readlink -f "$0" 2>/dev/null)"
  if [[ -n "$me" && "$me" != "$SELF_PATH" ]]; then
    cp -f "$me" "$SELF_PATH" && chmod +x "$SELF_PATH"
  fi

  systemctl restart "$SB_SVC" >/dev/null 2>&1
  sleep 1
  if systemctl is-active --quiet "$SB_SVC"; then
    ok "安装完成,服务已启动。"
  else
    warn "服务未运行(当前还没有任何节点,属于正常情况)。"
  fi
  echo
  ok "以后可以直接输入 ${BLD}sbvm${RST} 打开这个菜单。"
  echo
  read -r -p "现在创建第一个节点吗? [Y/n]: " a
  [[ ! "$a" =~ ^[Nn]$ ]] && act_add
}

act_add() {
  require_installed || return 1
  load_nodes

  local port uuid path name def_port
  def_port="$(rand_port)"

  echo
  read -r -p "端口 (回车随机 ${def_port}): " port
  port="${port:-$def_port}"
  if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    err "端口非法。"; return 1
  fi
  if port_in_use "$port"; then
    err "端口 ${port} 已被占用。"; return 1
  fi

  read -r -p "UUID (回车自动生成): " uuid
  uuid="${uuid:-$(gen_uuid)}"
  if ! [[ "$uuid" =~ ^[0-9a-fA-F-]{36}$ ]]; then
    err "UUID 格式不对(应为 36 位标准格式)。"; return 1
  fi

  read -r -p "WebSocket 路径 (回车随机, 必须以 / 开头): " path
  path="${path:-$(gen_path)}"
  [[ "${path:0:1}" != "/" ]] && path="/${path}"

  read -r -p "节点备注 (回车默认 node-${port}): " name
  name="${name:-node-${port}}"

  local tmp; tmp="$(mktemp)"
  jq --argjson port "$port" --arg uuid "$uuid" --arg path "$path" \
     --arg name "$name" --arg listen "$LISTEN_ADDR" '
     .inbounds += [{
       "type": "vmess",
       "tag": ("vm-" + ($port|tostring)),
       "listen": $listen,
       "listen_port": $port,
       "users": [ { "name": $name, "uuid": $uuid, "alterId": 0 } ],
       "transport": { "type": "ws", "path": $path }
     }]' "$SB_CONF" > "$tmp" || { err "生成配置失败。"; rm -f "$tmp"; return 1; }

  apply_config "$tmp" || return 1
  fw_open "$port"
  ok "节点已创建并生效。"

  load_nodes
  local i
  for i in "${!N_PORT[@]}"; do
    [[ "${N_PORT[$i]}" == "$port" ]] && { print_node_detail "$i"; break; }
  done
}

pick_node() {            # 选一个节点,结果放进 PICK
  load_nodes
  PICK=""
  if (( NODE_COUNT == 0 )); then
    warn "当前没有任何节点。"
    return 1
  fi
  echo
  printf "  %-4s %-8s %-38s %-16s %s\n" "序号" "端口" "UUID" "路径" "备注"
  local i
  for i in "${!N_PORT[@]}"; do
    printf "  %-4s %-8s %-38s %-16s %s\n" \
      "$((i+1))" "${N_PORT[$i]}" "${N_UUID[$i]}" "${N_PATH[$i]}" "${N_NAME[$i]}"
  done
  echo
  local n
  read -r -p "输入序号 (0 取消): " n
  [[ "$n" == "0" || -z "$n" ]] && return 1
  if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n < 1 || n > NODE_COUNT )); then
    err "序号无效。"; return 1
  fi
  PICK=$((n-1))
  return 0
}

act_list() {
  require_installed || return 1
  load_nodes
  if (( NODE_COUNT == 0 )); then warn "当前没有任何节点。"; return 0; fi
  echo
  echo -e "${BLD}共 ${NODE_COUNT} 个节点:${RST}"
  printf "  %-4s %-8s %-38s %-16s %s\n" "序号" "端口" "UUID" "路径" "备注"
  local i
  for i in "${!N_PORT[@]}"; do
    printf "  %-4s %-8s %-38s %-16s %s\n" \
      "$((i+1))" "${N_PORT[$i]}" "${N_UUID[$i]}" "${N_PATH[$i]}" "${N_NAME[$i]}"
  done
  echo
  local n
  read -r -p "查看某个节点的完整信息请输入序号 (0=全部导出链接, 回车跳过): " n
  if [[ "$n" == "0" ]]; then
    local ip; ip="$(get_public_ip)"
    echo; hr
    for i in "${!N_PORT[@]}"; do
      vmess_link "$ip" "${N_PORT[$i]}" "${N_UUID[$i]}" "${N_PATH[$i]}" "${N_NAME[$i]}"
      echo
    done
    hr
  elif [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= NODE_COUNT )); then
    print_node_detail "$((n-1))"
  fi
}

act_del() {
  require_installed || return 1
  pick_node || return 1
  local port="${N_PORT[$PICK]}" tag="${N_TAG[$PICK]}"
  read -r -p "确认删除端口 ${port} 的节点? [y/N]: " a
  [[ ! "$a" =~ ^[Yy]$ ]] && return 0

  local tmp; tmp="$(mktemp)"
  jq --arg tag "$tag" 'del(.inbounds[] | select(.tag == $tag))' "$SB_CONF" > "$tmp" \
    || { err "生成配置失败。"; rm -f "$tmp"; return 1; }
  apply_config "$tmp" || return 1
  fw_close "$port"
  ok "节点已删除,防火墙端口已回收。"
}

act_edit() {
  require_installed || return 1
  pick_node || return 1
  local i="$PICK"
  local old_port="${N_PORT[$i]}" old_tag="${N_TAG[$i]}"
  local port uuid path name

  echo
  msg "直接回车表示不修改该项。"
  read -r -p "端口 [${old_port}]: " port;  port="${port:-$old_port}"
  read -r -p "UUID [${N_UUID[$i]}]: " uuid; uuid="${uuid:-${N_UUID[$i]}}"
  read -r -p "路径 [${N_PATH[$i]}]: " path; path="${path:-${N_PATH[$i]}}"
  read -r -p "备注 [${N_NAME[$i]}]: " name; name="${name:-${N_NAME[$i]}}"

  if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then err "端口非法。"; return 1; fi
  if [[ "$port" != "$old_port" ]] && port_in_use "$port" "$old_port"; then
    err "端口 ${port} 已被占用。"; return 1
  fi
  if ! [[ "$uuid" =~ ^[0-9a-fA-F-]{36}$ ]]; then err "UUID 格式不对。"; return 1; fi
  [[ "${path:0:1}" != "/" ]] && path="/${path}"

  local tmp; tmp="$(mktemp)"
  jq --arg tag "$old_tag" --argjson port "$port" --arg uuid "$uuid" \
     --arg path "$path" --arg name "$name" '
     .inbounds |= map(
       if .tag == $tag then
           .listen_port = $port
         | .tag = ("vm-" + ($port|tostring))
         | .users[0].uuid = $uuid
         | .users[0].name = $name
         | .transport.path = $path
       else . end)' "$SB_CONF" > "$tmp" \
    || { err "生成配置失败。"; rm -f "$tmp"; return 1; }

  apply_config "$tmp" || return 1
  if [[ "$port" != "$old_port" ]]; then
    fw_close "$old_port"; fw_open "$port"
  fi
  ok "修改已生效。"

  load_nodes
  local k
  for k in "${!N_PORT[@]}"; do
    [[ "${N_PORT[$k]}" == "$port" ]] && { print_node_detail "$k"; break; }
  done
}

act_service() {          # act_service start|stop|restart
  require_installed || return 1
  case "$1" in
    start)   systemctl start   "$SB_SVC"; sleep 1 ;;
    stop)    systemctl stop    "$SB_SVC" ;;
    restart) systemctl restart "$SB_SVC"; sleep 1 ;;
  esac
  if [[ "$1" == "stop" ]]; then
    ok "已停止。"
  elif systemctl is-active --quiet "$SB_SVC"; then
    ok "运行中。"
  else
    err "启动失败,最近日志:"
    journalctl -u "$SB_SVC" -n 20 --no-pager 2>/dev/null | sed 's/^/    /'
  fi
}

act_status() {
  require_installed || return 1
  hr
  echo -e "${BLD}内核版本:${RST} $("$SB_BIN" version 2>/dev/null | head -n1)"
  echo -e "${BLD}开机自启:${RST} $(systemctl is-enabled "$SB_SVC" 2>/dev/null)"
  if systemctl is-active --quiet "$SB_SVC"; then
    echo -e "${BLD}运行状态:${RST} ${GRN}运行中${RST}"
  else
    echo -e "${BLD}运行状态:${RST} ${RED}未运行${RST}"
  fi
  hr
  systemctl status "$SB_SVC" --no-pager -l 2>/dev/null | head -n 15
  hr
  echo -e "${BLD}监听端口:${RST}"
  ss -lntp 2>/dev/null | grep -i 'sing-box' | sed 's/^/    /' || echo "    (无)"
}

act_log() {
  require_installed || return 1
  msg "按 Ctrl+C 退出日志并返回菜单。"
  sleep 1
  # 设一个非空 trap: 子进程恢复默认行为(被 Ctrl+C 结束),
  # 父进程(本脚本)执行 trap 后继续跑,不会一起退出
  trap 'echo' INT
  journalctl -u "$SB_SVC" -f --no-pager
  trap - INT
  echo
}

act_update() {
  require_installed || return 1
  detect_arch
  local cur new
  cur="$("$SB_BIN" version 2>/dev/null | head -n1 | awk '{print $3}')"
  msg "当前版本: ${cur:-未知}"
  msg "正在查询最新版本..."
  new="$(latest_version)"
  msg "最新版本: ${new}"
  if [[ "$cur" == "$new" ]]; then
    ok "已经是最新版。"
    read -r -p "仍要强制重装? [y/N]: " a
    [[ ! "$a" =~ ^[Yy]$ ]] && return 0
  fi
  read -r -p "指定其他版本号(回车=用 ${new}): " v
  v="${v:-$new}"; v="${v#v}"

  download_core "$v" || return 1
  save_meta

  # 新内核先校验现有配置,不通过就把旧内核换回来
  if ! "$SB_BIN" check -c "$SB_CONF" >/tmp/sbvm_check.log 2>&1; then
    err "新版本内核无法解析当前配置,正在回退到旧内核:"
    sed 's/^/    /' /tmp/sbvm_check.log
    [[ -f "${SB_BIN}.bak" ]] && install -m 755 "${SB_BIN}.bak" "$SB_BIN" && ok "已回退。"
    return 1
  fi
  systemctl restart "$SB_SVC"; sleep 2
  if systemctl is-active --quiet "$SB_SVC"; then
    ok "更新完成并已重启。"
  else
    err "新内核启动失败,正在回退..."
    [[ -f "${SB_BIN}.bak" ]] && install -m 755 "${SB_BIN}.bak" "$SB_BIN"
    systemctl restart "$SB_SVC"; sleep 1
    systemctl is-active --quiet "$SB_SVC" && ok "已回退到旧内核。" || err "回退后仍异常,请用 [14] 诊断。"
  fi
}

act_backup() {
  require_installed || return 1
  echo
  echo "  1) 立即备份当前配置"
  echo "  2) 从备份恢复"
  echo "  0) 返回"
  local c; read -r -p "选择: " c
  case "$c" in
    1)
      mkdir -p "$SB_BACKUP"
      local f="${SB_BACKUP}/config.json.manual-$(date +%Y%m%d-%H%M%S)"
      cp -f "$SB_CONF" "$f" && ok "已备份到: $f" ;;
    2)
      local files=() i=1
      while IFS= read -r line; do files+=("$line"); done \
        < <(ls -1t "${SB_BACKUP}"/config.json.* 2>/dev/null | head -n 30)
      if (( ${#files[@]} == 0 )); then warn "没有可用备份。"; return 0; fi
      echo
      for f in "${files[@]}"; do
        printf "  %-3s %s  (%s)\n" "$i" "$(basename "$f")" \
          "$(date -r "$f" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
        ((i++))
      done
      echo
      local n; read -r -p "选择要恢复的编号 (0 取消): " n
      [[ "$n" == "0" || -z "$n" ]] && return 0
      if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n < 1 || n > ${#files[@]} )); then err "编号无效。"; return 1; fi
      local tmp; tmp="$(mktemp)"
      cp -f "${files[$((n-1))]}" "$tmp"
      apply_config "$tmp" && ok "已恢复。" ;;
  esac
}

act_tune() {
  echo
  msg "将写入 /etc/sysctl.d/99-sbvm.conf (原文件不动,可随时删除该文件还原)"
  local kv
  kv="$(uname -r | awk -F. '{printf "%d%03d", $1, $2}')"
  if (( kv < 4009 )); then
    warn "当前内核 $(uname -r) 低于 4.9,不支持 BBR,只做基础调优。"
  fi
  cat > /etc/sysctl.d/99-sbvm.conf <<'EOF'
# --- sbvm 网络调优 ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 8192
net.ipv4.tcp_fin_timeout = 15
net.ipv4.ip_local_port_range = 10000 65000
fs.file-max = 1048576
EOF
  if (( kv < 4009 )); then
    sed -i '/bbr/d;/default_qdisc/d' /etc/sysctl.d/99-sbvm.conf
  fi
  sysctl --system >/dev/null 2>&1
  echo
  echo -e "${BLD}当前拥塞控制算法:${RST} $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  echo -e "${BLD}当前队列调度:${RST} $(sysctl -n net.core.default_qdisc 2>/dev/null)"
  ok "调优完成(部分参数需重启后完全生效)。"
}

act_diagnose() {
  require_installed || return 1
  load_nodes
  echo
  hr
  echo -e "${BLD}【1】内核与服务${RST}"
  echo "    版本: $("$SB_BIN" version 2>/dev/null | head -n1)"
  if systemctl is-active --quiet "$SB_SVC"; then
    ok   "systemd 服务运行中"
  else
    err  "systemd 服务未运行"
    journalctl -u "$SB_SVC" -n 15 --no-pager 2>/dev/null | sed 's/^/      /'
  fi

  echo
  echo -e "${BLD}【2】配置文件校验${RST}"
  if "$SB_BIN" check -c "$SB_CONF" >/tmp/sbvm_check.log 2>&1; then
    ok "config.json 语法与语义均正常"
  else
    err "config.json 校验失败:"; sed 's/^/      /' /tmp/sbvm_check.log
  fi

  echo
  echo -e "${BLD}【3】节点与监听${RST}"
  if (( NODE_COUNT == 0 )); then
    warn "没有任何节点"
  else
    local i p
    for i in "${!N_PORT[@]}"; do
      p="${N_PORT[$i]}"
      if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"; then
        ok "端口 ${p} 正在监听  (${N_NAME[$i]})"
      else
        err "端口 ${p} 未监听    (${N_NAME[$i]})"
      fi
    done
  fi

  echo
  echo -e "${BLD}【4】本地 WebSocket 握手测试${RST}"
  if (( NODE_COUNT > 0 )); then
    local i code key
    for i in "${!N_PORT[@]}"; do
      key="$(head -c 16 /dev/urandom | base64)"
      code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
              -H "Connection: Upgrade" -H "Upgrade: websocket" \
              -H "Sec-WebSocket-Key: ${key}" -H "Sec-WebSocket-Version: 13" \
              "http://127.0.0.1:${N_PORT[$i]}${N_PATH[$i]}" 2>/dev/null)"
      if [[ "$code" == "101" ]]; then
        ok "端口 ${N_PORT[$i]} 路径 ${N_PATH[$i]} → 101 升级成功"
      else
        err "端口 ${N_PORT[$i]} 路径 ${N_PATH[$i]} → 返回 ${code:-无响应} (路径写错或服务异常)"
      fi
    done
  fi

  echo
  echo -e "${BLD}【5】防火墙${RST}"
  echo "    检测到的后端: $(fw_backend)"
  case "$(fw_backend)" in
    ufw)       ufw status 2>/dev/null | head -n 20 | sed 's/^/      /' ;;
    firewalld) firewall-cmd --list-ports 2>/dev/null | sed 's/^/      开放端口: /' ;;
    iptables)  iptables -L INPUT -n --line-numbers 2>/dev/null | head -n 20 | sed 's/^/      /' ;;
    none)      echo "      未检测到本机防火墙" ;;
  esac

  echo
  echo -e "${BLD}【6】网络环境${RST}"
  echo "    公网 IP: $(get_public_ip)"
  echo "    监听地址设置: ${LISTEN_ADDR}"
  echo "    IPv6 支持: $([[ -e /proc/net/if_inet6 ]] && echo 是 || echo 否)"
  hr
  echo
  warn "如果上面 1~5 全绿但客户端还是连不上,几乎可以肯定是"
  warn "服务商控制台的安全组 / 网络ACL 没放行端口(阿里云、腾讯云、"
  warn "AWS、GCP、Oracle 都有,这一层脚本改不了,必须去网页后台开)。"
}

act_settings() {
  echo
  echo -e "${BLD}当前设置${RST}"
  echo "    监听地址 LISTEN_ADDR = ${LISTEN_ADDR}"
  echo "    对外显示IP OVERRIDE_IP = ${OVERRIDE_IP:-(自动探测)}"
  echo
  echo "  1) 修改监听地址 (:: = 双栈 / 0.0.0.0 = 仅IPv4)"
  echo "  2) 手动指定对外显示的 IP (NAT 机 / 有中转时用)"
  echo "  3) 清除对外 IP 覆盖,恢复自动探测"
  echo "  0) 返回"
  local c v; read -r -p "选择: " c
  case "$c" in
    1) read -r -p "输入 :: 或 0.0.0.0 : " v
       [[ "$v" == "::" || "$v" == "0.0.0.0" ]] && { LISTEN_ADDR="$v"; save_meta; ok "已保存,新建的节点会使用该地址。"; } \
         || err "输入无效。" ;;
    2) read -r -p "输入对外 IP: " v; OVERRIDE_IP="$v"; save_meta; ok "已保存。" ;;
    3) OVERRIDE_IP=""; save_meta; ok "已恢复自动探测。" ;;
  esac
}

act_uninstall() {
  echo
  warn "这将删除 sing-box 内核、systemd 服务、全部节点配置和本脚本。"
  read -r -p "确认卸载请输入大写 YES : " a
  [[ "$a" != "YES" ]] && { msg "已取消。"; return 0; }

  # 先把端口从防火墙收回
  if [[ -f "$SB_CONF" ]]; then
    local ports p
    ports="$(jq -r '.inbounds[]? | .listen_port // empty' "$SB_CONF" 2>/dev/null)"
    for p in $ports; do fw_close "$p"; done
    ok "防火墙端口已回收"
  fi

  systemctl stop    "$SB_SVC" >/dev/null 2>&1
  systemctl disable "$SB_SVC" >/dev/null 2>&1
  rm -f "$SB_UNIT"
  systemctl daemon-reload >/dev/null 2>&1
  systemctl reset-failed  >/dev/null 2>&1
  ok "systemd 服务已移除"

  local keep=""
  read -r -p "保留配置备份到 /root/sbvm-backup ? [y/N]: " keep
  if [[ "$keep" =~ ^[Yy]$ ]] && [[ -d "$SB_DIR" ]]; then
    mkdir -p /root/sbvm-backup
    cp -a "$SB_DIR"/. /root/sbvm-backup/ 2>/dev/null
    ok "备份已保存到 /root/sbvm-backup"
  fi

  rm -f  "$SB_BIN" "${SB_BIN}.bak"
  rm -rf "$SB_DIR" "$SB_DATA"
  rm -f  /etc/sysctl.d/99-sbvm.conf
  ok "内核与配置已删除"

  echo
  ok "卸载完成。"
  local me; me="$(readlink -f "$0" 2>/dev/null)"
  rm -f "$SELF_PATH"
  [[ -n "$me" && "$me" != "$SELF_PATH" ]] && rm -f "$me"
  exit 0
}

#================================== 主菜单 ===================================
show_menu() {
  clear 2>/dev/null
  local st ver cnt
  if installed; then
    ver="$("$SB_BIN" version 2>/dev/null | head -n1 | awk '{print $3}')"
    systemctl is-active --quiet "$SB_SVC" && st="${GRN}运行中${RST}" || st="${RED}未运行${RST}"
    load_nodes; cnt="$NODE_COUNT"
  else
    ver="未安装"; st="${YEL}未安装${RST}"; cnt=0
  fi
  echo
  echo -e "${BLD}${BLU}===============================================${RST}"
  echo -e "${BLD}   sing-box  VMess + WebSocket  管理面板${RST}"
  echo -e "${BLD}   无域名 / 纯 IP 模式${RST}"
  echo -e "${BLD}${BLU}===============================================${RST}"
  echo -e "   内核版本: ${ver}     状态: ${st}     节点数: ${cnt}"
  hr
  echo -e "   ${BLD}1${RST}) 安装 / 重装 sing-box"
  hr
  echo -e "   ${BLD}2${RST}) 新增节点            ${BLU}(增)${RST}"
  echo -e "   ${BLD}3${RST}) 删除节点            ${BLU}(删)${RST}"
  echo -e "   ${BLD}4${RST}) 修改节点            ${BLU}(改)${RST}"
  echo -e "   ${BLD}5${RST}) 查看节点 / 导出链接与二维码  ${BLU}(查)${RST}"
  hr
  echo -e "   ${BLD}6${RST}) 启动     ${BLD}7${RST}) 停止     ${BLD}8${RST}) 重启"
  echo -e "   ${BLD}9${RST}) 运行状态与监听端口"
  echo -e "  ${BLD}10${RST}) 实时日志"
  hr
  echo -e "  ${BLD}11${RST}) 更新 / 切换内核版本"
  echo -e "  ${BLD}12${RST}) 备份 / 恢复配置"
  echo -e "  ${BLD}13${RST}) 网络调优 (BBR + 内核参数)"
  echo -e "  ${BLD}14${RST}) ${GRN}一键诊断自检${RST}  ← 连不上时先跑这个"
  echo -e "  ${BLD}15${RST}) 脚本设置 (监听地址 / 对外IP)"
  hr
  echo -e "  ${BLD}${RED}16${RST}) 彻底卸载"
  echo -e "   ${BLD}0${RST}) 退出"
  hr
}

main() {
  need_root
  detect_os
  ensure_deps
  detect_arch
  load_meta

  while true; do
    show_menu
    read -r -p "请输入选项 [0-16]: " choice
    echo
    case "$choice" in
      1)  act_install ;;
      2)  act_add ;;
      3)  act_del ;;
      4)  act_edit ;;
      5)  act_list ;;
      6)  act_service start ;;
      7)  act_service stop ;;
      8)  act_service restart ;;
      9)  act_status ;;
      10) act_log ;;
      11) act_update ;;
      12) act_backup ;;
      13) act_tune ;;
      14) act_diagnose ;;
      15) act_settings ;;
      16) act_uninstall ;;
      0)  echo "再见。"; exit 0 ;;
      *)  err "无效选项。" ;;
    esac
    pause
  done
}

main "$@"
