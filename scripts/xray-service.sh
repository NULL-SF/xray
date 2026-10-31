#!/usr/bin/env bash
# 核心入口。读取 config/active.txt 与对应链接，生成临时配置后执行 Xray 核心。
# vless、vmess、hysteria2 都执行 bin/xray_26.1.23，使用统一 SOCKS / HTTP 入口。
# 端口由 config/port.txt 配置，缺失或非法时回退到 10808。
# 链接为空或无法识别时仍然监听。外部连接不会成功，进程不退出，不改线路。
# 标准错误进入调用方的日志。运行配置在项目目录 runtime，不要手改。
set -euo pipefail

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$SCRIPT_DIR" != "${BASH_SOURCE[0]}" ]] || SCRIPT_DIR=.
ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
source "${ROOT}/scripts/terminal-env.sh"
_xray_remove_preload "$ROOT"
unset -f _xray_remove_preload
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy NO_PROXY no_proxy
ACTIVE="${ROOT}/config/active.txt"
XRAY_BIN="${ROOT}/bin/xray_26.1.23"
XRAY_CONFIG="${ROOT}/runtime/xray_config.json"

die() {
  printf '%s [xray] %s\n' "$(date '+%Y/%m/%d %H:%M:%S')" "$*" >&2
  exit 1
}

[[ -x "$XRAY_BIN" ]] || die "缺少可执行文件 ${XRAY_BIN}"
umask 077
mkdir -p "${ROOT}/runtime" "${ROOT}/config/links"
# 锁随核心进程存活，避免开机任务和手动启动同时生成配置、重复启动。
exec 9>"${ROOT}/runtime/service.lock"
flock -n 9 || exit 0
for _xray_name in vless vmess hysteria2; do
  _xray_link="${ROOT}/config/links/${_xray_name}.txt"
  if [[ ! -e "$_xray_link" ]]; then
    : > "$_xray_link"
    chmod 600 "$_xray_link"
  fi
done
unset _xray_name _xray_link

# 保存默认端口回退值；当前线路为空时写默认值。节点链接只在缺失时创建空文件。
_xray_ensure_ports "$ROOT" || exit 1
PORT="$PROXY_PORT"
export XRAY_PORT="$PROXY_PORT"
raw=""
if [[ -r "$ACTIVE" ]]; then
  raw="$(tr -d '[:space:]' < "$ACTIVE")"
fi
case "$raw" in
  "")
    printf '%s\n' "hysteria2" > "$ACTIVE"
    printf '%s [xray] 当前线路缺失或为空，已写入 hysteria2。\n' "$(date '+%Y/%m/%d %H:%M:%S')" >&2
    ;;
  reality)
    printf '%s\n' "vless" > "$ACTIVE"
    ;;
  hy2|hysteria)
    printf '%s\n' "hysteria2" > "$ACTIVE"
    ;;
  vless|vmess|hysteria2) ;;
  *) die "无法识别的线路: ${raw}。应为 vless、vmess 或 hysteria2。" ;;
esac

if ss -lnt 2>/dev/null | grep "127\\.0\\.0\\.1:${PORT}[[:space:]]" >/dev/null; then
  die "127.0.0.1:${PORT} 已被其他进程占用"
fi
echo $$ > "${ROOT}/runtime/xray.pid"
trap 'rm -f "${ROOT}/runtime/xray.pid"' EXIT

# 开机后默认路由可能尚未出现。最多等 30 秒，避免核心在没有出口时启动失败。
for _ in $(seq 1 30); do
  if ip route show default 2>/dev/null | grep . >/dev/null; then
    break
  fi
  sleep 1
done

profile="$(tr -d '[:space:]' < "$ACTIVE")"
link_file="${ROOT}/config/links/${profile}.txt"
link=""
if [[ -r "$link_file" ]]; then
  link="$(cat -- "$link_file")"
fi
export XRAY_ROOT="$ROOT"
export XRAY_PROFILE="$profile"
export XRAY_LINK="$link"

