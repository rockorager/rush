//! Floating-point rendering for the printf utility.

const std = @import("std");

const Writer = std.Io.Writer;

pub const Options = struct {
    spec: u8,
    left_adjust: bool = false,
    zero_pad: bool = false,
    sign_plus: bool = false,
    sign_space: bool = false,
    alternate: bool = false,
    width: ?usize = null,
    precision: ?usize = null,
};

pub fn render(allocator: std.mem.Allocator, writer: *Writer, value: f64, options: Options) !void {
    const rendered = try format(allocator, options, value);
    defer allocator.free(rendered);
    try appendPadded(writer, rendered, options);
}

fn format(allocator: std.mem.Allocator, options: Options, value: f64) ![]u8 {
    const lower_spec = std.ascii.toLower(options.spec);
    var rendered: []u8 = switch (lower_spec) {
        'f' => try formatDecimal(allocator, value, options.precision orelse 6, options.alternate),
        'e' => try formatScientific(allocator, value, options.precision orelse 6, options.alternate),
        'g' => try formatGeneral(allocator, value, options.precision orelse 6, options.alternate),
        'a' => try formatHex(allocator, value, options.precision, options.alternate),
        else => unreachable,
    };
    errdefer allocator.free(rendered);
    try applySign(allocator, &rendered, options);
    if (std.ascii.isUpper(options.spec)) asciiUpper(rendered);
    return rendered;
}

fn formatDecimal(allocator: std.mem.Allocator, value: f64, precision: usize, alternate: bool) ![]u8 {
    const buffer = try allocator.alloc(u8, @max(std.fmt.float.bufferSize(.decimal, f64), precision + 32));
    defer allocator.free(buffer);
    const decimal = round(printfFloatDecimal(value), .decimal, precision);
    const rendered = std.fmt.float.formatDecimal(u64, buffer, decimal, precision) catch |err| switch (err) {
        error.BufferTooSmall => return error.OutOfMemory,
    };
    return duplicateWithAlternateDecimalPoint(allocator, rendered, alternate);
}

fn formatScientific(allocator: std.mem.Allocator, value: f64, precision: usize, alternate: bool) ![]u8 {
    const rendered = try renderScientific(allocator, value, precision);
    defer allocator.free(rendered);
    return normalizeScientific(allocator, rendered, alternate);
}

fn renderScientific(allocator: std.mem.Allocator, value: f64, precision: usize) ![]u8 {
    const buffer = try allocator.alloc(u8, @max(std.fmt.float.bufferSize(.scientific, f64), precision + 32));
    defer allocator.free(buffer);
    const decimal = round(printfFloatDecimal(value), .scientific, precision);
    const rendered = std.fmt.float.formatScientific(u64, buffer, decimal, precision) catch |err| switch (err) {
        error.BufferTooSmall => return error.OutOfMemory,
    };
    return allocator.dupe(u8, rendered);
}

fn formatGeneral(allocator: std.mem.Allocator, value: f64, precision_arg: usize, alternate: bool) ![]u8 {
    const precision = if (precision_arg == 0) 1 else precision_arg;
    const scientific = try renderScientific(allocator, value, precision - 1);
    defer allocator.free(scientific);
    if (isSpecial(scientific)) return duplicateWithAlternateDecimalPoint(allocator, scientific, false);

    const exponent = scientificExponent(scientific) orelse 0;
    const use_scientific = exponent < -4 or exponent >= @as(i32, @intCast(precision));
    const rendered = if (use_scientific)
        try normalizeScientific(allocator, scientific, alternate)
    else blk: {
        const decimal_precision: usize = if (exponent >= 0)
            if (precision > @as(usize, @intCast(exponent + 1))) precision - @as(usize, @intCast(exponent + 1)) else 0
        else
            precision + @as(usize, @intCast(-exponent - 1));
        break :blk try formatDecimal(allocator, value, decimal_precision, alternate);
    };
    errdefer allocator.free(rendered);
    if (!alternate) {
        if (try trimGeneralZeros(allocator, rendered)) |trimmed| {
            allocator.free(rendered);
            return trimmed;
        }
    }
    return rendered;
}

