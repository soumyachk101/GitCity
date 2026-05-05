import json
import sys

try:
    with open('lint_results.json', 'r') as f:
        data = json.load(f)
except Exception as e:
    print(f"Error loading JSON: {e}")
    sys.exit(1)

critical_patterns = ["setState", "refs", "impure", "render"]
summary = {}

for file in data:
    path = file['filePath']
    critical_errors = []
    for msg in file['messages']:
        if msg['severity'] == 2: # Error
            if any(p in msg['message'] for p in critical_patterns):
                critical_errors.append(msg)
    
    if critical_errors:
        summary[path] = critical_errors

for path, errors in sorted(summary.items(), key=lambda x: len(x[1]), reverse=True):
    print(f"{path}: {len(errors)} critical errors")
    for e in errors[:3]:
        print(f"  Line {e['line']}: {e['message'][:100]}...")