# 链接为空或无法生成配置时，仍打开本地端口。出去的连接直接丢弃。
listen_anyway() {
  python3 - "$XRAY_CONFIG" <<'PY'
import json, os, sys
from pathlib import Path
cfg = {
    "log": {"loglevel": "warning"},
    "inbounds": [{
        "port": int(os.environ["XRAY_PORT"]),
        "listen": "127.0.0.1",
        "protocol": "socks",
        "settings": {"udp": True},
    }],
    "outbounds": [{"protocol": "blackhole", "settings": {"response": {"type": "none"}}}],
}
target = Path(sys.argv[1])
temporary = target.with_name(target.name + f".{os.getpid()}.tmp")
temporary.write_text(json.dumps(cfg, indent=2) + "\n")
temporary.replace(target)
PY
  chmod 600 "$XRAY_CONFIG"
  printf '%s [xray] 链接无法使用，将启动混合代理入口并拒绝转发外部连接。\n' "$(date '+%Y/%m/%d %H:%M:%S')" >&2
  printf '%s [xray] 启动 Xray，线路 %s，SOCKS / HTTP 混合代理入口 127.0.0.1:%s。\n' "$(date '+%Y/%m/%d %H:%M:%S')" "$profile" "$PROXY_PORT" >&2
  exec "$XRAY_BIN" run -config "$XRAY_CONFIG"
}

if [[ -z "$link" ]]; then
  listen_anyway
fi

set +e
python3 - "$XRAY_CONFIG" <<'PY'
"""Convert supported share links to Xray 26.1.23 JSON; never log credentials."""
import base64
from decimal import Decimal
import json
import os
from pathlib import Path
import re
import sys
from urllib.parse import parse_qsl, unquote, urlsplit


FINGERPRINTS = set('360 android chrome edge firefox hello360_11_0 hello360_7_5 hello360_auto helloandroid_11_okhttp hellochrome_100 hellochrome_100_psk hellochrome_102 hellochrome_106_shuffle hellochrome_112_psk_shuf hellochrome_114_padding_psk_shuf hellochrome_115_pq hellochrome_115_pq_psk hellochrome_120 hellochrome_120_pq hellochrome_131 hellochrome_58 hellochrome_62 hellochrome_70 hellochrome_72 hellochrome_83 hellochrome_87 hellochrome_96 hellochrome_auto helloedge_106 helloedge_85 helloedge_auto hellofirefox_102 hellofirefox_105 hellofirefox_120 hellofirefox_55 hellofirefox_56 hellofirefox_63 hellofirefox_65 hellofirefox_99 hellofirefox_auto hellogolang helloios_11_1 helloios_12_1 helloios_13 helloios_14 helloios_auto helloqq_11_1 helloqq_auto hellorandomized hellorandomizedalpn hellorandomizednoalpn hellosafari_16_0 hellosafari_auto ios qq random randomized randomizednoalpn safari unsafe'.split())


class LinkError(ValueError):
    pass


def boolean(value):
    if str(value).lower() in {"1", "true"}:
        return True
    if str(value).lower() in {"0", "false"}:
        return False
    raise LinkError("布尔参数必须为 true/false 或 1/0")


def integer(value, low=0, high=65535):
    if isinstance(value, bool) or not re.fullmatch(r"[0-9]+", str(value)):
        raise LinkError("整数参数格式错误")
    try:
        number = int(value)
    except (ValueError, TypeError):
        raise LinkError("数值参数格式错误") from None
    if not low <= number <= high:
        raise LinkError("数值参数超出范围")
    return number


class Params:
    def __init__(self, data):
        self.data = dict(data)
        self.used = set()

    def get(self, *names, default=""):
        found = [n for n in names if n in self.data]
        self.used.update(found)
        values = [self.data[n] for n in found]
        if any(not isinstance(v, (str, int, bool)) for v in values):
            raise LinkError("链接参数必须是字符串、整数或布尔值")
        def canonical(value):
            if value == "":
                return value
            if names[0] in {"type", "security", "fp"}:
                value = str(value).lower()
                if names[0] == "type":
                    return {"raw": "tcp", "websocket": "ws", "splithttp": "xhttp", "mkcp": "kcp"}.get(value, value)
                return value
            if names[0] == "insecure":
                return boolean(value)
            if names[0] == "pinSHA256":
                return str(value).replace(":", "").lower()
            return value
        values = [canonical(value) for value in values]
        if values and any(v != values[0] for v in values):
            raise LinkError("同一参数的不同别名存在冲突")
        return values[0] if values else default

    def finish(self):
        # Presentation-only metadata does not affect a connection.
        ignored = {"ps", "remarks", "remark", "v"}
        if set(self.data) - self.used - ignored:
            raise LinkError("链接含尚未支持或不适用于当前传输的参数；未生成不完整配置")


def json_object(value):
    try:
        result = json.loads(value, object_pairs_hook=unique_object,
                            parse_constant=lambda _: (_ for _ in ()).throw(LinkError("JSON 不支持非有限数值")))
    except (ValueError, TypeError):
        raise LinkError("扩展配置必须是无重复字段的 JSON 对象") from None
    if not isinstance(result, dict):
        raise LinkError("扩展配置必须是 JSON 对象")
    return result


