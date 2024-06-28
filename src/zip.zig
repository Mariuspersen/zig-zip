const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const compress = std.compress;
const mem = std.mem;
const Allocator = mem.Allocator;

const string = []const u8;

fn contains(comptime T: type, haystack: []const T, needle: []const T) bool {
    if (mem.lastIndexOf(T, haystack, needle)) |_| {
        return true;
    } else return false;
}

const delims = &.{
    fs.path.sep_posix,
    fs.path.sep_windows,
};

const archive = struct {
    const Self = @This();
    const local_file_header_signature = [_]u8{ 80, 75, 3, 4 };

    files: mem.SplitIterator(u8, .sequence),

    fn init(file_content: string) archive {
        return .{
            .files = mem.splitSequence(
                u8,
                file_content[4..],
                &local_file_header_signature,
            ),
        };
    }

    fn extract_all(self: *Self, dir: fs.Dir) !void {
        defer self.files.reset();

        while (self.files.next()) |data| {
            var lf = try local_file.init(data);
            const lffp = lf.file_path();
            var lffp_it = mem.splitAny(
                u8,
                lffp,
                delims,
            );

            var temp_dir = dir;
            while (lffp_it.next()) |sub| {
                temp_dir.makeDir(sub) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };
                temp_dir = try temp_dir.openDir(sub, .{});
            }

            const lffn = lf.file_name();

            const file = try temp_dir.createFile(lffn, .{});
            defer file.close();

            const writer = file.writer();
            try lf.deflate(writer);
        }
    }

    fn extract_file_to_writer(self: *Self, filename: string, writer: anytype) !void {
        defer self.files.reset();
        while (self.files.next()) |data| {
            var lf = try local_file.init(data);
            if (contains(u8, lf.header.filename, filename)) {
                try lf.deflate(writer);
                break;
            }
        }
    }

    fn list_files(self: *Self, writer: anytype) !void {
        defer self.files.reset();
        while (self.files.next()) |data| {
            const lf = try local_file.init(data);
            try writer.print("{s}\n", .{lf.header.filename});
        }
    }
};

const local_file = struct {
    const Self = @This();

    header: local_file_header,
    content: string,

    fn init(file_content: string) !local_file {
        var header = try local_file_header.init(file_content);
        if (file_content.len < header.compressed_size + header.size()) return error.compressed_size_header_mismatch;
        const content = file_content[header.size() .. header.size() + header.compressed_size];

        return .{
            .header = header,
            .content = content,
        };
    }

    fn size(self: *Self) usize {
        return self.header.size() + self.header.compressed_size;
    }

    fn deflate(self: *Self, writer: anytype) !void {
        var buf_stream = std.io.fixedBufferStream(self.content);
        const reader = buf_stream.reader();

        switch (self.header.compression_method) {
            0x8 => try compress.flate.decompress(reader, writer),
            0x0 => try writer.writeAll(self.content),
            else => return error.not_implemented,
        }
    }

    fn file_type(self: *Self) string {
        const idx_dot = mem.lastIndexOf(u8, self.header.filename, ".");
        const idx_delim = mem.lastIndexOfAny(u8, self.header.filename, delims);
        
        if (idx_dot) |dot_index|
        if (idx_delim) |delim_index| {
            if(delim_index > dot_index) return "";
            if(delim_index + 1 == dot_index) return "";

            return self.header.filename[dot_index..];
        };

        return "";
    }

    fn file_name(self: *Self) string {
        const idx = mem.lastIndexOfAny(u8, self.header.filename, delims);
        if (idx) |i| {
            return self.header.filename[i + 1 ..];
        }

        return self.header.filename;
    }

    fn file_path(self: *Self) string {
        const idx = mem.lastIndexOfAny(u8, self.header.filename, delims);
        if (idx) |i| {
            return self.header.filename[0..i];
        }

        return ".";
    }
};

const local_file_header = struct {
    const known_size: usize = 26;
    const Self = @This();

    signature: u32 = 0x04034b50,
    version: u16,
    genera_purpose_bit_flag: u16,
    compression_method: u16,
    last_modification_time: u16,
    last_modification_date: u16,
    crc_32: u32,
    compressed_size: u32,
    uncompressed_size: u32,
    file_name_length: u16,
    extra_field_length: u16,
    filename: string = undefined,
    extra_field: string = undefined,

    fn init(file_content: string) !local_file_header {
        if (file_content.len < 28) return error.file_content_too_short;
        var temp = local_file_header{
            .version = mem.readInt(u16, file_content[0..2], .little),
            .genera_purpose_bit_flag = mem.readInt(u16, file_content[2..4], .little),
            .compression_method = mem.readInt(u16, file_content[4..6], .little),
            .last_modification_time = mem.readInt(u16, file_content[6..8], .little),
            .last_modification_date = mem.readInt(u16, file_content[8..10], .little),
            .crc_32 = mem.readInt(u32, file_content[10..14], .little),
            .compressed_size = mem.readInt(u32, file_content[14..18], .little),
            .uncompressed_size = mem.readInt(u32, file_content[18..22], .little),
            .file_name_length = mem.readInt(u16, file_content[22..24], .little),
            .extra_field_length = mem.readInt(u16, file_content[24..26], .little),
        };

        const filename_end = 26 + temp.file_name_length;
        const extra_end = filename_end + temp.extra_field_length;
        temp.filename = file_content[26..filename_end];
        temp.extra_field = file_content[filename_end..extra_end];

        return temp;
    }

    fn size(self: *Self) usize {
        return local_file_header.known_size + self.file_name_length + self.extra_field_length;
    }
};

test "archive extract" {
    const file = try fs.cwd().openFile("archive.zip", .{});
    defer file.close();
    const stat = try file.stat();
    const buffer: []const u8 = try file.readToEndAlloc(testing.allocator, stat.size);
    defer testing.allocator.free(buffer);

    const subpath = "archive_extract";

    fs.cwd().makeDir(subpath) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const dir = try fs.cwd().openDir(subpath, .{});

    var arc = archive.init(buffer);
    try arc.extract_all(dir);
}

test "archive single file" {
    const file = try fs.cwd().openFile("archive.zip", .{});
    defer file.close();
    const stat = try file.stat();
    const buffer: []const u8 = try file.readToEndAlloc(testing.allocator, stat.size);
    defer testing.allocator.free(buffer);

    const subpath = "archive_single_file";

    fs.cwd().makeDir(subpath) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var file_list = std.ArrayList(u8).init(testing.allocator);
    defer file_list.deinit();


    var dir = try fs.cwd().openDir(subpath, .{});
    var arc = archive.init(buffer);

    try arc.list_files(file_list.writer());
    var file_iter = mem.splitAny(u8, file_list.items, "\n");

    const filename = file_iter.peek();

    var result_file = try dir.createFile(filename.?, .{});
    defer result_file.close();

    try arc.extract_file_to_writer(filename.?, result_file.writer());
}
