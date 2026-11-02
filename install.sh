#!/usr/bin/env bash
# sing-box 1.14.4 on the DGX Spark, self-contained under ~/.local/opt/singbox.
#
#   TUN mode: every egress except LAN/private goes to the Mac's Clash Verge mixed
#   port. TUN DNS (172.19.0.2) resolves through the tunnel (DoH).
#
# Layout:
#   ~/.local/opt/singbox/sing-box      binary
#   ~/.local/opt/singbox/config.json   config (owned by the user, editable)
#   ~/.local/opt/singbox/state/        cache
#   /etc/systemd/system/sing-box.service
#
# Usage (root):
#   sudo bash ~/.local/opt/singbox/install.sh              # install / re-install
#   sudo bash ~/.local/opt/singbox/install.sh --dns-only   # only fix system DNS
#   sudo bash ~/.local/opt/singbox/install.sh --reset-config
set -euo pipefail

MODE="install"
for arg in "$@"; do
  case "${arg}" in
    --dns-only) MODE="dns" ;;
    --reset-config) RESET_CONFIG=1 ;;
    *) echo "unknown argument: ${arg}" >&2; exit 2 ;;
  esac
done

UPSTREAM_HOST=192.168.3.14    # Mac LAN address
UPSTREAM_PORT=7897            # Clash Verge mixed port
VERSION=1.14.4
TUN_DNS=172.19.0.2

[[ ${EUID} -eq 0 ]] || { echo "must run as root: sudo bash $0 [--dns-only|--reset-config]" >&2; exit 1; }

RUN_USER="${SUDO_USER:-zysq}"
USER_HOME="$(getent passwd "${RUN_USER}" | cut -d: -f6)"
OPT="${USER_HOME}/.local/opt/singbox"
BIN="${OPT}/sing-box"
CONF="${OPT}/config.json"
STATE="${OPT}/state"
UNIT=/etc/systemd/system/sing-box.service
RESOLVED_CONF=/etc/systemd/resolved.conf.d/10-sing-box-dns.conf
STAGE="${USER_HOME}/sing-box"          # legacy staging dir with the downloaded tarball

dns_answer() {  # $1 = resolver, prints sorted A records of www.google.com
  python3 - "$1" <<'PY'
import socket, struct, sys
def ask(host, dns, timeout=6):
    pkt = b"\xab\xcd\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"
    for part in host.split("."):
        pkt += bytes([len(part)]) + part.encode()
    pkt += b"\x00\x00\x01\x00\x01"
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    s.sendto(pkt, (dns, 53))
    d, _ = s.recvfrom(2048)
    i = 12
    while d[i]:
        i += d[i] + 1
    i += 5
    out = []
    for _ in range(struct.unpack("!H", d[6:8])[0]):
        i += 2 if d[i] & 0xC0 == 0xC0 else 1 + d[i]
        t, _, _, rdl = struct.unpack("!HHIH", d[i:i + 10])
        i += 10
        if t == 1:
            out.append(".".join(map(str, d[i:i + 4])))
        i += rdl
    return sorted(out)
print(",".join(ask("www.google.com", sys.argv[1])))
PY
}

wait_listener() {  # $1 = port, $2 = max seconds
  local i
  for ((i = 0; i < ${2}; i++)); do
    ss -ltn 2>/dev/null | grep -q ":${1} " && return 0
    sleep 1
  done
  return 1
}

curl_retry() {  # $1 = retries, rest = curl args
  local n="$1"; shift
  local out="" i
  for ((i = 1; i <= n; i++)); do
    out="$(timeout 40 curl -s -m 30 "$@" || true)"
    [[ -n "${out}" && "${out}" != "000" ]] && { echo "${out}"; return 0; }
    sleep 2
  done
  echo "${out:-000}"
  return 1
}

