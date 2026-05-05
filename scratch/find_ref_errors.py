import json
import os

with open('src_lint.json', 'r') as f:
    data = json.load(f)

files_with_ref_errors = {}
for file in data:
    path = file['filePath']
    errors = [m for m in file['messages'] if "refs" in m.get('message', '').lower()]
    if errors:
        files_with_ref_errors[path] = errors

for path, errors in sorted(files_with_ref_errors.items()):
    rel_path = os.path.relpath(path, os.getcwd())
    print(f"{rel_path}: {len(errors)} ref errors")
    for e in errors:
        print(f"  Line {e['line']}: {e['message'][:100]}...")