def list_strings(value):
    result = [s.strip() for s in str(value).split(",")]
    if not result or any(not s for s in result):
        raise LinkError("逗号分隔的参数不能包含空项")
    return result


def duration(value, low=0, high=2147483647):
    match = re.fullmatch(r"([0-9]+)(s|m|h)?", str(value))
    if not match:
        raise LinkError("时间参数须为整数秒或带 s/m/h 单位")
    return integer(str(int(match[1]) * {None: 1, "s": 1, "m": 60, "h": 3600}[match[2]]), low, high)


def port_list(value):
    pieces = str(value).split(",")
    result = []
    for piece in pieces:
        ends = piece.strip().split("-")
        if len(ends) not in {1, 2}:
            raise LinkError("端口列表格式错误")
        start, end = integer(ends[0], 1), integer(ends[-1], 1)
        if end < start:
            raise LinkError("端口范围起点不能大于终点")
        result.append(str(start) if start == end else f"{start}-{end}")
    return ",".join(result)


def apply_fields(p, target, strings=(), numbers=(), bools=()):
    for key in strings:
        value = p.get(key)
        if value != "":
            target[key] = str(value)
    for key in numbers:
        value = p.get(key)
        if value != "":
            target[key] = integer(value, 0, 2147483647)
    for key in bools:
        value = p.get(key)
        if value != "":
            target[key] = boolean(value)


def tls_settings(p, address, host="", network="tcp"):
    result = {"serverName": p.get("sni", "serverName", "peer", default=str(host).split(",")[0] or address)}
    result.update(certificate(p))
    alpn = p.get("alpn")
    if alpn:
        result["alpn"] = list_strings(alpn)
        if network == "hysteria" and result["alpn"] != ["h3"]:
            raise LinkError("Hysteria2 的 ALPN 必须为 h3")
    elif network == "hysteria":
        result["alpn"] = ["h3"]
    fp = str(p.get("fp", "fingerprint")).lower()
    if fp:
        if network in {"kcp", "hysteria"}:
            raise LinkError("当前核心在此传输中不会应用 TLS fingerprint，不能导入该参数")
        if fp not in FINGERPRINTS:
            raise LinkError("当前解析器未确认该 TLS fingerprint，请使用常见指纹名")
        result["fingerprint"] = fp
    ech = p.get("ech", "echConfigList")
    if ech:
        if "://" not in ech:
            try:
                raw = base64.b64decode(ech + "=" * (-len(ech) % 4), altchars=b"-_", validate=True)
            except ValueError:
                raise LinkError("ECH 必须是 Base64 配置或核心支持的 DNS 查询地址") from None
            if len(raw) < 6 or int.from_bytes(raw[:2], "big") != len(raw) - 2:
                raise LinkError("ECHConfigList 长度格式错误")
            ech = base64.b64encode(raw).decode()
        elif network == "hysteria" and "echConfigList" not in p.data:
            raise LinkError("Hysteria2 标准 ech 参数须为 Base64 配置；DNS 查询扩展请使用 echConfigList")
        result["echConfigList"] = ech
        force = p.get("echForceQuery", default="full")
        if force not in {"none", "half", "full"}:
            raise LinkError("echForceQuery 必须为 none/half/full")
        result["echForceQuery"] = force
    apply_fields(p, result, strings=("minVersion", "maxVersion"),
                 bools=("enableSessionResumption", "disableSystemRoot"))
    # This version's uTLS copyConfig omits these settings. Native TLS is
    # necessary to honor them rather than merely accepting their JSON keys.
    if network not in {"kcp", "hysteria"} and any(k in result for k in ("minVersion", "maxVersion", "enableSessionResumption")):
        if fp and fp not in {"unsafe", "hellogolang"}:
            raise LinkError("此核心的自定义 TLS 版本/会话恢复不能与 uTLS 指纹同时生效；请使用 fp=unsafe")
        result["fingerprint"] = "unsafe"
    ca = p.get("ca", "caFile")
    if ca:
        path = Path(ca).expanduser()
        if not path.is_absolute():
            path = Path(os.environ.get("XRAY_ROOT", ".")) / path
        if not path.is_file():
            raise LinkError("指定的 CA 文件不存在")
        result["certificates"] = [{"certificateFile": str(path), "usage": "verify"}]
    if result.get("minVersion") and result["minVersion"] not in {"1.0", "1.1", "1.2", "1.3"}:
        raise LinkError("TLS minVersion 无效")
    if result.get("maxVersion") and result["maxVersion"] not in {"1.0", "1.1", "1.2", "1.3"}:
        raise LinkError("TLS maxVersion 无效")
    if result.get("minVersion", "1.0") > result.get("maxVersion", "1.3"):
        raise LinkError("TLS 最低版本高于最高版本")
    if network == "hysteria" and (result.get("maxVersion", "1.3") != "1.3"):
        raise LinkError("Hysteria2 需要 TLS 1.3")
    return result


