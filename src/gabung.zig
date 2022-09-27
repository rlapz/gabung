const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const os = std.os;
const Allocator = mem.Allocator;

const assert = std.debug.assert;

// TODO: add max files limit
//const max_files = 128;

// File layout (Merged)
//
// +-----------------+
// |      Files      |
// .        .        .
// .        .        .
// .        .        .
// .        .        .
// .        .        .
// +-----------------+
// | File Properties |
// .        .        .
// .        .        .
// +-----------------+
// |     Counter     |
// +-----------------+
//
// File Properties: 264 bytes
// Counter        :   8 bytes; Big endian
//

// File properties
const FileProp = extern struct {
    // Big endian
    // Offset / size
    offt: u64,

    // Null terminated bytes
    // File name
    name: [name_len:0]u8,

    // Null terminated bytes
    // File extension
    ext: [ext_len:0]u8,

    const name_len = 248 - 1;
    const ext_len = 8 - 1;

    const This = @This();
    fn setName(this: *This, name: []const u8) void {
        var len = name.len;
        if (len > name_len)
            len -= (len - name_len);

        mem.copy(u8, &this.name, name[0..len]);
        this.name[len] = 0;
    }

    fn setExt(this: *This, ext: []const u8) void {
        var len = ext.len;
        if (len > ext_len)
            len -= (len - ext_len);

        mem.copy(u8, &this.ext, ext[0..len]);
        this.ext[len] = 0;
    }

    fn setOfft(this: *This, offt: u64) void {
        this.offt = mem.nativeToBig(u64, offt);
    }

    fn getName(this: *This) []const u8 {
        return toSlice(&this.name);
    }

    fn getExt(this: *This) []const u8 {
        return toSlice(&this.ext);
    }

    fn getOfft(this: This) u64 {
        return mem.bigToNative(u64, this.offt);
    }

    // Assertions
    comptime {
        assert(@offsetOf(This, "offt") == 0);
        assert(@offsetOf(This, "name") == 8);
        assert(@offsetOf(This, "ext") == 256);
        assert(@sizeOf(This) == 8 + 248 + 8);

        assert(@alignOf(This) == @alignOf(u64));
    }
};

fn toSlice(str: [*]const u8) []const u8 {
    var count: usize = 0;
    while (str[count] != 0) : (count += 1) {}

    return str[0..count];
}

//
// Merger
//
pub const Merger = struct {
    allocator: Allocator,
    src: []const []const u8,
    trg: []const u8,

    const This = @This();

    pub fn init(
        allocator: Allocator,
        src: []const []const u8,
        trg: []const u8,
    ) This {
        return This{
            .allocator = allocator,
            .src = src,
            .trg = trg,
        };
    }

    pub fn merge(this: *This) !void {
        const flen = this.src.len;
        const allocator = &this.allocator;

        //
        // Load all files
        //
        var files = try allocator.alloc(fs.File, flen);
        defer allocator.free(files);

        var props = try this.loadAll(files);
        defer allocator.free(props);

        //
        // Create a new file (target file)
        //
        const cwd = fs.cwd();
        const trg = brk: while (true) {
            const _trg = this.trg;
            break :brk cwd.createFile(_trg, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    if (mem.lastIndexOf(u8, _trg, "/")) |idx| {
                        try cwd.makePath(_trg[0..idx]);
                        continue;
                    }
                    return err;
                },
                else => return err,
            };
        };

        //
        // Merge files
        //
        for (files) |file| {
            try trg.writeFileAll(file, .{});
            file.close();
        }

        //
        // Add file properties
        //
        var iovs = try allocator.alloc(os.iovec_const, flen + 1);
        defer allocator.free(iovs);

        var iovsp = iovs[0..flen];
        for (iovsp) |*iov, i| {
            iov.iov_base = @ptrCast([*]const u8, &props[i]);
            iov.iov_len = @sizeOf(FileProp);
        }

        //
        // Add file counter
        //
        const fc = mem.nativeToBig(u64, flen);
        iovs[flen].iov_base = @ptrCast([*]const u8, &fc);
        iovs[flen].iov_len = @sizeOf(u64);

        //
        // Write all
        //
        try trg.writevAll(iovs);
    }

    fn loadAll(this: *This, files: []fs.File) ![]FileProp {
        const src = this.src;
        const cwd = fs.cwd();
        const flen = files.len;

        var props = try this.allocator.alloc(FileProp, flen);
        @memset(@ptrCast([*]u8, props.ptr), 0x69, flen * @sizeOf(FileProp));

        for (src) |fname, i| {
            const file = try cwd.openFile(fname, .{});
            const fstat = try file.stat();
            const fext = fs.path.extension(fname);
            const fbsname = brk: {
                const bn = fs.path.basename(fname);
                const idx = mem.lastIndexOf(u8, bn, fext) orelse bn.len;

                break :brk bn[0..idx];
            };

            files[i] = file;
            const p = &props[i];
            p.setOfft(fstat.size);
            p.setName(fbsname);
            p.setExt(fext);
        }

        return props;
    }
};

