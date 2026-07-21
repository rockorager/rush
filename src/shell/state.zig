//! Mutable shell state for direct evaluation.

const std = @import("std");

const ast = @import("ast.zig");
const host = @import("../host.zig");
const memory = @import("memory.zig");
const result = @import("result.zig");
const source = @import("source.zig");

pub const Mode = enum {
    posix,
    bash,
};

pub const Options = struct {
    mode: Mode = .bash,
    allexport: bool = false,
    /// Implementation-extension Emacs-style line editing. On by default and
    /// mutually exclusive with `vi` when either option is enabled.
    emacs: bool = true,
    errexit: bool = false,
    hashall: bool = false,
    history: bool = false,
    nounset: bool = false,
    noglob: bool = false,
    noclobber: bool = false,
    noexec: bool = false,
    pipefail: bool = false,
    promptvars: bool = true,
    notify: bool = false,
    verbose: bool = false,
    /// POSIX vi command-line editing for the interactive line editor.
    /// Mutually exclusive with `emacs` when either option is enabled.
    vi: bool = false,
    expand_aliases: bool = false,
    xtrace: bool = false,
    monitor: bool = false,
    interactive: bool = false,
};

pub const Variable = struct {
    name: []const u8,
    value: []const u8,
    exported: bool = false,
    readonly: bool = false,
    integer: bool = false,

    pub fn validate(self: Variable) void {
        std.debug.assert(self.name.len != 0);
    }
};

pub const VariableAttributes = struct {
    name: []const u8,
    exported: bool = false,
    readonly: bool = false,
    integer: bool = false,

    pub fn validate(self: VariableAttributes) void {
        std.debug.assert(self.name.len != 0);
        std.debug.assert(self.exported or self.readonly or self.integer);
    }
};

pub const ProcessSubstitution = struct {
    fd: host.Fd,
    pid: host.Pid,
};

pub const ReapOnlyProcessSubstitution = struct {
    pid: host.Pid,
};

pub const PromptMetadataField = enum {
    username,
    hostname,
    terminal_name,
};

const PromptMetadata = struct {
    username: ?[]const u8 = null,
    hostname: ?[]const u8 = null,
    terminal_name: ?[]const u8 = null,

    fn value(self: PromptMetadata, field: PromptMetadataField) ?[]const u8 {
        return switch (field) {
            .username => self.username,
            .hostname => self.hostname,
            .terminal_name => self.terminal_name,
        };
    }

    fn set(self: *PromptMetadata, field: PromptMetadataField, value_text: []const u8) void {
        std.debug.assert(self.value(field) == null);
        switch (field) {
            .username => self.username = value_text,
            .hostname => self.hostname = value_text,
            .terminal_name => self.terminal_name = value_text,
        }
    }

    fn deinit(self: *PromptMetadata, allocator: std.mem.Allocator) void {
        if (self.username) |value_text| allocator.free(value_text);
        if (self.hostname) |value_text| allocator.free(value_text);
        if (self.terminal_name) |value_text| allocator.free(value_text);
        self.* = .{};
    }
};

pub const ArrayElement = struct {
    index: usize,
    value: []const u8,
};

pub const ArrayVariable = struct {
    name: []const u8,
    elements: []ArrayElement,
    exported: bool = false,
    readonly: bool = false,
    integer: bool = false,

    pub fn validate(self: ArrayVariable) void {
        std.debug.assert(self.name.len != 0);
        for (self.elements, 0..) |element, index| {
            if (index != 0) std.debug.assert(self.elements[index - 1].index < element.index);
        }
    }

    pub fn elementValue(self: ArrayVariable, index: usize) ?[]const u8 {
        for (self.elements) |element| {
            if (element.index == index) return element.value;
            if (element.index > index) return null;
        }
        return null;
    }
};

pub const ArrayAttributes = struct {
    exported: bool = false,
    readonly: bool = false,
    integer: bool = false,
};

pub const Binding = struct {
    name: []const u8,
    value: Value,
    exported: bool = false,
    readonly: bool = false,
    integer: bool = false,

    pub const Value = union(enum) {
        unset,
        scalar: []const u8,
        array: []ArrayElement,
    };

    pub fn variable(self: Binding) ?Variable {
        const value = switch (self.value) {
            .scalar => |value| value,
            else => return null,
        };
        return .{
            .name = self.name,
            .value = value,
            .exported = self.exported,
            .readonly = self.readonly,
            .integer = self.integer,
        };
    }

    pub fn attributes(self: Binding) ?VariableAttributes {
        if (self.value != .unset) return null;
        return .{
            .name = self.name,
            .exported = self.exported,
            .readonly = self.readonly,
            .integer = self.integer,
        };
    }

    pub fn array(self: Binding) ?ArrayVariable {
        const elements = switch (self.value) {
            .array => |elements| elements,
            else => return null,
        };
        return .{
            .name = self.name,
            .elements = elements,
            .exported = self.exported,
            .readonly = self.readonly,
            .integer = self.integer,
        };
    }

    fn deinit(self: Binding, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        switch (self.value) {
            .unset => {},
            .scalar => |value| allocator.free(value),
            .array => |elements| {
                for (elements) |element| allocator.free(element.value);
                allocator.free(elements);
            },
        }
    }
};

const SavedLocalBinding = struct {
    name: []const u8,
    binding: ?Binding,

    fn deinit(self: SavedLocalBinding, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.binding) |binding| binding.deinit(allocator);
    }
};

const LocalFrame = struct {
    saved: std.StringHashMapUnmanaged(SavedLocalBinding) = .empty,
    assignment_prefixes: std.StringHashMapUnmanaged(void) = .empty,

    fn deinit(self: *LocalFrame, allocator: std.mem.Allocator) void {
        var saved_iterator = self.saved.iterator();
        while (saved_iterator.next()) |entry| entry.value_ptr.deinit(allocator);
        self.saved.deinit(allocator);

        var prefix_iterator = self.assignment_prefixes.iterator();
        while (prefix_iterator.next()) |entry| allocator.free(entry.key_ptr.*);
        self.assignment_prefixes.deinit(allocator);
        self.* = undefined;
    }
};

