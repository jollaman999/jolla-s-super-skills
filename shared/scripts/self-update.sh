#!/usr/bin/env bash
# 설치한 skills 를 원격(origin/main)에 맞춰 둔다. 세션 시작 훅이 check-install.sh 다음에 부른다.
# 조건이 맞을 때만 fast-forward 로 당기고, 안 맞으면 아무것도 안 바꾸고 이유를 한 줄 낸다.
#
# usage: self-update.sh [설정디렉터리] [--quiet] [--now]
#   설정디렉터리 : 기본 $CLAUDE_CONFIG_DIR, 없으면 ~/.claude. 프로젝트 설치면 <프로젝트>/.claude
#   --quiet      : 업데이트했거나 못 했을 때만 출력한다 (SessionStart 훅이 쓰는 형태)
#                  훅이 부르면(CLAUDE_PROJECT_DIR 가 있고 표준 출력이 터미널이 아님) 알림을 훅 JSON 하나로 낸다.
#                  systemMessage 는 사용자 화면에, additionalContext 는 Claude 맥락에 간다
#   --now        : 원격 확인 주기를 무시하고 지금 원격을 확인한다. 받을 때까지 기다린다 (최대 60초)
#
# 환경 변수
#   SELF_UPDATE_CHECK_SEC : 원격 확인 주기(초). 기본 3600 (1시간)
#
# 하는 일
#   0) 훅에서 불렸으면 바로 앞 check-install.sh 가 넘긴 링크 깨짐 알림(.jolla-skills.broken)을 맨 앞에 싣고 지운다
#   1) 뒤에서 돈 업데이트가 남긴 알림(.jolla-skills.pending)이 있으면 먼저 내고 지운다. --quiet 여도 낸다
#   2) 설치 기록에 autoupdate=off 가 있으면 더는 아무것도 안 한다
#      뒤에서 돈 원격 확인이 실패했으면 그 이유를 한 줄 낸다. --quiet 에서는 같은 실패가 이어지는 동안 한 번만 낸다
#   3) 이미 받아 둔 origin/main 과 비교한다. 네트워크는 안 쓴다
#      뒤처졌고 조건이 맞으면 git merge --ff-only 로 당긴다
#      조건: 브랜치 main, 추적 파일에 커밋 안 한 변경 없음, origin/main 에 없는 로컬 커밋 없음,
#            다른 업데이트가 진행 중이 아님
#      안 맞으면 이유를 한 줄 낸다. --quiet 에서는 같은 원격 커밋에 대해 한 번만 낸다
#   4) 복사 설치면 repo 가 기록의 commit= 보다 앞서 있을 때 install.sh --copy 를 뒤에서 다시 돌린다
#      링크 설치면 당긴 뒤 why-hwp 받기를 뒤에서 돌린다
#   5) 마지막 원격 확인이 주기보다 오래됐으면 git fetch 를 떼어서 띄운다. 기다리지 않는다
#      받아 온 직후 그 프로세스가 3) 4) 를 똑같이 한다 (복사본 재설치는 그 자리에서 끝까지).
#      화면에 쓸 수 없으므로 알림은 .jolla-skills.pending 에 덧붙이고, 다음 세션 시작 때 1) 이 낸다
#
# 설정디렉터리에 두는 것 (install.sh --uninstall 이 지운다)
#   .jolla-skills.lastcheck   마지막으로 원격 확인을 띄운 시각 (epoch 초)
#   .jolla-skills.notified    못 당긴다고 마지막으로 알린 것
#   .jolla-skills.pending     뒤에서 돈 업데이트가 남긴 알림. 다음 세션 시작 때 내고 지운다
#   .jolla-skills.lock        업데이트 중 잠금. 동시에 시작한 세션 중 하나만 당긴다
#   .jolla-skills.broken      check-install.sh 가 훅에서 넘긴 링크 깨짐 알림. 같은 훅의 이 스크립트가 내고 지운다
#   .jolla-skills.fetchfail   뒤에서 돈 원격 확인의 실패 이유. 알렸으면 둘째 줄에 told. 한 번 성공하면 지운다
#   .jolla-skills.fetch.log   뒤에서 돌린 git fetch 와 그 뒤 비교의 마지막 출력
#   .jolla-skills.install.log 뒤에서 돌린 재설치·why-hwp 받기의 마지막 출력
#
# 끄기: 설치 기록(<설정디렉터리>/.jolla-skills.manifest)에 autoupdate=off 한 줄을 넣는다
#
# exit: 0=최신·업데이트함·건너뜀  1=뒤처졌는데 업데이트하지 못함  2=사용법 오류, 설치 기록이나 repo 없음
#       세션 시작 훅은 이 값과 상관없이 0 으로 끝난다
set -uo pipefail

