#!/usr/bin/env python3
# PreToolUse 훅 (Bash). 돌고 있는 프로세스를 거느린 프로세스를 끝내려 할 때 사용자에게 묻게 한다.
#
# 돌고 있는 시험을 감싼 timeout 프로세스만 끝내면 안쪽 시험은 산다고 믿고, 묻지 않고 끝내는 실패가 반복됐다.
# 실제로는 그렇지 않다. 이 PC 의 timeout(uutils coreutils 0.12.0)은 자기가 신호를 받으면 자식도 끝낸다.
# 문서 규칙으로는 안 막혔다. 같은 상황을 재현한 시험(eval E62)에서 9회 모두 묻지 않고 kill -KILL <PID> 를 했다.
# 그래서 막지 않고 확인 창을 띄운다(permissionDecision=ask). 끝내도 되는지는 사람이 정한다.
#
# 찾는 것: 명령 자리에 있는 kill, pkill, killall. 줄 처음, ; & | ( { ` 뒤, then/do/else 뒤,
#   그리고 sudo, timeout N, command, exec, nohup, env, VAR=값 뒤도 명령 자리로 본다.
#   따옴표 안은 그 문자열을 이 PC 의 셸이 실행할 때만 본다 - 바로 앞이 bash|sh|zsh -c, eval, su -c, watch 일 때다.
#   ssh, docker exec 같은 원격·컨테이너로 넘기는 명령은 PID 가 이 PC 의 것이 아니라 안 본다.
#   heredoc 본문은 이 PC 의 셸이 받는 것(bash/sh/zsh <<)만 보고, 파일로 쓰는 본문은 뺀다. 주석도 뺀다.
# 대상으로 보는 것:
#   - kill: 숫자 인자. 옵션(-9, -KILL, -s SIG, -SIGTERM, --)은 건너뛴다.
#     음수(-<pgid>)는 프로세스 그룹이라 그 그룹 구성원 전부, -1 은 보이는 프로세스 전부다.
#   - pkill: /proc 를 훑어 맞는 프로세스. 기본은 이름(comm) 정규식, -f 면 전체 명령 줄, -x 면 정확히 일치.
#   - killall: 이름(comm)이 정확히 같은 프로세스.
#   - kill 의 $NAME, ${NAME}, "$NAME": 같은 명령 글자 안에서 kill 보다 앞에 NAME=<숫자> 로 넣었으면 그 숫자.
#     (A=1; B=2, export NAME=, local NAME= 포함. 다시 넣으면 마지막 값. 숫자가 아닌 값을 넣었으면 못 정함)
#     TO=<PID>; kill -STOP $TO 모양이 숫자 PID 대신 변수로 빠져나간 적이 있다.
#   - kill 의 $(pgrep ...), `pgrep ...`, 그리고 NAME=$(pgrep ...) 로 넣은 $NAME: pgrep 을 실행하지 않고
#     pkill 과 같은 옵션 해석으로 /proc 를 훑는다.
#   이 중 하나라도 살아 있는 후손 프로세스를 거느리면 묻는다.
# 통과시키는 것 (대상을 정할 수 없거나 신호를 안 보낸다):
#   - 값을 모르는 인자: 같은 명령 안에서 숫자를 넣지 않은 변수($$, $!, $PPID, 루프 변수 포함),
#     pgrep 하나뿐이 아닌 치환($(cat pidfile), $(pgrep x | head -1)), %1 같은 작업 번호, 0
#   - kill -0 (살아 있는지만 본다), kill -l / -L (신호 목록)
#   - pkill·killall 의 못 알아듣는 옵션(-u, -P, -r, -g 등)이 붙은 것, xargs kill 처럼 명령 자리가 아닌 것
#   - 이 훅 자신과 그 조상(Claude Code, 셸). 안 빼면 pkill -f 패턴이 Claude Code 명령 줄에 걸린다
#   - 커널 스레드, 좀비, sudo 없이 root 가 아닐 때 남의 계정 프로세스 (신호가 가지 않는다)
#   - /proc 가 없는 곳 (Windows, macOS)
#
# 입력: 훅 JSON (stdin). tool_name, tool_input.command 를 쓴다.
# 출력: 물을 때만 permissionDecision=ask 를 담은 JSON 한 줄. 나머지는 아무것도 안 낸다.
# 언제나 0 으로 끝난다. 이 훅이 깨지면 묻지 않고 통과시킨다.
import json
import os
import re
import shlex
import signal
import sys