const RoundMode = enum { decimal, scientific };

fn printfFloatDecimal(value: f64) std.fmt.float.FloatDecimal(u64) {
    return std.fmt.float.binaryToDecimal(
        u64,
        @as(u64, @bitCast(value)),
        std.math.floatMantissaBits(f64),
        std.math.floatExponentBits(f64),
        false,
        &std.fmt.float.Backend64_TablesFull,
    );
}

fn round(
    decimal: std.fmt.float.FloatDecimal(u64),
    mode: RoundMode,
    precision: usize,
) std.fmt.float.FloatDecimal(u64) {
    if (decimal.exponent == 0x7fffffff) return decimal;

    var round_digit: usize = 0;
    var output = decimal.mantissa;
    var exponent = decimal.exponent;
    const output_length = decimalLength(output);

    switch (mode) {
        .decimal => {
            if (decimal.exponent > 0) {
                round_digit = output_length - 1 + precision + @as(usize, @intCast(decimal.exponent));
            } else {
                const min_exp_required: usize = @intCast(-decimal.exponent);
                if (precision + output_length > min_exp_required) {
                    round_digit = precision + output_length - min_exp_required;
                }
            }
        },
        .scientific => {
            round_digit = 1 + precision;
        },
    }

    if (round_digit < output_length) {
        var sticky = false;
        for (round_digit + 1..output_length) |_| {
            sticky = sticky or output % 10 != 0;
            output /= 10;
            exponent += 1;
        }

        const guard = output % 10;
        output /= 10;
        exponent += 1;
        if (guard > 5 or (guard == 5 and (sticky or output % 2 == 1))) {
            output += 1;

            if (isPowerOf10(output)) {
                output /= 10;
                exponent += 1;
            }
        }
    }

    return .{
        .mantissa = output,
        .exponent = exponent,
        .sign = decimal.sign,
    };
}

fn isPowerOf10(value: u64) bool {
    var n = value;
    while (n != 0) : (n /= 10) {
        if (n % 10 != 0) return false;
    }
    return true;
}

fn decimalLength(value: u64) usize {
    if (value >= 10000000000000000) return 17;
    if (value >= 1000000000000000) return 16;
    if (value >= 100000000000000) return 15;
    if (value >= 10000000000000) return 14;
    if (value >= 1000000000000) return 13;
    if (value >= 100000000000) return 12;
    if (value >= 10000000000) return 11;
    if (value >= 1000000000) return 10;
    if (value >= 100000000) return 9;
    if (value >= 10000000) return 8;
    if (value >= 1000000) return 7;
    if (value >= 100000) return 6;
    if (value >= 10000) return 5;
    if (value >= 1000) return 4;
    if (value >= 100) return 3;
    if (value >= 10) return 2;
    return 1;
}

fn normalizeScientific(allocator: std.mem.Allocator, rendered: []const u8, alternate: bool) ![]u8 {
    if (isSpecial(rendered)) return allocator.dupe(u8, rendered);
    const e_index = std.mem.indexOfScalar(u8, rendered, 'e') orelse return allocator.dupe(u8, rendered);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, rendered[0..e_index]);
    if (alternate and std.mem.indexOfScalar(u8, rendered[0..e_index], '.') == null) try output.append(allocator, '.');
    try output.append(allocator, 'e');

    var exponent = std.fmt.parseInt(i32, rendered[e_index + 1 ..], 10) catch unreachable;
    if (exponent < 0) {
        try output.append(allocator, '-');
        exponent = -exponent;
    } else {
        try output.append(allocator, '+');
    }
    if (exponent < 10) try output.append(allocator, '0');
    const exponent_text = try allocator.print("{d}", .{exponent});
    defer allocator.free(exponent_text);
    try output.appendSlice(allocator, exponent_text);
    return output.toOwnedSlice(allocator);
}

fn duplicateWithAlternateDecimalPoint(allocator: std.mem.Allocator, rendered: []const u8, alternate: bool) ![]u8 {
    if (!alternate or isSpecial(rendered) or std.mem.indexOfScalar(u8, rendered, '.') != null) {
        return allocator.dupe(u8, rendered);
    }
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, rendered);
    try output.append(allocator, '.');
    return output.toOwnedSlice(allocator);
}

