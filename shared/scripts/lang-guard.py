#!/usr/bin/env python3
# PostToolUse 훅. 도구를 부르기 직전에 쓴 글이 사용자가 쓰는 언어와 다르면 그 턴 안에서 바로 알린다.
#
# 규칙(CLAUDE.md 응답 형식의 언어 행)은 있는데 짧은 진행 줄이 영어로 샌다.
# 규칙을 넣은 뒤에도 일주일 동안 8개 프로젝트에서 영어 진행 줄이 43번 나갔다.
# 문서로는 안 막혀서, 새는 순간에 모델에게 되돌려 준다.
#
# 입력: 훅 JSON (stdin). transcript_path, session_id, tool_use_id 를 쓴다.
# 출력: 어긋났을 때만 hookSpecificOutput.additionalContext 를 담은 JSON 한 줄. 나머지는 아무것도 안 낸다.
# 언제나 0 으로 끝난다. 이 훅이 깨져도 작업을 막지 않는다.
#
# PreToolUse 가 아니라 PostToolUse 인 이유: PreToolUse 시점에는 바로 앞 글이 아직 기록에 없었다.
# PostToolUse 시점에는 들어와 있고, additionalContext 는 같은 턴 안에서 모델에게 닿았다 (2026-11-03 실측).
import json
import os
import re
import sys
import tempfile
import hashlib

SCRIPTS = {
    # 자음·모음 낱자(ㄱ-ㆎ)도 한국어다. 사용자는 "ㄱㄱ", "ㅇㅇ" 처럼 낱자만으로 답한다.
    # 완성형(가-힣)만 보면 그 뒤로 판정을 건너뛰어 영어 진행 줄을 놓쳤다.
    "한국어": re.compile(r"[가-힣ㄱ-ㆎ]"),
    "일본어": re.compile(r"[぀-ヿ]"),
    "중국어": re.compile(r"[一-鿿]"),
    "러시아어": re.compile(r"[Ѐ-ӿ]"),
}
LATIN_WORD = re.compile(r"[A-Za-z]{2,}")
PARENS = re.compile(r"\([^()]*\)")
MIN_WORDS = 2          # 이보다 짧은 영어 조각(명령 이름, 상태 한 단어)은 넘긴다. "Still installing." 은 2단어다
TAIL_BYTES = 4 << 20   # 기록 끝에서 이만큼만 읽는다. 사용자 발화를 못 찾으면 이 세션에서 전에 본 언어로 판정한다


def strip_code(t):
    t = re.sub(r"```.*?```", " ", t, flags=re.S)
    t = re.sub(r"`[^`\n]*`", " ", t)
    t = re.sub(r"https?://\S+", " ", t)
    t = re.sub(r"(?:~|\.{0,2})?/[\w./-]+", " ", t)
    return t


def user_text(entry):
    """사람이 직접 쓴 발화면 그 글, 아니면 None (tool_result, 명령 출력, 시스템 주입)."""
    if entry.get("type") != "user" or entry.get("isMeta"):
        return None
    c = (entry.get("message") or {}).get("content")
    if isinstance(c, str):
        texts = [c]
    elif isinstance(c, list):
        if any((x or {}).get("type") == "tool_result" for x in c):
            return None
        texts = [x.get("text", "") for x in c if (x or {}).get("type") == "text"]
    else:
        return None
    t = "\n".join(texts).strip()
    if not t or t.startswith("<") or t.startswith("[Request interrupted"):
        return None
    return t


def read_tail(path):
    with open(path, "rb") as f:
        f.seek(0, 2)
        size = f.tell()
        f.seek(max(0, size - TAIL_BYTES))
        data = f.read()
    lines = data.split(b"\n")
    if size > TAIL_BYTES:
        lines = lines[1:]  # 잘린 첫 줄
    out = []
    for l in lines:
        try:
            out.append(json.loads(l))
        except Exception:
            pass
    return out


def main():
    d = json.load(sys.stdin)
    entries = read_tail(d["transcript_path"])
    cur = d.get("tool_use_id")

    # 뒤에서부터: 이번 도구 호출 바로 앞의 글 묶음과, 마지막 사용자 발화를 찾는다.
    pending, collecting, utext = [], True, None
    for e in reversed(entries):
        t = e.get("type")
        if t == "assistant":
            if collecting:
                for x in (e.get("message") or {}).get("content") or []:
                    if (x or {}).get("type") == "text" and x.get("text", "").strip():
                        pending.append(x["text"])
            continue
        if t != "user":
            continue
        c = (e.get("message") or {}).get("content")
        own = isinstance(c, list) and any(
            (x or {}).get("type") == "tool_result" and x.get("tool_use_id") == cur for x in c)
        if own and not pending:
            continue  # 이번 도구의 결과가 먼저 기록돼 있으면 건너뛴다
        collecting = False
        ut = user_text(e)
        if ut is not None:
            utext = ut
            break
    if not pending:
        return

    base = os.path.join(tempfile.gettempdir(), "lang-guard-%s" % re.sub(r"\W", "", d.get("session_id", "x")))
    # 사용자 언어를 세션마다 적어 둔다. 긴 작업 중에는 마지막 사용자 발화가 기록 끝 TAIL_BYTES 밖으로
    # 밀려나는데(6MB 떨어진 경우가 있었다), 그때도 이 값으로 판정한다.
    langfile = base + ".lang"
    if utext is not None:
        lang = next((n for n, rx in SCRIPTS.items() if rx.search(utext)), None)
        try:
            with open(langfile, "w") as f:
                f.write(lang or "-")
        except OSError:
            pass
    else:
        try:
            lang = open(langfile).read().strip()
        except OSError:
            return
        if lang not in SCRIPTS:
            return
    if lang is None:
        return  # 사용자가 영어(라틴 문자)로 쓰면 볼 것이 없다
    rx = SCRIPTS[lang]

    bad = []
    for t in reversed(pending):  # 쓴 순서대로
        # 괄호 안만 사용자 언어인 글("Still waiting (20분 상한)")은 사용자 언어로 쓴 글이 아니다
        s = PARENS.sub(" ", strip_code(t))
        if rx.search(s):
            continue
        if len(LATIN_WORD.findall(s)) >= MIN_WORDS:
            bad.append(t.strip())
    if not bad:
        return

    # 병렬 도구 호출이면 같은 글에 PostToolUse 가 여러 번 온다. 한 번만 알린다.
    key = hashlib.sha1("\n".join(bad).encode()).hexdigest()[:16]
    seen = base
    try:
        if key in open(seen).read().split():
            return
    except OSError:
        pass
    try:
        with open(seen, "a") as f:
            f.write(key + "\n")
    except OSError:
        pass

    sample = bad[0].replace("\n", " ")
    if len(sample) > 80:
        sample = sample[:80] + "..."
    msg = (
        "[lang-guard] 방금 도구를 부르기 전에 쓴 글이 %s가 아니었습니다: \"%s\". "
        "사용자는 %s로 씁니다. 진행 문장도 사용자가 쓴 언어로 씁니다 (CLAUDE.md 응답 형식의 언어 행). "
        "다음 글부터 %s로 쓰세요. 이 안내에 답하거나 사과하지 말고 하던 일을 이어갑니다."
        % (lang, sample, lang, lang)
    )
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse",
                                             "additionalContext": msg}}, ensure_ascii=False))


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
