const std = @import("std");
const string = []const u8;
const extras = @import("extras");

const u = @import("index.zig");

//
//

pub const b = 1;
pub const kb = b * 1024;
pub const mb = kb * 1024;
pub const gb = mb * 1024;

const ansi_red = "\x1B[31m";
const ansi_reset = "\x1B[39m";

pub fn assert(ok: bool, comptime fmt: string, args: anytype) void {
    if (!ok) {
        std.debug.print(ansi_red ++ fmt ++ ansi_reset ++ "\n", args);
        std.os.exit(1);
    }
}

pub fn fail(comptime fmt: string, args: anytype) noreturn {
    assert(false, fmt, args);
    unreachable;
}

pub fn try_index(comptime T: type, array: []T, n: usize, def: T) T {
    if (array.len <= n) {
        return def;
    }
    return array[n];
}

pub fn split(alloc: std.mem.Allocator, in: string, delim: string) ![]string {
    var list = std.ArrayList(string).init(alloc);
    errdefer list.deinit();

    var iter = std.mem.split(u8, in, delim);
    while (iter.next()) |str| {
        try list.append(str);
    }
    return list.toOwnedSlice();
}

pub fn does_folder_exist(fpath: string) !bool {
    const file = std.fs.cwd().openFile(fpath, .{}) catch |e| switch (e) {
        error.FileNotFound => return false,
        error.IsDir => return true,
        else => |ee| return ee,
    };
    defer file.close();
    const s = try file.stat();
    if (s.kind != .directory) {
        return false;
    }
    return true;
}

pub fn trim_suffix(in: string, suffix: string) string {
    if (std.mem.endsWith(u8, in, suffix)) {
        return in[0 .. in.len - suffix.len];
    }
    return in;
}

pub fn list_contains_gen(comptime T: type, haystack: []const T, needle: T) bool {
    for (haystack) |item| {
        if (item.eql(needle)) {
            return true;
        }
    }
    return false;
}

pub fn file_list(alloc: std.mem.Allocator, dpath: string) ![]const string {
    var dir = try std.fs.cwd().openIterableDir(dpath, .{});
    defer dir.close();
    return try extras.fileList(alloc, dir);
}

pub fn run_cmd_raw(alloc: std.mem.Allocator, dir: ?string, args: []const string) !std.ChildProcess.ExecResult {
    return std.ChildProcess.exec(.{ .allocator = alloc, .cwd = dir, .argv = args, .max_output_bytes = std.math.maxInt(usize) }) catch |e| switch (e) {
        error.FileNotFound => {
            u.fail("\"{s}\" command not found", .{args[0]});
        },
        else => |ee| return ee,
    };
}

pub fn run_cmd(alloc: std.mem.Allocator, dir: ?string, args: []const string) !u32 {
    const result = try run_cmd_raw(alloc, dir, args);
    alloc.free(result.stdout);
    alloc.free(result.stderr);
    return result.term.Exited;
}

pub fn list_remove(alloc: std.mem.Allocator, input: []string, search: string) ![]string {
    var list = std.ArrayList(string).init(alloc);
    errdefer list.deinit();
    for (input) |item| {
        if (!std.mem.eql(u8, item, search)) {
            try list.append(item);
        }
    }
    return list.toOwnedSlice();
}

pub fn last(in: []string) !string {
    if (in.len == 0) {
        return error.EmptyArray;
    }
    return in[in.len - 1];
}

const alphabet = "0123456789abcdefghijklmnopqrstuvwxyz";

pub fn random_string(alloc: std.mem.Allocator, len: usize) !string {
    const now: u64 = @intCast(std.time.nanoTimestamp());
    var rand = std.rand.DefaultPrng.init(now);
    var r = rand.random();
    var buf = try alloc.alloc(u8, len);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        buf[i] = alphabet[r.int(usize) % alphabet.len];
    }
    return buf;
}

pub fn parse_split(comptime T: type, comptime delim: string) type {
    return struct {
        const Self = @This();

        id: T,
        string: string,

        pub fn do(input: string) !Self {
            var iter = std.mem.split(u8, input, delim);
            const start = iter.next() orelse return error.IterEmpty;
            const id = std.meta.stringToEnum(T, start) orelse return error.NoMemberFound;
            return Self{
                .id = id,
                .string = iter.rest(),
            };
        }
    };
}

