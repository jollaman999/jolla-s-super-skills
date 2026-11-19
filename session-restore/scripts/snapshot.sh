#!/bin/bash
# 이 PC 에서 도는 Claude Code 세션을 적어 둔다. 재부팅 뒤 restore.sh 가 이것을 보고 다시 연다.
# tmux 안의 세션은 그 tmux 세션 이름으로, tmux 밖(그냥 터미널)의 세션은 Claude 세션 이름으로
# tmux 세션을 새로 만들어 열도록 적는다.
# usage: snapshot.sh [-n]      -n 이면 적지 않고 보여주기만 한다
# 칸: tmux 세션 이름, 작업 디렉터리, Claude 세션 ID, 세션 이름, 원래 자리(tmux/터미널),
#     실행할 claude 명령(--resume 포함)
set -euo pipefail
CFG=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
DIR=$CFG/session-restore
OUT=$DIR/last.tsv
DRY=0
[ "${1:-}" = "-n" ] && DRY=1

PANES=
if command -v tmux >/dev/null; then
	PANES=$(tmux list-panes -a -F '#{session_name}	#{pane_pid}' 2>/dev/null || true)
fi

ROWS=$(printf '%s\n' "$PANES" | SESS_DIR="$CFG/sessions" python3 -I -c '
import glob, json, os, re, shlex, sys

SESS = os.environ["SESS_DIR"]

def children(pid):
    try:
        with open(f"/proc/{pid}/task/{pid}/children") as f:
            return [int(x) for x in f.read().split()]
    except OSError:
        return []

def argv(pid):
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            return [a.decode() for a in f.read().split(b"\0") if a]
    except OSError:
        return []

def live_claude(pid):
    # 기록 파일만 남고 프로세스가 끝났거나 pid 가 다른 프로그램에 다시 쓰인 경우를 거른다
    a = argv(pid)
    return bool(a) and os.path.basename(a[0]) == "claude"

def record(pid):
    rec = os.path.join(SESS, f"{pid}.json")
    if not os.path.exists(rec) or not live_claude(pid):
        return None
    d = json.load(open(rec))
    if d.get("kind", "interactive") != "interactive":
        return None
    return d

def claude_under(pid):
    # 패널 프로세스부터 아래로 내려가며 Claude 세션 기록이 있는 첫 프로세스
    todo = [pid]
    while todo:
        p = todo.pop(0)
        d = record(p)
        if d:
            return p, d
        todo += children(p)
    return None, None

def resume_cmd(pid, sid):
    out, skip = [], False
    for a in argv(pid)[1:]:
        if skip:
            skip = False
            continue
        if a in ("-c", "--continue"):
            continue
        if a in ("-r", "--resume", "--session-id"):
            skip = True
            continue
        if a.startswith(("--resume=", "--session-id=")):
            continue
        out.append(a)
    return shlex.join(["claude", *out, "--resume", sid])

rows, seen, names = [], set(), set()

for line in sys.stdin:
    if not line.strip():
        continue
    name, pane_pid = line.rstrip("\n").split("\t")
    pid, d = claude_under(int(pane_pid))
    if not pid or pid in seen:
        continue
    seen.add(pid)
    names.add(name)
    rows.append([name, d["cwd"], d["sessionId"], d.get("name", ""), "tmux",
                 resume_cmd(pid, d["sessionId"])])

# tmux 밖의 세션. tmux 세션 이름에 못 쓰는 . 과 : 는 - 로 바꾸고, 겹치면 번호를 붙인다
for rec in sorted(glob.glob(os.path.join(SESS, "*.json"))):
    try:
        pid = int(os.path.basename(rec)[:-5])
    except ValueError:
        continue
    if pid in seen:
        continue
    d = record(pid)
    if not d:
        continue
    seen.add(pid)
    base = re.sub(r"[.:\s]", "-", d.get("name") or "claude-" + d["sessionId"][:8])
    name, n = base, 2
    while name in names:
        name, n = f"{base}-{n}", n + 1
    names.add(name)
    rows.append([name, d["cwd"], d["sessionId"], d.get("name", ""), "터미널",
                 resume_cmd(pid, d["sessionId"])])

for r in rows:
    print("\t".join(r))
')

if [ -z "$ROWS" ]; then
	echo "도는 Claude 세션이 없습니다"
	exit 0
fi

if [ "$DRY" = 1 ]; then
	printf '%s\n' "$ROWS" | awk -F'\t' '{printf "%-20s %-8s %-24s %s\n", $1, $5, $4, $2}'
	exit 0
fi

mkdir -p "$DIR"
printf '%s\n' "$ROWS" > "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
echo "$(wc -l < "$OUT") 개를 $OUT 에 적었습니다"
