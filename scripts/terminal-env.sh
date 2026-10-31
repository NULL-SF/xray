# 仅使用 Bash 内建命令，旧 proxychains 配置损坏时也可解除本项目的预加载。
_xray_remove_preload() {
  local root="$1" kept="" part found=0
  local parts=()
  IFS=$' :\t' read -ra parts <<< "${LD_PRELOAD:-}"
  for part in "${parts[@]}"; do
    if [[ "$part" == "${root}/lib/libproxychains4.so" ]]; then
      found=1
    elif [[ -n "$part" ]]; then
      kept="${kept:+${kept}:}${part}"
    fi
  done
  if [[ "$found" == 1 ]]; then
    if [[ -n "$kept" ]]; then
      export LD_PRELOAD="$kept"
    else
      unset LD_PRELOAD
    fi
  fi
  if [[ "$found" == 1 || "${PROXYCHAINS_CONF_FILE:-}" == "${root}/runtime/proxychains.conf" || "${PROXYCHAINS_CONF_FILE:-}" == "${root}/tmp/proxychains.conf" ]]; then
    unset PROXYCHAINS_CONF_FILE PROXYCHAINS_QUIET_MODE
  fi
  return 0
}

# 只读加载：缺失、空白、非法端口按协议回退；状态查询不写文件。
_xray_load_ports() {
  local root="$1" kind value file fallback defaulted
  SOCKS_PORT_DEFAULTED=0 HTTP_PORT_DEFAULTED=0
  for kind in socks http; do
    file="$root/config/ports/$kind.txt"
    value="" defaulted=0
    if [[ -e "$file" && ( ! -f "$file" || ! -r "$file" ) ]]; then
      printf '端口配置不是可读的普通文件：%s\n' "$file" >&2
      return 1
    fi
    [[ ! -r "$file" ]] || value=$(<"$file")
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ "$kind" == socks ]]; then fallback=10808; else fallback=10809; fi
    if [[ ! "$value" =~ ^[0-9]{1,5}$ ]] || (( 10#$value < 1 || 10#$value > 65535 )); then
      value="$fallback"
      defaulted=1
    fi
    if [[ "$kind" == socks ]]; then
      SOCKS_PORT=$((10#$value))
      SOCKS_PORT_DEFAULTED="$defaulted"
    else
      HTTP_PORT=$((10#$value))
      HTTP_PORT_DEFAULTED="$defaulted"
    fi
  done
  [[ "$SOCKS_PORT" != "$HTTP_PORT" ]] || { printf 'SOCKS5 与 HTTP 端口不能相同（包括默认回退后冲突）。\n' >&2; return 1; }
}

# 仅启动/切换/终端接入时保存回退值；有效的用户配置保持不变。
_xray_ensure_ports() {
  local root="$1" kind defaulted value temporary label
  _xray_load_ports "$root" || return 1
  mkdir -p "$root/config/ports" || return 1
  for kind in socks http; do
    if [[ "$kind" == socks ]]; then
      defaulted="$SOCKS_PORT_DEFAULTED" value="$SOCKS_PORT"
    else
      defaulted="$HTTP_PORT_DEFAULTED" value="$HTTP_PORT"
    fi
    if [[ "$defaulted" == 1 ]]; then
      temporary=$(mktemp "$root/config/ports/.$kind.XXXXXX") || return 1
      if ! printf '%s\n' "$value" > "$temporary" || ! mv -f -- "$temporary" "$root/config/ports/$kind.txt"; then
        rm -f -- "$temporary"
        return 1
      fi
      if [[ "$kind" == socks ]]; then label=SOCKS5; else label=HTTP; fi
      printf '%s 端口配置缺失、为空或无效，已写入默认值 %s。\n' "$label" "$value" >&2
    fi
  done
}

# 仅核对本项目运行进程、生成配置和双入口；不启停服务，也不证明节点可联网。
_xray_check_running_ports() {
  _xray_check_ports ready "$1" "$2" "$3"
}

_xray_check_available_ports() {
  _xray_check_ports available "$1" "$2" "$3"
}

_xray_check_ports() {
  python3 - "$@" <<'PY_PORT_CHECK'
#!/usr/bin/env python3
"""检查本项目进程拥有的监听套接字，或在停止旧进程前预检新端口。"""
import json
from pathlib import Path
import socket
import sys


def owned_ports(root):
    pid = int((root / 'runtime/xray.pid').read_text())
    proc = Path(f'/proc/{pid}')
    command = (proc / 'cmdline').read_bytes().split(b'\0')
    expected = [str(root / 'bin/xray_26.1.23'), 'run', '-config', str(root / 'runtime/xray_config.json')]
    if command != [arg.encode() for arg in expected] + [b'']:
        raise ValueError('未找到本项目正在运行的核心')
    inodes = set()
    for fd in (proc / 'fd').iterdir():
        try:
            target = fd.readlink().as_posix()
        except FileNotFoundError:
            continue  # 核心可能正在关闭另一个连接。
        if target.startswith('socket:['):
            inodes.add(target[8:-1])
    ports = set()
    for row in (proc / 'net/tcp').read_text().splitlines()[1:]:
        fields = row.split()
        host, port = fields[1].split(':')
        if fields[3] == '0A' and host == '0100007F' and fields[9] in inodes:
            ports.add(int(port, 16))
    return ports


def main():
    mode, directory, socks, http = sys.argv[1:]
    root = Path(directory)
    expected = {'socks': int(socks), 'http': int(http)}
    if mode == 'ready':
        ports = owned_ports(root)
        cfg = json.loads((root / 'runtime/xray_config.json').read_text())
        actual = {i['protocol']: i['port'] for i in cfg['inbounds']
                  if i.get('listen') == '127.0.0.1'}
        if actual != expected:
            raise ValueError('运行入口与端口配置不一致（可能尚未启用双入口或修改后未重启）')
        if not set(expected.values()) <= ports:
            raise ValueError('双入口未全部由本项目核心监听')
    elif mode == 'available':
        try:
            ports = owned_ports(root)
        except (OSError, ValueError, IndexError):
            ports = set()
        for kind, port in expected.items():
            if port in ports:
                continue
            try:
                with socket.socket() as sock:
                    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                    sock.bind(('127.0.0.1', port))
                    sock.listen(1)
            except OSError as exc:
                label = {'socks': 'SOCKS5', 'http': 'HTTP'}[kind]
                raise ValueError(f'{label} 端口 127.0.0.1:{port} 不可用：{exc.strerror}；未停止现有服务') from None
    else:
        raise ValueError('未知端口检查模式')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, IndexError, TypeError) as error:
        print(f'代理入口检查失败：{error}', file=sys.stderr)
        sys.exit(1)
PY_PORT_CHECK
}
