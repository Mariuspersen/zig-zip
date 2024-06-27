const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const compress = std.compress;

const string = []const u8;

const zip_local_file_header = struct {
    const known_size: usize = 30; 

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
    filename: []const u8,
    extra_field: []const u8,

    fn init(file_content: string) !zip_local_file_header {
        if(file_content.len < 30) return error.file_content_too_short;
        var temp = zip_local_file_header{
            .signature = std.mem.readInt(u32, file_content[0..4], .little),
            .version = std.mem.readInt(u16, file_content[4..6], .little),
            .genera_purpose_bit_flag = std.mem.readInt(u16, file_content[6..8], .little),
            .compression_method = std.mem.readInt(u16, file_content[8..10], .little),
            .last_modification_time = std.mem.readInt(u16, file_content[10..12], .little),
            .last_modification_date = std.mem.readInt(u16, file_content[12..14], .little),
            .crc_32 = std.mem.readInt(u32, file_content[14..18], .little),
            .compressed_size = std.mem.readInt(u32, file_content[18..22], .little),
            .uncompressed_size = std.mem.readInt(u32, file_content[22..26], .little),
            .file_name_length = std.mem.readInt(u16, file_content[26..28], .little),
            .extra_field_length = std.mem.readInt(u16, file_content[28..30], .little),
            .filename = "test",
            .extra_field = "test"
        };
        const filename_end = 30+temp.file_name_length;
        const extra_begin = filename_end;
        const extra_end = extra_begin + temp.extra_field_length;
        temp.filename = file_content[30..filename_end];
        temp.extra_field = file_content[extra_begin..extra_end];
        if (temp.signature == 0x04034b50) {
            return temp;
        } else return error.not_a_zip_file_header;
    }
};

test "sizeof(zip_local_file_header)" {
    std.debug.print("@sizeOf(zip_local_file_header): {d}\n", .{@sizeOf(zip_local_file_header)});
}

test "sizeof([]const u8)" {
    std.debug.print("@sizeOf([]const u8): {d}\n", .{@sizeOf([]const u8)});
}

test "find_tile_header" {
    const file = try fs.cwd().openFile("logfile.zip", .{});
    var buffer: [zip_local_file_header.known_size]u8 = undefined;
    _ = try file.read(&buffer);
    std.debug.print("zip_header text: {s}\n", .{buffer});
}

test "zip_file_header_init" {
    const file = try fs.cwd().openFile("logfile.zip", .{});
    const stat = try file.stat();
    const buffer: []const u8 = try file.readToEndAlloc(testing.allocator, stat.size);
    defer testing.allocator.free(buffer);

    const result = try zip_local_file_header.init(buffer);
    std.debug.print("{any}\nfilename:{s}\nextra:{s}\n", .{result,result.filename,result.extra_field});
}
