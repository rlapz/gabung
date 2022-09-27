const std = @import("std");

pub fn stdout(comptime fmt: []const u8, args: anytype) void {
    std.io.getStdOut().writer().print(fmt, args) catch return;
}

pub fn stderr(comptime fmt: []const u8, args: anytype) void {
    std.io.getStdErr().writer().print(fmt, args) catch return;
}

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const sc = if (scope == .default) "" else @tagName(scope) ++ ": ";
    comptime var lv = level.asText();
    comptime var prefix = "[" ++ lv ++ "]: " ++ sc;
    const writer = switch (level) {
        .err => stdout,
        else => stderr,
    };

    writer(prefix ++ format ++ "\n", args);
}
