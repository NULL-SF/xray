#!/usr/bin/env bash
# 管理 127.0.0.1 上 config/ports/ 中配置的 SOCKS5 与 HTTP 双入口。
# vless、vmess、hysteria2 均使用 bin/xray_26.1.23。当前线路见 config/active.txt。
# 开机自启写在该用户的 crontab，到点执行 scripts/xray-service.sh。start 也是把这个脚本放进后台。
# 操作结果写入 log/xray.log。询问与 status 只显示在终端。
set -euo pipefail

ROOT="${BASH_SOURCE[0]%/*}"
[[ "$ROOT" != "${BASH_SOURCE[0]}" ]] || ROOT=.
ROOT="$(cd -- "$ROOT" && pwd -P)"
# 管理命令及其启动的核心不继承终端代理，避免自代理。
source "${ROOT}/scripts/terminal-env.sh"
_xray_remove_preload "$ROOT"
unset -f _xray_remove_preload
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy NO_PROXY no_proxy
ACTIVE="${ROOT}/config/active.txt"
PIDFILE="${ROOT}/runtime/xray.pid"
LOG="${ROOT}/log/xray.log"
MARK="xray-proxy-boot"
TERMINAL_MARK="xray-proxy-terminal"
TERMINAL_FLAG="${ROOT}/config/terminal.on"
BASHRC="${HOME}/.bashrc"
load_port() {
  _xray_load_ports "$ROOT" || return 1
  PORT="$SOCKS_PORT"
}
PORT_CONFIG_VALID=1
if ! load_port; then
  case "${1:-}" in
    status|stop|log)
      PORT_CONFIG_VALID=0
      PORT=0 SOCKS_PORT=0 HTTP_PORT=0
      ;;
    *) exit 1 ;;
  esac
fi
ensure_port() {
  _xray_ensure_ports "$ROOT" || return 1
  PORT="$SOCKS_PORT"
}

lock_management() {
  mkdir -p "${ROOT}/runtime"
  exec {MANAGEMENT_LOCK}>"${ROOT}/runtime/management.lock"
  if ! flock -w 45 "$MANAGEMENT_LOCK"; then
    printf '其他管理操作尚未结束，请稍后重试。\n' >&2
    return 1
  fi
  if [[ "$PORT_CONFIG_VALID" == 1 ]]; then load_port; fi
}

sync_proxychains() {
  mkdir -p "${ROOT}/runtime" || return 1
  local tmp_config
  tmp_config="$(mktemp "${ROOT}/runtime/.proxychains.conf.XXXXXX")" || return 1
  if ! cat > "$tmp_config" <<EOF
# 由 xray.sh 根据 config/ports/socks.txt 生成到 runtime。不要手改。
# 仅在 source proxy.env 之后生效。
strict_chain
proxy_dns
remote_dns_subnet 224
tcp_read_time_out 15000
tcp_connect_time_out 8000
quiet_mode

# 本机地址直连，避免再进入代理端口。
localnet 127.0.0.0/255.0.0.0
localnet ::1/128

[ProxyList]
socks5 127.0.0.1 ${PORT}
EOF
  then
    rm -f -- "$tmp_config"
    return 1
  fi
  if ! mv -f -- "$tmp_config" "${ROOT}/runtime/proxychains.conf"; then
    rm -f -- "$tmp_config"
    return 1
  fi
}

note() {
  printf '%s\n' "$*"
  mkdir -p "${ROOT}/log"
  printf '%s [xray] %s\n' "$(date '+%Y/%m/%d %H:%M:%S')" "$*" >> "$LOG"
}

current_profile() {
  local name=""
  if [[ -r "$ACTIVE" ]]; then
    name="$(tr -d '[:space:]' < "$ACTIVE")"
  fi
  # 旧文件里可能写过这些简称。
  [[ "$name" == "reality" ]] && name="vless"
  [[ "$name" == "hy2" || "$name" == "hysteria" ]] && name="hysteria2"
  printf '%s\n' "${name:-hysteria2}"
}