def certificate(p):
    result = {}
    insecure = p.get("insecure", "allowInsecure", "allowinsecure")
    if insecure != "":
        result["allowInsecure"] = boolean(insecure)
    pin = p.get("pinSHA256", "pinnedPeerCertSha256")
    if pin:
        pin = pin.replace(":", "").lower()
        if not re.fullmatch(r"[0-9a-f]{64}", pin):
            raise LinkError("证书 SHA-256 指纹格式错误")
        result["pinnedPeerCertSha256"] = pin
        # Hysteria's pin authenticates the certificate, independently of SNI.
        # Xray additionally checks DNS for pinned CA:true certificates. Keep
        # the pin and chain validation, but do not impose the SNI as DNSName.
        result["verifyPeerCertInNames"] = [""]
    return result


XHTTP_EXTRA = set("headers xPaddingBytes noGRPCHeader noSSEHeader scMaxEachPostBytes scMinPostsIntervalMs scMaxBufferedPosts scStreamUpServerSecs xmux downloadSettings".split())
XMUX_FIELDS = set("maxConcurrency maxConnections cMaxReuseTimes hMaxRequestTimes hMaxReusableSecs hKeepAlivePeriod".split())
TLS_FIELDS = set("allowInsecure certificates serverName alpn enableSessionResumption disableSystemRoot minVersion maxVersion cipherSuites fingerprint pinnedPeerCertSha256 curvePreferences serverNameToVerify verifyPeerCertInNames echConfigList echForceQuery echSockopt".split())
SOCKOPT_FIELDS = set("mark tcpFastOpen tproxy acceptProxyProtocol domainStrategy dialerProxy tcpKeepAliveInterval tcpKeepAliveIdle tcpCongestion tcpWindowClamp tcpMaxSeg penetrate tcpUserTimeout v6only interface tcpMptcp customSockopt addressPortStrategy happyEyeballs trustedXForwardedFor".split())


def check_keys(obj, allowed):
    if not isinstance(obj, dict) or set(obj) - allowed:
        raise LinkError("扩展 JSON 含未知或不适用的字段")


def validate_headers(headers):
    if not isinstance(headers, dict) or any(not isinstance(k, str) or not isinstance(v, str) or any(c in k + v for c in '\r\n') for k, v in headers.items()):
        raise LinkError("headers 必须是字符串键值对象，且不能包含换行")


def validate_sockopt(obj):
    check_keys(obj, SOCKOPT_FIELDS)
    if "domainStrategy" in obj and str(obj["domainStrategy"]).lower() not in {"asis", "useip", "useipv4", "useipv6", "useipv4v6", "useipv6v4", "forceip", "forceipv4", "forceipv6", "forceipv4v6", "forceipv6v4"}:
        raise LinkError("sockopt domainStrategy 无效")
    if "tproxy" in obj and obj["tproxy"] not in {"off", "tproxy", "redirect"}:
        raise LinkError("sockopt tproxy 无效")
    if "happyEyeballs" in obj:
        check_keys(obj["happyEyeballs"], set("prioritizeIPv6 tryDelayMs interleave maxConcurrentTry".split()))
    if "customSockopt" in obj:
        if not isinstance(obj["customSockopt"], list):
            raise LinkError("customSockopt 必须为数组")
        for item in obj["customSockopt"]:
            check_keys(item, set("system network level opt value type".split()))