pub const HashFn = enum {
    blake3,
    sha256,
    sha512,
};

pub fn validate_hash(alloc: std.mem.Allocator, input: string, file_path: string) !bool {
    const hash = parse_split(HashFn, "-").do(input) catch return false;
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();
    const data = try file.reader().readAllAlloc(alloc, gb);
    const expected = hash.string;
    const actual = switch (hash.id) {
        .blake3 => try do_hash(alloc, std.crypto.hash.Blake3, data),
        .sha256 => try do_hash(alloc, std.crypto.hash.sha2.Sha256, data),
        .sha512 => try do_hash(alloc, std.crypto.hash.sha2.Sha512, data),
    };
    const result = std.mem.startsWith(u8, actual, expected);
    if (!result) {
        std.log.info("expected: {s}, actual: {s}", .{ expected, actual });
    }
    return result;
}

pub fn do_hash(alloc: std.mem.Allocator, comptime algo: type, data: string) !string {
    var h = algo.init(.{});
    var out: [algo.digest_length]u8 = undefined;
    h.update(data);
    h.final(&out);
    const hex = try std.fmt.allocPrint(alloc, "{x}", .{std.fmt.fmtSliceHexLower(out[0..])});
    return hex;
}

/// Returns the result of running `git rev-parse HEAD`
pub fn git_rev_HEAD(alloc: std.mem.Allocator, dir: std.fs.Dir) !string {
    const dirg = try dir.openDir(".git", .{});
    const h = std.mem.trim(u8, try dirg.readFileAlloc(alloc, "HEAD", 50), "\n");
    if (!std.mem.startsWith(u8, h, "ref:")) return h;
    const r = std.mem.trim(u8, try dirg.readFileAlloc(alloc, h[5..], 50), "\n");
    return r;
}

pub fn slice(comptime T: type, input: []const T, from: usize, to: usize) []const T {
    const f = @max(from, 0);
    const t = @min(to, input.len);
    return input[f..t];
}

pub fn detect_pkgname(alloc: std.mem.Allocator, override: string, dir: string) !string {
    if (override.len > 0) {
        return override;
    }
    const dirO = if (dir.len == 0) std.fs.cwd() else try std.fs.cwd().openDir(dir, .{});
    if (!(try extras.doesFileExist(dirO, "build.zig"))) {
        return error.NoBuildZig;
    }
    const dpath = try std.fs.realpathAlloc(alloc, try std.fs.path.join(alloc, &.{ dir, "build.zig" }));
    const splitP = try split(alloc, dpath, std.fs.path.sep_str);
    var name = splitP[splitP.len - 2];
    name = extras.trimPrefix(name, "zig-");
    assert(name.len > 0, "package name must not be an empty string", .{});
    return name;
}

pub fn detct_mainfile(alloc: std.mem.Allocator, override: string, dir: ?std.fs.Dir, name: string) !string {
    if (override.len > 0) {
        if (try extras.doesFileExist(dir, override)) {
            if (std.mem.endsWith(u8, override, ".zig")) {
                return override;
            }
        }
    }
    const namedotzig = try std.mem.concat(alloc, u8, &.{ name, ".zig" });
    if (try extras.doesFileExist(dir, namedotzig)) {
        return namedotzig;
    }
    if (try extras.doesFileExist(dir, try std.fs.path.join(alloc, &.{ "src", "lib.zig" }))) {
        return "src/lib.zig";
    }
    if (try extras.doesFileExist(dir, try std.fs.path.join(alloc, &.{ "src", "main.zig" }))) {
        return "src/main.zig";
    }
    return error.CantFindMain;
}

pub fn indexOfN(haystack: string, needle: u8, n: usize) ?usize {
    var i: usize = 0;
    var c: usize = 0;
    while (c < n) {
        i = indexOfAfter(haystack, needle, i) orelse return null;
        c += 1;
    }
    return i;
}

pub fn indexOfAfter(haystack: string, needle: u8, after: usize) ?usize {
    for (haystack, 0..) |c, i| {
        if (i <= after) continue;
        if (c == needle) return i;
    }
    return null;
}