core_for() {
  printf '%s\n' "bin/xray_26.1.23"
}

own_listener() {
  local pid cmd
  pid="$(listener_pid)"
  [[ -n "$pid" ]] || return 1
  cmd="$(pid_cmdline "$pid")"
  [[ "$cmd" == "${ROOT}/bin/xray_26.1.23 run -config ${ROOT}/runtime/xray_config.json " ]]
}

port_open() {
  ss -lnt 2>/dev/null | grep "127\\.0\\.0\\.1:${PORT}[[:space:]]" >/dev/null
}

listener_pid() {
  ss -lntp 2>/dev/null | sed -n "s/.*127\\.0\\.0\\.1:${PORT} .*pid=\\([0-9]*\\).*/\\1/p" | sed -n '1p'
}

daemon_alive() {
  local pid cmd
  [[ -f "$PIDFILE" ]] || return 1
  pid="$(tr -d '[:space:]' < "$PIDFILE")"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  cmd="$(pid_cmdline "$pid")"
  [[ "$cmd" == "${ROOT}/bin/xray_26.1.23 run -config ${ROOT}/runtime/xray_config.json " ]] || {
    [[ "/proc/$pid/exe" -ef "/proc/$$/exe" ]] &&
      [[ "$cmd" == *" ${ROOT}/scripts/xray-service.sh "* ]]
  }
}

pid_cmdline() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] || return 0
  tr '\0' ' ' 2>/dev/null < "/proc/${1}/cmdline" || true
}

# 结束该进程及其子进程。
kill_tree() {
  local pid="$1" child
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  [[ "$pid" -gt 1 ]] || return 0
  for child in $(ps -o pid= --ppid "$pid" 2>/dev/null || true); do
    kill_tree "$child"
  done
  kill -TERM "$pid" 2>/dev/null || true
}

cron_line() {
  local service="${ROOT}/scripts/xray-service.sh" logfile="$LOG" logdir="${ROOT}/log" line
  [[ "$ROOT" != *$'\n'* ]] || { printf '路径含换行符，无法登记 crontab。\n' >&2; return 1; }
  service="${service//\'/\'\\\'\'}"
  logfile="${logfile//\'/\'\\\'\'}"
  logdir="${logdir//\'/\'\\\'\'}"
  printf -v line "@reboot sleep 20; mkdir -p '%s'; PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin '%s' >> '%s' 2>&1 < /dev/null # %s" \
    "$logdir" "$service" "$logfile" "$MARK"
  # cron 即使在引号内也会解释百分号，需先转义。
  printf '%s\n' "${line//%/\\%}"
}

cron_enabled() {
  crontab -l 2>/dev/null | grep " # ${MARK}$" >/dev/null
}

set_cron() {
  local mode="$1" current entry had_crontab=1
  if ! current="$(LC_ALL=C crontab -l 2>&1)"; then
    if [[ "$current" == *'no crontab for '* ]]; then
      current=""
      had_crontab=0
    else
      printf '读取 crontab 失败，未修改：%s\n' "$current" >&2
      return 1
    fi
  fi
  current="$(printf '%s\n' "$current" | grep -v " # ${MARK}$" || true)"
  if [[ "$mode" == "on" ]]; then
    entry="$(cron_line)" || return 1
    { [[ -z "$current" ]] || printf '%s\n' "$current"; printf '%s\n' "$entry"; } | crontab -
    return
  fi
  if [[ -z "$current" ]]; then
    [[ "$had_crontab" == 1 ]] || return 0
    crontab -r
    return
  fi
  printf '%s\n' "$current" | crontab -
}