def validate_extra(obj, depth=0):
    if depth > 4:
        raise LinkError("XHTTP 扩展嵌套过深")
    check_keys(obj, XHTTP_EXTRA)
    if "headers" in obj:
        validate_headers(obj["headers"])
    if "xmux" in obj:
        check_keys(obj["xmux"], XMUX_FIELDS)
    if "downloadSettings" in obj:
        d = obj["downloadSettings"]
        check_keys(d, set("address port network security tlsSettings realitySettings xhttpSettings sockopt".split()))
        if d.get("network", "tcp") not in {"xhttp", "splithttp"}:
            raise LinkError("XHTTP downloadSettings 必须明确使用 xhttp 传输")
        if "sockopt" in d:
            validate_sockopt(d["sockopt"])
        security = d.get("security", "none")
        if security not in {"none", "tls", "reality"}:
            raise LinkError("downloadSettings 的 security 不支持")
        if "tlsSettings" in d:
            if security != "tls":
                raise LinkError("downloadSettings 的 TLS 配置与 security 不匹配")
            check_keys(d["tlsSettings"], TLS_FIELDS)
            if "echSockopt" in d["tlsSettings"]:
                validate_sockopt(d["tlsSettings"]["echSockopt"])
            if "certificates" in d["tlsSettings"]:
                if not isinstance(d["tlsSettings"]["certificates"], list):
                    raise LinkError("certificates 必须是数组")
                for cert in d["tlsSettings"]["certificates"]:
                    check_keys(cert, set("certificateFile certificate usage buildChain oneTimeLoading".split()))
        if "realitySettings" in d:
            if security != "reality":
                raise LinkError("downloadSettings 的 REALITY 配置与 security 不匹配")
            check_keys(d["realitySettings"], set("fingerprint serverName password publicKey shortId mldsa65Verify spiderX".split()))
        x = d.get("xhttpSettings", {})
        check_keys(x, XHTTP_EXTRA | {"host", "path", "mode", "extra"})
        if "extra" in x:
            if set(x) - {"host", "path", "mode", "extra"}:
                raise LinkError("downloadSettings 的 extra 不能与同级扩展字段混用")
            validate_extra(x["extra"], depth + 1)
        else:
            validate_extra({k: v for k, v in x.items() if k not in {"host", "path", "mode"}}, depth + 1)


def stream_extensions(p, stream):
    sockopt = p.get("sockopt")
    if sockopt:
        stream["sockopt"] = json_object(sockopt)
        validate_sockopt(stream["sockopt"])
    tfo = p.get("tfo", "tcpFastOpen")
    if tfo != "":
        if stream["network"] in {"kcp", "hysteria"}:
            raise LinkError("TCP Fast Open 不适用于 UDP 传输")
        settings = stream.setdefault("sockopt", {})
        if "tcpFastOpen" in settings:
            raise LinkError("tcpFastOpen 不应同时出现在链接和 sockopt 中")
        settings["tcpFastOpen"] = boolean(tfo) if str(tfo).lower() in {"true", "false", "0", "1"} else integer(tfo, 0, 2147483647)