CHECK_SEC="${SELF_UPDATE_CHECK_SEC:-3600}"   # 원격 확인 주기 1시간
case "$CHECK_SEC" in ''|*[!0-9]*) CHECK_SEC=3600 ;; esac
FETCH_TO=60              # git fetch 상한
BG_TO=300                # 뒤에서 도는 재설치·why-hwp 받기 상한
STALE_MIN=15             # 이보다 오래된 잠금은 죽은 실행이 남긴 것으로 본다. BG_TO 보다 길어야 한다
LOCK_WAIT=30             # 받아 온 뒤 잠금을 기다리는 횟수 (1초 간격)

QUIET=0; NOW=0; BG=""; CFG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --quiet|-q)     QUIET=1 ;;
    --now)          NOW=1 ;;
    --bg-fetch)     BG=fetch ;;        # 내부용: 떼어서 띄운 원격 확인. 받아 온 뒤 비교·당기기까지 한다
    --bg-reinstall) BG=reinstall ;;    # 내부용: 떼어서 띄운 복사본 재설치. 잠금을 넘겨받는다
    --bg-hwp)       BG=hwp ;;          # 내부용: 떼어서 띄운 why-hwp 받기
    -h|--help)      sed -n '2,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)             echo "모르는 옵션: $1" >&2; sed -n '5,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
    *)              CFG="$1" ;;
  esac
  shift
done
CFG="${CFG:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
MANIFEST="$CFG/.jolla-skills.manifest"
LASTCHECK="$CFG/.jolla-skills.lastcheck"
NOTIFIED="$CFG/.jolla-skills.notified"
PENDING="$CFG/.jolla-skills.pending"
LOCK="$CFG/.jolla-skills.lock"
BROKEN_NOTE="$CFG/.jolla-skills.broken"
FETCHFAIL="$CFG/.jolla-skills.fetchfail"
FETCH_LOG="$CFG/.jolla-skills.fetch.log"
INSTALL_LOG="$CFG/.jolla-skills.install.log"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

export GIT_TERMINAL_PROMPT=0       # 자격 증명을 물으며 멈추지 않게 한다

