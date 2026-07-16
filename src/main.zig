const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const builtin = @import("builtin");

const site_exporter = @import("site_exporter");
const zap = @import("zap");

var debug_allocator: std.heap.DebugAllocator(.{
    // just to be explicit
    .thread_safe = true,
}) = .{};

pub fn main(init: std.process.Init) !void {
    const args = init.minimal.args.vector;
    var listen_interface: ?[*:0]const u8 = null;
    var listen_port: usize = 8080;
    if (args.len >= 2) {
        listen_interface = args[1];
    }
    if (args.len >= 3) {
        listen_port = std.fmt.parseUnsigned(@TypeOf(listen_port), std.mem.span(args[2]), 10) catch {
            std.log.err("Unknown port: {s}", .{args[2]});
            return;
        };
    }
    if (args.len >= 4) {
        std.log.warn("Remaining {d} arguments are ignored", .{args.len - 3});
    }

    const gpa, const is_debug = switch (builtin.mode) {
        .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
        .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
    };
    defer if (is_debug) {
        const check = debug_allocator.deinit();
        if (check == .leak) {
            std.log.err("mem leak detected!", .{});
        }
    };

    var app_context = ac: {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var db_url = get_environ(arena.allocator(), init.io, init.environ_map.get("DB_URL") orelse {
            std.log.err("DB_URL not set", .{});
            return;
        }) catch |err| {
            std.log.err("Unable to read DB_URL: {}", .{err});
            return;
        };
        db_url = std.mem.trim(u8, db_url, "\n\t ");
        break :ac try site_exporter.AppContext.init(gpa, db_url, Io.Duration.fromSeconds(3 * std.time.s_per_min));
    };
    defer app_context.deinit();

    const App = zap.App.Create(site_exporter.AppContext);
    try App.init(init.io, gpa, &app_context, .{});
    defer App.deinit();

    var metrics_endpoint = site_exporter.MetricsEndpoint.init(gpa, init.io, "/metrics");
    defer metrics_endpoint.deinit();
    try App.register(&metrics_endpoint);

    try App.listen(.{
        .interface = listen_interface,
        .port = listen_port,
    });

    zap.start(.{
        .threads = 4,
        .workers = 1,
    });
}

fn get_environ(allocator: Allocator, io: Io, value: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, value, "file:")) {
        const file = try Io.Dir.cwd().openFile(io, value[5..], .{ .mode = .read_only });
        defer file.close(io);

        var buffer: [256]u8 = undefined;
        var reader = file.reader(io, &buffer);
        const file_size = @as(usize, @intCast(try reader.getSize()));
        const content = try reader.interface.readAlloc(allocator, file_size);
        return content;
    }
    return value;
}