start_proxy() {
  if port_open; then
    if ! own_listener; then
      note "启动失败：127.0.0.1:${PORT} 已由其他进程占用。请先在 config/ports/socks.txt 设置空闲端口。"
      return 1
    fi
    FRESH_START=0
    _xray_check_running_ports "$ROOT" "$SOCKS_PORT" "$HTTP_PORT" || return 1
    sync_proxychains || return 1
    note "双入口已在监听，未重复启动。"
    return 0
  fi
  if daemon_alive; then
    note "核心进程已在运行，127.0.0.1:${PORT} 尚未监听。详见 ${LOG}"
    return 1
  fi
  if ( PORT="$HTTP_PORT"; port_open ); then
    note "启动失败：HTTP 端口 ${HTTP_PORT} 已被占用。"
    return 1
  fi
  _xray_check_available_ports "$ROOT" "$SOCKS_PORT" "$HTTP_PORT" || return 1
  # 核心不能持有管理锁，否则后续 stop/restart 会一直等待。
  mkdir -p "${ROOT}/log"
  ( exec {MANAGEMENT_LOCK}>&-; exec nohup "${ROOT}/scripts/xray-service.sh" ) >> "$LOG" 2>&1 < /dev/null &
  local child=$!
  disown || true
  # 核心在默认路由出现前最多等待 30 秒，这里留出余量。端口一旦打开即返回。
  # 启动程序已经退出时不再继续等，原因在日志里。
  local i
  for i in $(seq 1 40); do
    if port_open && ( PORT="$HTTP_PORT"; port_open ); then
      if ! own_listener || ! ( PORT="$HTTP_PORT"; own_listener ); then
        note "启动失败：SOCKS5 或 HTTP 入口被其他进程占用。"
        return 1
      fi
      note "已启动。线路 $(current_profile)（$(core_for "$(current_profile)")），监听 SOCKS5 127.0.0.1:${SOCKS_PORT}、HTTP 127.0.0.1:${HTTP_PORT}。"
      sync_proxychains || return 1
      FRESH_START=1
      return 0
    fi
    if ! kill -0 "$child" 2>/dev/null; then
      note "启动失败：SOCKS5 和 HTTP 双入口未全部就绪。详见 ${LOG}"
      return 1
    fi
    sleep 1
  done
  if daemon_alive; then
    note "40 秒内 SOCKS5 和 HTTP 双入口未全部就绪。核心进程仍在启动。详见 ${LOG}"
  else
    note "启动失败：40 秒内 SOCKS5 和 HTTP 双入口未全部就绪。详见 ${LOG}"
  fi
  return 1
}

# 只结束本项目的进程；配置端口上的其他进程不属于停止范围。
stop_proxy() {
  local pid port attempt
  if daemon_alive; then
    pid="$(tr -d '[:space:]' < "$PIDFILE")"
    kill_tree "$pid"
  fi
  for port in "$SOCKS_PORT" "$HTTP_PORT"; do
    if ( PORT="$port"; own_listener ); then
      pid="$(PORT="$port"; listener_pid)"
      kill_tree "$pid"
    fi
  done
  for attempt in {1..30}; do
    if ! daemon_alive && ! own_listener && ! ( PORT="$HTTP_PORT"; own_listener ); then
      rm -f "$PIDFILE"
      note "本项目核心已停止。"
      return 0
    fi
    sleep 0.1
  done
  note "停止失败：本项目进程或监听尚未退出。"
  return 1
}

# 常见外网页面。跟随跳转后的最终响应为 200，视为该页能打开。
PROBE_URL="https://www.google.com"

