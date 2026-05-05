import json
import os

with open('lint_results.json', 'r') as f:
    data = json.load(f)

rules = ["react-hooks/set-state-in-effect", "react-hooks/refs"]
files_with_errors = {}

for file in data:
    path = file['filePath']
    errors = [m for m in file['messages'] if m.get('ruleId') in rules]
    if errors:
        files_with_errors[path] = errors

for path, errors in sorted(files_with_errors.items()):
    rel_path = os.path.relpath(path, os.getcwd())
    print(f"{rel_path}: {len(errors)} functional errors")
    for e in errors:
        print(f"  Line {e['line']}: {e['ruleId']} - {e['message'][:80]}...")
