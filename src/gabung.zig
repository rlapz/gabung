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

    pub const Opt = struct {
        no_footer: bool = false,
    };

    const This = @This();
    const logger = std.log.scoped(.Merger);

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

    pub fn merge(this: *This, opt: Opt) !void {
        const flen = this.src.len;
        const allocator = &this.allocator;

        //
        // Load all files
        //
        var files = try allocator.alloc(fs.File, flen);
        defer allocator.free(files);

        var props = brk: {
            if (opt.no_footer) {
                try this.loadAllNoProp(files);
                break :brk null;
            }
            break :brk try this.loadAll(files);
        };
        defer if (props) |p| {
            allocator.free(p);
        };

        //
        // Create a new file (target file)
        //
        const cwd = fs.cwd();
        var trg: fs.File = undefined;

        while (true) {
            const _trg = this.trg;
            trg = cwd.createFile(_trg, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    if (mem.lastIndexOf(u8, _trg, "/")) |idx| {
                        cwd.makePath(_trg[0..idx]) catch |_err| {
                            logger.err("Failed to create path: {s}", .{
                                _trg[0..idx],
                            });
                            return _err;
                        };
                        continue;
                    }

                    logger.err("Failed to create file: {s}", .{_trg});
                    return err;
                },
                else => {
                    logger.err("Failed to create file: {s}", .{_trg});
                    return err;
                },
            };
            break;
        }

        //
        // Merge files
        //
        for (files) |file, i| {
            trg.writeFileAll(file, .{}) catch |err| {
                logger.err("Failed to write file: {s}", .{this.src[i]});
                return err;
            };
            file.close();
        }

        // Without footer
        if (opt.no_footer)
            return;

        //
        // Add file properties
        //
        var iovs = try allocator.alloc(os.iovec_const, flen + 1);
        defer allocator.free(iovs);

        var iovsp = iovs[0..flen];
        var _props = props.?;
        for (iovsp) |*iov, i| {
            iov.iov_base = @ptrCast([*]const u8, &_props[i]);
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
        trg.writevAll(iovs) catch |err| {
            logger.err("Failed to write file properties", .{});
            return err;
        };
    }

    fn loadAllNoProp(this: *This, files: []fs.File) !void {
        const src = this.src;
        const cwd = fs.cwd();

        for (src) |fname, i| {
            files[i] = cwd.openFile(fname, .{}) catch |err| {
                logger.err("Failed to open: {s}", .{fname});
                return err;
            };
        }
    }

    fn loadAll(this: *This, files: []fs.File) ![]FileProp {
        const src = this.src;
        const cwd = fs.cwd();
        const flen = files.len;

        var props = try this.allocator.alloc(FileProp, flen);
        @memset(@ptrCast([*]u8, props.ptr), 0x69, flen * @sizeOf(FileProp));

        for (src) |fname, i| {
            const file = cwd.openFile(fname, .{}) catch |err| {
                logger.err("Failed to open: {s}", .{fname});
                return err;
            };
            const fstat = try file.stat();
            if (fstat.kind == .Directory) {
                logger.err("Cannot accept directory: {s}", .{fname});
                return error.InvalidArgument;
            }

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

    const logger = std.log.scoped(.Splitter);

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
        const file = cwd.openFile(this.src, .{}) catch |err| {
            logger.err("Failed to open: {s}", .{this.src});
            return err;
        };
        defer file.close();

        const props = try this.load(file);
        defer allocator.free(props);

        //
        // Create target path
        //
        var trg_dir: fs.Dir = undefined;
        while (true) {
            trg_dir = cwd.openDir(this.trg, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    cwd.makePath(this.trg) catch |_err| {
                        logger.err("Failed to create path: {s}", .{
                            this.trg,
                        });
                        return _err;
                    };
                    continue;
                },
                else => {
                    logger.err("Failed to open directory: {s}", .{
                        this.trg,
                    });
                    return err;
                },
            };
            break;
        }
        defer trg_dir.close();

        //
        // Create files
        //
        var offt: u64 = 0;
        var buffer: [1024]u8 = undefined;
        for (props) |*prop| {
            const ftrg_name = std.fmt.bufPrint(&buffer, "{s}{s}", .{
                prop.getName(),
                prop.getExt(),
            }) catch |err| {
                logger.err("File name is too long", .{});
                return err;
            };
            const ftrg = trg_dir.createFile(ftrg_name, .{}) catch |err| {
                logger.err("Failed to create file: {s}", .{ftrg_name});
                return err;
            };
            defer ftrg.close();

            const size = prop.getOfft();
            ftrg.writeFileAll(file, .{
                .in_offset = offt,
                .in_len = size,
            }) catch |err| {
                logger.err("Failed to create file: {s}", .{ftrg_name});
                return err;
            };

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

        const file_rd = file.readvAll(iovs) catch |err| {
            logger.err("Failed to read file properties", .{});
            return err;
        };
        if (file_rd != (prop_size * count))
            return error.InvalidFile;

        try file.seekTo(0);
        return props;
    }
};
