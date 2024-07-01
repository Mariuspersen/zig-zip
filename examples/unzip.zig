const std = @import("std");
const zip = @import("zip");

const Help: String = @embedFile("help.txt");

const heap = std.heap;
const process = std.process;
const fs = std.fs;
const mem = std.mem;

const Archive = zip.Archive;
const String = zip.String;

const delims = &.{
    fs.path.sep_posix,
    fs.path.sep_windows,
};

const Flags = struct {
    extract: bool = false,
    single: bool = false,
    select: bool = false,
    list: bool = false,
    stdout: bool = false,

    fn init(arg: String) Flags {
        var temp: Flags = .{};
        for (arg[1..]) |char| switch (char) {
            'e' => temp.extract = true,
            'l' => temp.list = true,
            'f' => temp.single = true,
            's', 'i' => temp.select = true,
            'o' => temp.stdout = true,
            else => {},
        };
        return temp;
    }
};

const File = struct {
    flags: Flags,
    path: String,

    fn init(arg1: String, arg2: String) File {
        return .{
            .flags = Flags.init(arg1),
            .path = arg2,
        };
    }

    fn fileNameNoExtension(self: *File) String {
        var base = fs.path.basename(self.path);
        const extension = fs.path.extension(self.path);
        const index = mem.lastIndexOf(u8, base, extension);
        if (index) |i| {
            return base[0..i];
        }

        return base;
    }
};

pub fn main() !void {
    var arena = heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try process.argsWithAllocator(allocator);
    _ = args.skip();
    defer args.deinit();

    const stdout = std.io.getStdOut();
    var bw = std.io.bufferedWriter(stdout.writer());
    const stdbw = bw.writer();
    defer bw.flush() catch {};

    var files = std.ArrayList(File).init(allocator);
    defer files.deinit();

    while (args.next()) |arg| {
        if (mem.eql(u8, arg, "--help") or mem.eql(u8, arg, "-h")) {
            try stdbw.writeAll(Help);
        }

        if (arg[0] == '-') {
            if (args.next()) |arg2| try files.append(File.init(arg, arg2));
        } else {
            try files.append(File.init("-i", arg));
        }
    }

    for (files.items) |*file| {
        if (file.flags.single or file.flags.stdout) {
            const to_extract = fs.path.basename(file.path);
            for (files.items) |*subfile| {
                const sub_file_base = fs.path.basename(subfile.path);
                if (subfile.flags.select) {
                    if (mem.eql(u8, to_extract, sub_file_base)) return error.saving_to_input_file;
                    const open_subfile = try fs.cwd().openFile(subfile.path, .{});
                    defer open_subfile.close();

                    const sub_stat = try open_subfile.stat();
                    const sub_content = try open_subfile.readToEndAlloc(allocator, sub_stat.size);
                    defer allocator.free(sub_content);

                    var subzip = Archive.init(sub_content);
                    if (file.flags.stdout) {
                        try subzip.extractFileToWriter(to_extract, stdbw);
                    } else {
                        const dest_file = try fs.cwd().createFile(to_extract, .{});
                        defer dest_file.close();
                        try subzip.extractFileToWriter(to_extract, dest_file.writer());
                    }

                    break;
                }
            }
            continue;
        }

        if (file.flags.select) continue;

        const open_file = try fs.cwd().openFile(file.path, .{});
        defer open_file.close();

        const stat = try open_file.stat();
        const content = try open_file.readToEndAlloc(allocator, stat.size);
        defer allocator.free(content);

        var archive = Archive.init(content);

        if (file.flags.list) {
            try archive.listFiles(stdbw);
        }

        if (file.flags.extract) {
            const dir_name = file.fileNameNoExtension();
            try fs.cwd().makeDir(dir_name);
            var dir = try fs.cwd().openDir(dir_name, .{});
            defer dir.close();
            try archive.extractAll(dir);
        }
    }
}
