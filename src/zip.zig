const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const compress = std.compress;
const mem = std.mem;
const Allocator = mem.Allocator;

const Endian = std.builtin.Endian;
const native_endian = std.builtin.cpu.arch.endian();
const crc = std.hash.crc;

pub const String = []const u8;

fn contains(comptime T: type, haystack: []const T, needle: []const T) bool {
    if (mem.lastIndexOf(T, haystack, needle)) |_| {
        return true;
    } else return false;
}

inline fn IntToByteSlice(
    number: anytype,
) [@divExact(@typeInfo(@TypeOf(number)).Int.bits, 8)]u8 {
    return @bitCast(number);
}

const delims = &.{
    fs.path.sep_posix,
    fs.path.sep_windows,
};

pub const Archive = struct {
    const Self = @This();
    const local_file_header_signature = [_]u8{ 80, 75, 3, 4 };

    files: mem.SplitIterator(u8, .sequence),

    pub fn init(file_content: String) Archive {
        return .{
            .files = mem.splitSequence(
                u8,
                file_content,
                &local_file_header_signature,
            ),
        };
    }

    pub fn addFile( filename: String, data: String,writer: anytype, allocator: Allocator) !void {
        try LocalFile.create(data, filename, writer, allocator);
    }

    inline fn checkStart(self: *Self) !void {
        if (self.files.next()) |data| {
            if (!mem.eql(u8, data, "")) {
                return error.weird_start_to_file;
            }
        }
    }

    pub fn extractAll(self: *Self, dir: fs.Dir) !void {
        defer self.files.reset();
        try checkStart(self);

        while (self.files.next()) |data| {
            var lf = try LocalFile.init(data);
            const lffp = lf.filePath();
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

            const lffn = lf.fileName();

            const file = temp_dir.createFile(lffn, .{}) catch |err| switch (err) {
                fs.File.OpenError.IsDir => continue,
                else => return err,
            };
            defer file.close();

            const writer = file.writer();
            try lf.deflate(writer);
        }
    }

    pub fn extractFileToWriter(self: *Self, filename: String, writer: anytype) !void {
        defer self.files.reset();
        try checkStart(self);

        while (self.files.next()) |data| {
            var lf = try LocalFile.init(data);
            if (contains(u8, lf.header.filename, filename)) {
                try lf.deflate(writer);
                break;
            }
        }
    }

    pub fn listFiles(self: *Self, writer: anytype) !void {
        defer self.files.reset();
        try checkStart(self);

        while (self.files.next()) |data| {
            const lf = try LocalFile.init(data);
            try writer.print("{s}\n", .{lf.header.filename});
        }
    }
};

const LocalFile = struct {
    const Self = @This();

    header: LocalFileHeader,
    content: String,

    fn init(file_content: String) !LocalFile {
        var header = try LocalFileHeader.init(file_content);
        if (file_content.len < header.compressed_size + header.size()) return error.compressed_size_header_mismatch;
        const content = file_content[header.size() .. header.size() + header.compressed_size];

        return .{
            .header = header,
            .content = content,
        };
    }

    fn create(data: String, filename: String, writer: anytype, allocator: Allocator) !void {
        var buf_stream = std.io.fixedBufferStream(data);
        var temp_buf = std.ArrayList(u8).init(allocator);
        defer temp_buf.deinit();

        const crc32 = crc.Crc32.hash(data);

        try compress.flate.compress(buf_stream.reader(), temp_buf.writer(), .{});
        const lfh = LocalFileHeader.create(@intCast(temp_buf.items.len), @intCast(data.len), crc32, filename);
        try writer.writeAll(&Archive.local_file_header_signature);
        try writer.writeAll(&IntToByteSlice(lfh.version));
        try writer.writeAll(&IntToByteSlice(lfh.genera_purpose_bit_flag));
        try writer.writeAll(&IntToByteSlice(lfh.compression_method));
        try writer.writeAll(&IntToByteSlice(lfh.last_modification_time));
        try writer.writeAll(&IntToByteSlice(lfh.last_modification_date));
        try writer.writeAll(&IntToByteSlice(lfh.crc_32));
        try writer.writeAll(&IntToByteSlice(lfh.compressed_size));
        try writer.writeAll(&IntToByteSlice(lfh.uncompressed_size));
        try writer.writeAll(&IntToByteSlice(lfh.file_name_length));
        try writer.writeAll(&IntToByteSlice(lfh.extra_field_length));
        try writer.writeAll(lfh.filename[0..lfh.file_name_length]);
        try writer.writeAll(lfh.extra_field[0..lfh.extra_field_length]);
        try writer.writeAll(temp_buf.items);
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

    fn fileType(self: *Self) String {
        const idx_dot = mem.lastIndexOf(u8, self.header.filename, ".");
        const idx_delim = mem.lastIndexOfAny(u8, self.header.filename, delims);

        if (idx_dot) |dot_index|
            if (idx_delim) |delim_index| {
                if (delim_index > dot_index) return "";
                if (delim_index + 1 == dot_index) return "";

                return self.header.filename[dot_index..];
            };

        return "";
    }

    fn fileName(self: *Self) String {
        const idx = mem.lastIndexOfAny(u8, self.header.filename, delims);
        if (idx) |i| {
            return self.header.filename[i + 1 ..];
        }

        return self.header.filename;
    }

    fn filePath(self: *Self) String {
        const idx = mem.lastIndexOfAny(u8, self.header.filename, delims);
        if (idx) |i| {
            return self.header.filename[0..i];
        }

        return ".";
    }
};

const LocalFileHeader = struct {
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
    filename: String = undefined,
    extra_field: String = undefined,

    fn init(file_content: String) !LocalFileHeader {
        if (file_content.len < 26) return error.file_content_too_short;
        var temp = LocalFileHeader{
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

        if (temp.compressed_size == 0xffffffff or temp.uncompressed_size == 0xffffffff) return error.ZIP64_not_implemented;

        const filename_end = 26 + temp.file_name_length;
        const extra_end = filename_end + temp.extra_field_length;
        temp.filename = file_content[26..filename_end];
        temp.extra_field = file_content[filename_end..extra_end];

        return temp;
    }

    fn create(compressed_size: u32, uncompressed_size: u32, crc32_hash: u32,filename: String) LocalFileHeader {
        const temp = LocalFileHeader{
            .version = 20,
            .genera_purpose_bit_flag = 2,
            .compression_method = 0x8,
            .last_modification_date = 3,
            .last_modification_time = 4,
            .crc_32 = crc32_hash,
            .compressed_size = compressed_size,
            .uncompressed_size = uncompressed_size,
            .file_name_length = @intCast(filename.len),
            .extra_field_length = 0,
            .filename = filename,
            .extra_field = "",
        };
        return temp;
    }

    fn size(self: *Self) usize {
        return LocalFileHeader.known_size + self.file_name_length + self.extra_field_length;
    }
};