def stream_settings(p, address):
    network = str(p.get("type", "net", default="tcp")).lower()
    network = {"raw": "tcp", "websocket": "ws", "splithttp": "xhttp", "mkcp": "kcp"}.get(network, network)
    if network not in {"tcp", "ws", "httpupgrade", "grpc", "xhttp", "kcp"}:
        raise LinkError("当前核心不支持该传输类型（旧 HTTP/H2/QUIC 已移除）")
    security = str(p.get("security", "tls", default="none")).lower() or "none"
    if security not in {"none", "tls", "reality"}:
        raise LinkError("不支持的传输安全类型")
    stream = {"network": network, "security": security}
    if network not in {"tcp", "kcp"} and p.data.get("headerType") in {"", "none"}:
        p.get("headerType")
    host = p.get("host") if security == "tls" or network in {"ws", "httpupgrade", "xhttp", "grpc"} or (network == "tcp" and p.data.get("headerType") == "http") else ""
    if security == "tls":
        stream["tlsSettings"] = tls_settings(p, address, host, network)
    elif security == "reality":
        if network not in {"tcp", "xhttp", "grpc"}:
            raise LinkError("当前核心的 REALITY 仅支持 TCP、XHTTP、gRPC")
        key = p.get("pbk", "publicKey", "password")
        if not key:
            raise LinkError("REALITY 缺少公钥")
        stream["realitySettings"] = {
            "serverName": p.get("sni", "serverName", "peer"), "publicKey": key,
            "shortId": p.get("sid", "shortId"),
            "fingerprint": p.get("fp", "fingerprint", default="chrome"),
            "spiderX": p.get("spx", "spiderX", default="/"),
        }
        pqv = p.get("pqv", "mldsa65Verify")
        if pqv:
            stream["realitySettings"]["mldsa65Verify"] = pqv
        if stream["realitySettings"]["fingerprint"] not in FINGERPRINTS - {"unsafe", "hellogolang"}:
            raise LinkError("REALITY fingerprint 不支持或未确认")
    if network in {"ws", "httpupgrade", "xhttp"}:
        path = p.get("path", default="/") or "/"
        if not str(path).startswith("/"):
            path = "/" + str(path)
        opts = {"host": host, "path": path}
        headers = p.get("headers")
        if headers:
            opts["headers"] = json_object(headers)
            validate_headers(opts["headers"])
            if any(k.lower() == "host" for k in opts["headers"]):
                raise LinkError("请使用 host 参数，不要在 headers 中重复指定 Host")
        if network == "xhttp":
            opts["mode"] = p.get("mode", default="auto") or "auto"
            if opts["mode"] not in {"auto", "packet-up", "stream-up", "stream-one"}:
                raise LinkError("XHTTP mode 不支持")
            extra = p.get("extra")
            if extra:
                opts["extra"] = json_object(extra)
                validate_extra(opts["extra"])
                if headers:
                    raise LinkError("XHTTP headers 请放在 extra 中，避免被 extra 覆盖")
        elif network in {"ws", "httpupgrade"}:
            ed = p.get("ed")
            if ed:
                from urllib.parse import quote
                if "ed" in dict(parse_qsl(urlsplit(path).query)):
                    raise LinkError("early-data 参数 ed 不能同时出现在 path 和链接参数中")
                opts["path"] += ("&" if "?" in path else "?") + "ed=" + quote(str(integer(ed, 0, 4294967295)))
            query = parse_qsl(urlsplit(opts["path"]).query, keep_blank_values=True)
            path_ed = [v for k, v in query if k == "ed"]
            if len(path_ed) > 1:
                raise LinkError("path 中包含重复 ed")
            if path_ed:
                integer(path_ed[0], 0, 4294967295)
            eh = p.get("eh")
            if eh and (network != "ws" or str(eh).lower() != "sec-websocket-protocol"):
                raise LinkError("仅 WebSocket 支持 eh=Sec-WebSocket-Protocol")
            if network == "ws":
                apply_fields(p, opts, numbers=("heartbeatPeriod",))
        stream[{"ws": "wsSettings", "httpupgrade": "httpupgradeSettings", "xhttp": "xhttpSettings"}[network]] = opts
    elif network == "grpc":
        mode = p.get("mode", default="gun") or "gun"
        if mode not in {"gun", "multi"}:
            raise LinkError("gRPC mode 必须是 gun 或 multi")
        multi = p.get("multiMode")
        if multi != "" and "mode" in p.data and boolean(multi) != (mode == "multi"):
            raise LinkError("gRPC mode 与 multiMode 存在冲突")
        stream["grpcSettings"] = {
            "serviceName": p.get("serviceName", "path"),
            "authority": p.get("authority", default=host),
            "multiMode": boolean(multi) if multi != "" else mode == "multi",
        }
        apply_fields(p, stream["grpcSettings"], strings=("user_agent",),
                     numbers=("idle_timeout", "health_check_timeout", "initial_windows_size"),
                     bools=("permit_without_stream",))
    elif network == "kcp":
        stream["kcpSettings"] = {"seed": p.get("seed", "path"), "header": {"type": p.get("headerType", default="none") or "none"}}
        apply_fields(p, stream["kcpSettings"], numbers=("mtu", "tti", "uplinkCapacity", "downlinkCapacity", "readBufferSize", "writeBufferSize"), bools=("congestion",))
        domain = p.get("domain")
        if domain:
            if stream["kcpSettings"]["header"]["type"] != "dns":
                raise LinkError("mKCP domain 仅适用于 DNS 伪装")
            stream["kcpSettings"]["header"]["domain"] = domain
    else:
        header = p.get("headerType", default="none") or "none"
        opts = {"header": {"type": header}}
        if header == "http":
            path = p.get("path", default="/") or "/"
            opts["header"]["request"] = {"path": list_strings(path), "headers": {"Host": list_strings(host or address)}}
        elif header != "none":
            raise LinkError("TCP headerType 仅支持 none/http")
        stream["tcpSettings"] = opts
    # Empty defaults in legacy VMess JSON are not connection options.
    stream_extensions(p, stream)
    return stream


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise LinkError("VMess JSON 含重复字段")
        result[key] = value
    return result


def decode_vmess(link):
    try:
        payload = unquote(link.split("://", 1)[1].split("#", 1)[0], errors="strict")
        raw = base64.b64decode(payload + "=" * (-len(payload) % 4), altchars=b"-_", validate=True)
        data = json_object(raw)
    except LinkError:
        raise
    except (ValueError, UnicodeError):
        raise LinkError("VMess Base64 JSON 格式错误") from None
    if not isinstance(data, dict):
        raise LinkError("VMess 内容必须是 JSON 对象")
    return data


