#!/bin/bash
# mymux -- SessionStart hook
# Reads the cwd from Claude Code's stdin JSON and sends it to the app
# via the IPC Unix domain socket. Runs on both startup and resume.

INPUT=$(cat)

CWD=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null)

if [ -z "$CWD" ] || [ -z "$MYMUX_TERMINAL_ID" ] || [ -z "$MYMUX_SOCKET_PATH" ]; then
    exit 0
fi

python3 -c "
import socket, json
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    sock.connect('$MYMUX_SOCKET_PATH')
    hello = json.dumps({'type':'hello','terminal_id':'$MYMUX_TERMINAL_ID','version':1}) + '\n'
    sock.sendall(hello.encode())
    sock.recv(4096)
    msg = json.dumps({'type':'set_working_directory','terminal_id':'$MYMUX_TERMINAL_ID','path':'$CWD','req_id':'hook-1'}) + '\n'
    sock.sendall(msg.encode())
    sock.recv(4096)
    sock.close()
except Exception:
    pass
" 2>/dev/null
exit 0
