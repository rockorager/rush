#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>

int main(void) {
    int status = system("value='two words'; test \"$value\" = 'two words'; exit 7");
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 7) return 1;
    FILE *pipe = popen("printf '%s\\n' \"$(printf popen-ok)\"", "r");
    if (!pipe) return 2;
    char text[64];
    if (!fgets(text, sizeof(text), pipe)) return 3;
    status = pclose(pipe);
    if (strcmp(text, "popen-ok\n") || !WIFEXITED(status) || WEXITSTATUS(status)) return 4;
    puts("system:7\npopen:ok");
    return 0;
}