# 只报告当前连接，不改线路，也不启停监听。
report_connection() {
  local kind label port url result code secs ms
  local failed=0 entry_failed
  local urls=() proxy_args=()
  for kind in http socks; do
    if [[ "$kind" == http ]]; then
      label=HTTP port="$HTTP_PORT"
      urls=(http://www.google.com "$PROBE_URL")
      proxy_args=(--proxy "http://127.0.0.1:${HTTP_PORT}")
    else
      label=SOCKS5 port="$SOCKS_PORT"
      urls=("$PROBE_URL")
      proxy_args=(--socks5-hostname "127.0.0.1:${SOCKS_PORT}")
    fi
    ms="未测得"
    # 分别核对入口归属；一个入口异常不跳过另一个入口的检查。
    if ! ( PORT="$port"; port_open ); then
      note "${label} 入口：连接失败，127.0.0.1:${port} 未在监听；访问 ${PROBE_URL} 的首字节耗时：未测得。"
      failed=1
      continue
    fi
    if ! ( PORT="$port"; own_listener ); then
      note "${label} 入口：连接失败，127.0.0.1:${port} 被其他进程占用；访问 ${PROBE_URL} 的首字节耗时：未测得。"
      failed=1
      continue
    fi
    entry_failed=0
    for url in "${urls[@]}"; do
      if ! result="$(curl -sS -L --noproxy '' "${proxy_args[@]}" \
        --connect-timeout 12 --max-time 20 -o /dev/null \
        -w '%{http_code} %{time_starttransfer}' "$url" 2>/dev/null)"; then
        note "${label} 入口访问 ${url} 失败（连接、TLS 或传输未完成）。" >/dev/null
        entry_failed=1
        continue
      fi
      code="${result%% *}"
      secs="${result#* }"
      if [[ "$code" != 200 ]]; then
        note "${label} 入口访问 ${url} 失败（响应 ${code}）。" >/dev/null
        entry_failed=1
      elif [[ "$url" == "$PROBE_URL" && "$secs" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        ms="$(awk -v t="$secs" 'BEGIN { printf "%d", t * 1000 }') 毫秒"
      fi
    done
    if [[ "$entry_failed" == 0 ]]; then
      note "${label} 入口：连接正常；访问 ${PROBE_URL} 的首字节耗时：${ms}。"
    else
      note "${label} 入口：连接失败；访问 ${PROBE_URL} 的首字节耗时：${ms}。详见日志。"
      failed=1
    fi
  done
  return "$failed"
}

switch_xray() {
  local current choice previous
  current="$(current_profile)"
  echo "当前线路: ${current}（$(core_for "$current")）"
  echo "  1) vless"
  echo "  2) hysteria2"
  echo "  3) vmess"
  printf '输入序号或线路名：'
  read -r choice
  case "$choice" in
    1|vless) choice="vless" ;;
    2|hysteria2) choice="hysteria2" ;;
    3|vmess) choice="vmess" ;;
    *)
      echo "已取消，未作更改。"
      return 1
      ;;
  esac
  lock_management
  ensure_port
  _xray_check_available_ports "$ROOT" "$SOCKS_PORT" "$HTTP_PORT" || return 1
  current="$(current_profile)"
  if [[ "$choice" == "$current" ]]; then
    note "当前已是 ${current}，按重启处理。"
    stop_proxy
    start_proxy
    report_connection || true
    return
  fi
  previous="$current"
  if ! stop_proxy; then
    note "未能停止当前进程，未切换，线路仍为 ${previous}。"
    return 1
  fi
  printf '%s\n' "$choice" > "$ACTIVE"
  if ! start_proxy; then
    note "已切换到 ${choice}，并已写入 config/active.txt。监听未能启动，详见 ${LOG}"
    return 1
  fi
  note "已切换到 ${choice}。已写入 config/active.txt，此后启动与开机使用该线路。"
  report_connection || true
}

terminal_enabled() {
  [[ -f "$TERMINAL_FLAG" ]] && grep -q "${TERMINAL_MARK}-begin" "$BASHRC" 2>/dev/null
}

set_terminal() {
  local mode="$1"
  python3 - "$BASHRC" "$mode" "$ROOT" <<'PY'
import os, pathlib, shlex, sys, tempfile
path, mode, root = sys.argv[1:]
begin = "# xray-proxy-terminal-begin"
end = "# xray-proxy-terminal-end"
file = pathlib.Path(path).resolve()
text = file.read_text() if file.exists() else ""
def save_text(text):
    file.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=file.parent, prefix="." + file.name + ".", delete=False) as stream:
            temporary = pathlib.Path(stream.name)
            stream.write(text)
        if file.exists():
            temporary.chmod(file.stat().st_mode & 0o777)
        temporary.replace(file)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
