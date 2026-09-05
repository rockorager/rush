import subprocess

p = subprocess.run("printf '%s\\n' \"$(printf python-ok)\"", shell=True, capture_output=True, text=True)
assert (p.returncode, p.stdout, p.stderr) == (0, "python-ok\n", ""), p
p = subprocess.run("exit 9", shell=True)
assert p.returncode == 9, p
print("subprocess shell=True:ok")