def hysteria_outbound(p, u, address, remote_port, authority_ports):
    auth = unquote(u.username or "", errors="strict")
    if u.password is not None:
        auth += ":" + unquote(u.password, errors="strict")
    tls = tls_settings(p, address, network="hysteria")
    hy = {"version": 2, "auth": auth}
    stream = {"network": "hysteria", "security": "tls", "tlsSettings": tls, "hysteriaSettings": hy}
    ports = p.get("mport", "ports")
    authority_hop = "," in authority_ports or "-" in authority_ports
    if authority_hop:
        normal = port_list(authority_ports)
        if ports and port_list(ports) != normal:
            raise LinkError("地址端口列表与 mport/ports 冲突")
        ports = normal
    interval = p.get("hopInterval", "hop-interval")
    if interval and not ports:
        raise LinkError("hopInterval 需要端口跳跃列表")
    if ports:
        hy["udphop"] = {"port": port_list(ports), "interval": duration(interval or "30", 5)}
    obfs = p.get("obfs")
    if obfs and obfs != "none":
        if obfs != "salamander":
            raise LinkError("当前核心仅支持 salamander 混淆")
        password = p.get("obfs-password", "obfsPassword")
        if not password:
            raise LinkError("Salamander 缺少混淆密码")
        stream["udpmasks"] = [{"type": "salamander", "settings": {"password": password}}]
    for direction in ("up", "down"):
        value = p.get(direction)
        mbps = p.get(direction + "mbps", direction + "Mbps", direction + "_mbps")
        if value and mbps:
            raise LinkError("带宽不能同时指定速率字符串和 Mbps 参数")
        if mbps:
            if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", str(mbps)):
                raise LinkError("Mbps 带宽必须是非负数")
            # The share-link Mbps aliases use decimal megabits. Xray's
            # bandwidth string parser treats "mbps" as 1024*1024 bit/s.
            # Convert explicitly so importing a link does not raise its rate.
            bits = Decimal(str(mbps)) * 1000000
            if bits != bits.to_integral_value():
                raise LinkError("Mbps 带宽精度不能小于 1 bit/s")
            value = str(integer(str(int(bits)), 0, 18446744073709551615)) + " bps"
        if value:
            hy[direction] = str(value)
    congestion = p.get("congestion")
    if congestion:
        if congestion not in {"reno", "bbr", "brutal", "force-brutal"}:
            raise LinkError("Hysteria2 congestion 在当前核心中未支持或未确认")
        hy["congestion"] = congestion
    apply_fields(p, hy, numbers=("initStreamReceiveWindow", "maxStreamReceiveWindow", "initConnectionReceiveWindow", "maxConnectionReceiveWindow"), bools=("disablePathMTUDiscovery",))
    for key in ("maxIdleTimeout", "keepAlivePeriod"):
        value = p.get(key)
        if value != "":
            hy[key] = duration(value)
    stream_extensions(p, stream)
    return {"protocol": "hysteria", "settings": {"version": 2, "address": address, "port": remote_port}, "streamSettings": stream}


