import sys

if len(sys.argv) < 2:
    print("Usage: patch_makefile.py <path_to_makefile_in>")
    sys.exit(1)

path = sys.argv[1]
print(f"Patching {path}...")

with open(path, "r") as f:
    lines = f.readlines()

new_lines = []
skip = False
patched = False

for line in lines:
    if line.startswith("install-exec-hook:"):
        new_lines.append(line)
        new_lines.append('\t@echo "install-exec-hook bypassed for static macOS build"\n')
        skip = True
        patched = True
        continue
    if skip:
        # Stop skipping when we hit the next rule or an empty line before it
        if line.startswith("uninstall-local:") or line.strip() == "uninstall-local:":
            skip = False
        elif line.strip() == "" and any(l.startswith("uninstall-local:") for l in lines[lines.index(line):lines.index(line)+3]):
            skip = False
        else:
            continue
    new_lines.append(line)

with open(path, "w") as f:
    f.writelines(new_lines)

if patched:
    print("Successfully patched install-exec-hook.")
else:
    print("Warning: install-exec-hook target not found in file.")
