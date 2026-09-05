#!/bin/bash
# This orchestrator stays on Bash; tested commands explicitly use /bin/sh.
set -u
flavor=$1
case $flavor in
    dash) ;;
    rush) ln -sfn /usr/local/bin/rush /bin/sh ;;
    *) exit 2 ;;
esac
export LC_ALL=C DEBIAN_FRONTEND=noninteractive
printf 'stage\tstatus\tseconds\n' >/results/status.tsv
{
    cat /etc/os-release
    printf 'shell=%s\n' "$(readlink /bin/sh)"
    dpkg-query -W
    sha256sum /usr/local/bin/rush
    sha256sum /sources/*.orig.tar.*
} >/results/environment.txt
failed=0
run() {
    local name=$1 start end status
    shift
    start=$(python3 -c 'import time; print(time.monotonic_ns())')
    printf 'START %s\n' "$name"
    timeout --kill-after=10s 600s "$@" >"/results/$name.log" 2>&1
    status=$?
    end=$(python3 -c 'import time; print(time.monotonic_ns())')
    printf '%s\t%s\t%s\n' "$name" "$status" "$(((end-start)/1000000000))" | tee -a /results/status.tsv
    if ((status != 0)); then failed=1; fi
    return "$status"
}
skip() {
    printf '%s\t125\t0\n' "$1" | tee -a /results/status.tsv
    printf 'Not run: prerequisite failed\n' >"/results/$1.log"
    failed=1
}

run make make --no-print-directory -f /fixtures/Makefile -C /work
run libc-build gcc -Wall -Wextra -Werror /fixtures/callers.c -o /work/callers
run libc-callers /work/callers
run python-callers python3 /fixtures/callers.py
run startup python3 /fixtures/startup-probes.py

for package in hello dash gzip coreutils findutils; do
    directory=(/sources/"$package"-*/configure)
    directory=${directory[0]%/configure}
    pushd "$directory" >/dev/null || exit 2
    if run "$package-configure" env FORCE_UNSAFE_CONFIGURE=1 CONFIG_SHELL=/bin/sh \
        /bin/sh ./configure --prefix=/work/install --disable-nls; then
        if run "$package-build" make -j2 SHELL=/bin/sh; then
            # GNU tests should exercise normal-user behavior, not skip it as root.
            chown -R tester:tester "$directory"
            run "$package-check" runuser -u tester -- env RUN_EXPENSIVE_TESTS=no \
                RUN_VERY_EXPENSIVE_TESTS=no make -j2 SHELL=/bin/sh check
            run "$package-install" make SHELL=/bin/sh install
        else
            skip "$package-check"
            skip "$package-install"
        fi
    else
        skip "$package-build"
        skip "$package-check"
        skip "$package-install"
    fi
    # Keep detailed upstream failure reports after the container is removed.
    find "$directory" -name test-suite.log -exec cp --parents '{}' /results/ \;
    popd >/dev/null
done

directory=(/sources/git-*/Makefile)
directory=${directory[0]%/Makefile}
pushd "$directory" >/dev/null || exit 2
if run git-build make -j2 prefix=/work/install SHELL_PATH=/bin/sh SHELL=/bin/sh \
    NO_GETTEXT=YesPlease NO_TCLTK=YesPlease all; then
    chown -R tester:tester "$directory"
    run git-check runuser -u tester -- make -C t prefix=/work/install SHELL_PATH=/bin/sh SHELL=/bin/sh \
        NO_GETTEXT=YesPlease NO_TCLTK=YesPlease \
        'T=t0000-basic.sh t0001-init.sh t0020-crlf.sh t0040-parse-options.sh t1400-update-ref.sh'
    run git-install make SHELL_PATH=/bin/sh SHELL=/bin/sh NO_GETTEXT=YesPlease NO_TCLTK=YesPlease \
        prefix=/work/install install
else
    skip git-check
    skip git-install
fi
if [[ -d t/test-results ]]; then cp -r t/test-results /results/git-test-results; fi
popd >/dev/null

run apt-install apt-get install -y --no-install-recommends cron logrotate man-db openssh-server locales
run dpkg-configure dpkg --configure -a
run apt-reinstall apt-get install -y --reinstall cron logrotate man-db openssh-server
run apt-upgrade apt-get upgrade -y
run lifecycle-install dpkg -i /packages/lifecycle-1.deb
run lifecycle-upgrade dpkg -i /packages/lifecycle-2.deb
run lifecycle-remove dpkg -r rush-shell-lifecycle
run lifecycle-purge dpkg -P rush-shell-lifecycle
cp /var/log/rush-lifecycle.log /results/lifecycle.log
run apt-remove apt-get remove -y cron logrotate man-db openssh-server
run apt-purge apt-get purge -y cron logrotate man-db openssh-server
run apt-reinstall-certificates apt-get install -y --reinstall ca-certificates
run dpkg-audit /bin/bash -c 'dpkg --audit > /results/dpkg-audit.txt; status=$?; cat /results/dpkg-audit.txt; test "$status" -eq 0 && test ! -s /results/dpkg-audit.txt'
run shell-target /bin/bash -c 'actual=$(readlink -f /bin/sh); printf "%s\n" "$actual"; if [[ $1 == rush ]]; then test "$actual" = /usr/local/bin/rush; else test "$actual" = /usr/bin/dash; fi' _ "$flavor"
exit "$failed"