HEREDOC = re.compile(r"(?<!<)<<(-?)\s*(['\"]?)([A-Za-z_][\w.-]*)\2")
LOCAL_SHELLS = r"(?:bash|sh|zsh|dash|ksh)"
# 이 앞에 있으면 그 뒤 명령은 다른 호스트·컨테이너에서 돈다
REMOTE = re.compile(r"\b(?:ssh|docker|podman|nerdctl|kubectl|lxc|incus|vagrant)\b[^;&|\n]*$")
# 따옴표 문자열을 이 PC 의 셸이 실행하는 자리
LAUNCHER = re.compile(
    r"(?:\b" + LOCAL_SHELLS + r"[ \t]+(?:-[A-Za-z]+[ \t]+)*-[A-Za-z]*c[ \t]*"
    r"|\beval[ \t]*"
    r"|\bsu\b[^;&|\n'\"]*-c[ \t]*"
    r"|\bwatch\b[^;&|\n'\"]*)$"
)
# 명령 앞에 붙어도 그 명령이 명령 자리에 있는 것으로 보는 말
PREFIX = (
    r"(?:(?:sudo(?:[ \t]+-[ugCDprTU](?:[ \t]+|=)?[^ \t;&|\n]+|[ \t]+-[^ \t;&|\n]+)*"
    r"|timeout(?:[ \t]+-[sk](?:[ \t]+|=)?[^ \t;&|\n]+|[ \t]+-[^ \t;&|\n]+)*[ \t]+\d+(?:\.\d+)?[smhd]?"
    r"|command|exec|nohup|builtin|time"
    r"|env(?:[ \t]+[A-Za-z_]\w*=[^ \t;&|\n]*)*"
    r"|[A-Za-z_]\w*=[^ \t;&|\n]*)[ \t]+)*"
)
KILL = re.compile(
    r"(?:^|(?<=[\n;&|({`'\"!])|(?<=\bthen)|(?<=\bdo)|(?<=\belse))[ \t]*"
    r"(" + PREFIX + r")(?:/usr)?(?:/s?bin/)?(kill|pkill|killall)(?=[ \t;&|\n)`'\"]|$)"
)
# 변수 대입이 명령 자리에서 시작하는 곳 (export·local 같은 말 뒤 포함)
ASSIGN_START = re.compile(
    r"(?:^|(?<=[\n;&|({`'\"])|(?<=\bthen)|(?<=\bdo)|(?<=\belse))[ \t]*"
    r"(?:(?:export|local|declare|typeset|readonly)(?:[ \t]+-[A-Za-z]+)*[ \t]+)?(?=[A-Za-z_]\w*=)"
)
NAME_EQ = re.compile(r"([A-Za-z_]\w*)=")
REDIRECT = re.compile(r"^\d*(?:>>?|<|&>>?|>&|<&|>\|)(.*)$")
SIGNAMES = {s.name[3:] for s in signal.Signals if s.name.startswith("SIG") and not s.name.startswith("SIG_")}
SIGNAMES |= {"RTMIN", "RTMAX", "CLD", "POLL", "IOT"}


def strip_heredocs(text):
    """이 PC 의 셸이 받지 않는 heredoc 본문을 지운다."""
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
            keep = re.search(r"(?:^|[\s;&|(])" + LOCAL_SHELLS + r"\b", head) and not REMOTE.search(head)
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


def local_bound(text, pos, spans):
    """pos 가 이 PC 의 셸이 실행하는 자리면 인자를 읽을 끝 위치, 아니면 None."""
    for s, e in spans:
        if s < pos < e:
            head = text[max(0, s - 200):s]
            if LAUNCHER.search(head) and not REMOTE.search(head):
                return e
            return None
    return len(text)