pub const Function = struct {
    name: []const u8,
    source_name: []const u8,
    source_text: []const u8,
    definition: ast.FunctionDefinition,

    pub fn validate(self: Function) void {
        std.debug.assert(self.name.len != 0);
        std.debug.assert(self.source_name.len != 0);
        std.debug.assert(self.source_text.len != 0);
        self.definition.validate();
        std.debug.assert(std.mem.eql(u8, self.name, self.definition.name));
    }
};

pub const FunctionCallFrame = struct {
    name: []const u8,
    source_name: []const u8,
};

const FunctionAutoloadState = enum {
    missed,
    suppressed,
};

fn functionAutoloadSearchUsesVariable(name: []const u8) bool {
    return std.mem.eql(u8, name, "HOME") or
        std.mem.eql(u8, name, "XDG_CONFIG_HOME") or
        std.mem.eql(u8, name, "XDG_DATA_HOME") or
        std.mem.eql(u8, name, "XDG_DATA_DIRS");
}

pub const Alias = struct {
    name: []const u8,
    value: []const u8,

    pub fn validate(self: Alias) void {
        std.debug.assert(self.name.len != 0);
    }
};

pub const CommandHash = struct {
    name: []const u8,
    path: []const u8,

    pub fn validate(self: CommandHash) void {
        std.debug.assert(self.name.len != 0);
        std.debug.assert(self.path.len != 0);
    }
};

pub const JobStatus = enum {
    running,
    stopped,
};

pub const BackgroundJob = struct {
    id: usize,
    pid: host.Pid,
    process_group: host.Pid,
    job_control: bool,
    pids: std.ArrayListUnmanaged(host.Pid) = .empty,
    status: JobStatus = .running,
    command: []const u8,

    pub fn validate(self: BackgroundJob) void {
        std.debug.assert(self.id != 0);
        std.debug.assert(self.pid != 0);
        std.debug.assert(self.process_group != 0);
        std.debug.assert(self.pids.items.len != 0);
        std.debug.assert(self.command.len != 0);
    }

    fn deinit(self: *BackgroundJob, allocator: std.mem.Allocator) void {
        self.pids.deinit(allocator);
        allocator.free(self.command);
        self.* = undefined;
    }
};

