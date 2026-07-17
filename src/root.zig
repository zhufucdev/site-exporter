//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Mutex = std.Io.Mutex;
const Io = std.Io;
const Thread = std.Thread;

const m = @import("metrics");
const zap = @import("zap");

const pq = @cImport({
    @cInclude("libpq-fe.h");
});
const Metrics = struct {
    page_views: PageViews,
    up: m.Gauge(u8),

    const PageViews = m.GaugeVec(u32, struct { page_id: []const u8 });

    pub fn init(allocator: Allocator, io: Io) !Metrics {
        return .{
            .page_views = try PageViews.init(allocator, io, "page_views", .{ .help = "view per article" }, .{}),
            .up = m.Gauge(u8).init("up", .{ .help = "whether the database is up" }, .{}),
        };
    }
};

const PGconnMutexGuard = struct {
    db: *pq.PGconn,
    mutex: *Mutex,

    fn init(db: *pq.PGconn, mutex: *Mutex) PGconnMutexGuard {
        return .{
            .db = db,
            .mutex = mutex,
        };
    }

    fn deinit(self: *PGconnMutexGuard, io: Io) !void {
        defer self.mutex.unlock(io);
    }
};

const ExpirationTask = struct {
    allocator: Allocator,
    io: Io,
    db: *pq.PGconn,
    mutex: *Mutex,
    timeout: Io.Duration,
    canceled: bool = false,
    thread: ?Thread,

    fn init(allocator: Allocator, io: Io, db: *pq.PGconn, mutex: *Mutex, timeout: Io.Duration) Allocator.Error!*ExpirationTask {
        var s = try allocator.create(ExpirationTask);
        s.allocator = allocator;
        s.io = io;
        s.db = db;
        s.mutex = mutex;
        s.timeout = timeout;
        s.thread = null;
        return s;
    }

    fn deinit(self: *ExpirationTask) void {
        if (!self.canceled) {
            pq.PQfinish(self.db);
        }
        self.canceled = true;
        if (self.thread) |t| {
            t.join();
        }
    }

    fn start(self: *ExpirationTask) Thread.SpawnError!void {
        if (self.thread != null) {
            return Thread.SpawnError.Unexpected;
        }
        self.canceled = false;
        const t = try Thread.spawn(.{}, tickExpiration, .{self});
        self.thread = t;
    }

    fn cancel(self: *ExpirationTask) void {
        self.canceled = true;
        if (self.thread) |thread| {
            thread.detach();
        }
        self.thread = null;
    }
};

/// Note: polling based, 1 second interval
fn tickExpiration(self: *ExpirationTask) !void {
    defer self.allocator.destroy(self);
    const interval_ns = 1_000_000_000;
    while (!self.canceled and self.timeout.nanoseconds > 0) {
        const real_interval = @min(interval_ns, self.timeout.nanoseconds);
        Io.sleep(self.io, Io.Duration.fromNanoseconds(real_interval), .awake) catch {
            std.log.warn("expiration task canceled", .{});
            return;
        };
        self.timeout.nanoseconds -= interval_ns;
    }
    if (self.canceled) {
        return;
    }
    try self.mutex.lock(self.io);
    defer self.mutex.unlock(self.io);

    pq.PQfinish(self.db);
}

pub const DbError = error{
    Connection,
    Query,
};