fn scientificExponent(rendered: []const u8) ?i32 {
    const e_index = std.mem.indexOfScalar(u8, rendered, 'e') orelse return null;
    return std.fmt.parseInt(i32, rendered[e_index + 1 ..], 10) catch null;
}

fn trimGeneralZeros(allocator: std.mem.Allocator, rendered: []const u8) !?[]u8 {
    if (isSpecial(rendered)) return null;
    const e_index = std.mem.indexOfScalar(u8, rendered, 'e') orelse rendered.len;
    const dot_index = std.mem.indexOfScalar(u8, rendered[0..e_index], '.') orelse return null;
    var end = e_index;
    while (end > dot_index + 1 and rendered[end - 1] == '0') end -= 1;
    if (end > dot_index and rendered[end - 1] == '.') end -= 1;
    if (end == e_index) return null;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, rendered[0..end]);
    try output.appendSlice(allocator, rendered[e_index..]);
    return try output.toOwnedSlice(allocator);
}

fn formatHex(allocator: std.mem.Allocator, value: f64, precision: ?usize, alternate: bool) ![]u8 {
    if (std.math.isNan(value) or std.math.isInf(value)) {
        var buffer: [8]u8 = undefined;
        const rendered = std.fmt.float.render(&buffer, value, .{}) catch unreachable;
        return allocator.dupe(u8, rendered);
    }

    const negative = std.math.signbit(value);
    const magnitude = @abs(value);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    if (negative) try output.append(allocator, '-');
    try output.appendSlice(allocator, "0x");

    if (magnitude == 0) {
        try output.append(allocator, '0');
        const digits = precision orelse 0;
        if (alternate or digits != 0) {
            try output.append(allocator, '.');
            try output.appendNTimes(allocator, '0', digits);
        }
        try output.appendSlice(allocator, "p+0");
        return output.toOwnedSlice(allocator);
    }

    const parts = std.math.frexp(magnitude);
    var exponent = parts.exponent - 1;
    var scaled = parts.significand * 2.0;
    var leading: u8 = @intFromFloat(@floor(scaled));
    scaled -= @floatFromInt(leading);

    const requested_digits = precision orelse 13;
    var digits: std.ArrayList(u8) = .empty;
    defer digits.deinit(allocator);
    const generated_digits = if (precision == null) 13 else requested_digits + 1;
    for (0..generated_digits) |_| {
        scaled *= 16.0;
        const digit: u8 = @intFromFloat(@floor(scaled));
        try digits.append(allocator, digit);
        scaled -= @floatFromInt(digit);
    }

    if (precision) |_| {
        if (digits.items.len > requested_digits) {
            const guard_digit = digits.items[requested_digits];
            const sticky = scaled != 0;
            const last_digit_is_odd = if (requested_digits == 0)
                leading % 2 == 1
            else
                digits.items[requested_digits - 1] % 2 == 1;
            const round_up = guard_digit > 8 or (guard_digit == 8 and (sticky or last_digit_is_odd));
            if (round_up) {
                var carry_index = requested_digits;
                while (carry_index > 0) {
                    carry_index -= 1;
                    if (digits.items[carry_index] != 15) {
                        digits.items[carry_index] += 1;
                        break;
                    }
                    digits.items[carry_index] = 0;
                } else {
                    if (leading < 15) {
                        leading += 1;
                    }
                }
            }
        }
        digits.shrinkRetainingCapacity(requested_digits);
    } else {
        while (digits.items.len != 0 and digits.items[digits.items.len - 1] == 0) _ = digits.pop();
    }

    try output.append(allocator, '0' + leading);
    if (alternate or digits.items.len != 0) {
        try output.append(allocator, '.');
        for (digits.items) |digit| try output.append(allocator, lowerHexDigit(digit));
    }
    try output.append(allocator, 'p');
    if (exponent < 0) {
        try output.append(allocator, '-');
        exponent = -exponent;
    } else {
        try output.append(allocator, '+');
    }
    const exponent_text = try allocator.print("{d}", .{exponent});
    defer allocator.free(exponent_text);
    try output.appendSlice(allocator, exponent_text);
    return output.toOwnedSlice(allocator);
}

