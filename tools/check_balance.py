"""粗略的结构检查：括号/花括号/方括号是否配平（跳过字符串与注释）。
不能替代 dart analyze，但能抓出明显的手误。
"""
import sys
from pathlib import Path

ROOT = Path(r"C:/Users/Tyler Zhang/WorkBuddy AI/2026-10-27-20-51-53/wisp/lib")
PAIRS = {')': '(', ']': '[', '}': '{'}


def strip_code(src: str) -> str:
    out = []
    i, n = 0, len(src)
    state = None  # None | 'line' | 'block' | 'single' | 'double' | 'raw'
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ''
        if state is None:
            if c == '/' and nxt == '/':
                state = 'line'
                i += 2
                continue
            if c == '/' and nxt == '*':
                state = 'block'
                i += 2
                continue
            if c == "'" and nxt == "'" and src[i + 2:i + 3] == "'":
                state = 'triple_s'
                i += 3
                continue
            if c == '"' and nxt == '"' and src[i + 2:i + 3] == '"':
                state = 'triple_d'
                i += 3
                continue
            if c == "'":
                state = 'single'
                i += 1
                continue
            if c == '"':
                state = 'double'
                i += 1
                continue
            out.append(c)
            i += 1
            continue
        if state == 'line':
            if c == '\n':
                state = None
            i += 1
            continue
        if state == 'block':
            if c == '*' and nxt == '/':
                state = None
                i += 2
                continue
            i += 1
            continue
        if state in ('triple_s', 'triple_d'):
            q = "'" if state == 'triple_s' else '"'
            if src[i:i + 3] == q * 3:
                state = None
                i += 3
                continue
            i += 1
            continue
        if state in ('single', 'double'):
            if c == '\\':
                i += 2
                continue
            if (state == 'single' and c == "'") or (state == 'double' and c == '"'):
                state = None
            i += 1
            continue
    return ''.join(out)


bad = 0
for path in sorted(ROOT.rglob('*.dart')):
    code = strip_code(path.read_text(encoding='utf-8'))
    stack = []
    line = 1
    ok = True
    for ch in code:
        if ch == '\n':
            line += 1
        elif ch in '([{':
            stack.append((ch, line))
        elif ch in ')]}':
            if not stack or stack[-1][0] != PAIRS[ch]:
                print(f'{path.relative_to(ROOT)}:{line} 多余的 {ch}')
                ok = False
                break
            stack.pop()
    if ok and stack:
        ch, ln = stack[-1]
        print(f'{path.relative_to(ROOT)}:{ln} 未闭合的 {ch}')
        ok = False
    if not ok:
        bad += 1

total = len(list(ROOT.rglob('*.dart')))
print(f'检查 {total} 个文件，问题 {bad} 个')
sys.exit(1 if bad else 0)
