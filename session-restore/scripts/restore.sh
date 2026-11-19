#!/bin/bash
# snapshot.sh 가 적은 Claude Code 세션을 같은 이름·같은 디렉터리의 tmux 세션에서 다시 연다.
# 원래 tmux 밖(그냥 터미널)에서 돌던 세션도 tmux 세션으로 연다.
# usage: restore.sh [-n] [IN]   -n 이면 열지 않고 무엇을 열지만 보여준다
# 같은 이름의 tmux 세션이 이미 있거나 디렉터리가 사라졌으면 건너뛴다.
# 연 뒤 패널에서 claude 가 실제로 도는지 15초까지 기다려 본다.
set -euo pipefail
DRY=0
if [ "${1:-}" = "-n" ]; then DRY=1; shift; fi
IN=${1:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-restore/last.tsv}

[ -s "$IN" ] || { echo "적어 둔 세션이 없습니다: $IN" >&2; exit 1; }
command -v tmux >/dev/null || { echo "tmux 가 없습니다" >&2; exit 1; }

echo "기록: $IN ($(date -r "$IN" '+%F %T'))"
OPENED=()
while IFS=$'\t' read -r name cwd sid label origin cmd; do
	if tmux has-session -t "=$name" 2>/dev/null; then
		echo "건너뜀 $name ($label): 같은 이름의 tmux 세션이 이미 있음"
		continue
	fi
	if [ ! -d "$cwd" ]; then
		echo "건너뜀 $name ($label): $cwd 가 없음"
		continue
	fi
	if [ "$DRY" = 1 ]; then
		echo "열 것  $name ($label, 원래 $origin) $cwd"
		continue
	fi
	tmux new-session -d -s "$name" -c "$cwd"
	tmux send-keys -t "=$name:" "$cmd" Enter
	OPENED+=("$name")
	echo "엶     $name ($label, 원래 $origin) $cwd"
done < "$IN"

[ "$DRY" = 1 ] || [ ${#OPENED[@]} -eq 0 ] && exit 0

# 연 것마다 패널의 현재 명령이 claude 로 바뀌었는지 본다
BAD=0
for name in "${OPENED[@]}"; do
	cur=
	for _ in $(seq 1 15); do
		cur=$(tmux display-message -p -t "=$name:" '#{pane_current_command}' 2>/dev/null || true)
		[ "$cur" = claude ] && break
		sleep 1
	done
	if [ "$cur" = claude ]; then
		echo "확인 $name: claude 실행 중"
	else
		echo "확인 $name: claude 가 안 보임 (지금 명령: ${cur:-없음}). tmux attach -t $name 으로 보세요"
		BAD=1
	fi
done
exit $BAD
