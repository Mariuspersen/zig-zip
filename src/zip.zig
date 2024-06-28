const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const compress = std.compress;
const mem = std.mem;
const Allocator = mem.Allocator;

const string = []const u8;

const archive = struct {
    const Self = @This();
    const needle = [_]u8{ 80, 75, 3, 4 };

    filename: string = undefined,
    files: std.ArrayList(local_file),

    fn init(file_content: string, allocator: Allocator) !archive {
        //  TODO: remove allocations, replace with std.mem.split, maybe 
        var temp = .{
            .files = std.ArrayList(local_file).init(allocator),
        };
        try index(file_content, &temp.files);
        return temp;
    }

    fn extract(self: *Self, subpath: string, allocator: Allocator) !void {
        // TODO: remove allocations
        for (self.files.items) |*lf| {
            const path = try fs.path.join(allocator, &.{ subpath, try lf.file_path() });
            defer allocator.free(path);

            _ = mem.replace(u8, path, "/", fs.path.sep_str, path);

            var path_it = mem.split(u8, path, fs.path.sep_str);
            var dir = fs.cwd();
            while (path_it.next()) |sub| {
                dir.makeDir(sub) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };
                dir = try dir.openDir(sub, .{});
            }

            const lffn = try lf.file_name();
            if (lffn.len == 0) continue;

            const file = try dir.createFile(lffn, .{});
            defer file.close();

            const writer = file.writer();
            try lf.deflate(writer);
        }
    }

    fn index(file_content: string, files: *std.ArrayList(local_file)) !void {
        const idx = mem.indexOf(u8, file_content, &needle);
        if (idx) |i| {
            const lf = try local_file.init(file_content[i..]);
            try files.append(lf);
            try index(file_content[i + 1 ..], files);
        }
    }
    fn extract_file_to_writer(self: *Self, filename: string, writer: anytype) !void {
        for (self.files.items) |*lf| if (mem.indexOf(u8, lf.header.filename,filename) != null) {
            try lf.deflate(writer);
            break;
        };
    }


    fn deinit(self: *Self) void {
        self.files.deinit();
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
            else => {
                std.debug.print("{any}\n{s}", .{self.header,self.header.filename});
                return error.not_implemented;
            },
        }
    }

    fn file_type(self: *Self) !string {
        const idx = mem.lastIndexOf(u8, self.header.filename, ".");
        if (idx) |i| {
            return self.header.filename[i..];
        }

        return error.unable_to_determine_file_type;
    }

    fn file_name(self: *Self) !string {
        const idx = mem.lastIndexOf(u8, self.header.filename, "/");
        if (idx) |i| {
            return self.header.filename[i + 1 ..];
        }

        return error.unable_to_determine_file_name;
    }

    fn file_path(self: *Self) !string {
        const idx = mem.lastIndexOf(u8, self.header.filename, "/");
        if (idx) |i| {
            return self.header.filename[0..i];
        }

        return error.unable_to_determine_file_path;
    }
};

const local_file_header = struct {
    const known_size: usize = 30;
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
        // TODO: replace init with init_no_signature
        if (file_content.len < 30) return error.file_content_too_short;
        var temp = local_file_header{
            .signature = mem.readInt(u32, file_content[0..4], .little),
            .version = mem.readInt(u16, file_content[4..6], .little),
            .genera_purpose_bit_flag = mem.readInt(u16, file_content[6..8], .little),
            .compression_method = mem.readInt(u16, file_content[8..10], .little),
            .last_modification_time = mem.readInt(u16, file_content[10..12], .little),
            .last_modification_date = mem.readInt(u16, file_content[12..14], .little),
            .crc_32 = mem.readInt(u32, file_content[14..18], .little),
            .compressed_size = mem.readInt(u32, file_content[18..22], .little),
            .uncompressed_size = mem.readInt(u32, file_content[22..26], .little),
            .file_name_length = mem.readInt(u16, file_content[26..28], .little),
            .extra_field_length = mem.readInt(u16, file_content[28..30], .little),
        };
        if (temp.signature != 0x04034b50) return error.not_a_zip_file_header;

        const filename_end = 30 + temp.file_name_length;
        const extra_end = filename_end + temp.extra_field_length;
        temp.filename = file_content[30..filename_end];
        temp.extra_field = file_content[filename_end..extra_end];

        return temp;
    }

    fn init_no_signature(file_content: string) !local_file_header {
        if (file_content.len < 30) return error.file_content_too_short;
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

        const filename_end = 28 + temp.file_name_length;
        const extra_end = filename_end + temp.extra_field_length;
        temp.filename = file_content[28..filename_end];
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

    var arc = try archive.init(buffer, testing.allocator);
    defer arc.deinit();
    try arc.extract("result", testing.allocator);
}

test "archive single file" {
    const file = try fs.cwd().openFile("archive.zip", .{});
    defer file.close();
    const stat = try file.stat();
    const buffer: []const u8 = try file.readToEndAlloc(testing.allocator, stat.size);
    defer testing.allocator.free(buffer);

    const subpath = "result";

    fs.cwd().makeDir(subpath) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const path = try fs.path.join(testing.allocator, &.{ subpath, "archive_single_file.txt" });
    defer testing.allocator.free(path);

    var result_file = try fs.cwd().createFile(path, .{});
    defer result_file.close();

    var arc = try archive.init(buffer, testing.allocator);
    defer arc.deinit();

    try arc.extract_file_to_writer("logfile.txt", result_file.writer());
}
