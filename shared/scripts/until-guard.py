#!/usr/bin/env python3
# PreToolUse 훅 (Bash). 횟수 상한 없는 대기 루프를 실행 전에 막는다.
#
# 규칙(CLAUDE.md 원격 명령 절의 "until 폴링에는 횟수 상한")은 있는데 문서로는 안 막혔다.
# 7주치 기록에서 루프가 든 Bash 명령 613개를 이 판정에 돌리면 39개가 걸리고, 그중 37개가 서브에이전트였다.
# 기다리던 대상이 죽으면 그런 루프는 세션이 끝날 때까지 남는다. 남은 대기 프로세스를 손으로 끝낸 적이 있다.
#
# 막는 것: until 루프 전부. 그리고 몸통에 sleep 이 있는 while 루프 - 같은 폴링을 while ! 로 쓴 것이다.
#   until 만 막으면 while ! 로 바꿔 쓰고 지나간다. read 로 입력을 읽는 while 은 입력이 끝나면 끝나므로 뺀다.
# 상한으로 보는 것:
#   - 루프 조건·몸통 안의 수 비교 (-lt -le -gt -ge, (( a < b )))
#   - 루프를 감싼 timeout: timeout N bash|sh|zsh -c '...', timeout N ssh ... '...', timeout N bash <<EOF
#   조건 안의 timeout (until timeout 20 ssh ...; do) 은 한 번 시도의 상한이지 루프의 상한이 아니다.
#   2026-11-12 에 남은 루프가 바로 이 모양이었다.
# 찾는 곳: 명령 전체. bash -c, eval, ssh 로 넘기는 따옴표 안도 본다 (남은 루프가 eval '...' 안이었다).
#   따옴표 안은 그 문자열을 셸이 실행할 때만 본다 - 바로 앞이 bash|sh|zsh -c, eval, ssh 일 때다.
#   변수에 담거나 echo 로 찍는 문자열은 실행되지 않으니 막지 않는다 (CMD='... until ...' 를 막은 오탐이 있었다).
#   heredoc 본문은 셸이 받는 것(bash/sh/zsh/ssh <<)만 보고, 파이썬 코드나 파일로 쓰는 본문은 뺀다. 주석도 뺀다.
#
# 같은 자리(실행 전 Bash)에서 하나를 더 본다: 검증 명령과 git commit 을 한 호출에 넣은 것.
#   규칙(CLAUDE.md "검증이 끝나야 커밋한다")은 있는데 `(go test ...; echo rc=$?) && git commit`, `make | tail && git commit`
#   처럼 검증이 실패해도 커밋되는 모양이 10번 중 9번 나왔고, 실패한 커밋이 2개 남았다.
#   검증(go test·make·pytest·bash -n ...)이 git commit 보다 앞에 있으면 연결 방식과 상관없이 막는다.
#   && 로 이은 것도 막는다 - 검증 출력을 보지 않고 커밋하는 것이 같기 때문이다.
#   이 검사를 따로 훅으로 두지 않은 것은, 이미 설치된 PC 들이 다시 설치하지 않아도 자동 업데이트만으로 걸리게 하려는 것이다.
#
# 입력: 훅 JSON (stdin). tool_name, tool_input.command 를 쓴다.
# 출력: 막을 때만 permissionDecision=deny 를 담은 JSON 한 줄. 나머지는 아무것도 안 낸다.
# 언제나 0 으로 끝난다. 이 훅이 깨지면 막지 않고 통과시킨다.
import json
import re
import sys

SHELLS = r"(?:bash|sh|zsh|dash|ssh)"
HEREDOC = re.compile(r"(?<!<)<<(-?)\s*(['\"]?)([A-Za-z_][\w.-]*)\2")
# 루프 키워드는 명령 자리에 있어야 한다: 줄 처음, ; & | ( { 따옴표 뒤, then/do/else 뒤
LOOP = re.compile(
    r"(?:^|(?<=[\n;&|({`'\"])|(?<=\bthen)|(?<=\bdo)|(?<=\belse))[ \t]*"
    r"(until|while)[ \t]+((?:[^\n]|\\\n)*?)[ \t]*(?:;|\n)\s*do\b"
)
WORD = re.compile(r"\b(do|done)\b")
CMP = re.compile(r"-(?:lt|le|gt|ge)\b|\(\([^()]*[<>][^()]*\)\)")
OUTER = re.compile(r"\btimeout[ \t]+(?:-\S+[ \t]+)*\d+[smhd]?[ \t]+(?:\S+=\S*[ \t]+)*" + SHELLS + r"\b")
TIMEOUT_WORD = re.compile(r"\btimeout[ \t]+(?:-\S+[ \t]+)*\d")
# 따옴표 문자열을 셸이 실행하는 자리: 여는 따옴표 바로 앞이 이 모양이면 그 안은 명령이다
LAUNCHER = re.compile(
    r"(?:\b(?:bash|sh|zsh|dash|ksh)[ \t]+(?:-[A-Za-z]+[ \t]+)*-[A-Za-z]*c[ \t]*"
    r"|\beval[ \t]*"
    r"|\b(?:ssh|su|watch)\b[^;&|\n'\"]*)$"
)


