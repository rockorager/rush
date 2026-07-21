//! Terminal editor namespace.
//!
//! Core modules are deterministic editor state, policy, rendering, and request
//! planning. Adapter modules own TTY, signal, thread, and provider effects.

pub const buffer = @import("editor/buffer.zig");
pub const completion = @import("editor/completion.zig");
pub const driver = @import("editor/driver.zig");
pub const history = @import("editor/history.zig");
pub const key = @import("editor/key.zig");
pub const menu = @import("editor/menu.zig");
pub const path = @import("editor/path.zig");
pub const prompt_markers = @import("prompt_markers.zig");
pub const render = @import("editor/render.zig");
pub const request = @import("editor/request.zig");
/// Editor-only signal adapter for interactive event-loop wake pipes. It stays
/// here rather than in `runtime/*` because the API is tied to editor driver
/// lifecycle and not a general shell runtime port.
pub const signal = @import("editor/signal.zig");
pub const session = @import("editor/session.zig");
pub const line = session;
pub const terminal = @import("editor/terminal.zig");
pub const vi = @import("editor/vi.zig");
