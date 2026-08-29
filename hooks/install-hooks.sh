#!/usr/bin/env bash
# pre-commit + commit-msg 훅을 대상 repo 에 설치한다. 기존 훅이 있으면 체인해서 안 깨뜨린다.
#
# usage: install-hooks.sh <repo> [public|private]
#   프로필을 안 주면 gh 로 공개 여부를 확인해 정한다. 확인 불가면 private.
#     public  = 시크릿 + 내부 조직명 + 사설IP 차단
#     private = 시크릿(비밀번호·토큰·개인키)만 차단
#   em dash 와 커밋 메시지 규칙은 프로필과 무관하게 항상 검사한다.
set -uo pipefail
SRCDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Git Bash 의 ln -s 는 링크를 못 만들면 조용히 복사한다. 켜 두면 실패하므로 감지할 수 있다.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) export MSYS="${MSYS:+$MSYS }winsymlinks:nativestrict" ;;
esac
DIR="${1:?usage: install-hooks.sh <repo> [public|private]}"
WANT="${2:-}"

DIR=$(cd "$DIR" 2>/dev/null && pwd -P) || { echo "경로 없음: $1" >&2; exit 2; }
GITDIR=$(git -C "$DIR" rev-parse --git-dir 2>/dev/null) || { echo "git repo 아님: $DIR" >&2; exit 2; }
case "$GITDIR" in /*) ;; *) GITDIR="$DIR/$GITDIR" ;; esac
HOOKS="$GITDIR/hooks"; mkdir -p "$HOOKS"

# --- 프로필 결정 ---
if [ -z "$WANT" ]; then
  RURL=$(git -C "$DIR" remote get-url origin 2>/dev/null || echo "")
  WANT=private
  if [ -n "$RURL" ] && command -v gh >/dev/null 2>&1; then
    # sed ERE 에는 lazy quantifier 가 없다. .git 을 먼저 떼고 마지막 두 조각을 취한다.
    slug=$(printf '%s' "$RURL" | sed -E 's#\.git$##' | sed -E 's#^.*[:/]([^/:]+/[^/]+)$#\1#')
    vis=$(GH_HOST=github.com gh repo view "$slug" --json visibility -q .visibility 2>/dev/null | tr 'A-Z' 'a-z')
    [ "$vis" = public ] && WANT=public
    [ -n "$vis" ] && echo "  gh 확인: $slug = $vis"
  fi
  [ -z "$RURL" ] && echo "  remote 없음 -> private"
fi
case "$WANT" in public|private) ;; *) echo "프로필은 public 또는 private" >&2; exit 2 ;; esac

# --- 설치 (기존 훅이 있으면 보존해서 체인) ---
# 링크로 걸고, 링크가 안 되면 복사한다.
# Windows 는 개발자 모드가 꺼져 있으면 링크를 못 만든다. 훅은 파일 하나뿐이라
# 복사여도 동작하지만, repo 를 갱신하면 이 스크립트를 다시 돌려야 한다.
place_hook() { # <훅이름>
  local name="$1" src="$SRCDIR/$1" target="$HOOKS/$1"
  rm -f "$target"
  if ln -s "$src" "$target" 2>/dev/null && [ -L "$target" ]; then
    echo "  $name: 링크"
    return 0
  fi
  rm -rf "$target"
  if cp "$src" "$target" 2>/dev/null; then
    chmod +x "$target" 2>/dev/null
    echo "  $name: 복사 (링크를 못 만드는 환경). repo 갱신 후 이 스크립트를 다시 돌리세요"
    return 0
  fi
  echo "  $name: 설치 실패" >&2
  return 1
}

# 내가 놓은 것인지는 경로 문자열이 아니라 표식으로 본다.
# 클론 위치에 'skills/hooks' 가 안 들어 있으면 경로 매칭은 빗나가고,
# 복사로 깔린 내 훅을 남의 훅으로 오인해 자기 자신에게 체인을 건다.
is_mine() { # <파일>
  grep -q 'jolla-skills-hook\|jolla-skills-chain' "$1" 2>/dev/null
}

install_hook() { # <훅이름>
  local name="$1" src="$SRCDIR/$1" target="$HOOKS/$1"
  [ -f "$src" ] || { echo "  원본 없음, 건너뜀: $name" >&2; return; }
  if [ -L "$target" ]; then
    place_hook "$name"
  elif [ -e "$target" ]; then
    if is_mine "$target"; then
      if grep -q 'jolla-skills-chain' "$target" 2>/dev/null; then
        echo "  $name: 이미 체인돼 있음"
      else
        place_hook "$name"
      fi
    else
      cp "$target" "$HOOKS/$name.orig"
      cat > "$target" <<CHAIN
#!/usr/bin/env bash
# jolla-skills-chain  (원래 훅 먼저, 그다음 이 repo 의 $name)
"\$(dirname "\$0")/$name.orig" "\$@" || exit \$?
exec "$src" "\$@"
CHAIN
      chmod +x "$target"
      echo "  $name: 기존 훅 보존 -> $name.orig 로 옮기고 체인"
    fi
  else
    place_hook "$name"
  fi
}

install_hook pre-commit
install_hook commit-msg

printf '%s\n' "$WANT" > "$HOOKS/.profile"
echo "설치 완료: $DIR"
echo "  훅:     $HOOKS/{pre-commit,commit-msg}"
echo "  프로필: $WANT"
[ "$WANT" = private ] && echo "  -> 비밀번호·토큰·개인키만 차단합니다"
[ "$WANT" = public ]  && echo "  -> 시크릿 + 내부 조직명 + 사설IP 를 차단합니다"
echo "  -> em dash 와 커밋 메시지 규칙은 프로필과 무관하게 검사합니다"
if [ "$WANT" = public ]; then
  ORG_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hook-org-patterns"
  [ -f "$ORG_HOME" ] || [ -f "$HOOKS/.org-patterns" ] || {
    echo "  알림: 사내 이름 목록이 없습니다. 만들면 그 이름들도 차단합니다:"
    echo "        $ORG_HOME   (한 줄에 정규식 하나)"
  }
fi
echo "  해제:   rm $HOOKS/pre-commit $HOOKS/commit-msg $HOOKS/.profile"
