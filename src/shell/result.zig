//! Evaluation results and shell control flow.

pub const ExitStatus = u8;

pub const ControlFlow = union(enum) {
    normal,
    /// Unwind the current command after enabling noexec; the source reader
    /// must continue parsing subsequent input without evaluating it.
    noexec,
    exit: ExitStatus,
    return_: ExitStatus,
    break_: usize,
    continue_: usize,
    fatal: ExitStatus,
};

pub const EvalResult = struct {
    status: ExitStatus = 0,
    flow: ControlFlow = .normal,
};

pub const Diagnostic = struct {
    message: []const u8,
    status: ExitStatus = 2,
};
