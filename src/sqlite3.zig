//! The subset of the SQLite C API that history storage uses, declared from
//! `sqlite3.h`. Pointer types mirror translated C so nullability matches the
//! header; the symbols come from the bundled or system libsqlite3.

pub const sqlite3 = opaque {};
pub const sqlite3_stmt = opaque {};
pub const sqlite3_int64 = c_longlong;
pub const sqlite3_destructor_type = ?*const fn (?*anyopaque) callconv(.c) void;
pub const sqlite3_callback = ?*const fn (?*anyopaque, c_int, [*c][*c]u8, [*c][*c]u8) callconv(.c) c_int;

pub const SQLITE_OK = 0;
pub const SQLITE_ROW = 100;
pub const SQLITE_DONE = 101;
pub const SQLITE_NULL = 5;
pub const SQLITE_OPEN_READWRITE = 0x00000002;
pub const SQLITE_OPEN_CREATE = 0x00000004;
pub const SQLITE_OPEN_NOMUTEX = 0x00008000;

pub extern fn sqlite3_open_v2(filename: [*c]const u8, db: [*c]?*sqlite3, flags: c_int, vfs: [*c]const u8) c_int;
pub extern fn sqlite3_close(db: ?*sqlite3) c_int;
pub extern fn sqlite3_exec(
    db: ?*sqlite3,
    sql: [*c]const u8,
    callback: sqlite3_callback,
    context: ?*anyopaque,
    errmsg: [*c][*c]u8,
) c_int;
pub extern fn sqlite3_errcode(db: ?*sqlite3) c_int;
pub extern fn sqlite3_errmsg(db: ?*sqlite3) [*c]const u8;
pub extern fn sqlite3_changes(db: ?*sqlite3) c_int;
pub extern fn sqlite3_last_insert_rowid(db: ?*sqlite3) sqlite3_int64;
pub extern fn sqlite3_compileoption_used(option_name: [*c]const u8) c_int;
pub extern fn sqlite3_free(ptr: ?*anyopaque) void;

pub extern fn sqlite3_prepare_v2(
    db: ?*sqlite3,
    sql: [*c]const u8,
    sql_len: c_int,
    stmt: [*c]?*sqlite3_stmt,
    tail: [*c][*c]const u8,
) c_int;
pub extern fn sqlite3_step(stmt: ?*sqlite3_stmt) c_int;
pub extern fn sqlite3_reset(stmt: ?*sqlite3_stmt) c_int;
pub extern fn sqlite3_clear_bindings(stmt: ?*sqlite3_stmt) c_int;
pub extern fn sqlite3_finalize(stmt: ?*sqlite3_stmt) c_int;

pub extern fn sqlite3_bind_int(stmt: ?*sqlite3_stmt, index: c_int, value: c_int) c_int;
pub extern fn sqlite3_bind_int64(stmt: ?*sqlite3_stmt, index: c_int, value: sqlite3_int64) c_int;
pub extern fn sqlite3_bind_null(stmt: ?*sqlite3_stmt, index: c_int) c_int;
pub extern fn sqlite3_bind_text(
    stmt: ?*sqlite3_stmt,
    index: c_int,
    text: [*c]const u8,
    len: c_int,
    destructor: sqlite3_destructor_type,
) c_int;

pub extern fn sqlite3_column_type(stmt: ?*sqlite3_stmt, column: c_int) c_int;
pub extern fn sqlite3_column_int(stmt: ?*sqlite3_stmt, column: c_int) c_int;
pub extern fn sqlite3_column_int64(stmt: ?*sqlite3_stmt, column: c_int) sqlite3_int64;
pub extern fn sqlite3_column_text(stmt: ?*sqlite3_stmt, column: c_int) [*c]const u8;