say(){ [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# SessionStart 훅의 평문 출력은 Claude 맥락에만 가고 사용자 화면에는 안 뜬다.
# 훅이 부를 때는 알림을 모았다가 끝에서 JSON 하나로 낸다. 터미널에서 --quiet 로 돌리면 평문 그대로다.
HOOK=0
[ "$QUIET" -eq 1 ] && [ -z "$BG" ] && [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ ! -t 1 ] && HOOK=1
HOOK_MSG=""

# 알림 한 줄. --quiet 이어도 낸다. 뒤에서 돌 때는 화면이 없으므로 다음 세션 시작이 낼 수 있게 pending 에도 덧붙인다.
emit() {
  [ -n "$BG" ] && printf '%s\n' "$*" >> "$PENDING"
  if [ "$HOOK" -eq 1 ]; then HOOK_MSG="$HOOK_MSG$*"$'\n'; else printf '%s\n' "$*"; fi
}

# 표준 입력을 JSON 문자열 하나로 바꾼다. python 이 없는 Git Bash 에서도 돌게 awk 로 한다.
# 바이트 단위로 보므로 한글(UTF-8)은 그대로 지나가고, 따옴표·역슬래시·제어 문자만 바꾼다. 마지막 줄바꿈은 뺀다.
json_str() {
  LC_ALL=C awk '
    BEGIN {
      for (i = 1; i < 32; i++) esc[sprintf("%c", i)] = sprintf("\\u%04x", i)
      esc["\t"] = "\\t"; esc["\r"] = "\\r"; esc["\""] = "\\\""; esc["\\"] = "\\\\"
    }
    {
      s = ""; n = length($0)
      for (i = 1; i <= n; i++) { c = substr($0, i, 1); s = s ((c in esc) ? esc[c] : c) }
      out = (NR > 1) ? out "\\n" s : s
    }
    END { printf "\"%s\"", out }'
}

# 모은 알림을 훅 JSON 으로 낸다. 알릴 것이 없으면 아무것도 안 낸다.
hook_flush() {
  [ "$HOOK" -eq 1 ] && [ -n "$HOOK_MSG" ] || return 0
  local m
  m=$(printf '%s' "${HOOK_MSG%$'\n'}" | json_str)
  printf '{"systemMessage":%s,"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "$m" "$m"
}

TIMEOUT_BIN=""
for c in timeout gtimeout; do have "$c" && { TIMEOUT_BIN="$c"; break; }; done

# 상한 없는 네트워크 명령은 금지다. timeout(1) 이 없으면 직접 건다.
run_to() { # <초> <명령...>   rc 124 = 시간초과
  if [ -n "$TIMEOUT_BIN" ]; then "$TIMEOUT_BIN" "$@"; return $?; fi
  local secs="$1"; shift
  local pid wd rc
  set -m                          # 자식을 별도 프로세스 그룹으로: 손자까지 같이 죽인다
  "$@" & pid=$!
  set +m
  ( sleep "$secs"; kill -TERM -"$pid" 2>/dev/null
    sleep 2;       kill -KILL -"$pid" 2>/dev/null ) >/dev/null 2>&1 & wd=$!
  wait "$pid"; rc=$?
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  [ "$rc" -ge 128 ] && rc=124
  return "$rc"
}

# 훅을 기다리게 하지 않는다. 표준 입출력을 전부 파일로 돌려야 Claude Code 가 훅 출력의 끝을 바로 본다.
# setsid 가 없으면(Git Bash, macOS) 별도 프로세스 그룹으로 띄워 훅이 끝날 때 같이 죽지 않게 한다.
detach() { # <로그> <명령...>
  local log="$1"; shift
  if have setsid; then
    setsid "$@" </dev/null >"$log" 2>&1 &
  else
    set -m
    "$@" </dev/null >"$log" 2>&1 &
    set +m
  fi
}

g() { git -C "$REPO" "$@"; }
short() { g rev-parse --short "$1" 2>/dev/null || printf '%s' "${1:0:7}"; }

# 잠금은 noclobber 로 만든다. 파일이 이미 있으면 만들기가 실패하므로 둘 중 하나만 잡는다.
LOCKED=0; HANDED=0
take_lock() {
  if ( set -o noclobber; printf '%s\n' "$$" > "$LOCK" ) 2>/dev/null; then LOCKED=1; return 0; fi
  if [ -n "$(find "$LOCK" -mmin +"$STALE_MIN" 2>/dev/null)" ]; then
    rm -f "$LOCK"
    if ( set -o noclobber; printf '%s\n' "$$" > "$LOCK" ) 2>/dev/null; then LOCKED=1; return 0; fi
  fi
  return 1
}
release_lock() { [ "$LOCKED" -eq 1 ] && [ "$HANDED" -eq 0 ] && rm -f "$LOCK"; }

# pending 은 잠금을 쥔 쪽만 쓰고 지운다. 그래서 덧붙이는 중에 지워 줄을 잃는 일이 없다.
flush_pending() {
  [ -e "$PENDING" ] || return 0
  if [ "$HOOK" -eq 1 ]; then HOOK_MSG="$HOOK_MSG$(cat "$PENDING")"$'\n'; else cat "$PENDING"; fi
  rm -f "$PENDING"
}

# 원격 확인 실패 이유 한 줄. git 이 낸 첫 줄(인증 거부, 이름 풀이 실패 등)을 쓴다.
fetch_fail_reason() { # <rc> <git 출력>
  local line
  line=$(printf '%s\n' "$2" | tr -d '\r' | sed -n '/[^[:space:]]/{p;q;}')
  if [ "$1" -eq 124 ]; then printf '%s초 안에 끝나지 않았습니다 (시간 초과)%s' "$FETCH_TO" "${line:+: $line}"
  elif [ -n "$line" ]; then printf '%s' "$line"
  else printf 'git fetch 가 rc=%s 로 끝났습니다' "$1"; fi
}

# 같은 이유면 그대로 둬서 이미 알렸다는 표시(told)를 지킨다. 이유가 바뀌면 새 실패로 보고 다시 알린다.
record_fetch_fail() { # <이유>
  [ "$(sed -n 1p "$FETCHFAIL" 2>/dev/null)" = "$1" ] || printf '%s\n' "$1" > "$FETCHFAIL"
}

manifest_get() { sed -n "s/^$1=//p" "$MANIFEST" 2>/dev/null | head -1; }

# 같은 것을 세션마다 다시 알리지 않는다. 손으로 돌릴 때(--quiet 없음)는 매번 낸다.
notify_once() { # <열쇠> <문장>
  if { [ "$QUIET" -eq 1 ] || [ -n "$BG" ]; } && [ "$(cat "$NOTIFIED" 2>/dev/null)" = "$1" ]; then return; fi
  printf '%s\n' "$1" > "$NOTIFIED"
  emit "$2"
}

reinstall_args() { # 기록과 같은 범위·방식
  if [ "$SCOPE" = project ]; then printf '%s\n' --copy --yes --project "$(dirname "$CFG")"
  else printf '%s\n' --copy --yes --global; fi
}

# 복사본을 기록과 같은 범위로 다시 깐다. 잠금을 쥔 채 부른다. 마지막 줄은 "완료" 나 "실패 rc=N"
do_reinstall() {
  local args=() a rc
  while IFS= read -r a; do args+=("$a"); done < <(reinstall_args)
  run_to "$BG_TO" env CLAUDE_CONFIG_DIR="$CFG" bash "$REPO/install.sh" "${args[@]}"
  rc=$?
  [ "$rc" -eq 0 ] && echo "완료" || echo "실패 rc=$rc"
  return "$rc"
}

# 받아 둔 origin/main 과 비교하고 조건이 맞으면 fast-forward 한다. 네트워크는 안 쓴다.
# 세션 시작과, 뒤에서 받아 온 직후가 같이 쓴다. 잠금을 쥔 채 부른다.
# 못 당기면 이유를 알리고, 당겼을 때의 알림은 부른 쪽이 낸다 (복사본 재설치 문구가 달라서).
# 남기는 것: CUR(당겼으면 새 HEAD) PREV(당기기 전 HEAD) REMOTE BEHIND UPDATED
# return: 0=최신·당김·비교할 것 없음  1=뒤처졌는데 못 당김  2=HEAD 없음
CUR=""; PREV=""; REMOTE=""; BEHIND=0; UPDATED=0
compare_pull() {
  local ahead branch reason hint out
  CUR=$(g rev-parse -q --verify HEAD 2>/dev/null); PREV="$CUR"
  REMOTE=$(g rev-parse -q --verify "refs/remotes/origin/main^{commit}" 2>/dev/null)
  BEHIND=0; UPDATED=0
  if [ -z "$CUR" ]; then
    say "repo 에 HEAD 가 없습니다: $REPO"
    return 2
  fi
  if [ -z "$REMOTE" ]; then
    say "받아 둔 origin/main 이 아직 없습니다. 다음 원격 확인 뒤에 비교합니다"
    return 0
  fi
  BEHIND=$(g rev-list --count "HEAD..$REMOTE" 2>/dev/null || echo 0)
  ahead=$(g rev-list --count "$REMOTE..HEAD" 2>/dev/null || echo 0)
  if [ "$BEHIND" -eq 0 ]; then
    say "최신입니다 ($(short "$CUR"))"
    return 0
  fi
  branch=$(g symbolic-ref --short -q HEAD 2>/dev/null)
  reason=""; hint="git -C $REPO pull --ff-only"
  if [ "$branch" != main ]; then
    reason="브랜치가 main 이 아니고 ${branch:-분리된 HEAD} 라서"
    hint="git -C $REPO switch main && git -C $REPO pull --ff-only"
  elif [ "$ahead" -gt 0 ]; then
    reason="origin/main 에 없는 로컬 커밋이 ${ahead}개 있어서"
    hint="git -C $REPO pull --rebase"
  elif [ -n "$(g status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    reason="추적 파일에 커밋하지 않은 변경이 있어서"
  else
    out=$(LC_ALL=C git -C "$REPO" merge --ff-only --quiet "$REMOTE" 2>&1 </dev/null)
    if [ $? -eq 0 ]; then
      UPDATED=1
      CUR="$REMOTE"
      return 0
    elif printf '%s' "$out" | grep -q "untracked working tree files would be overwritten"; then
      reason="추적하지 않는 파일($(printf '%s\n' "$out" | sed -n 's/^[[:space:]]\{1,\}//p' | head -1))을 덮어써야 해서"
      hint="그 파일을 옮긴 뒤 git -C $REPO pull --ff-only"
    else
      reason="git merge --ff-only 가 실패해서 ($(printf '%s\n' "$out" | head -1))"
    fi
  fi
  notify_once "$REMOTE" "skills 가 원격보다 ${BEHIND}커밋 뒤처졌지만 $reason 업데이트하지 않았습니다. 직접: $hint"
  return 1
}

updated_msg() { printf 'skills 를 %s → %s 로 업데이트했습니다 (커밋 %s개)' "$(short "$PREV")" "$(short "$CUR")" "$BEHIND"; }

bg_main() {
  local rc
  case "$BG" in
    fetch)
      local out
      out=$(run_to "$FETCH_TO" git -C "$REPO" fetch --quiet origin "+refs/heads/main:refs/remotes/origin/main" 2>&1 </dev/null)
      rc=$?
      [ -n "$out" ] && printf '%s\n' "$out"
      echo "rc=$rc"
      if [ "$rc" -ne 0 ]; then
        record_fetch_fail "$(fetch_fail_reason "$rc" "$out")"
        return 0
      fi
      rm -f "$FETCHFAIL"
      # 세션 시작은 잠금을 쥔 채 이 프로세스를 띄운다. 풀릴 때까지 기다린 뒤 받은 것을 바로 비교한다.
      for _ in $(seq 1 "$LOCK_WAIT"); do
        take_lock && break
        sleep 1
      done
      if [ "$LOCKED" -eq 0 ]; then
        echo "잠금($LOCK)을 ${LOCK_WAIT}초 동안 못 잡았습니다. 비교는 다음 세션 시작에 맡깁니다"
        return 0
      fi
      trap release_lock EXIT
      compare_pull
      [ "$UPDATED" -eq 1 ] || return 0
      if [ "$MODE" = copy ]; then
        # 이미 뒤에서 돌고 있으므로 재설치도 여기서 끝까지 하고 결과를 알린다.
        if do_reinstall >"$INSTALL_LOG" 2>&1; then
          emit "$(updated_msg). 복사본도 다시 설치했습니다"
        else
          # 세션 시작이 다시 시도할 때 같은 실패를 또 알리지 않게 그쪽 열쇠를 남긴다.
          printf 'copy:%s\n' "$CUR" > "$NOTIFIED"
          emit "$(updated_msg). 그런데 복사본을 다시 설치하지 못했습니다 ($(tail -1 "$INSTALL_LOG")). 로그: $INSTALL_LOG. 다음 세션 시작 때 다시 시도합니다"
        fi
      else
        detach "$INSTALL_LOG" bash "$BGS" --bg-hwp "$CFG"
        emit "$(updated_msg)"
      fi
      ;;
    reinstall)
      # 부른 쪽이 잡은 잠금을 넘겨받았다. 끝나면 푼다.
      do_reinstall
      rm -f "$LOCK"
      ;;
    hwp)
      local fw="$CFG/skills/doc-write/scripts/fetch-why-hwp.sh"
      [ -f "$fw" ] && run_to "$BG_TO" bash "$fw"
      echo "rc=$?"
      ;;
  esac
  return 0
}

