const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");

const site_exporter = @import("site_exporter");
const zap = @import("zap");

var debug_allocator: std.heap.DebugAllocator(.{
    // just to be explicit
    .thread_safe = true,
}) = .{};

pub fn main(init: std.process.Init) !void {
    const gpa, const is_debug = switch (builtin.mode) {
        .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
        .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    const db_url = init.environ_map.get("DB_URL") orelse std.debug.panic("DB_URL not set", .{});
    var app_context = try site_exporter.AppContext.init(try init.arena.allocator().dupeSentinel(u8, db_url, 0));
    defer app_context.deinit();

    const App = zap.App.Create(site_exporter.AppContext);
    try App.init(init.io, gpa, &app_context, .{});
    defer App.deinit();

    var metrics_endpoint = site_exporter.MetricsEndpoint.init(init.io, "/metrics");
    try App.register(&metrics_endpoint);

    try App.listen(.{
        .interface = "0.0.0.0",
        .port = 8080,
    });

    zap.start(.{
        .threads = 4,
        .workers = 1,
    });
}