def skip_subst(text, i, end):
    """text[i] 가 $( 나 ` 의 시작일 때 짝이 맞는 끝 바로 뒤 위치."""
    if text[i] == "`":
        j = i + 1
        while j < end and text[j] != "`":
            j += 2 if text[j] == "\\" else 1
        return min(j + 1, end)
    depth = 0
    j = i + 1
    while j < end:
        c = text[j]
        if c == "\\":
            j += 2
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return j + 1
        j += 1
    return end


def arg_text(text, i, end, subs, word=False):
    """명령 이름 뒤에서 그 명령이 끝나는 곳까지의 (글자, 끝 위치). word 면 낱말 하나(공백 전)까지.
    $(...) 와 `...` 는 KGSUB<n>KG 로 바꾸고 안쪽 글자를 subs[n] 에 담는다."""
    out = []
    q = None
    while i < end:
        c = text[i]
        if q == "'":
            out.append(c)
            if c == "'":
                q = None
            i += 1
            continue
        if c == "\\" and i + 1 < end:
            out.append(text[i:i + 2])
            i += 2
            continue
        if c == "`" or (c == "$" and text[i + 1:i + 2] == "("):
            j = skip_subst(text, i, end)
            subs.append(text[i + (1 if c == "`" else 2):j - 1])
            out.append("KGSUB%dKG" % (len(subs) - 1))
            i = j
            continue
        if q == '"':
            if c == '"':
                q = None
        elif c in "'\"":
            q = c
        elif c == "&" and ((i > 0 and text[i - 1] in "<>") or text[i + 1:i + 2] == ">"):
            pass
        elif c in ";&|\n)":
            break
        elif c == "}" and (i == 0 or text[i - 1] in " \t"):
            break
        elif word and c in " \t":
            break
        out.append(c)
        i += 1
    return "".join(out), i


def words(arg):
    """인자 문자열을 낱말로 자르고 리다이렉트를 뺀다. 못 자르면 None."""
    try:
        toks = shlex.split(arg, posix=True)
    except ValueError:
        return None
    out = []
    skip = False
    for t in toks:
        if skip:
            skip = False
            continue
        m = REDIRECT.match(t)
        if m:
            skip = m.group(1) == ""
            continue
        out.append(t)
    return out


def pgrep_spec(inner):
    """치환 안쪽이 pgrep 하나뿐이면 그 인자 낱말 목록, 아니면 None. pgrep 은 실행하지 않는다."""
    m = re.fullmatch(r"\s*pgrep[ \t]+(.*?)\s*", inner, re.S)
    if not m:
        return None
    no_single = re.sub(r"'[^']*'", "", m.group(1))
    bare = re.sub(r'"[^"]*"', "", no_single)
    if re.search(r"[$`]", no_single) or re.search(r"[|;&<>\n()]", bare):
        return None
    return words(m.group(1))


def assigned_value(raw, subs):
    """대입한 값이 숫자면 그 글자, pgrep 하나뿐인 치환이면 ("pgrep", 인자), 아니면 None."""
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in "'\"":
        raw = raw[1:-1]
    if re.fullmatch(r"\d+", raw):
        return raw
    m = re.fullmatch(r"KGSUB(\d+)KG", raw)
    if m:
        spec = pgrep_spec(subs[int(m.group(1))])
        if spec is not None:
            return ("pgrep", spec)
    return None


def assignments(text, spans):
    """명령 자리의 NAME=값 (export·local 등 포함) 을 (위치, 이름, 값) 으로. 값은 assigned_value 의 것."""
    out = []
    for m in ASSIGN_START.finditer(text):
        end = local_bound(text, m.end(), spans)
        if end is None:
            continue
        i = m.end()
        while True:
            a = NAME_EQ.match(text, i)
            if not a:
                break
            subs = []
            raw, i = arg_text(text, a.end(), end, subs, word=True)
            out.append((a.start(), a.group(1), assigned_value(raw, subs)))
            while i < end and text[i] in " \t":
                i += 1
    return out


