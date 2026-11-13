#!/usr/bin/env bash
# 설치한 skills 를 원격(origin/main)에 맞춰 둔다. 세션 시작 훅이 check-install.sh 다음에 부른다.
# 조건이 맞을 때만 fast-forward 로 당기고, 안 맞으면 아무것도 안 바꾸고 이유를 한 줄 낸다.
#
# usage: self-update.sh [설정디렉터리] [--quiet] [--now]
#   설정디렉터리 : 기본 $CLAUDE_CONFIG_DIR, 없으면 ~/.claude. 프로젝트 설치면 <프로젝트>/.claude
#   --quiet      : 업데이트했거나 못 했을 때만 출력한다 (SessionStart 훅이 쓰는 형태)
#   --now        : 6시간 주기를 무시하고 지금 원격을 확인한다. 받을 때까지 기다린다 (최대 60초)
#
# 하는 일
#   1) 설치 기록에 autoupdate=off 가 있으면 아무것도 안 한다
#   2) 이미 받아 둔 origin/main 과 비교한다. 네트워크는 안 쓴다
#      뒤처졌고 조건이 맞으면 git merge --ff-only 로 당긴다
#      조건: 브랜치 main, 추적 파일에 커밋 안 한 변경 없음, origin/main 에 없는 로컬 커밋 없음,
#            다른 업데이트가 진행 중이 아님
#      안 맞으면 이유를 한 줄 낸다. --quiet 에서는 같은 원격 커밋에 대해 한 번만 낸다
#   3) 복사 설치면 repo 가 기록의 commit= 보다 앞서 있을 때 install.sh --copy 를 뒤에서 다시 돌린다
#      링크 설치면 당긴 뒤 why-hwp 받기를 뒤에서 돌린다
#   4) 마지막 원격 확인이 6시간보다 오래됐으면 git fetch 를 떼어서 띄운다. 기다리지 않는다
#
# 설정디렉터리에 두는 것 (install.sh --uninstall 이 지운다)
#   .jolla-skills.lastcheck   마지막으로 원격 확인을 띄운 시각 (epoch 초)
#   .jolla-skills.notified    못 당긴다고 마지막으로 알린 것
#   .jolla-skills.lock        업데이트 중 잠금. 동시에 시작한 세션 중 하나만 당긴다
#   .jolla-skills.fetch.log   뒤에서 돌린 git fetch 의 마지막 출력
#   .jolla-skills.install.log 뒤에서 돌린 재설치·why-hwp 받기의 마지막 출력
#
# 끄기: 설치 기록(<설정디렉터리>/.jolla-skills.manifest)에 autoupdate=off 한 줄을 넣는다
#
# exit: 0=최신·업데이트함·건너뜀  1=뒤처졌는데 업데이트하지 못함  2=사용법 오류, 설치 기록이나 repo 없음
#       세션 시작 훅은 이 값과 상관없이 0 으로 끝난다
set -uo pipefail

CHECK_SEC=21600          # 원격 확인 주기 6시간
FETCH_TO=60              # git fetch 상한
BG_TO=300                # 뒤에서 도는 재설치·why-hwp 받기 상한
STALE_MIN=15             # 이보다 오래된 잠금은 죽은 실행이 남긴 것으로 본다. BG_TO 보다 길어야 한다

QUIET=0; NOW=0; BG=""; CFG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --quiet|-q)     QUIET=1 ;;
    --now)          NOW=1 ;;
    --bg-fetch)     BG=fetch ;;        # 내부용: 떼어서 띄운 원격 확인
    --bg-reinstall) BG=reinstall ;;    # 내부용: 떼어서 띄운 복사본 재설치. 잠금을 넘겨받는다
    --bg-hwp)       BG=hwp ;;          # 내부용: 떼어서 띄운 why-hwp 받기
    -h|--help)      sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)             echo "모르는 옵션: $1" >&2; sed -n '5,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
    *)              CFG="$1" ;;
  esac
  shift
