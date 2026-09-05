import os
import subprocess
import tempfile

with tempfile.TemporaryDirectory() as directory:
    os.chmod(directory, 0o755)
    startup = directory + "/env.sh"
    with open(startup, "w") as output:
        output.write('if [ "$(id -ru)" != "$(id -u)" ] || [ "$(id -rg)" != "$(id -g)" ]; '
                     'then printf UNSAFE; fi\nprintf "ENV\\n"\n')
    os.chmod(startup, 0o644)
    env = {"PATH": "/usr/bin:/bin", "HOME": directory, "ENV": startup, "LC_ALL": "C", "TERM": "dumb"}
    for name, args, setup in [
        ("interactive-c", ["-ic", 'printf "BODY\\n"'], None),
        ("interactive-stdin", ["-i"], None),
        ("mismatched-uid", ["-i"], lambda: os.setresuid(65534, 0, 0)),
        ("mismatched-gid", ["-i"], lambda: os.setresgid(65534, 0, 0)),
    ]:
        result = subprocess.run(["/bin/sh", *args], env=env, input="exit\n", text=True,
                                capture_output=True, preexec_fn=setup, timeout=10)
        print(name, result.returncode, repr(result.stdout), repr(result.stderr))
        assert result.returncode == 0 and "UNSAFE" not in result.stdout, result
        if name == "interactive-c":
            assert result.stdout == "ENV\nBODY\n", result
        elif name == "interactive-stdin":
            assert result.stdout == "ENV\n", result
