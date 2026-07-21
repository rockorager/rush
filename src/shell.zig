//! Public facade for the rewritten shell core.

const std = @import("std");
const shell_factory = @import("shell/shell_factory.zig");

pub const ast = @import("shell/ast.zig");
pub const builtin = @import("shell/builtin.zig");
pub const eval = @import("shell/eval.zig");
pub const invocation = @import("shell/invocation.zig");
pub const lexer = @import("shell/lexer.zig");
pub const memory = @import("shell/memory.zig");
pub const output = @import("shell/output.zig");
pub const parser = @import("shell/parser.zig");
pub const printf = @import("shell/printf.zig");
pub const prompt = @import("shell/prompt.zig");
pub const result = @import("shell/result.zig");
pub const source = @import("shell/source.zig");
pub const state = @import("shell/state.zig");
pub const token = @import("shell/token.zig");

pub const Shell = shell_factory.Shell;
pub const ShellWithBuiltins = shell_factory.ShellWithBuiltins;

pub const ExitStatus = result.ExitStatus;
pub const EvalResult = result.EvalResult;
pub const ShellState = state.State;
pub const SourceSpan = source.Span;
pub const Token = token.Token;

test {
    std.testing.refAllDecls(@This());
}