//
// Splitter
//
pub const Splitter = struct {
    allocator: Allocator,
    src: []const u8,
    trg: []const u8,

    const This = @This();
    pub fn init(allocator: Allocator, src: []const u8, trg: []const u8) This {
        return This{
            .allocator = allocator,
            .trg = trg,
            .src = src,
        };
    }

    pub fn split(this: *This) !void {
        const allocator = &this.allocator;
        const cwd = fs.cwd();

        //
        // Open and load source file
        //
        const file = try cwd.openFile(this.src, .{});
        defer file.close();

        const props = try this.load(file);
        defer allocator.free(props);

        //
        // Create target path
        //
        var trg_dir = brk: while (true) {
            break :brk cwd.openDir(this.trg, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    try cwd.makePath(this.trg);
                    continue;
                },
                else => return err,
            };
        };
        defer trg_dir.close();

        //
        // Create files
        //
        var offt: u64 = 0;
        var buffer: [1024]u8 = undefined;
        for (props) |*prop| {
            const ftrg_name = try std.fmt.bufPrint(&buffer, "{s}{s}", .{
                prop.getName(),
                prop.getExt(),
            });
            const ftrg = try trg_dir.createFile(ftrg_name, .{});
            defer ftrg.close();

            const size = prop.getOfft();
            try ftrg.writeFileAll(file, .{
                .in_offset = offt,
                .in_len = size,
            });

            offt += size;
        }
    }

    fn load(this: *This, file: fs.File) ![]FileProp {
        //
        // Get file count
        //
        file.seekFromEnd(-@sizeOf(u64)) catch |err| switch (err) {
            error.Unseekable => return error.InvalidFile,
            else => return err,
        };
        const cpos = try file.getPos();

        var count: u64 = 0;
        const count_size = @sizeOf(u64);
        const count_bf = @ptrCast([*]u8, &count)[0..count_size];
        const count_rd = try file.readAll(count_bf);
        if (count_rd != count_size or count == 0)
            return error.InvalidFile;

        count = mem.bigToNative(u64, count);

        //
        // Get file properties
        //
        const prop_size = @sizeOf(FileProp);
        if (cpos < prop_size or count > cpos)
            return error.InvalidFile;

        const pcount = prop_size * count;
        if (pcount > cpos)
            return error.InvalidFile;

        const pbegin = cpos - pcount;
        try file.seekTo(pbegin);

        const allocator = &this.allocator;
        var props = try allocator.alloc(FileProp, @intCast(usize, count));
        var iovs = try allocator.alloc(os.iovec, @intCast(usize, count));
        defer allocator.free(iovs);

        for (iovs) |*iov, i| {
            iov.iov_base = @ptrCast([*]u8, &props[i]);
            iov.iov_len = prop_size;
        }

        const file_rd = try file.readvAll(iovs);
        if (file_rd != (prop_size * count))
            return error.InvalidFile;

        try file.seekTo(0);
        return props;
    }
};
