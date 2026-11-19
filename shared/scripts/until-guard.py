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
#   heredoc 본문은 셸이 받는 것(bash/sh/zsh/ssh <<)만 보고, 파이썬 코드나 파일로 쓰는 본문은 뺀다. 주석도 뺀다.
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
    for m in LOOP.finditer(text):
        kw, cond = m.group(1), m.group(2)
        end = loop_end(text, m.end())
        region = text[m.start():end]
        if kw == "while":
            if not re.search(r"\bsleep\b", region) or re.search(r"\bread\b", cond):
                continue
        if CMP.search(region) or wrapped_by_timeout(text, m.start()):
            continue
        found.append(region.strip())
    return found


def main():
    d = json.load(sys.stdin)
    if d.get("tool_name") != "Bash":
        return
    cmd = (d.get("tool_input") or {}).get("command") or ""
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