write_config() {
  cat >"${CONF}.new" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "dns": {
    "servers": [
      { "type": "udp", "tag": "dns-local", "server": "223.5.5.5" },
      { "type": "https", "tag": "dns-proxy", "server": "1.1.1.1", "detour": "proxy" }
    ],
    "rules": [ { "ip_is_private": true, "server": "dns-local" } ],
    "final": "dns-proxy",
    "strategy": "prefer_ipv4"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "singbox0",
      "address": [ "172.19.0.1/30", "fdfe:dcba:9876::1/126" ],
      "auto_route": true,
      "auto_redirect": true,
      "strict_route": false,
      "route_exclude_address": [
        "0.0.0.0/8", "10.0.0.0/8", "127.0.0.0/8", "169.254.0.0/16",
        "172.16.0.0/12", "192.168.0.0/16", "224.0.0.0/4",
        "::1/128", "fc00::/7", "fe80::/10"
      ]
    },
    { "type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 7897 }
  ],
  "outbounds": [
    {
      "type": "socks",
      "tag": "proxy",
      "server": "${UPSTREAM_HOST}",
      "server_port": ${UPSTREAM_PORT},
      "version": "5"
    },
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "auto_detect_interface": true,
    "default_domain_resolver": { "server": "dns-local" },
    "rules": [
      { "action": "sniff" },
      { "ip_is_private": true, "outbound": "direct" }
    ],
    "final": "proxy"
  },
  "experimental": {
    "cache_file": { "enabled": true },
    "clash_api": { "external_controller": "127.0.0.1:9097" }
  }
}
EOF
  chown "${RUN_USER}:${RUN_USER}" "${CONF}.new"
  chmod 0644 "${CONF}.new"
  mv -f "${CONF}.new" "${CONF}"
}

apply_dns() {
  echo "==> pointing systemd-resolved at the tunnel DNS (${TUN_DNS})"
  mkdir -p /etc/systemd/resolved.conf.d
  cat >"${RESOLVED_CONF}" <<EOF
[Resolve]
DNS=${TUN_DNS}
FallbackDNS=223.5.5.5
Domains=~.
EOF
  systemctl restart systemd-resolved
  sleep 3
  local sys_ans tun_ans shared
  sys_ans="$(dns_answer 127.0.0.53 || true)"
  tun_ans="$(dns_answer "${TUN_DNS}" || true)"
  echo "    system resolver: ${sys_ans:-<none>}"
  echo "    tunnel resolver: ${tun_ans:-<none>}"
  shared="$(python3 -c "import sys;a=set(filter(None,sys.argv[1].split(',')));b=set(filter(None,sys.argv[2].split(',')));print(len(a&b))" "${sys_ans}" "${tun_ans}" 2>/dev/null || echo 0)"
  if [[ -z "${tun_ans}" || "${shared}" == "0" ]]; then
    echo "!! system DNS does not follow the tunnel, removing override" >&2
    rm -f "${RESOLVED_CONF}"
    systemctl restart systemd-resolved
    return 1
  fi
}

remove_dns() {
  rm -f "${RESOLVED_CONF}"
  systemctl restart systemd-resolved || true
}

if [[ "${MODE}" == "dns" ]]; then
  apply_dns
  echo "DONE (dns only)"
  exit 0
fi

echo "==> preparing ${OPT}"
install -d -o "${RUN_USER}" -g "${RUN_USER}" -m 0755 "${OPT}"
install -d -o root -g root -m 0755 "${STATE}"

echo "==> installing binary ${VERSION}"
staged_bin="${STAGE}/dl/sing-box-${VERSION}-linux-arm64/sing-box"
if [[ -x "${staged_bin}" ]]; then
  install -m 0755 "${staged_bin}" "${BIN}"
else
  tmp="$(mktemp -d)"
  curl -fsSL -o "${tmp}/sb.tar.gz" \
    "https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-arm64.tar.gz"
  tar xzf "${tmp}/sb.tar.gz" -C "${tmp}"
  install -m 0755 "${tmp}/sing-box-${VERSION}-linux-arm64/sing-box" "${BIN}"
  rm -rf "${tmp}"
fi

if [[ ! -f "${CONF}" || "${RESET_CONFIG:-0}" == "1" ]]; then
  echo "==> writing ${CONF}"
  write_config
else
  echo "==> keeping existing ${CONF}"