pub const State = struct {
    allocator: std.mem.Allocator,
    definition_arena: memory.Arena,
    options: Options = .{},
    bindings: std.StringHashMapUnmanaged(Binding) = .empty,
    local_frames: std.ArrayListUnmanaged(LocalFrame) = .empty,
    function_call_stack: std.ArrayListUnmanaged(FunctionCallFrame) = .empty,
    functions: std.StringHashMapUnmanaged(Function) = .empty,
    function_autoload_states: std.StringHashMapUnmanaged(FunctionAutoloadState) = .empty,
    aliases: std.StringHashMapUnmanaged(Alias) = .empty,
    command_hashes: std.StringHashMapUnmanaged(CommandHash) = .empty,
    signal_traps: std.StringHashMapUnmanaged([]const u8) = .empty,
    pending_traps: std.ArrayListUnmanaged([]const u8) = .empty,
    process_substitutions: std.ArrayListUnmanaged(ProcessSubstitution) = .empty,
    reap_process_substitutions: std.ArrayListUnmanaged(ReapOnlyProcessSubstitution) = .empty,
    background_pids: std.ArrayListUnmanaged(host.Pid) = .empty,
    background_jobs: std.ArrayListUnmanaged(BackgroundJob) = .empty,
    last_status: result.ExitStatus = 0,
    last_pipeline_statuses: []result.ExitStatus = &.{},
    last_status_errexit_ignored: bool = false,
    last_background_pid: ?host.Pid = null,
    getopts_char_index: usize = 1,
    errexit_ignore_depth: usize = 0,
    loop_depth: usize = 0,
    diagnostic_line_offset: usize = 0,
    root_source_kind: ?source.SourceKind = null,
    current_source_name: []const u8 = "environment",
    exit_trap: ?[]const u8 = null,
    exit_trap_listing: ?[]const u8 = null,
    running_exit_trap: bool = false,
    running_signal_trap: bool = false,
    shell_pid: ?host.Pid = null,
    /// Controlling terminal used for job-control handoff. Prefer this over
    /// stdin so fg/bg still work when the interactive editor owns /dev/tty.
    controlling_tty: ?host.Fd = null,
    parent_pid: ?host.Pid = null,
    start_time_ns: i128 = 0,
    seconds_base_time_ns: i128 = 0,
    seconds_offset: i64 = 0,
    random_state: u64 = 1,
    /// One-based number shown by the next Bash `\#` prompt escape.
    prompt_command_number: u64 = 1,
    /// One-based history number shown by the next Bash `\!` prompt escape.
    prompt_history_number: i64 = 1,
    prompt_metadata: PromptMetadata = .{},
    arg_zero: []const u8 = "rush",
    positionals: []const []const u8 = &.{},
    owned_positionals: []const []const u8 = &.{},

    pub fn init(allocator: std.mem.Allocator, options: Options) State {
        return .{
            .allocator = allocator,
            .definition_arena = memory.Arena.init(allocator),
            .options = options,
        };
    }

    pub fn deinit(self: *State) void {
        var binding_iterator = self.bindings.valueIterator();
        while (binding_iterator.next()) |binding| binding.deinit(self.allocator);
        self.bindings.deinit(self.allocator);
        for (self.local_frames.items) |*frame| frame.deinit(self.allocator);
        self.local_frames.deinit(self.allocator);
        self.function_call_stack.deinit(self.allocator);
        self.functions.deinit(self.allocator);
        var autoload_iterator = self.function_autoload_states.iterator();
        while (autoload_iterator.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.function_autoload_states.deinit(self.allocator);
        var alias_iterator = self.aliases.iterator();
        while (alias_iterator.next()) |entry| {
            self.allocator.free(entry.value_ptr.name);
            self.allocator.free(entry.value_ptr.value);
        }
        self.aliases.deinit(self.allocator);
        var command_hash_iterator = self.command_hashes.iterator();
        while (command_hash_iterator.next()) |entry| {
            self.allocator.free(entry.value_ptr.name);
            self.allocator.free(entry.value_ptr.path);
        }
        self.command_hashes.deinit(self.allocator);
        var signal_trap_iterator = self.signal_traps.iterator();
        while (signal_trap_iterator.next()) |entry| self.allocator.free(entry.value_ptr.*);
        self.signal_traps.deinit(self.allocator);
        self.pending_traps.deinit(self.allocator);
        self.process_substitutions.deinit(self.allocator);
        self.reap_process_substitutions.deinit(self.allocator);
        self.background_pids.deinit(self.allocator);
        for (self.background_jobs.items) |*job| job.deinit(self.allocator);
        self.background_jobs.deinit(self.allocator);
        if (self.last_pipeline_statuses.len != 0) self.allocator.free(self.last_pipeline_statuses);
        self.prompt_metadata.deinit(self.allocator);
        self.freeOwnedPositionals();
        self.clearExitTrap();
        self.definition_arena.deinit();
        self.* = undefined;
    }

    pub fn definitionAllocator(self: *State) std.mem.Allocator {
        return self.definition_arena.allocator();
    }

    pub fn getVariable(self: State, name: []const u8) ?Variable {
        std.debug.assert(name.len != 0);
        const binding = self.bindings.get(name) orelse return null;
        return binding.variable();
    }

    pub fn promptMetadata(self: State, field: PromptMetadataField) ?[]const u8 {
        return self.prompt_metadata.value(field);
    }

    /// Copies and caches stable host metadata for prompt escape expansion.
    pub fn cachePromptMetadata(self: *State, field: PromptMetadataField, value_text: []const u8) ![]const u8 {
        if (self.prompt_metadata.value(field)) |cached| return cached;
        const owned = try self.allocator.dupe(u8, value_text);
        self.prompt_metadata.set(field, owned);
        return owned;
    }

    pub fn getArray(self: State, name: []const u8) ?ArrayVariable {
        std.debug.assert(name.len != 0);
        const binding = self.bindings.get(name) orelse return null;
        return binding.array();
    }

    pub fn getVariableAttributes(self: State, name: []const u8) ?VariableAttributes {
        std.debug.assert(name.len != 0);
        const binding = self.bindings.get(name) orelse return null;
        return binding.attributes();
    }

    fn getBindingPtr(self: *State, name: []const u8) ?*Binding {
        return self.bindings.getPtr(name);
    }

    pub fn resetStartTime(self: *State, now_ns: i128) void {
        self.start_time_ns = now_ns;
        self.seconds_base_time_ns = now_ns;
        self.random_state = @intCast(@as(u64, @truncate(@as(u128, @bitCast(now_ns)))) | 1);
    }

    pub fn setRandomSeed(self: *State, text: []const u8) void {
        const parsed = std.fmt.parseInt(i64, text, 10) catch 0;
        const seed = absSeed(parsed);
        self.random_state = if (seed == 0) 1 else seed;
        self.removeVariable("RANDOM");
    }

    fn absSeed(value: i64) u64 {
        if (value >= 0) return @intCast(value);
        return @as(u64, @intCast(-(value + 1))) + 1;
    }

    pub fn nextRandom(self: *State) u15 {
        const modulus: u64 = 2147483647;
        self.random_state = ((self.random_state % modulus) * 16807) % modulus;
        if (self.random_state == 0) self.random_state = 1;
        return @intCast(self.random_state % 32768);
    }

    pub fn resetSeconds(self: *State, text: []const u8, now_ns: i128) void {
        self.seconds_offset = std.fmt.parseInt(i64, text, 10) catch 0;
        self.seconds_base_time_ns = now_ns;
        self.removeVariable("SECONDS");
    }

    pub fn secondsValue(self: State, now_ns: i128) i64 {
        const elapsed_ns = @max(now_ns - self.seconds_base_time_ns, 0);
        return self.seconds_offset + @as(i64, @intCast(@divFloor(elapsed_ns, std.time.ns_per_s)));
    }

    pub fn setLastPipelineStatuses(self: *State, statuses: []const result.ExitStatus) !void {
        std.debug.assert(statuses.len != 0);
        const owned = try self.allocator.dupe(result.ExitStatus, statuses);
        if (self.last_pipeline_statuses.len != 0) self.allocator.free(self.last_pipeline_statuses);
        self.last_pipeline_statuses = owned;
    }

    pub fn putVariable(self: *State, variable: Variable) !void {
        variable.validate();
        const attributes = self.getVariableAttributes(variable.name);
        if (attributes) |attribute| {
            if (attribute.readonly) return error.ReadonlyVariable;
        }
        const owned_value = try self.allocator.dupe(u8, variable.value);
        errdefer self.allocator.free(owned_value);

        if (self.getBindingPtr(variable.name)) |binding| switch (binding.value) {
            .scalar => |existing| {
                if (binding.readonly and !std.mem.eql(u8, existing, variable.value)) return error.ReadonlyVariable;
                self.allocator.free(existing);
                binding.value = .{ .scalar = owned_value };
                binding.exported = variable.exported;
                binding.readonly = variable.readonly;
                binding.integer = binding.integer or variable.integer;
                self.clearFunctionAutoloadMissesIfSearchVariable(variable.name);
                return;
            },
            else => {},
        };

        const owned_name = try self.allocator.dupe(u8, variable.name);
        errdefer self.allocator.free(owned_name);

        self.removeVariable(variable.name);
        try self.bindings.put(self.allocator, owned_name, .{
            .name = owned_name,
            .value = .{ .scalar = owned_value },
            .exported = variable.exported or (attributes != null and attributes.?.exported),
            .readonly = variable.readonly or (attributes != null and attributes.?.readonly),
            .integer = variable.integer or (attributes != null and attributes.?.integer),
        });
        self.clearFunctionAutoloadMissesIfSearchVariable(owned_name);
    }

    pub fn removeVariable(self: *State, name: []const u8) void {
        std.debug.assert(name.len != 0);
        const clears_autoload_misses = functionAutoloadSearchUsesVariable(name);
        if (self.bindings.fetchRemove(name)) |entry| entry.value.deinit(self.allocator);
        if (clears_autoload_misses) self.clearFunctionAutoloadMisses();
    }

    pub fn putArray(self: *State, name: []const u8, values: []const []const u8) !void {
        try self.putArrayWithAttributes(name, values, .{});
    }

    pub fn putArrayWithAttributes(
        self: *State,
        name: []const u8,
        values: []const []const u8,
        declared: ArrayAttributes,
    ) !void {
        std.debug.assert(name.len != 0);
        if (self.getVariableAttributes(name)) |attributes| if (attributes.readonly) return error.ReadonlyVariable;
        if (self.getVariable(name)) |variable| if (variable.readonly) return error.ReadonlyVariable;
        const existing_array = self.getArray(name);
        if (existing_array) |array| if (array.readonly) return error.ReadonlyVariable;
        const attributes = self.getVariableAttributes(name);

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_elements = try self.dupeArrayValues(values);
        errdefer freeArrayElements(self.allocator, owned_elements);

        const exported = (existing_array != null and existing_array.?.exported) or
            (attributes != null and attributes.?.exported) or declared.exported;
        const readonly = (existing_array != null and existing_array.?.readonly) or
            (attributes != null and attributes.?.readonly) or declared.readonly;
        const integer = (existing_array != null and existing_array.?.integer) or
            (attributes != null and attributes.?.integer) or declared.integer;

        self.removeVariable(name);
        try self.bindings.put(self.allocator, owned_name, .{
            .name = owned_name,
            .value = .{ .array = owned_elements },
            .exported = exported,
            .readonly = readonly,
            .integer = integer,
        });
        self.clearFunctionAutoloadMissesIfSearchVariable(owned_name);
    }

    pub fn putArrayElements(self: *State, name: []const u8, elements: []const ArrayElement) !void {
        try self.putArrayElementsWithAttributes(name, elements, .{});
    }

    pub fn putArrayElementsWithAttributes(
        self: *State,
        name: []const u8,
        elements: []const ArrayElement,
        declared: ArrayAttributes,
    ) !void {
        std.debug.assert(name.len != 0);
        if (self.getVariableAttributes(name)) |attributes| if (attributes.readonly) return error.ReadonlyVariable;
        if (self.getVariable(name)) |variable| if (variable.readonly) return error.ReadonlyVariable;

        try self.putArrayWithAttributes(name, &.{}, .{
            .exported = declared.exported,
            .integer = declared.integer,
        });
        for (elements) |element| try self.putArrayElement(name, element.index, element.value);
        if (declared.readonly) {
            try self.putVariableAttributes(.{ .name = name, .readonly = true });
        }
    }

    pub fn appendArrayElements(self: *State, name: []const u8, elements: []const ArrayElement) !void {
        std.debug.assert(name.len != 0);
        if (self.getVariableAttributes(name)) |attributes| if (attributes.readonly) return error.ReadonlyVariable;
        if (self.getVariable(name)) |variable| {
            if (variable.readonly) return error.ReadonlyVariable;
            if (self.getArray(name) == null) try self.putArray(name, &.{variable.value});
        }
        if (self.getArray(name) == null) try self.putArray(name, &.{});
        for (elements) |element| try self.putArrayElement(name, element.index, element.value);
    }

    pub fn putArrayElement(self: *State, name: []const u8, index: usize, value: []const u8) !void {
        std.debug.assert(name.len != 0);
        if (self.getVariableAttributes(name)) |attributes| if (attributes.readonly) return error.ReadonlyVariable;
        if (self.getVariable(name)) |variable| if (variable.readonly) return error.ReadonlyVariable;
        if (self.getArray(name)) |array| if (array.readonly) return error.ReadonlyVariable;
        const attributes = self.getVariableAttributes(name);
        const variable = self.getVariable(name);

        const owned_value = try self.allocator.dupe(u8, value);
        var value_transferred = false;
        errdefer if (!value_transferred) self.allocator.free(owned_value);

        if (self.getBindingPtr(name)) |binding| switch (binding.value) {
            .array => |*elements| {
                try self.putExistingArrayElement(elements, index, owned_value);
                value_transferred = true;
                return;
            },
            else => {},
        };

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const elements = try self.allocator.alloc(ArrayElement, 1);
        errdefer self.allocator.free(elements);
        elements[0] = .{ .index = index, .value = owned_value };
        value_transferred = true;
        self.removeVariable(name);
        try self.bindings.put(self.allocator, owned_name, .{
            .name = owned_name,
            .value = .{ .array = elements },
            .exported = (attributes != null and attributes.?.exported) or (variable != null and variable.?.exported),
            .integer = (attributes != null and attributes.?.integer) or (variable != null and variable.?.integer),
        });
        self.clearFunctionAutoloadMissesIfSearchVariable(owned_name);
    }

    pub fn putArrayAttributes(self: *State, attributes: VariableAttributes) !void {
        const updates_array = self.getArray(attributes.name) != null;
        try self.putVariableAttributes(attributes);
        if (updates_array) self.clearFunctionAutoloadMissesIfSearchVariable(attributes.name);
    }

    fn putExistingArrayElement(self: *State, elements: *[]ArrayElement, index: usize, owned_value: []const u8) !void {
        for (elements.*, 0..) |*element, element_index| {
            if (element.index == index) {
                self.allocator.free(element.value);
                element.value = owned_value;
                return;
            }
            if (element.index > index) {
                try self.insertArrayElement(elements, element_index, .{ .index = index, .value = owned_value });
                return;
            }
        }
        try self.insertArrayElement(elements, elements.len, .{ .index = index, .value = owned_value });
    }

    fn insertArrayElement(self: *State, elements: *[]ArrayElement, insert_index: usize, element: ArrayElement) !void {
        std.debug.assert(insert_index <= elements.len);
        const resized = try self.allocator.alloc(ArrayElement, elements.len + 1);
        @memcpy(resized[0..insert_index], elements.*[0..insert_index]);
        resized[insert_index] = element;
        @memcpy(resized[insert_index + 1 ..], elements.*[insert_index..]);
        self.allocator.free(elements.*);
        elements.* = resized;
    }

    fn dupeArrayValues(self: *State, values: []const []const u8) ![]ArrayElement {
        const owned = try self.allocator.alloc(ArrayElement, values.len);
        var initialized: usize = 0;
        errdefer {
            for (owned[0..initialized]) |element| self.allocator.free(element.value);
            self.allocator.free(owned);
        }
        for (values, 0..) |value, index| {
            owned[index] = .{ .index = index, .value = try self.allocator.dupe(u8, value) };
            initialized += 1;
        }
        return owned;
    }

    fn dupeArrayElements(self: *State, elements: []const ArrayElement) ![]ArrayElement {
        const owned = try self.allocator.alloc(ArrayElement, elements.len);
        var initialized: usize = 0;
        errdefer {
            for (owned[0..initialized]) |element| self.allocator.free(element.value);
            self.allocator.free(owned);
        }
        for (elements, 0..) |element, index| {
            owned[index] = .{ .index = element.index, .value = try self.allocator.dupe(u8, element.value) };
            initialized += 1;
        }
        return owned;
    }

    fn freeArrayElements(allocator: std.mem.Allocator, elements: []const ArrayElement) void {
        for (elements) |element| allocator.free(element.value);
        allocator.free(elements);
    }

    pub fn removeArray(self: *State, name: []const u8) void {
        const binding = self.bindings.get(name) orelse return;
        if (binding.value != .array) return;
        const removed = self.bindings.fetchRemove(name).?;
        removed.value.deinit(self.allocator);
    }

    pub fn removeArrayElement(self: *State, name: []const u8, index: usize) !void {
        const binding = self.getBindingPtr(name) orelse return;
        const elements = switch (binding.value) {
            .array => |*elements| elements,
            else => return,
        };
        for (elements.*, 0..) |element, element_index| {
            if (element.index == index) {
                const old_elements = elements.*;
                const new_elements = try self.allocator.alloc(ArrayElement, old_elements.len - 1);
                @memcpy(new_elements[0..element_index], old_elements[0..element_index]);
                @memcpy(new_elements[element_index..], old_elements[element_index + 1 ..]);
                self.allocator.free(element.value);
                self.allocator.free(old_elements);
                elements.* = new_elements;
                self.clearFunctionAutoloadMissesIfSearchVariable(name);
                return;
            }
            if (element.index > index) return;
        }
    }

    pub fn putVariableAttributes(self: *State, attributes: VariableAttributes) !void {
        attributes.validate();
        if (self.bindings.getPtr(attributes.name)) |binding| {
            binding.exported = binding.exported or attributes.exported;
            binding.readonly = binding.readonly or attributes.readonly;
            binding.integer = binding.integer or attributes.integer;
            return;
        }
        const owned_name = try self.allocator.dupe(u8, attributes.name);
        errdefer self.allocator.free(owned_name);
        try self.bindings.put(self.allocator, owned_name, .{
            .name = owned_name,
            .value = .unset,
            .exported = attributes.exported,
            .readonly = attributes.readonly,
            .integer = attributes.integer,
        });
    }

    pub fn removeVariableAttributes(self: *State, name: []const u8) void {
        const binding = self.bindings.get(name) orelse return;
        if (binding.value != .unset) return;
        const removed = self.bindings.fetchRemove(name).?;
        removed.value.deinit(self.allocator);
    }

    /// Pushes a frame that owns copies of its assignment-prefix names.
    pub fn pushLocalFrame(self: *State, assignment_prefixes: []const []const u8) !void {
        var frame: LocalFrame = .{};
        errdefer frame.deinit(self.allocator);

        for (assignment_prefixes) |name| {
            if (frame.assignment_prefixes.contains(name)) continue;
            const owned_name = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(owned_name);
            try frame.assignment_prefixes.put(self.allocator, owned_name, {});
        }

        try self.local_frames.append(self.allocator, frame);
    }

    /// Restores the variable bindings saved by the innermost local frame.
    ///
    /// Map capacity is reserved before any binding is touched, so the
    /// restore itself transfers ownership of the saved strings without
    /// allocating. On OutOfMemory nothing has been mutated and the frame
    /// remains pushed. Requires a matching `pushLocalFrame`.
    pub fn popLocalFrame(self: *State) !void {
        std.debug.assert(self.local_frames.items.len != 0);
        const saved_count = self.local_frames.items[self.local_frames.items.len - 1].saved.count();
        try self.bindings.ensureUnusedCapacity(self.allocator, saved_count);

        var frame = self.local_frames.pop().?;
        defer frame.deinit(self.allocator);

        var iterator = frame.saved.valueIterator();
        while (iterator.next()) |binding| self.restoreSavedBinding(binding);
    }

    fn restoreSavedBinding(self: *State, binding: *SavedLocalBinding) void {
        self.removeVariable(binding.name);
        if (binding.binding) |saved| {
            self.bindings.putAssumeCapacity(saved.name, saved);
            binding.binding = null;
        }
    }

    pub fn hasLocalFrame(self: State) bool {
        return self.local_frames.items.len != 0;
    }

    /// Requires an active local frame.
    pub fn hasSavedLocalBinding(self: State, name: []const u8) bool {
        std.debug.assert(self.local_frames.items.len != 0);
        return self.local_frames.items[self.local_frames.items.len - 1].saved.contains(name);
    }

    pub fn declareLocal(self: *State, name: []const u8, value: ?[]const u8) !void {
        try self.declareLocalWithAttributes(.{ .name = name, .value = value });
    }

    pub const LocalDeclaration = struct {
        name: []const u8,
        value: ?[]const u8 = null,
        exported: bool = false,
        readonly: bool = false,
        integer: bool = false,
    };

    /// Declares a local in the innermost frame, which must already be active.
    pub fn declareLocalWithAttributes(self: *State, declaration: LocalDeclaration) !void {
        const name = declaration.name;
        std.debug.assert(name.len != 0);
        if (self.getVariable(name)) |variable| if (variable.readonly) return error.ReadonlyVariable;
        if (self.getVariableAttributes(name)) |attributes| if (attributes.readonly) return error.ReadonlyVariable;
        const frame = self.currentLocalFrame();
        try self.saveLocalBinding(frame, name);

        if (declaration.value) |local_value| {
            try self.putVariable(.{
                .name = name,
                .value = local_value,
                .exported = declaration.exported,
                .readonly = declaration.readonly,
                .integer = declaration.integer,
            });
        } else if (!frame.assignment_prefixes.contains(name)) {
            self.removeVariable(name);
            if (declaration.exported or declaration.readonly or declaration.integer) {
                try self.putVariableAttributes(.{
                    .name = name,
                    .exported = declaration.exported,
                    .readonly = declaration.readonly,
                    .integer = declaration.integer,
                });
            }
        } else if (declaration.exported or declaration.readonly or declaration.integer) {
            try self.putVariableAttributes(.{
                .name = name,
                .exported = declaration.exported,
                .readonly = declaration.readonly,
                .integer = declaration.integer,
            });
        }
    }

    pub fn declareLocalArray(self: *State, name: []const u8, values: []const []const u8) !void {
        try self.declareLocalArrayWithAttributes(name, values, .{});
    }

    /// Declares a local array in the innermost active frame.
    pub fn declareLocalArrayWithAttributes(
        self: *State,
        name: []const u8,
        values: []const []const u8,
        declared: ArrayAttributes,
    ) !void {
        std.debug.assert(name.len != 0);
        if (self.getVariable(name)) |variable| if (variable.readonly) return error.ReadonlyVariable;
        if (self.getVariableAttributes(name)) |attributes| if (attributes.readonly) return error.ReadonlyVariable;
        const frame = self.currentLocalFrame();
        try self.saveLocalBinding(frame, name);
        try self.putArrayWithAttributes(name, values, declared);
    }

    fn currentLocalFrame(self: *State) *LocalFrame {
        std.debug.assert(self.local_frames.items.len != 0);
        return &self.local_frames.items[self.local_frames.items.len - 1];
    }

    fn saveLocalBinding(self: *State, frame: *LocalFrame, name: []const u8) !void {
        if (frame.saved.contains(name)) return;
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);

        const binding = if (self.bindings.get(name)) |existing| try self.dupeBinding(existing) else null;
        errdefer if (binding) |saved| saved.deinit(self.allocator);

        try frame.saved.put(self.allocator, owned_name, .{
            .name = owned_name,
            .binding = binding,
        });
    }

    /// Deep-copies a binding for independent ownership by a saved local frame.
    fn dupeBinding(self: *State, binding: Binding) !Binding {
        const name = try self.allocator.dupe(u8, binding.name);
        errdefer self.allocator.free(name);
        const value: Binding.Value = switch (binding.value) {
            .unset => .unset,
            .scalar => |value| .{ .scalar = try self.allocator.dupe(u8, value) },
            .array => |elements| .{ .array = try self.dupeArrayElements(elements) },
        };
        return .{
            .name = name,
            .value = value,
            .exported = binding.exported,
            .readonly = binding.readonly,
            .integer = binding.integer,
        };
    }

    /// Pushes a frame that borrows the function's name and source name.
    pub fn pushFunctionCall(self: *State, function: Function) !void {
        try self.function_call_stack.append(self.allocator, .{
            .name = function.name,
            .source_name = function.source_name,
        });
    }

    /// Pops the innermost function frame; one must be active.
    pub fn popFunctionCall(self: *State) void {
        std.debug.assert(self.function_call_stack.items.len != 0);
        _ = self.function_call_stack.pop();
    }

    pub fn setPositionals(self: *State, positionals: []const []const u8) !void {
        const owned = try self.allocator.alloc([]const u8, positionals.len);
        errdefer self.allocator.free(owned);

        var copied: usize = 0;
        errdefer for (owned[0..copied]) |item| self.allocator.free(item);

        for (positionals, 0..) |positional, index| {
            owned[index] = try self.allocator.dupe(u8, positional);
            copied += 1;
        }

        self.freeOwnedPositionals();
        self.owned_positionals = owned;
        self.positionals = owned;
    }

    fn freeOwnedPositionals(self: *State) void {
        for (self.owned_positionals) |positional| self.allocator.free(positional);
        self.allocator.free(self.owned_positionals);
        self.owned_positionals = &.{};
    }

    pub fn getFunction(self: State, name: []const u8) ?Function {
        std.debug.assert(name.len != 0);
        return self.functions.get(name);
    }

    /// Installs a function definition whose name, source text, and AST storage
    /// have already been allocated from `definitionAllocator()`.
    pub fn putPersistentFunction(self: *State, function: Function) !void {
        function.validate();
        try self.functions.put(self.allocator, function.name, function);
        self.clearFunctionAutoloadState(function.name);
    }

    pub fn removeFunction(self: *State, name: []const u8) void {
        std.debug.assert(name.len != 0);
        _ = self.functions.remove(name);
    }

    pub fn suppressFunctionAutoload(self: *State, name: []const u8) !void {
        std.debug.assert(name.len != 0);
        if (self.function_autoload_states.getPtr(name)) |state| {
            state.* = .suppressed;
            return;
        }
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.function_autoload_states.put(self.allocator, owned_name, .suppressed);
    }

    pub fn isFunctionAutoloadSuppressed(self: State, name: []const u8) bool {
        std.debug.assert(name.len != 0);
        return if (self.function_autoload_states.get(name)) |state| state == .suppressed else false;
    }

    pub fn markFunctionAutoloadMissed(self: *State, name: []const u8) !void {
        std.debug.assert(name.len != 0);
        if (self.function_autoload_states.contains(name)) return;
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.function_autoload_states.put(self.allocator, owned_name, .missed);
    }

    pub fn isFunctionAutoloadMissed(self: State, name: []const u8) bool {
        std.debug.assert(name.len != 0);
        return if (self.function_autoload_states.get(name)) |state| state == .missed else false;
    }

    fn clearFunctionAutoloadMissesIfSearchVariable(self: *State, name: []const u8) void {
        if (!functionAutoloadSearchUsesVariable(name)) return;
        self.clearFunctionAutoloadMisses();
    }

    fn clearFunctionAutoloadMisses(self: *State) void {
        while (true) {
            var iterator = self.function_autoload_states.iterator();
            const missed = while (iterator.next()) |entry| {
                if (entry.value_ptr.* == .missed) break entry.key_ptr.*;
            } else return;
            if (self.function_autoload_states.fetchRemove(missed)) |entry| self.allocator.free(entry.key);
        }
    }

    fn clearFunctionAutoloadState(self: *State, name: []const u8) void {
        if (self.function_autoload_states.fetchRemove(name)) |entry| self.allocator.free(entry.key);
    }

    pub fn getAlias(self: State, name: []const u8) ?Alias {
        std.debug.assert(name.len != 0);
        return self.aliases.get(name);
    }

    pub fn putAlias(self: *State, alias: Alias) !void {
        alias.validate();
        const owned_value = try self.allocator.dupe(u8, alias.value);
        errdefer self.allocator.free(owned_value);

        if (self.aliases.getPtr(alias.name)) |existing| {
            self.allocator.free(existing.value);
            existing.value = owned_value;
            return;
        }

        const owned_name = try self.allocator.dupe(u8, alias.name);
        errdefer self.allocator.free(owned_name);

        try self.aliases.put(self.allocator, owned_name, .{
            .name = owned_name,
            .value = owned_value,
        });
    }

    pub fn removeAlias(self: *State, name: []const u8) bool {
        std.debug.assert(name.len != 0);
        if (self.aliases.fetchRemove(name)) |entry| {
            self.allocator.free(entry.value.name);
            self.allocator.free(entry.value.value);
            return true;
        }
        return false;
    }

    pub fn clearAliases(self: *State) void {
        var iterator = self.aliases.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.value_ptr.name);
            self.allocator.free(entry.value_ptr.value);
        }
        self.aliases.clearRetainingCapacity();
    }

    pub fn putCommandHash(self: *State, command_hash: CommandHash) !void {
        command_hash.validate();
        const owned_path = try self.allocator.dupe(u8, command_hash.path);
        errdefer self.allocator.free(owned_path);

        if (self.command_hashes.getPtr(command_hash.name)) |existing| {
            self.allocator.free(existing.path);
            existing.path = owned_path;
            return;
        }

        const owned_name = try self.allocator.dupe(u8, command_hash.name);
        errdefer self.allocator.free(owned_name);

        try self.command_hashes.put(self.allocator, owned_name, .{
            .name = owned_name,
            .path = owned_path,
        });
    }

    pub fn clearCommandHashes(self: *State) void {
        var iterator = self.command_hashes.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.value_ptr.name);
            self.allocator.free(entry.value_ptr.path);
        }
        self.command_hashes.clearRetainingCapacity();
    }

    pub fn setExitTrap(self: *State, action: []const u8) !void {
        const owned = try self.allocator.dupe(u8, action);
        errdefer self.allocator.free(owned);
        const listed = try self.allocator.dupe(u8, action);
        errdefer self.allocator.free(listed);
        self.clearExitTrap();
        self.exit_trap = owned;
        self.exit_trap_listing = listed;
    }

    pub fn clearExitTrap(self: *State) void {
        if (self.exit_trap) |action| self.allocator.free(action);
        self.exit_trap = null;
        if (self.exit_trap_listing) |action| self.allocator.free(action);
        self.exit_trap_listing = null;
    }

    pub fn forgetActiveExitTrap(self: *State) void {
        self.exit_trap = null;
    }

    pub fn getSignalTrap(self: State, name: []const u8) ?[]const u8 {
        return self.signal_traps.get(name);
    }

    pub fn setSignalTrap(self: *State, name: []const u8, action: []const u8) !void {
        const owned_action = try self.allocator.dupe(u8, action);
        errdefer self.allocator.free(owned_action);
        if (self.signal_traps.getPtr(name)) |existing| {
            self.allocator.free(existing.*);
            existing.* = owned_action;
            return;
        }
        try self.signal_traps.put(self.allocator, name, owned_action);
    }

    pub fn clearSignalTrap(self: *State, name: []const u8) void {
        if (self.signal_traps.fetchRemove(name)) |entry| self.allocator.free(entry.value);
    }

    pub fn clearSignalTraps(self: *State) void {
        var iterator = self.signal_traps.iterator();
        while (iterator.next()) |entry| self.allocator.free(entry.value_ptr.*);
        self.signal_traps.clearRetainingCapacity();
        self.pending_traps.clearRetainingCapacity();
    }

    pub fn queueTrap(self: *State, name: []const u8) !void {
        try self.pending_traps.append(self.allocator, name);
    }

    pub fn popPendingTrap(self: *State) ?[]const u8 {
        if (self.pending_traps.items.len == 0) return null;
        const name = self.pending_traps.items[0];
        // ziglint-ignore: Z011 Z024 deprecated API left unchanged to avoid semantic drift in lint-only pass; preserve existing readable expression shape; lint-only cleanup
        std.mem.copyForwards([]const u8, self.pending_traps.items[0 .. self.pending_traps.items.len - 1], self.pending_traps.items[1..]);
        self.pending_traps.items.len -= 1;
        return name;
    }

    pub fn addBackgroundPid(self: *State, pid: host.Pid) !void {
        try self.background_pids.append(self.allocator, pid);
    }

    pub fn addBackgroundJob(self: *State, pid: host.Pid, command: []const u8, job_control: bool) !void {
        try self.addBackgroundJobPids(&.{pid}, pid, command, job_control);
    }

    pub fn addBackgroundJobPids(
        self: *State,
        pids: []const host.Pid,
        process_group: host.Pid,
        command: []const u8,
        job_control: bool,
    ) !void {
        std.debug.assert(pids.len != 0);
        std.debug.assert(process_group != 0);
        const owned_command = try self.allocator.dupe(u8, command);
        errdefer self.allocator.free(owned_command);
        // ziglint-ignore: Z011 deprecated API left unchanged to avoid semantic drift in lint-only pass
        var owned_pids: std.ArrayListUnmanaged(host.Pid) = .empty;
        errdefer owned_pids.deinit(self.allocator);
        try owned_pids.appendSlice(self.allocator, pids);
        const job: BackgroundJob = .{
            .id = self.nextAvailableJobId(),
            .pid = pids[pids.len - 1],
            .process_group = process_group,
            .job_control = job_control,
            .pids = owned_pids,
            .status = .running,
            .command = owned_command,
        };
        job.validate();
        try self.background_jobs.append(self.allocator, job);
    }

    fn nextAvailableJobId(self: State) usize {
        var id: usize = 1;
        while (true) : (id += 1) {
            for (self.background_jobs.items) |job| {
                if (job.id == id) break;
            } else return id;
        }
    }

    pub fn removeBackgroundPid(self: *State, pid: host.Pid) bool {
        var removed = false;
        for (self.background_pids.items, 0..) |known, index| {
            if (known != pid) continue;
            _ = self.background_pids.orderedRemove(index);
            removed = true;
            break;
        }
        return self.removePidFromBackgroundJobs(pid) or removed;
    }

    fn removePidFromBackgroundJobs(self: *State, pid: host.Pid) bool {
        for (self.background_jobs.items, 0..) |*job, job_index| {
            for (job.pids.items, 0..) |job_pid, pid_index| {
                if (job_pid != pid) continue;
                _ = job.pids.orderedRemove(pid_index);
                if (job.pids.items.len == 0) {
                    var removed_job = self.background_jobs.orderedRemove(job_index);
                    removed_job.deinit(self.allocator);
                } else if (job.pid == pid) {
                    job.pid = job.pids.items[job.pids.items.len - 1];
                }
                return true;
            }
        }
        return false;
    }

    pub fn backgroundJobPid(self: State, job_id: usize) ?host.Pid {
        for (self.background_jobs.items) |job| if (job.id == job_id) return job.pid;
        return null;
    }

    pub fn backgroundJob(self: State, job_id: usize) ?BackgroundJob {
        for (self.background_jobs.items) |job| if (job.id == job_id) return job;
        return null;
    }

    pub fn resolveJobSpec(self: State, spec: []const u8) ?BackgroundJob {
        if (spec.len < 2 or spec[0] != '%') return null;
        const selector = spec[1..];
        if (std.mem.eql(u8, selector, "%") or std.mem.eql(u8, selector, "+")) return self.currentBackgroundJob();
        if (std.mem.eql(u8, selector, "-")) return self.previousBackgroundJob();
        if (std.fmt.parseInt(usize, selector, 10)) |job_id| {
            return self.backgroundJob(job_id);
        } else |_| {}
        if (selector[0] == '?') {
            if (selector.len == 1) return null;
            return self.findBackgroundJobContaining(selector[1..]);
        }
        return self.findBackgroundJobStartingWith(selector);
    }

    pub fn currentBackgroundJob(self: State) ?BackgroundJob {
        if (self.background_jobs.items.len == 0) return null;
        if (self.recentBackgroundJobWithStatus(.stopped, null)) |job| return job;
        return self.background_jobs.items[self.background_jobs.items.len - 1];
    }

    pub fn previousBackgroundJob(self: State) ?BackgroundJob {
        const current = self.currentBackgroundJob() orelse return null;
        if (self.recentBackgroundJobWithStatus(.stopped, current.id)) |job| return job;
        var index = self.background_jobs.items.len;
        while (index > 0) {
            index -= 1;
            const job = self.background_jobs.items[index];
            if (job.id != current.id) return job;
        }
        return null;
    }

    pub fn backgroundJobMarker(self: State, job_id: usize) u8 {
        if (self.currentBackgroundJob()) |job| {
            if (job.id == job_id) return '+';
        }
        if (self.previousBackgroundJob()) |job| {
            if (job.id == job_id) return '-';
        }
        return ' ';
    }

    fn recentBackgroundJobWithStatus(self: State, status: JobStatus, excluded_id: ?usize) ?BackgroundJob {
        var index = self.background_jobs.items.len;
        while (index > 0) {
            index -= 1;
            const job = self.background_jobs.items[index];
            if (excluded_id != null and job.id == excluded_id.?) continue;
            if (job.status == status) return job;
        }
        return null;
    }

    fn findBackgroundJobStartingWith(self: State, prefix: []const u8) ?BackgroundJob {
        if (prefix.len == 0) return null;
        var index = self.background_jobs.items.len;
        while (index > 0) {
            index -= 1;
            const job = self.background_jobs.items[index];
            if (std.mem.startsWith(u8, job.command, prefix)) return job;
        }
        return null;
    }

    fn findBackgroundJobContaining(self: State, needle: []const u8) ?BackgroundJob {
        std.debug.assert(needle.len != 0);
        var index = self.background_jobs.items.len;
        while (index > 0) {
            index -= 1;
            const job = self.background_jobs.items[index];
            if (std.mem.indexOf(u8, job.command, needle) != null) return job;
        }
        return null;
    }

    pub fn setBackgroundJobStatusByPid(self: *State, pid: host.Pid, status: JobStatus) bool {
        for (self.background_jobs.items) |*job| {
            for (job.pids.items) |job_pid| {
                if (job_pid != pid) continue;
                job.status = status;
                return true;
            }
        }
        return false;
    }

    pub fn setBackgroundJobStatus(self: *State, job_id: usize, status: JobStatus) bool {
        for (self.background_jobs.items) |*job| {
            if (job.id != job_id) continue;
            job.status = status;
            return true;
        }
        return false;
    }

    pub fn forgetBackgroundJob(self: *State, pid: host.Pid) void {
        for (self.background_jobs.items, 0..) |*job, index| {
            if (job.pid != pid) continue;
            var removed_job = self.background_jobs.orderedRemove(index);
            removed_job.deinit(self.allocator);
            return;
        }
    }

    pub fn clearBackgroundPids(self: *State) void {
        self.background_pids.clearRetainingCapacity();
        for (self.background_jobs.items) |*job| job.deinit(self.allocator);
        self.background_jobs.clearRetainingCapacity();
    }
};

test "State replaces variable values without losing the binding" {
    var shell_state = State.init(std.testing.allocator, .{});
    defer shell_state.deinit();

    try shell_state.putVariable(.{ .name = "x", .value = "old" });
    try shell_state.putVariable(.{ .name = "x", .value = "new", .exported = true });

    const variable = shell_state.getVariable("x") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("x", variable.name);
    try std.testing.expectEqualStrings("new", variable.value);
    try std.testing.expect(variable.exported);
}