def kill_calls(command):
    """kill·pkill·killall 호출마다 dict(name, w=낱말 목록, sudo, env=그 앞까지의 변수 값, subs=치환 안쪽)."""
    text = strip_comments(strip_heredocs(command.replace("\r\n", "\n")))
    spans = quote_spans(text)
    assigns = assignments(text, spans)
    calls = []
    for m in KILL.finditer(text):
        end = local_bound(text, m.start(2), spans)
        if end is None:
            continue
        subs = []
        w = words(arg_text(text, m.end(), end, subs)[0])
        if w is None:
            continue
        env = {}
        for pos, name, val in assigns:
            if pos < m.start(2):
                env[name] = val
        calls.append({"name": m.group(2), "w": w, "sudo": bool(re.search(r"\bsudo\b", m.group(1))),
                      "env": env, "subs": subs})
    return calls


def resolve(w, env, subs):
    """kill 인자의 $NAME·${NAME}·치환을 아는 값으로 바꾼다. pgrep 은 ("pgrep", 인자) 로 남긴다."""
    out = []
    for t in w:
        m = re.fullmatch(r"\$(?:\{(\w+)\}|(\w+))", t)
        if m and env.get(m.group(1) or m.group(2)) is not None:
            t = env[m.group(1) or m.group(2)]
        else:
            m = re.fullmatch(r"KGSUB(\d+)KG", t)
            spec = pgrep_spec(subs[int(m.group(1))]) if m else None
            if spec is not None:
                t = ("pgrep", spec)
        out.append(t)
    return out


def read_procs():
    """pid -> dict(comm, ppid, pgrp, state, uid). 읽다가 사라진 것은 뺀다."""
    procs = {}
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        try:
            with open("/proc/%s/stat" % name, "rb") as f:
                raw = f.read().decode("utf-8", "replace")
            uid = os.stat("/proc/" + name).st_uid
        except OSError:
            continue
        lp, rp = raw.find("("), raw.rfind(")")
        rest = raw[rp + 2:].split()
        pid = int(name)
        procs[pid] = {"comm": raw[lp + 1:rp], "state": rest[0], "ppid": int(rest[1]),
                      "pgrp": int(rest[2]), "uid": uid}
    return procs


def cmdline(pid, procs):
    p = procs[pid]
    if "cmd" not in p:
        try:
            with open("/proc/%d/cmdline" % pid, "rb") as f:
                raw = f.read()
            p["cmd"] = " ".join(a.decode("utf-8", "replace") for a in raw.split(b"\0") if a)
        except OSError:
            p["cmd"] = ""
    return p["cmd"]


def kill_targets(w, procs):
    saw_signal = False
    i = 0
    while i < len(w):
        t = w[i]
        if isinstance(t, tuple):
            break
        if t in ("-l", "-L", "--list", "--table") or t.startswith("-l") and t[2:].isdigit():
            return []
        if t in ("-s", "-n", "--signal"):
            if i + 1 < len(w) and w[i + 1] == "0":
                return []
            saw_signal = True
            i += 2
            continue
        if t == "--":
            i += 1
            break
        if t.startswith("-") and not saw_signal:
            if t[1:] in ("0", "SIG0"):
                return []
            saw_signal = True
            i += 1
            continue
        break
    pids = []
    for t in w[i:]:
        if isinstance(t, tuple):
            pids.extend(pkill_targets(t[1], procs))
        elif re.fullmatch(r"\d+", t) and int(t) > 0:
            pids.append(int(t))
        elif t == "-1":
            pids.extend(sorted(procs))
        elif re.fullmatch(r"-\d+", t) and int(t[1:]) > 0:
            g = int(t[1:])
            pids.extend(sorted(p for p, v in procs.items() if v["pgrp"] == g))
    return pids


def is_signal_opt(t):
    s = t[1:]
    return s.isdigit() or s in SIGNAMES or (s.startswith("SIG") and s[3:] in SIGNAMES)


def pkill_targets(w, procs):
    full = exact = icase = False
    pats = []
    rest = False
    i = 0
    while i < len(w):
        t = w[i]
        i += 1
        if rest or not t.startswith("-") or t == "-":
            pats.append(t)
        elif t == "--":
            rest = True
        elif t in ("--full", "--exact", "--ignore-case", "--echo") or re.fullmatch(r"-[fxie]+", t):
            full |= t == "--full" or (not t.startswith("--") and "f" in t)
            exact |= t == "--exact" or (not t.startswith("--") and "x" in t)
            icase |= t == "--ignore-case" or (not t.startswith("--") and "i" in t)
        elif t == "--signal":
            i += 1
        elif t.startswith("--signal=") or is_signal_opt(t):
            pass
        else:
            return []
    if len(pats) != 1 or "$" in pats[0] or "KGSUB" in pats[0]:
        return []
    try:
        rx = re.compile(pats[0], re.I if icase else 0)
    except re.error:
        return []
    out = []
    for pid in sorted(procs):
        s = cmdline(pid, procs) if full else procs[pid]["comm"]
        if full and not s:
            s = procs[pid]["comm"]
        if (rx.fullmatch(s) if exact else rx.search(s)):
            out.append(pid)
    return out


