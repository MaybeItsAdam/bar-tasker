import re

def check(filename):
    with open(filename, 'r') as f:
        lines = f.readlines()

    depth = 0
    for i, line in enumerate(lines, 1):
        stripped = line.strip()
        if stripped.startswith('//') or not stripped:
            continue
        
        # very basic heuristic: count indent spaces
        indent = len(line) - len(line.lstrip(' '))
        expected_indent = depth * 2
        
        # count braces
        # ignore comments and strings for counting
        clean_line = re.sub(r'".*?(?<!\\)"', '""', line)
        clean_line = re.sub(r'//.*', '', clean_line)
        opens = clean_line.count('{')
        closes = clean_line.count('}')
        
        if closes > 0 and stripped.startswith('}'):
            expected_indent = (depth - closes) * 2
            
        if indent != expected_indent and expected_indent >= 0:
            print(f"L{i}: indent={indent}, expected={expected_indent}, diff={indent-expected_indent} | {stripped[:40]}")
            
        depth += opens - closes

check('Bar Tasker/KanbanBoardView.swift')