def parse_link(profile, link, port=10808):
    link = link.strip().lstrip("\ufeff")
    connection_part = link.split("#", 1)[0]
    if not link or any(c.isspace() for c in connection_part) or re.search(r"%(?![0-9a-fA-F]{2})", connection_part):
        raise LinkError("请提供单条完整链接；空格应使用 URL 编码")
    profile = {"hy2": "hysteria2"}.get(profile, profile)
    try:
        u = urlsplit(link)
        if profile == "vmess" and u.scheme == "vmess" and "@" not in u.netloc:
            d = decode_vmess(link)
            address, remote_port, uid = d.get("add"), integer(d.get("port"), 1), d.get("id")
            user = {"id": uid, "alterId": integer(d.get("aid") or 0), "security": d.get("scy") or "auto"}
            # Preserve separate Host / SNI, cipher, ALPN, fingerprint and transport.
            fields = {k: v for k, v in d.items() if k not in {"add", "port", "id", "aid", "scy", "v", "ps"} and v not in ("", None)}
            if "type" in fields:
                kind = fields.pop("type")
                if fields.get("net") == "grpc" and kind in {"gun", "multi"}:
                    if "mode" in fields and fields["mode"] != kind:
                        raise LinkError("VMess JSON 的 type 与 mode 冲突")
                    fields["mode"] = kind
                else:
                    if "headerType" in fields and fields["headerType"] != kind:
                        raise LinkError("VMess JSON 的 type 与 headerType 冲突")
                    fields["headerType"] = kind
            p = Params(fields)
        else:
            if u.scheme not in ({"hysteria2", "hy2"} if profile == "hysteria2" else {profile}) or profile not in {"hysteria2", "vless", "vmess"}:
                raise LinkError("链接协议与所选线路不匹配")
            address = u.hostname
            authority = u.netloc.rsplit("@", 1)[-1]
            if authority.startswith("["):
                suffix = authority.split("]", 1)[1]
                if suffix and not suffix.startswith(":"):
                    raise LinkError("IPv6 地址格式错误")
                raw_port = suffix[1:] if suffix else ""
            else:
                if authority.count(":") > 1:
                    raise LinkError("IPv6 地址必须放在方括号内")
                raw_port = authority.rsplit(":", 1)[1] if ":" in authority else ""
            if profile != "hysteria2" and not raw_port:
                raise LinkError("VLESS/VMess URI 必须指定端口")
            if profile == "hysteria2":
                raw_port = raw_port or "443"
                normalized = port_list(raw_port)
                remote_port = int(normalized.split(",")[0].split("-")[0])
            else:
                remote_port = integer(raw_port, 1)
            pairs = parse_qsl(u.query, keep_blank_values=True, strict_parsing=True, errors="strict") if u.query else []
            if len(dict(pairs)) != len(pairs):
                raise LinkError("链接含重复参数")
            p = Params(pairs)
            if u.path not in {"", "/"}:
                raise LinkError("传输路径请通过 path 参数提供")
            uid = unquote(u.username or "", errors="strict")
            if profile == "hysteria2":
                if not address:
                    raise LinkError("Hysteria2 缺少服务器地址")
                outbound = hysteria_outbound(p, u, address, remote_port, raw_port)
                p.finish()
                return config(outbound, port)
            if u.password is not None:
                raise LinkError("VLESS/VMess 用户信息不应含密码字段")
            user = {"id": uid}
            if profile == "vless":
                user["encryption"] = p.get("encryption", default="none") or "none"
                flow = p.get("flow")
                if flow:
                    user["flow"] = flow
            else:
                user.update({"security": p.get("encryption", "scy", default="auto") or "auto", "alterId": integer(p.get("aid", "alterId", default="0"))})
        if not isinstance(address, str) or not isinstance(uid, str) or not address or not uid:
            raise LinkError("链接缺少服务器或用户 ID")
        if profile == "vmess":
            if user["alterId"] != 0:
                raise LinkError("当前核心仅支持 VMess AEAD（aid/alterId=0），非零旧版 alterId 无法兼容")
            user["security"] = str(user["security"]).lower()
            if user["security"] not in {"auto", "aes-128-gcm", "chacha20-poly1305", "none", "zero"}:
                raise LinkError("VMess 加密方式不支持，不能静默替换为 auto")
        stream = stream_settings(p, address)
        if profile == "vless" and user.get("flow") and (stream["network"] != "tcp" or stream["security"] not in {"tls", "reality"}):
            raise LinkError("当前核心的 Vision flow 需要直接使用 TCP + TLS/REALITY")
        p.finish()
        return config({"protocol": profile, "settings": {"vnext": [{"address": address, "port": remote_port, "users": [user]}]}, "streamSettings": stream}, port)
    except LinkError:
        raise
    except (ValueError, TypeError, KeyError):
        raise LinkError("链接字段格式错误") from None


def config(outbound, port):
    return {"log": {"loglevel": "warning"}, "inbounds": [{"listen": "127.0.0.1", "port": integer(port, 1), "protocol": "socks", "settings": {"udp": True}}], "outbounds": [outbound]}


def main():
    try:
        cfg = parse_link(os.environ["XRAY_PROFILE"], os.environ["XRAY_LINK"], os.environ["XRAY_PORT"])
    except LinkError as error:
        print("[xray] " + str(error), file=sys.stderr)
        return 1
    target = Path(sys.argv[1])
    temporary = target.with_name(target.name + f".{os.getpid()}.tmp")
    try:
        with open(temporary, "x", opener=lambda path, flags: os.open(path, flags, 0o600)) as f:
            json.dump(cfg, f, indent=2)
            f.write("\n")
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
xray_code=$?
set -e
if [[ "$xray_code" -ne 0 ]]; then
  listen_anyway
fi
chmod 600 "$XRAY_CONFIG"
# 配置错误时保留 xray 的标准错误，便于写入日志。打不开就改为只监听。
if ! "$XRAY_BIN" -test -config "$XRAY_CONFIG" >/dev/null; then
  listen_anyway
fi
printf '%s [xray] 启动 Xray，线路 %s，SOCKS / HTTP 混合代理入口 127.0.0.1:%s。\n' "$(date '+%Y/%m/%d %H:%M:%S')" "$profile" "$PROXY_PORT" >&2
exec "$XRAY_BIN" run -config "$XRAY_CONFIG"