while True:
    start = text.find(begin)
    if start < 0:
        break
    stop = text.find(end, start)
    if stop < 0:
        text = text[:start]
        break
    stop = text.find("\n", stop)
    stop = len(text) if stop < 0 else stop + 1
    text = text[:start] + text[stop:]
existed = file.exists()
if mode != "on":
    if existed:
        save_text(text)
    raise SystemExit(0)
if mode == "on":
    block = f"""# xray-proxy-terminal-begin
if [[ -f {shlex.quote(root + '/config/terminal.on')} && -f {shlex.quote(root + '/proxy.env')} ]]; then
  source {shlex.quote(root + '/proxy.env')}
fi
# xray-proxy-terminal-end
"""
    if text and not text.endswith("\n"):
        text += "\n"
    text += block
save_text(text)
PY
  if [[ "$mode" == "on" ]]; then
    : > "$TERMINAL_FLAG"
  else
    rm -f "$TERMINAL_FLAG"
  fi
}

terminal_xray() {
  local state choice
  if terminal_enabled; then
    state="开"
  else
    state="关"
  fi
  echo "终端自动接入代理: ${state}"
  echo "  1) 开启"
  echo "  2) 关闭"
  printf '输入序号：'
  read -r choice
  case "$choice" in
    1|on|开启)
      lock_management
      set_terminal on
      note "终端自动接入代理已开启。此后新打开的终端会自动接入代理。已经打开的窗口不受影响。"
      ;;
    2|off|关闭)
      lock_management
      set_terminal off
      note "终端自动接入代理已关闭。此后新打开的终端不会自动接入代理。已经打开的窗口不受影响。"
      ;;
    *)
      echo "已取消，未作更改。"
      return 1
      ;;
  esac
}

boot_xray() {
  local state choice
  if cron_enabled; then
    state="开"
  else
    state="关"
  fi
  echo "开机自启: ${state}"
  echo "  1) 开启"
  echo "  2) 关闭"
  printf '输入序号：'
  read -r choice
  case "$choice" in
    1|on|开启)
      set_cron on
      note "开机自启已开启。已写入 crontab，下次开机会自动启动。这次没有启动监听。"
      ;;
    2|off|关闭)
      set_cron off
      note "开机自启已关闭。crontab 中的登记已删除。这次没有停止监听。下次开机不会自动启动。"
      ;;
    *)
      echo "已取消，未作更改。"
      return 1
      ;;
  esac
}

