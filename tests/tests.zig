const zip = @import("zip");
const std = @import("std");

const Archive = zip.Archive;

const testing = std.testing;
const fs = std.fs;

test "extract from archive" {
    const file = try fs.cwd().openFile("archive.zip", .{});
    const stat = try file.stat();
    const data = try file.readToEndAlloc(testing.allocator, stat.size);

    defer file.close();
    defer testing.allocator.free(data);

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var content = std.ArrayList(u8).init(testing.allocator);
    defer content.deinit();

    var archive = Archive.init(data);
    try archive.listFiles(buffer.writer());

    var buf_it = std.mem.splitSequence(u8, buffer.items, "\n");

    if (buf_it.next()) |name| {
        try archive.extractFileToWriter(name, content.writer());
    }
}

test "compress to archive" {
    const file = try fs.cwd().openFile("build.zig", .{});
    const stat = try file.stat();
    const data = try file.readToEndAlloc(testing.allocator, stat.size);

    defer file.close();
    defer testing.allocator.free(data);

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var buffer2 = std.ArrayList(u8).init(testing.allocator);
    defer buffer2.deinit();
    
    try Archive.addFile("build.zig", data, buffer.writer(), testing.allocator);

    var archive = Archive.init(buffer.items);
    try archive.extractFileToWriter("build.zig", buffer2.writer());

    try testing.expect(std.mem.eql(u8, data, buffer2.items));
}