main() {
  # 링크 깨짐 알림을 업데이트 알림보다 먼저 싣는다. 아래에서 어느 길로 일찍 끝나도 사라지지 않게 맨 앞에서 읽는다.
  if [ "$HOOK" -eq 1 ] && [ -f "$BROKEN_NOTE" ]; then
    HOOK_MSG="$(cat "$BROKEN_NOTE")"$'\n'
    rm -f "$BROKEN_NOTE"
  fi
  if [ ! -f "$MANIFEST" ]; then
    say "설치 기록이 없습니다: $MANIFEST"
    return 2
  fi
  MODE=$(manifest_get mode); REPO=$(manifest_get repo); SCOPE=$(manifest_get scope)
  COMMIT=$(manifest_get commit); AUTO=$(manifest_get autoupdate)

  # 뒤에서 돈 업데이트의 결과를 먼저 낸다. 잠금을 쥔 쪽만 pending 을 읽고 지운다.
  if [ -z "$BG" ]; then
    if ! take_lock; then
      say "다른 업데이트가 진행 중이라 건너뜁니다 ($LOCK)"
      return 0
    fi
    trap release_lock EXIT
    flush_pending
  fi

  if [ "$AUTO" = off ]; then
    say "설치 기록에 autoupdate=off 가 있어 건너뜁니다: $MANIFEST"
    return 0
  fi
  if [ -z "$REPO" ] || ! g rev-parse --git-dir >/dev/null 2>&1; then
    say "repo 가 git 저장소가 아니거나 없습니다: ${REPO:-?}"
    return 2
  fi

  # 뒤에서 돌 일은 repo 의 이 스크립트로 띄운다. 복사 설치의 재설치가 설치본($SELF)을 지우고 다시 놓기 때문이다.
  BGS="$REPO/shared/scripts/self-update.sh"
  [ -f "$BGS" ] || BGS="$SELF"

  [ -n "$BG" ] && { bg_main; return 0; }

  local now last rc=0
  now=$(date +%s)

  # 뒤에서 돈 원격 확인이 실패했으면 이유를 알린다. 실패가 이어지는 동안은 한 번만 낸다.
  if [ -f "$FETCHFAIL" ] && [ "$NOW" -eq 0 ]; then
    if [ "$QUIET" -eq 0 ] || [ "$(sed -n 2p "$FETCHFAIL")" != told ]; then
      emit "skills 원격 확인(git fetch)에 실패했습니다: $(sed -n 1p "$FETCHFAIL") (로그: $FETCH_LOG)"
      [ "$QUIET" -eq 1 ] && printf 'told\n' >> "$FETCHFAIL"
    fi
  fi

  if [ "$NOW" -eq 1 ]; then
    say "원격을 확인합니다: git -C $REPO fetch origin main"
    printf '%s\n' "$now" > "$LASTCHECK"
    if run_to "$FETCH_TO" git -C "$REPO" fetch --quiet origin \
         "+refs/heads/main:refs/remotes/origin/main" </dev/null; then
      rm -f "$FETCHFAIL"
    else
      say "  원격 확인에 실패했습니다. 받아 둔 origin/main 과 비교합니다"
    fi
  fi

  compare_pull; rc=$?
  if [ "$UPDATED" -eq 1 ]; then
    if [ "$MODE" = copy ]; then
      emit "$(updated_msg). 복사본은 뒤에서 다시 설치합니다"
    else
      emit "$(updated_msg)"
    fi
  fi

  if [ "$NOW" -eq 0 ]; then
    last=$(cat "$LASTCHECK" 2>/dev/null)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    if [ $((now - last)) -ge "$CHECK_SEC" ]; then
      printf '%s\n' "$now" > "$LASTCHECK"
      detach "$FETCH_LOG" bash "$BGS" --bg-fetch "$CFG"
      say "원격 확인을 뒤에서 띄웠습니다. 받아 오면 바로 비교해 당기고, 알림은 다음 세션 시작 때 냅니다"
    else
      say "원격 확인은 $(( (now - last) / 60 ))분 전에 했습니다 (주기 $((CHECK_SEC / 60))분)"
    fi
  fi

  # 복사 설치는 repo 를 당겨도 설치본이 그대로다. 기록의 commit= 보다 repo 가 앞서면 다시 깐다.
  if [ "$MODE" = copy ] && [ -n "$COMMIT" ] && [ -n "$CUR" ] && [ "$COMMIT" != "$CUR" ] \
     && g merge-base --is-ancestor "$COMMIT" "$CUR" 2>/dev/null; then
    if [ "$UPDATED" -eq 0 ]; then
      if tail -1 "$INSTALL_LOG" 2>/dev/null | grep -q '^실패'; then
        notify_once "copy:$CUR" "skills 복사본을 다시 설치하지 못했습니다 ($(tail -1 "$INSTALL_LOG")). 로그: $INSTALL_LOG. 다시 시도합니다"
        rc=1
      else
        notify_once "copy:$CUR" "skills 복사본을 repo 에 맞춰 다시 설치합니다 ($(short "$COMMIT") → $(short "$CUR"))"
      fi
    fi
    HANDED=1
    detach "$INSTALL_LOG" bash "$BGS" --bg-reinstall "$CFG"
  elif [ "$UPDATED" -eq 1 ] && [ "$MODE" != copy ]; then
    # 새 커밋이 why-hwp 최소 버전을 올렸을 수 있다. 받을 필요가 없으면 받지 않고 끝난다.
    detach "$INSTALL_LOG" bash "$BGS" --bg-hwp "$CFG"
  fi

  return "$rc"
}

# 복사 설치는 재설치가 이 파일을 지우고 다시 놓는다. 끝까지 읽어 둔 뒤 실행하도록 한 줄로 끝낸다.
main; rc=$?; hook_flush; exit "$rc"
