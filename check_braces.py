import re

def check_braces(filename):
    with open(filename, 'r') as f:
        content = f.read()

    # Remove strings
    content = re.sub(r'".*?(?<!\\)"', '""', content)
    # Remove block comments
    content = re.sub(r'/\*.*?\*/', '', content, flags=re.DOTALL)
    # Remove line comments
    content = re.sub(r'//.*', '', content)

    stack = []
    line_num = 1
    for i, char in enumerate(content):
        if char == '\n':
            line_num += 1
        elif char == '{':
            stack.append(line_num)
        elif char == '}':
            if stack:
                stack.pop()
            else:
                print(f"Unmatched }} at line {line_num}")
                return
    if stack:
        print(f"Unmatched {{ from lines: {stack}")
    else:
        print("Braces are balanced")

check_braces('Bar Tasker/KanbanBoardView.swift')
