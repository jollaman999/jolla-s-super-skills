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
install_hook() { # <훅이름>
  local name="$1" src="$SRCDIR/$1" target="$HOOKS/$1"
  [ -f "$src" ] || { echo "  원본 없음, 건너뜀: $name" >&2; return; }
  if [ -e "$target" ] && [ ! -L "$target" ]; then
    if grep -q "skills/hooks/$name" "$target" 2>/dev/null; then
      echo "  $name: 이미 체인돼 있음"
    else
      cp "$target" "$HOOKS/$name.orig"
      cat > "$target" <<CHAIN
#!/usr/bin/env bash
# 원래 훅 먼저, 그다음 skills/hooks/$name
"\$(dirname "\$0")/$name.orig" "\$@" || exit \$?
exec "$src" "\$@"
CHAIN
      chmod +x "$target"
      echo "  $name: 기존 훅 보존 -> $name.orig 로 옮기고 체인"
    fi
  elif [ -L "$target" ]; then
    ln -sfn "$src" "$target"; echo "  $name: 링크 갱신"
  else
    ln -sfn "$src" "$target"; echo "  $name: 링크 생성"
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
echo "  해제:   rm $HOOKS/pre-commit $HOOKS/commit-msg $HOOKS/.profile"