pub const AppContext = struct {
    allocator: Allocator,
    db_conninfo: [:0]const u8,
    conn_expiration_timeout: Io.Duration,
    db: ?*pq.PGconn = null,
    db_mutex: Mutex = .init,
    expiration_task: ?*ExpirationTask = null,

    pub fn init(allocator: Allocator, conninfo: []const u8, conn_expiration: Io.Duration) !AppContext {
        const c_conninfo = try allocator.dupeSentinel(u8, conninfo, 0);
        return .{
            .allocator = allocator,
            .db_conninfo = c_conninfo,
            .conn_expiration_timeout = conn_expiration,
        };
    }

    pub fn deinit(self: *AppContext) void {
        if (self.expiration_task) |task| {
            task.deinit();
        }
        self.allocator.free(self.db_conninfo);
    }

    fn get_dbconn(self: *AppContext, io: Io) !PGconnMutexGuard {
        try self.db_mutex.lock(io);

        if (self.expiration_task) |task| {
            task.cancel();
            self.expiration_task = null;
        }
        defer {
            if (self.db) |db| {
                if (ExpirationTask.init(self.allocator, io, db orelse unreachable, &self.db_mutex, self.conn_expiration_timeout)) |task| {
                    task.start() catch |err| std.log.err("failed to start expiration task: {}", .{err});
                    self.expiration_task = task;
                } else |err| {
                    std.log.err("failed to allocate expiration task: {}", .{err});
                }
            }
        }

        if (self.db) |db| {
            return PGconnMutexGuard.init(db, &self.db_mutex);
        } else {
            const db = pq.PQconnectdb(self.db_conninfo) orelse unreachable;
            if (pq.PQstatus(db) != pq.CONNECTION_OK) {
                std.log.err("app context failed to initailize db connection: {s}", .{std.mem.span(pq.PQerrorMessage(db))});
                pq.PQfinish(db);
                self.db_mutex.unlock(io);
                return DbError.Connection;
            }
            self.db = db;
            return PGconnMutexGuard.init(db, &self.db_mutex);
        }
    }
};

pub const MetricsEndpoint = struct {
    path: []const u8,
    error_strategy: zap.Endpoint.ErrorStrategy = .log_to_response,

    allocator: Allocator,
    io: std.Io,
    metrics: Metrics,
    metrics_initialized: bool = false,
    metrics_mutex: Mutex,

    pub fn init(allocator: Allocator, io: std.Io, path: []const u8) MetricsEndpoint {
        return .{
            .allocator = allocator,
            .io = io,
            .path = path,
            .metrics = m.initializeNoop(Metrics),
            .metrics_mutex = Mutex.init,
        };
    }

    pub fn deinit(self: *MetricsEndpoint) void {
        if (!self.metrics_mutex.tryLock()) {
            std.log.err("failed to lock metrics, potential mem leak!", .{});
        } else {
            defer self.metrics_mutex.unlock(self.io);
        }
        if (self.metrics_initialized) {
            self.metrics.page_views.deinit();
        }
    }

    pub fn get(self: *MetricsEndpoint, allocator: Allocator, context: *AppContext, request: zap.Request) !void {
        try self.metrics_mutex.lock(self.io);
        if (!self.metrics_initialized) {
            self.metrics = try Metrics.init(self.allocator, self.io);
            self.metrics_initialized = true;
        }
        self.metrics_mutex.unlock(self.io);

        var db_guard = try context.get_dbconn(self.io);
        const res = pq.PQexec(db_guard.db,
            \\SELECT "pageId", "views" FROM page_views ORDER BY "pageId";
        );
        defer pq.PQclear(res);

        var rows: usize = 0;
        if (pq.PQresultStatus(res) != pq.PGRES_TUPLES_OK) {
            std.log.err("failed to get page views: {s}", .{pq.PQresultErrorMessage(res)});
            self.metrics.up.set(0);
        } else {
            self.metrics.up.set(1);

            rows = @as(usize, @intCast(pq.PQntuples(res)));
            var i: i32 = 0;
            while (i < rows) : (i += 1) {
                const page_id = std.mem.span(pq.PQgetvalue(res, i, 0));
                const views = std.mem.span(pq.PQgetvalue(res, i, 1));
                try self.metrics.page_views.set(.{ .page_id = page_id }, std.fmt.parseInt(u32, views, 10) catch return DbError.Query);
            }
        }

        var buffer = try std.ArrayList(u8).initCapacity(allocator, rows * 10);
        var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &buffer);

        try m.write(&self.metrics, &writer.writer);
        try writer.writer.print("# EOF\n", .{});
        try request.setHeader("content-type", "application/openmetrics-text; version=1.0.0");
        try request.sendBody(try writer.toOwnedSlice());

        db_guard.deinit(self.io) catch |err| {
            std.log.err("failed to release db connection, potential leaks! {}", .{err});
        };
    }
};
