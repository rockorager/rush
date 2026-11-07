/* Links the installed C ABI (`librush`) through the public header, as an
 * embedder would, and checks eval plus output capture. */

#include "rush.h"

#include <stdio.h>
#include <string.h>

static int failures;

static void check(int ok, const char *expr, int line) {
    if (ok) return;
    fprintf(stderr, "abi.c:%d: check failed: %s\n", line, expr);
    failures++;
}

static void check_output(const char *name, const uint8_t *ptr, size_t len, const char *expected, int line) {
    size_t expected_len = strlen(expected);
    if (len == expected_len && (len == 0 || memcmp(ptr, expected, len) == 0)) return;
    fprintf(stderr, "abi.c:%d: %s was \"%.*s\", expected \"%s\"\n", line, name, (int)len,
            len == 0 ? "" : (const char *)ptr, expected);
    failures++;
}

#define CHECK(expr) check((expr) != 0, #expr, __LINE__)
#define CHECK_STDOUT(instance, expected) \
    check_output("stdout", rush_stdout_ptr(instance), rush_stdout_len(instance), expected, __LINE__)
#define CHECK_STDERR(instance, expected) \
    check_output("stderr", rush_stderr_ptr(instance), rush_stderr_len(instance), expected, __LINE__)

static uint8_t eval(Rush *instance, const char *src) {
    return rush_eval(instance, (const uint8_t *)src, strlen(src));
}

static Rush *create(int line) {
    Rush *instance = rush_create();
    check(instance != NULL, "rush_create() != NULL", line);
    return instance;
}

static void version_is_non_empty(void) {
    CHECK(rush_version()[0] != '\0');
}

static void eval_captures_stdout(void) {
    Rush *instance = create(__LINE__);
    if (instance == NULL) return;
    CHECK(eval(instance, "echo hello") == 0);
    CHECK_STDOUT(instance, "hello\n");
    rush_destroy(instance);
}

static void standard_descriptor_redirections_route_and_close_output(void) {
    Rush *instance = create(__LINE__);
    if (instance == NULL) return;
    CHECK(eval(instance, "echo error >&2; echo hidden >&-; echo visible") == 0);
    CHECK_STDOUT(instance, "visible\n");
    CHECK_STDERR(instance, "error\necho: write failed\n");
    rush_destroy(instance);
}

static void unavailable_pipeline_reports_a_shell_error(void) {
    Rush *instance = create(__LINE__);
    if (instance == NULL) return;
    CHECK(eval(instance, "echo a | echo b") == 2);
    CHECK_STDERR(instance, "rush: shell error\n");
    rush_destroy(instance);
}

static void exec_of_an_unavailable_external_command_returns_127(void) {
    Rush *instance = create(__LINE__);
    if (instance == NULL) return;
    CHECK(eval(instance, "exec definitely-not-an-embedded-builtin") == 127);
    CHECK_STDERR(instance, "exec: definitely-not-an-embedded-builtin: not found\n");
    rush_destroy(instance);
}

static void finished_session_retains_an_exit_trap_failure_status(void) {
    Rush *instance = create(__LINE__);
    if (instance == NULL) return;
    CHECK(eval(instance, "trap 'echo a | echo b' EXIT; exit 7") == 2);
    CHECK(eval(instance, "echo still") == 2);
    CHECK_STDOUT(instance, "");
    CHECK_STDERR(instance, "");
    rush_destroy(instance);
}

static void nullable_cleanup_and_allocation_edge_cases(void) {
    rush_destroy(NULL);
    rush_wasm_free_u8_array(NULL, 0);
    CHECK(rush_wasm_alloc_u8_array(0) == NULL);

    uint8_t *bytes = rush_wasm_alloc_u8_array(16);
    CHECK(bytes != NULL);
    rush_wasm_free_u8_array(bytes, 16);
}

int main(void) {
    version_is_non_empty();
    eval_captures_stdout();
    standard_descriptor_redirections_route_and_close_output();
    unavailable_pipeline_reports_a_shell_error();
    exec_of_an_unavailable_external_command_returns_127();
    finished_session_retains_an_exit_trap_failure_status();
    nullable_cleanup_and_allocation_edge_cases();
    if (failures != 0) {
        fprintf(stderr, "librush ABI: %d check(s) failed\n", failures);
        return 1;
    }
    return 0;
}