def strip_heredocs(text):
    """셸이 받지 않는 heredoc 본문을 지운다. timeout 으로 감싼 셸 heredoc 도 상한이 있으니 지운다."""
    lines = text.split("\n")
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        i += 1
        for m in HEREDOC.finditer(line):
            strip_tabs, word = m.group(1) == "-", m.group(3)
            head = line[:m.start()]
            keep = re.search(r"(?:^|[\s;&|(])" + SHELLS + r"\b", head) and not TIMEOUT_WORD.search(head)
            while i < len(lines):
                body = lines[i]
                i += 1
                if (body.lstrip("\t") if strip_tabs else body) == word:
                    out.append(body)
                    break
                if keep:
                    out.append(body)
    return "\n".join(out)


def strip_comments(text):
    """따옴표 밖의 # 주석을 지운다. $# ${#v} 같은 것은 앞이 공백이 아니라서 남는다."""
    out = []
    q = None
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if q == "'":
            if c == "'":
                q = None
        elif q == '"':
            if c == "\\" and i + 1 < n:
                out.append(c)
                i += 1
                c = text[i]
            elif c == '"':
                q = None
        else:
            if c == "\\" and i + 1 < n:
                out.append(c)
                i += 1
                c = text[i]
            elif c in "'\"":
                q = c
            elif c == "#" and (i == 0 or text[i - 1] in " \t\n;&|("):
                while i < n and text[i] != "\n":
                    i += 1
                continue
        out.append(c)
        i += 1
    return "".join(out)


def quote_spans(text):
    """맨 바깥 따옴표 문자열의 (여는 위치, 닫는 위치) 목록."""
    spans = []
    q = None
    start = 0
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if q is None:
            if c == "\\":
                i += 2
                continue
            if c in "'\"":
                q, start = c, i
        elif q == '"' and c == "\\":
            i += 2
            continue
        elif c == q:
            spans.append((start, i))
            q = None
        i += 1
    if q is not None:
        spans.append((start, n))
    return spans


def runs_as_shell(text, pos, spans):
    """pos 가 따옴표 밖이거나, 셸이 실행하는 따옴표 문자열 안이면 True."""
    for s, e in spans:
        if s < pos < e:
            return bool(LAUNCHER.search(text[max(0, s - 200):s]))
    return True


def loop_end(text, start):
    """start 바로 뒤의 do 와 짝이 맞는 done 의 끝 위치. 못 찾으면 글 끝."""
    depth = 1
    for m in WORD.finditer(text, start):
        depth += 1 if m.group(1) == "do" else -1
        if depth == 0:
            return m.end()
    return len(text)


def quoted_span(text, pos):
    """pos 이후 처음 여는 따옴표부터 닫는 따옴표까지의 (시작, 끝). 없으면 None."""
    m = re.compile(r"['\"]").search(text, pos)
    if not m:
        return None
    q, i = m.group(0), m.end()
    while i < len(text):
        if q == '"' and text[i] == "\\":
            i += 2
            continue
        if text[i] == q:
            return m.start(), i
        i += 1
    return m.start(), len(text)


def wrapped_by_timeout(text, loop_start):
    """loop_start 가 timeout N bash -c '...' 같은 감싸개의 따옴표 안에 있나."""
    for m in OUTER.finditer(text, 0, loop_start):
        span = quoted_span(text, m.end())
        if span and span[0] < loop_start < span[1]:
            return True
    return False


def uncapped_loops(command):
    text = strip_comments(strip_heredocs(command.replace("\r\n", "\n")))
    found = []
    spans = quote_spans(text)
    for m in LOOP.finditer(text):
        kw, cond = m.group(1), m.group(2)
        if not runs_as_shell(text, m.start(1), spans):
            continue
        end = loop_end(text, m.end())
        region = text[m.start():end]
        if kw == "while":
            if not re.search(r"\bsleep\b", region) or re.search(r"\bread\b", cond):
                continue
        if CMP.search(region) or wrapped_by_timeout(text, m.start()):
            continue
        found.append(region.strip())
    return found