done
CFG="${CFG:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
MANIFEST="$CFG/.jolla-skills.manifest"
LASTCHECK="$CFG/.jolla-skills.lastcheck"
NOTIFIED="$CFG/.jolla-skills.notified"
LOCK="$CFG/.jolla-skills.lock"
FETCH_LOG="$CFG/.jolla-skills.fetch.log"
INSTALL_LOG="$CFG/.jolla-skills.install.log"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

export GIT_TERMINAL_PROMPT=0       # 자격 증명을 물으며 멈추지 않게 한다

say(){ [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }
tell(){ printf '%s\n' "$*"; }          # --quiet 이어도 내는 것
have() { command -v "$1" >/dev/null 2>&1; }

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

manifest_get() { sed -n "s/^$1=//p" "$MANIFEST" 2>/dev/null | head -1; }

# 같은 것을 세션마다 다시 알리지 않는다. 손으로 돌릴 때(--quiet 없음)는 매번 낸다.
notify_once() { # <열쇠> <문장>
  if [ "$QUIET" -eq 1 ] && [ "$(cat "$NOTIFIED" 2>/dev/null)" = "$1" ]; then return; fi
  printf '%s\n' "$1" > "$NOTIFIED"
  tell "$2"
}

reinstall_args() { # 기록과 같은 범위·방식
  if [ "$SCOPE" = project ]; then printf '%s\n' --copy --yes --project "$(dirname "$CFG")"
  else printf '%s\n' --copy --yes --global; fi
}

bg_main() {
  case "$BG" in
    fetch)
      run_to "$FETCH_TO" git -C "$REPO" fetch --quiet origin "+refs/heads/main:refs/remotes/origin/main"
      echo "rc=$?"
      ;;
    reinstall)
      # 부른 쪽이 잡은 잠금을 넘겨받았다. 끝나면 푼다.
      local args=() a rc
      while IFS= read -r a; do args+=("$a"); done < <(reinstall_args)
      run_to "$BG_TO" env CLAUDE_CONFIG_DIR="$CFG" bash "$REPO/install.sh" "${args[@]}"
      rc=$?
      [ "$rc" -eq 0 ] && echo "완료" || echo "실패 rc=$rc"
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
  if [ ! -f "$MANIFEST" ]; then
    say "설치 기록이 없습니다: $MANIFEST"
    return 2
  fi
  MODE=$(manifest_get mode); REPO=$(manifest_get repo); SCOPE=$(manifest_get scope)
  COMMIT=$(manifest_get commit); AUTO=$(manifest_get autoupdate)

  if [ "$AUTO" = off ]; then
    say "설치 기록에 autoupdate=off 가 있어 건너뜁니다: $MANIFEST"
    return 0
  fi
  if [ -z "$REPO" ] || ! g rev-parse --git-dir >/dev/null 2>&1; then
    say "repo 가 git 저장소가 아니거나 없습니다: ${REPO:-?}"
    return 2
  fi

  [ -n "$BG" ] && { bg_main; return 0; }

  # 뒤에서 돌 일은 repo 의 이 스크립트로 띄운다. 복사 설치의 재설치가 설치본($SELF)을 지우고 다시 놓기 때문이다.
  local bgs="$REPO/shared/scripts/self-update.sh"
  [ -f "$bgs" ] || bgs="$SELF"

  if ! take_lock; then
    say "다른 업데이트가 진행 중이라 건너뜁니다 ($LOCK)"
    return 0
  fi
  trap release_lock EXIT

  local now last rc=0 updated=0 head remote behind ahead branch reason hint out
  now=$(date +%s)

  if [ "$NOW" -eq 1 ]; then
    say "원격을 확인합니다: git -C $REPO fetch origin main"
    printf '%s\n' "$now" > "$LASTCHECK"
    if ! run_to "$FETCH_TO" git -C "$REPO" fetch --quiet origin \
         "+refs/heads/main:refs/remotes/origin/main" </dev/null; then
      say "  원격 확인에 실패했습니다. 받아 둔 origin/main 과 비교합니다"
    fi
  fi

  head=$(g rev-parse -q --verify HEAD 2>/dev/null)
  remote=$(g rev-parse -q --verify "refs/remotes/origin/main^{commit}" 2>/dev/null)
  if [ -z "$head" ]; then
    say "repo 에 HEAD 가 없습니다: $REPO"
    rc=2
  elif [ -z "$remote" ]; then
    say "받아 둔 origin/main 이 아직 없습니다. 다음 원격 확인 뒤에 비교합니다"
  else
    behind=$(g rev-list --count "HEAD..$remote" 2>/dev/null || echo 0)
    ahead=$(g rev-list --count "$remote..HEAD" 2>/dev/null || echo 0)
    if [ "$behind" -eq 0 ]; then
      say "최신입니다 ($(short "$head"))"
    else
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
        out=$(LC_ALL=C git -C "$REPO" merge --ff-only --quiet "$remote" 2>&1 </dev/null)
        if [ $? -eq 0 ]; then
          updated=1
          if [ "$MODE" = copy ]; then
            tell "skills 를 $(short "$head") → $(short "$remote") 로 업데이트했습니다 (커밋 ${behind}개). 복사본은 뒤에서 다시 설치합니다"
          else
            tell "skills 를 $(short "$head") → $(short "$remote") 로 업데이트했습니다 (커밋 ${behind}개)"
          fi
          head="$remote"
        elif printf '%s' "$out" | grep -q "untracked working tree files would be overwritten"; then
          reason="추적하지 않는 파일($(printf '%s\n' "$out" | sed -n 's/^[[:space:]]\{1,\}//p' | head -1))을 덮어써야 해서"
          hint="그 파일을 옮긴 뒤 git -C $REPO pull --ff-only"
        else
          reason="git merge --ff-only 가 실패해서 ($(printf '%s\n' "$out" | head -1))"
        fi
      fi
      if [ -n "$reason" ]; then
        notify_once "$remote" "skills 가 원격보다 ${behind}커밋 뒤처졌지만 $reason 업데이트하지 않았습니다. 직접: $hint"
        rc=1
      fi
    fi
  fi

  if [ "$NOW" -eq 0 ]; then
    last=$(cat "$LASTCHECK" 2>/dev/null)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    if [ $((now - last)) -ge "$CHECK_SEC" ]; then
      printf '%s\n' "$now" > "$LASTCHECK"
      detach "$FETCH_LOG" bash "$bgs" --bg-fetch "$CFG"
      say "원격 확인을 뒤에서 띄웠습니다. 결과는 다음 세션부터 씁니다"
    else
      say "원격 확인은 $(( (now - last) / 60 ))분 전에 했습니다 (주기 $((CHECK_SEC / 3600))시간)"
    fi
  fi

  # 복사 설치는 repo 를 당겨도 설치본이 그대로다. 기록의 commit= 보다 repo 가 앞서면 다시 깐다.
  if [ "$MODE" = copy ] && [ -n "$COMMIT" ] && [ -n "$head" ] && [ "$COMMIT" != "$head" ] \
     && g merge-base --is-ancestor "$COMMIT" "$head" 2>/dev/null; then
    if [ "$updated" -eq 0 ]; then
      if tail -1 "$INSTALL_LOG" 2>/dev/null | grep -q '^실패'; then
        notify_once "copy:$head" "skills 복사본을 다시 설치하지 못했습니다 ($(tail -1 "$INSTALL_LOG")). 로그: $INSTALL_LOG. 다시 시도합니다"
        rc=1
      else
        notify_once "copy:$head" "skills 복사본을 repo 에 맞춰 다시 설치합니다 ($(short "$COMMIT") → $(short "$head"))"
      fi
    fi
    HANDED=1
    detach "$INSTALL_LOG" bash "$bgs" --bg-reinstall "$CFG"
  elif [ "$updated" -eq 1 ] && [ "$MODE" != copy ]; then
    # 새 커밋이 why-hwp 최소 버전을 올렸을 수 있다. 받을 필요가 없으면 받지 않고 끝난다.
    detach "$INSTALL_LOG" bash "$bgs" --bg-hwp "$CFG"
  fi

  return "$rc"
}

# 복사 설치는 재설치가 이 파일을 지우고 다시 놓는다. 끝까지 읽어 둔 뒤 실행하도록 한 줄로 끝낸다.
main; exit $?