def killall_targets(w, procs):
    names = []
    rest = False
    i = 0
    while i < len(w):
        t = w[i]
        i += 1
        if rest or not t.startswith("-") or t == "-":
            names.append(t)
        elif t == "--":
            rest = True
        elif t in ("--exact", "--ignore-case", "--interactive", "--quiet", "--verbose", "--wait") \
                or re.fullmatch(r"-[eIiqvw]+", t):
            pass
        elif t in ("-s", "--signal"):
            i += 1
        elif t.startswith("--signal=") or is_signal_opt(t):
            pass
        else:
            return []
    out = []
    for n in names:
        if "$" in n or "KGSUB" in n or "/" in n or not n:
            continue
        out.extend(sorted(p for p, v in procs.items() if v["comm"] in (n, n[:15])))
    return out


def ancestors(procs):
    """이 훅 자신과 그 조상 pid."""
    seen = {os.getpid(), os.getppid()}
    p = os.getppid()
    while p in procs and procs[p]["ppid"] > 0 and procs[p]["ppid"] not in seen:
        p = procs[p]["ppid"]
        seen.add(p)
    return seen


def kernel_thread(pid, procs):
    return pid == 2 or procs[pid]["ppid"] == 2


def live_descendants(pid, procs, children, skip):
    out = []
    todo = list(children.get(pid, []))
    while todo:
        c = todo.pop(0)
        if c in skip or c not in procs:
            continue
        if procs[c]["state"] != "Z" and not kernel_thread(c, procs):
            out.append(c)
        todo.extend(children.get(c, []))
    return out


def main():
    d = json.load(sys.stdin)
    if d.get("tool_name") != "Bash":
        return
    cmd = (d.get("tool_input") or {}).get("command") or ""
    if not re.search(r"\b(?:p?kill|killall)\b", cmd) or not os.path.isdir("/proc/self"):
        return
    calls = kill_calls(cmd)
    if not calls:
        return
    procs = read_procs()
    skip = ancestors(procs)
    children = {}
    for p in sorted(procs):
        children.setdefault(procs[p]["ppid"], []).append(p)
    me = os.geteuid()
    targets = {}
    for c in calls:
        name, w, sudo = c["name"], c["w"], c["sudo"]
        if name == "kill":
            w = resolve(w, c["env"], c["subs"])
        found = {"kill": kill_targets, "pkill": pkill_targets, "killall": killall_targets}[name](w, procs)
        for p in found:
            if p in skip or p not in procs or kernel_thread(p, procs) or procs[p]["state"] == "Z":
                continue
            if not sudo and me != 0 and procs[p]["uid"] != me:
                continue
            targets.setdefault(p, None)
    risky = []
    for p in targets:
        desc = live_descendants(p, procs, children, skip)
        if desc:
            risky.append((p, desc))
    if not risky:
        return
    pid, desc = risky[0]
    shown = ", ".join("%d(%s)" % (c, procs[c]["comm"]) for c in desc[:3])
    if len(desc) > 3:
        shown += ", ..."
    msg = "[kill-guard] 끝내려는 %d(%s) 아래에 돌고 있는 프로세스가 %d개 있습니다: %s." % (
        pid, procs[pid]["comm"], len(desc), shown)
    if len(risky) > 1:
        msg += " 아래에 프로세스를 둔 대상이 이 밖에 %d개 더 있습니다." % (len(risky) - 1)
    msg += " 감싸는 프로세스만 끝내도 안쪽이 같이 끝날 수 있습니다. 끝내도 되는지 사용자에게 확인받으세요."
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                             "permissionDecision": "ask",
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
