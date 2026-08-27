#!/usr/bin/env bash
# 동시 세션이 있을 때: 현재 소스를 스냅샷으로 떠서 그 위에서 분석한다.
# 분석 중 다른 세션이 파일을 바꿔도 영향받지 않는다.
#
# usage:
#   snapshot.sh take  [project_dir]        -> 스냅샷 생성, 경로와 기준 해시 출력
#   snapshot.sh drift <snap_dir> [proj]    -> 스냅샷 이후 원본이 바뀐 파일 목록
#   snapshot.sh clean <snap_dir>           -> 스냅샷 제거
#
# 이식성: tar 를 쓰지 않는다. Git Bash 의 tar 는 배포판마다 옵션이 갈린다.
#         해시 도구도 있는 것을 골라 쓰고 무엇을 썼는지 스냅샷에 적어 둔다.
set -uo pipefail
CMD="${1:?take|drift|clean}"; shift

have() { command -v "$1" >/dev/null 2>&1; }

pick_hash() { # 쓸 수 있는 해시 도구 하나
  # 있다는 것과 도는 것은 다르다. 실제로 한 번 돌려 본다.
  # (Windows 에는 실행하면 바로 죽는 스텁이 PATH 에 놓이는 경우가 있다)
  for h in md5sum sha1sum shasum cksum; do
    have "$h" || continue
    printf 'x' | "$h" >/dev/null 2>&1 && { echo "$h"; return 0; }
  done
  return 1
}

hashes() { # <dir> <해시도구> - 추적 대상 파일의 해시 목록
  # 해시 도구는 호출자의 cwd 에서 돈다. git -C 로 목록만 받으면 경로가 안 맞아
  # 거의 모든 파일이 조용히 빠진다. 반드시 그 디렉터리 안에서 실행한다.
  ( cd "$1" 2>/dev/null && git ls-files -z 2>/dev/null | xargs -0 -r "$2" 2>/dev/null ) | sort -k2
}

case "$CMD" in
take)
  DIR=$(cd "${1:-$PWD}" && pwd -P)
  git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 || { echo "git repo 아님" >&2; exit 2; }
  HASH=$(pick_hash) || { echo "해시 도구가 없습니다 (md5sum/sha1sum/shasum/cksum 중 하나 필요)" >&2; exit 2; }
  SNAP=$(mktemp -d "${TMPDIR:-/tmp}/snap-$(basename "$DIR")-XXXXXX") || { echo "임시 디렉터리 생성 실패" >&2; exit 2; }
  # 추적 파일 + 스테이지 안 된 변경까지 그대로 복사
  N=0
  while IFS= read -r -d '' f; do
    case "$f" in */*) mkdir -p "$SNAP/${f%/*}" || continue ;; esac
    cp -Pp "$DIR/$f" "$SNAP/$f" 2>/dev/null && N=$((N+1))
  done < <(git -C "$DIR" ls-files -z)
  printf '%s\n' "$HASH" > "$SNAP/.snap-tool"
  hashes "$DIR" "$HASH" > "$SNAP/.snap-base.md5"
  git -C "$DIR" rev-parse HEAD > "$SNAP/.snap-head" 2>/dev/null
  echo "SNAPSHOT=$SNAP"
  echo "HEAD=$(cat "$SNAP/.snap-head" 2>/dev/null)"
  FILES=$(wc -l < "$SNAP/.snap-base.md5")
  echo "FILES=$FILES"
  echo "COPIED=$N"
  # 해시 목록이 비면 drift 가 영원히 "변경 없음" 을 낸다. 여기서 끊는다.
  if [ "$N" -eq 0 ] || [ "$FILES" -eq 0 ]; then
    rm -rf "$SNAP"
    echo "스냅샷이 비었습니다 (복사 $N개 / 해시 $FILES줄). 스냅샷을 지웠습니다" >&2
    exit 2
  fi
  ;;
drift)
  SNAP="${1:?snap_dir}"; DIR=$(cd "${2:-$PWD}" && pwd -P)
  [ -f "$SNAP/.snap-base.md5" ] || { echo "스냅샷 아님: $SNAP" >&2; exit 2; }
  # 뜰 때 쓴 도구와 같은 도구로 재야 비교가 성립한다
  HASH=$(cat "$SNAP/.snap-tool" 2>/dev/null || echo md5sum)
  have "$HASH" || { echo "스냅샷을 뜰 때 쓴 $HASH 이 지금 없습니다. 비교할 수 없습니다" >&2; exit 2; }
  hashes "$DIR" "$HASH" > "$SNAP/.snap-now.md5"
  BASE_N=$(wc -l < "$SNAP/.snap-base.md5"); NOW_N=$(wc -l < "$SNAP/.snap-now.md5")
  if [ "$BASE_N" -eq 0 ] || [ "$NOW_N" -eq 0 ]; then
    echo "확인 불가: 해시 목록이 비었습니다 (기준 ${BASE_N}줄 / 현재 ${NOW_N}줄)" >&2
    echo "  '변경 없음' 과 구분할 수 없습니다. $HASH 이 제대로 도는지 확인하세요" >&2
    exit 2
  fi
  if diff -q "$SNAP/.snap-base.md5" "$SNAP/.snap-now.md5" >/dev/null 2>&1; then
    echo "변경 없음 - 그대로 패치해도 안전"
    exit 0
  fi
  echo "스냅샷 이후 바뀐 파일:"
  diff "$SNAP/.snap-base.md5" "$SNAP/.snap-now.md5" \
    | grep -E '^[<>]' | awk '{print $1, $NF}' | sort -u -k2 | sed 's/^/  /'
  H1=$(cat "$SNAP/.snap-head" 2>/dev/null); H2=$(git -C "$DIR" rev-parse HEAD 2>/dev/null)
  [ "$H1" != "$H2" ] && echo "  HEAD 이동: ${H1:0:8} -> ${H2:0:8}"
  exit 1
  ;;
clean)
  SNAP="${1:?snap_dir}"
  # 경로 이름만으로 판단하지 않는다. /tmp/snap-private-tmp 같은 남의 디렉터리가
  # */snap-* 에 걸린다. 내가 만든 스냅샷에만 있는 표식 파일로 확인한다.
  if [ ! -f "$SNAP/.snap-base.md5" ]; then
    echo "내가 만든 스냅샷이 아님, 거부: $SNAP" >&2; exit 2
  fi
  rm -rf "$SNAP"; echo "제거: $SNAP"
  ;;
*) echo "usage: snapshot.sh take|drift|clean" >&2; exit 2 ;;
esac
