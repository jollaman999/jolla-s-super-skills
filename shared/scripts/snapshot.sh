#!/usr/bin/env bash
# 동시 세션이 있을 때: 현재 소스를 스냅샷으로 떠서 그 위에서 분석한다.
# 분석 중 다른 세션이 파일을 바꿔도 영향받지 않는다.
#
# usage:
#   snapshot.sh take  [project_dir]        -> 스냅샷 생성, 경로와 기준 해시 출력
#   snapshot.sh drift <snap_dir> [proj]    -> 스냅샷 이후 원본이 바뀐 파일 목록
#   snapshot.sh clean <snap_dir>           -> 스냅샷 제거
set -uo pipefail
CMD="${1:?take|drift|clean}"; shift

hashes() { # <dir> - 추적 대상 파일의 해시 목록
  git -C "$1" ls-files -z 2>/dev/null | xargs -0 -r md5sum 2>/dev/null | sort -k2
}

case "$CMD" in
take)
  DIR=$(cd "${1:-$PWD}" && pwd -P)
  git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 || { echo "git repo 아님" >&2; exit 2; }
  SNAP=$(mktemp -d "${TMPDIR:-/tmp}/snap-$(basename "$DIR")-XXXXXX")
  # 추적 파일 + 스테이지 안 된 변경까지 그대로 복사
  git -C "$DIR" ls-files -z | tar -C "$DIR" --null -T - -cf - 2>/dev/null | tar -C "$SNAP" -xf -
  hashes "$DIR" > "$SNAP/.snap-base.md5"
  git -C "$DIR" rev-parse HEAD > "$SNAP/.snap-head" 2>/dev/null
  echo "SNAPSHOT=$SNAP"
  echo "HEAD=$(cat "$SNAP/.snap-head" 2>/dev/null)"
  echo "FILES=$(wc -l < "$SNAP/.snap-base.md5")"
  ;;
drift)
  SNAP="${1:?snap_dir}"; DIR=$(cd "${2:-$PWD}" && pwd -P)
  [ -f "$SNAP/.snap-base.md5" ] || { echo "스냅샷 아님: $SNAP" >&2; exit 2; }
  hashes "$DIR" > "$SNAP/.snap-now.md5"
  if diff -q "$SNAP/.snap-base.md5" "$SNAP/.snap-now.md5" >/dev/null 2>&1; then
    echo "변경 없음 - 그대로 패치해도 안전"
    exit 0
  fi
  echo "스냅샷 이후 바뀐 파일:"
  diff "$SNAP/.snap-base.md5" "$SNAP/.snap-now.md5" \
    | grep -E '^[<>]' | awk '{print $1, $3}' | sort -u -k2 | sed 's/^/  /'
  H1=$(cat "$SNAP/.snap-head" 2>/dev/null); H2=$(git -C "$DIR" rev-parse HEAD 2>/dev/null)
  [ "$H1" != "$H2" ] && echo "  HEAD 이동: ${H1:0:8} -> ${H2:0:8}"
  exit 1
  ;;
clean)
  SNAP="${1:?snap_dir}"
  case "$SNAP" in */snap-*) rm -rf "$SNAP"; echo "제거: $SNAP" ;;
                        *) echo "스냅샷 경로가 아님, 거부: $SNAP" >&2; exit 2 ;; esac
  ;;
*) echo "usage: snapshot.sh take|drift|clean" >&2; exit 2 ;;
esac