# 명령 자리에 온 검증 명령과 git commit. 명령 자리 = 줄 처음, ; & | ( { 뒤, then/do 뒤
CMDPOS = r"(?:^|(?<=[\n;&|({`'\"])|(?<=\bthen)|(?<=\bdo))[ \t]*(?:(?:sudo|time|timeout[ \t]+(?:-\S+[ \t]+)*\d+[smhd]?|env(?:[ \t]+\S+=\S*)*|\S+=\S*)[ \t]+)*"
VERIFY = re.compile(
    CMDPOS + r"((?:\S*/)?(?:"
    r"go[ \t]+(?:test|build|vet)\b|make\b|gmake\b|pytest\b|python3?[ \t]+-m[ \t]+(?:pytest|unittest)\b|tox\b"
    r"|npm[ \t]+(?:test|run[ \t]+(?:test|build|lint))\b|yarn[ \t]+(?:test|build|lint)\b|pnpm[ \t]+(?:test|build)\b"
    r"|cargo[ \t]+(?:test|build|check|clippy)\b|mvn\b|gradle\b|\./gradlew\b|ctest\b|tsc\b"
    r"|(?:bash|sh|zsh)[ \t]+-n\b|shellcheck\b|lint-shell\.sh\b|test-[\w-]+\.sh\b|run\.sh\b))"
)
COMMIT = re.compile(CMDPOS + r"(git(?:[ \t]+-C[ \t]+\S+)?[ \t]+commit\b)")


def verify_then_commit(command):
    """검증 명령 뒤에 git commit 이 오면 (검증, 커밋) 조각을 낸다. 없으면 None."""
    text = strip_comments(strip_heredocs(command.replace("\r\n", "\n")))
    spans = quote_spans(text)
    commits = [m for m in COMMIT.finditer(text) if runs_as_shell(text, m.start(1), spans)]
    if not commits:
        return None
    first_commit = commits[0].start(1)
    for m in VERIFY.finditer(text):
        if m.start(1) < first_commit and runs_as_shell(text, m.start(1), spans):
            return m.group(1).strip(), commits[0].group(1).strip()
    return None


def main():
    d = json.load(sys.stdin)
    if d.get("tool_name") != "Bash":
        return
    cmd = (d.get("tool_input") or {}).get("command") or ""
    if "commit" in cmd:
        hit = verify_then_commit(cmd)
        if hit:
            msg = (
                "[until-guard] 검증(`%s`)과 `%s` 을 한 호출에 넣어 실행하지 않았습니다. "
                "`(...; echo rc=$?) && git commit` 이나 `make | tail && git commit` 은 검증이 실패해도 커밋되고, "
                "&& 로 이어도 검증 출력을 보지 않고 커밋하게 됩니다 (CLAUDE.md git 쓰기 절 \"검증이 끝나야 커밋한다\"). "
                "검증만 먼저 돌려 출력과 종료 코드를 보고, 통과했으면 다음 호출에서 git add·commit 하세요."
                % hit
            )
            print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                                     "permissionDecision": "deny",
                                                     "permissionDecisionReason": msg}}, ensure_ascii=False))
            return
    if "until" not in cmd and "while" not in cmd:
        return
    loops = uncapped_loops(cmd)
    if not loops:
        return
    head = re.sub(r"\s+", " ", loops[0])
    if len(head) > 100:
        head = head[:100] + "..."
    msg = (
        "[until-guard] 횟수 상한이 없는 대기 루프라 실행하지 않았습니다: `%s`. "
        "기다리던 대상이 죽거나 조건이 영영 안 맞으면 이 루프는 세션이 끝날 때까지 남습니다 (CLAUDE.md 원격 명령 절). "
        "상한을 넣어 다시 내세요. 예: `n=0; until <조건> || [ $n -ge 60 ]; do n=$((n+1)); sleep 5; done; [ $n -ge 60 ] && echo 기다림 상한`. "
        "루프 전체를 `timeout 600 bash -c '...'` 로 감싸도 됩니다. 조건 안의 timeout 은 한 번 시도의 상한이라 루프 상한이 아닙니다. "
        "5분 넘게 기다릴 것이면 run_in_background 로 띄우고 Monitor 로 봅니다 (waiting.md)."
        % head
    )
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                             "permissionDecision": "deny",
                                             "permissionDecisionReason": msg}}, ensure_ascii=False))


if __name__ == "__main__":
    # Windows 에서 출력이 파이프·파일로 가면 기본 인코딩(cp949)으로 나간다. 받는 쪽은 UTF-8 로 읽는다
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
