//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Allocator = std.mem.Allocator;

const m = @import("metrics");
const zap = @import("zap");

const pq = @cImport({
    @cInclude("libpq-fe.h");
});
const Metrics = struct {
    page_views: PageViews,

    const PageViews = m.GaugeVec(u32, struct { page_id: []const u8 });
};

pub const DbError = error{
    Connection,
    Query,
};

pub const AppContext = struct {
    db: *pq.PGconn,

    pub fn init(conninfo: [:0]const u8) DbError!AppContext {
        const db = pq.PQconnectdb(conninfo) orelse unreachable;
        if (pq.PQstatus(db) != pq.CONNECTION_OK) {
            std.log.err("app context failed to initailize db connection: {s}", .{std.mem.span(pq.PQerrorMessage(db))});
            return DbError.Connection;
        }
        return .{
            .db = db,
        };
    }

    pub fn deinit(self: *AppContext) void {
        pq.PQfinish(self.db);
    }
};

pub const MetricsEndpoint = struct {
    path: []const u8,
    error_strategy: zap.Endpoint.ErrorStrategy = .log_to_response,

    io: std.Io,
    metrics: Metrics,

    pub fn init(io: std.Io, path: []const u8) MetricsEndpoint {
        return .{
            .io = io,
            .path = path,
            .metrics = m.initializeNoop(Metrics),
        };
    }

    pub fn get(self: *MetricsEndpoint, allocator: Allocator, context: *AppContext, request: zap.Request) !void {
        self.metrics.page_views = try Metrics.PageViews.init(allocator, self.io, "page_views", .{}, .{});
        defer self.metrics.page_views.deinit();

        const res = pq.PQexec(context.db,
            \\SELECT "pageId", "views" FROM page_views ORDER BY "pageId";
        );
        defer pq.PQclear(res);
        if (pq.PQresultStatus(res) != pq.PGRES_TUPLES_OK) {
            std.log.err("failed to get page views: {s}", .{pq.PQresultErrorMessage(res)});
            return DbError.Query;
        }

        const rows = pq.PQntuples(res);
        var i: i32 = 0;
        while (i < rows) : (i += 1) {
            const page_id = std.mem.span(pq.PQgetvalue(res, i, 0));
            const views = std.mem.span(pq.PQgetvalue(res, i, 1));
            try self.metrics.page_views.set(.{ .page_id = page_id }, std.fmt.parseInt(u32, views, 10) catch unreachable);
        }

        var buffer = try std.ArrayList(u8).initCapacity(allocator, @as(usize, @intCast(rows)) * 10);
        var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &buffer);

        try m.write(&self.metrics, &writer.writer);
        try request.setHeader("content-type", "application/openmetrics-text; version=1.0.0");
        try request.sendBody(try writer.toOwnedSlice());
    }
};