fi
chown "${RUN_USER}:${RUN_USER}" "${CONF}"
chmod 0644 "${CONF}"

echo "==> writing ${UNIT}"
[[ -f "${UNIT}" ]] && cp -a "${UNIT}" "${UNIT}.bak"
cat >"${UNIT}" <<EOF
[Unit]
Description=sing-box service (TUN -> Mac mixed ${UPSTREAM_HOST}:${UPSTREAM_PORT})
Documentation=https://sing-box.sagernet.org
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=${BIN} check -c ${CONF}
ExecStart=${BIN} -D ${STATE} -c ${CONF} run
Restart=on-failure
RestartSec=3s
LimitNOFILE=infinity
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_DAC_READ_SEARCH
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

restore_previous() {
  echo "!! restoring previous unit" >&2
  if [[ -f "${UNIT}.bak" ]]; then
    mv -f "${UNIT}.bak" "${UNIT}"
    systemctl daemon-reload
    systemctl restart sing-box || systemctl disable --now sing-box || true
  else
    systemctl disable --now sing-box >/dev/null 2>&1 || true
  fi
  remove_dns
}

echo "==> validating config"
"${BIN}" check -c "${CONF}"

echo "==> validating config under the service capability set"
systemd-run --quiet --pipe --wait \
  -p CapabilityBoundingSet="CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_DAC_READ_SEARCH" \
  -p NoNewPrivileges=true \
  "${BIN}" check -c "${CONF}" \
  || { echo "!! config unreadable under service restrictions" >&2; exit 1; }

systemctl stop sing-box >/dev/null 2>&1 || true

for c in $(docker ps -aq --filter "name=sing-box" --filter "name=sb-" 2>/dev/null || true); do
  echo "==> removing conflicting container ${c}"
  docker rm -f "${c}" >/dev/null 2>&1 || true
done

systemctl daemon-reload
systemctl enable sing-box >/dev/null
echo "==> starting sing-box"
systemctl restart sing-box || true
sleep 5
if ! systemctl is-active --quiet sing-box; then
  sleep 5
  systemctl is-active --quiet sing-box || { journalctl -u sing-box -n 30 --no-pager >&2; restore_previous; exit 1; }
fi

echo "==> diagnostics: nft tables / ip rules"
nft list tables 2>/dev/null | head -5 || true
ip rule show | head -8 || true

echo "==> waiting for tun + listener"
ip -brief addr show singbox0 >/dev/null 2>&1 || {
  echo "!! tun missing" >&2; journalctl -u sing-box -n 30 --no-pager >&2; restore_previous; exit 1; }
wait_listener 7897 20 || echo "    WARNING: nothing listening on 7897 yet"
ss -ltn | grep 7897 || true

echo "==> verifying egress through tun (plain curl, no proxy env)"
egress="$(curl_retry 3 https://api.ipify.org)" || {
  echo "!! no egress through sing-box (got '${egress}')" >&2
  journalctl -u sing-box -n 40 --no-pager >&2
  restore_previous
  exit 1
}
echo "    egress ip: ${egress}"

echo "==> verifying mixed inbound 127.0.0.1:7897 (informational)"
code="$(curl_retry 3 -x http://127.0.0.1:7897 -o /dev/null -w '%{http_code}' https://www.google.com)"
if [[ "${code}" == "200" ]]; then
  echo "    google via 7897: ${code}"
else
  echo "    WARNING: mixed inbound returned '${code}' (tun egress is fine)"
fi

apply_dns || echo "    (DNS override skipped, TLS still works via SNI sniffing)"

echo "==> verifying LAN stays direct"
gw="$(ip route show default | awk '{print $3; exit}')"
ping -c1 -W2 "${gw}" >/dev/null && echo "    gateway ${gw} reachable" || echo "    WARNING: gateway ${gw} unreachable"

echo "==> removing legacy install paths"
rm -f /usr/local/bin/sing-box
rm -rf /etc/sing-box /var/lib/sing-box
rm -f "${UNIT}.bak"

systemctl --no-pager status sing-box | head -6
echo "DONE -- binary ${BIN}, config ${CONF}"
