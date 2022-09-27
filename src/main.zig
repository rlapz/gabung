const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const dprint = std.debug.print;

const util = @import("./util.zig");
const gabung = @import("./gabung.zig");
const Merger = gabung.Merger;
const Splitter = gabung.Splitter;

// Override default log function
pub const log = util.log;

// Override default log level
pub const log_level = switch (builtin.mode) {
    .Debug => .debug,
    else => .info,
};

fn printHelp(name: [*:0]const u8) void {
    util.stdout(
        \\Gabung: A simple file merger
        \\
        \\ Usages:
        \\  * Merge
        \\    {s} -m [FILE_1, FILE_2, FILE_3, ...] -o [FILE_OUTPUT]
        \\
        \\  * Split
        \\    {s} -s [FILE_INPUT] -o [PATH_OUTPUT]
        \\
        \\ Examples:
        \\  * Merge
        \\    {s} -m file1.jpg file2.txt file3.zip -o sus.jpg
        \\    {s} -m file1.jpg file2.txt file3.zip file4.exe -o sus.jpg
        \\
        \\  * Split
        \\    {s} -s sus.jpg -o .
        \\    {s} -s sus.jpg -o sus/
        \\
        \\
        \\[Release mode: {s}]
        \\
    , .{ name, name, name, name, name, name, @tagName(builtin.mode) });
}

pub fn main() !u8 {
    std.log.debug("--[Debug Mode]--\n", .{});

    var need_help = true;
    const argv = std.os.argv;
    const len = argv.len;

    defer if (need_help) {
        printHelp(argv[0]);
    };

    if (len < 2)
        return 1;

    const allocator = std.heap.page_allocator;

    const argv1 = mem.span(argv[1]);
    if (mem.eql(u8, argv1, "-m")) {
        if (len < 6)
            return 1;

        if (!mem.eql(u8, mem.span(argv[len - 2]), "-o"))
            return 1;

        const out = mem.span(argv[len - 1]);
        const filesz = argv[2 .. len - 2];
        var files = try allocator.alloc([]const u8, filesz.len);
        defer allocator.free(files);

        for (filesz) |f, i| {
            files[i] = mem.span(f);
        }

        need_help = false;

        const logger = std.log.scoped(.Merger);
        var m = Merger.init(allocator, files, out);
        m.merge() catch |err| {
            logger.err("{s}", .{@errorName(err)});
            return 1;
        };
    } else if (mem.eql(u8, argv1, "-s")) {
        if (len != 5)
            return 1;

        if (!mem.eql(u8, mem.span(argv[3]), "-o"))
            return 1;

        need_help = false;

        const logger = std.log.scoped(.Splitter);
        var s = Splitter.init(allocator, mem.span(argv[2]), mem.span(argv[4]));
        s.split() catch |err| {
            logger.err("{s}", .{@errorName(err)});
            return 1;
        };
    } else {
        return 1;
    }

    return 0;
}