fn applySign(allocator: std.mem.Allocator, rendered: *[]u8, options: Options) !void {
    if (rendered.*.len == 0 or rendered.*[0] == '-') return;
    const prefix: u8 = if (options.sign_plus) '+' else if (options.sign_space) ' ' else return;
    const next = try allocator.alloc(u8, rendered.*.len + 1);
    next[0] = prefix;
    @memcpy(next[1..], rendered.*);
    allocator.free(rendered.*);
    rendered.* = next;
}

fn appendPadded(writer: *Writer, rendered: []const u8, options: Options) !void {
    const width = options.width orelse 0;
    const pad_len = if (width > rendered.len) width - rendered.len else 0;
    const use_zero_pad = options.zero_pad and !options.left_adjust and !isSpecial(rendered);
    if (!options.left_adjust and !use_zero_pad) try writer.splatByteAll(' ', pad_len);
    if (use_zero_pad) {
        const split = zeroPadSplit(rendered);
        try writer.writeAll(rendered[0..split]);
        try writer.splatByteAll('0', pad_len);
        try writer.writeAll(rendered[split..]);
    } else {
        try writer.writeAll(rendered);
    }
    if (options.left_adjust) try writer.splatByteAll(' ', pad_len);
}

fn zeroPadSplit(rendered: []const u8) usize {
    var split: usize = if (rendered.len != 0 and
        (rendered[0] == '-' or rendered[0] == '+' or rendered[0] == ' ')) 1 else 0;
    if (rendered.len >= split + 2 and
        rendered[split] == '0' and
        (rendered[split + 1] == 'x' or rendered[split + 1] == 'X'))
    {
        split += 2;
    }
    return split;
}

fn isSpecial(rendered: []const u8) bool {
    const text = if (rendered.len != 0 and (rendered[0] == '-' or rendered[0] == '+' or rendered[0] == ' '))
        rendered[1..]
    else
        rendered;
    return std.ascii.eqlIgnoreCase(text, "inf") or std.ascii.eqlIgnoreCase(text, "nan");
}

fn asciiUpper(text: []u8) void {
    for (text) |*byte| byte.* = std.ascii.toUpper(byte.*);
}

fn lowerHexDigit(value: u8) u8 {
    std.debug.assert(value < 16);
    return if (value < 10) '0' + value else 'a' + (value - 10);
}

test "renderer preserves rounding zero boundaries and hex precision" {
    var output: Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try render(std.testing.allocator, &output.writer, 2.5, .{ .spec = 'f', .precision = 0 });
    try output.writer.writeByte('|');
    try render(std.testing.allocator, &output.writer, 3.5, .{ .spec = 'f', .precision = 0 });
    try output.writer.writeByte('|');
    try render(std.testing.allocator, &output.writer, 9.5, .{ .spec = 'f', .precision = 0 });
    try output.writer.writeByte('|');
    try render(std.testing.allocator, &output.writer, -0.0, .{ .spec = 'f', .precision = 1 });
    try output.writer.writeByte('|');
    try render(std.testing.allocator, &output.writer, @bitCast(@as(u64, 1)), .{ .spec = 'a' });
    try output.writer.writeByte('|');
    try render(std.testing.allocator, &output.writer, @bitCast(@as(u64, 0x7fefffffffffffff)), .{ .spec = 'a' });
    try output.writer.writeByte('|');
    try render(std.testing.allocator, &output.writer, 0x1.08p0, .{ .spec = 'a', .precision = 1 });
    try output.writer.writeByte('|');
    try render(std.testing.allocator, &output.writer, 0x1.18p0, .{ .spec = 'a', .precision = 1 });
    try output.writer.writeByte('|');
    try render(std.testing.allocator, &output.writer, 0x1.ff8p0, .{ .spec = 'a', .precision = 2 });

    try std.testing.expectEqualStrings(
        "2|4|10|-0.0|0x1p-1074|0x1.fffffffffffffp+1023|0x1.0p+0|0x1.2p+0|0x2.00p+0",
        output.writer.buffered(),
    );
}