status_xray() {
  local profile
  profile="$(current_profile)"
  echo "线路: ${profile}（$(core_for "$profile")）"
  if cron_enabled; then
    echo "开机自启: 开"
  else
    echo "开机自启: 关"
  fi
  if terminal_enabled; then
    echo "终端自动接入代理: 开"
  else
    echo "终端自动接入代理: 关"
  fi
  echo "日志: ${LOG}"
  if [[ "${SOCKS_PORT_DEFAULTED:-0}" == 1 ]]; then
    echo "SOCKS5 端口配置缺失、为空或无效，按默认 10808 查询；未写入文件。"
  fi
  if [[ "${HTTP_PORT_DEFAULTED:-0}" == 1 ]]; then
    echo "HTTP 端口配置缺失、为空或无效，按默认 10809 查询；未写入文件。"
  fi
  if [[ "$PORT_CONFIG_VALID" == 0 ]]; then
    echo "端口配置无效；以下运行配置仅供诊断，未修改文件。"
  fi
  if daemon_alive; then
    python3 - "$ROOT/runtime/xray_config.json" "$SOCKS_PORT" "$HTTP_PORT" "$PORT_CONFIG_VALID" <<'PY_STATUS'
import json, sys
try:
    inbounds = json.load(open(sys.argv[1]))['inbounds']
    actual = {(i['protocol'], i.get('listen'), i['port']) for i in inbounds}
    expected = {('socks', '127.0.0.1', int(sys.argv[2])),
                ('http', '127.0.0.1', int(sys.argv[3]))}
    if sys.argv[4] != '1' or actual != expected:
        if sys.argv[4] == '1':
            print('端口配置与运行配置不一致；以下监听状态按当前端口配置查询。')
        for i in inbounds:
            protocol = {"socks": "SOCKS5", "http": "HTTP"}.get(i["protocol"], i["protocol"])
            print(f"运行配置入口: {protocol} {i.get('listen')}:{i['port']}")
except (OSError, ValueError, KeyError, TypeError):
    print('运行配置不可读')
PY_STATUS
  fi
  [[ "$PORT_CONFIG_VALID" == 1 ]] || return 0
  if ( PORT="$HTTP_PORT"; port_open ); then
    if ( PORT="$HTTP_PORT"; own_listener ); then
      echo "HTTP 监听: 127.0.0.1:${HTTP_PORT}"
    else
      echo "HTTP 端口由其他进程占用: ${HTTP_PORT}"
    fi
  else
    echo "HTTP 未监听: ${HTTP_PORT}"
  fi
  if port_open; then
    local pid cmd
    if own_listener; then
      echo "SOCKS5 监听: 127.0.0.1:${PORT}"
    else
      echo "SOCKS5 监听: 127.0.0.1:${PORT} 已被其他进程占用"
    fi
    pid="$(listener_pid)"
    if [[ -n "$pid" && -r "/proc/${pid}/cmdline" ]]; then
      cmd="$(pid_cmdline "$pid")"
      if [[ -n "$cmd" ]]; then
        echo "进程 PID: ${pid}"
      fi
    fi
  else
    echo "SOCKS5 监听: 127.0.0.1:${PORT} 未在监听"
  fi
}

usage() {
  cat <<EOF
用法: $0 <命令>

  start    按 config/active.txt 启动。已在监听时不重复启动。断开远程连接后继续运行
  stop     停止本项目核心及双入口。依赖该代理的程序随即无法经该代理出网
  restart  关闭监听后按 config/active.txt 再启动，然后报告连接是否正常
  status   查看线路、开机自启、终端自动接入代理与监听。不写入日志
  test     分别检查 HTTP/HTTPS 经 HTTP 入口及 HTTPS 经 SOCKS5 入口，每个入口各显示连接结果及访问 ${PROBE_URL} 的首字节耗时。不改线路，也不启停监听
  switch   询问后切换 vless / hysteria2 / vmess 并保留。选中当前线路时按重启处理。监听起来后报告连接是否正常
  boot     只询问后开启或关闭开机自启。不启动、不停止当前监听
  terminal 询问后开启或关闭新终端自动接入代理。不开启、不关闭监听
  log      持续查看 ${LOG}
EOF
}

main() {
  case "${1:-}" in
    start)
      lock_management
      ensure_port
      FRESH_START=0
      start_proxy
      if [[ "${FRESH_START:-0}" -eq 1 ]]; then
        report_connection || true
      fi
      ;;
    stop) lock_management; stop_proxy ;;
    restart)
      lock_management
      ensure_port
      _xray_check_available_ports "$ROOT" "$SOCKS_PORT" "$HTTP_PORT"
      FRESH_START=0
      stop_proxy
      start_proxy
      report_connection || true
      ;;
    test) report_connection ;;
    switch) switch_xray ;;
    boot) boot_xray ;;
    terminal) terminal_xray ;;
    status) status_xray ;;
    log) tail -n 50 -f "$LOG" ;;
    __write_proxychains) lock_management; ensure_port; _xray_check_running_ports "$ROOT" "$SOCKS_PORT" "$HTTP_PORT"; sync_proxychains; printf '%s %s\n' "$SOCKS_PORT" "$HTTP_PORT" ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
