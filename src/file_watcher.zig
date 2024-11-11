const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const fd_t = posix.fd_t;

const Self = @This();

pub const FileId = packed struct(u64) {
    watch_fd: std.posix.fd_t,
    user_id: u32,
};

thread: std.Thread = undefined,
inotify_fd: fd_t = undefined,
file_ids: [64]FileId = undefined,
file_ids_len: usize = 0,
notifications: [64]FileId = undefined,
notifications_len: usize = 0,
mutex: std.Thread.Mutex = .{},
is_running: bool = false,
shutdown_ev_fd: fd_t = undefined,
epoll_fd: fd_t = undefined,

const MASKS = linux.IN.CLOSE_WRITE | linux.IN.DELETE;

pub fn start(self: *Self) !void {
    self.shutdown_ev_fd = try posix.eventfd(0, linux.EFD.NONBLOCK);
    self.inotify_fd = try posix.inotify_init1(linux.IN.NONBLOCK);
    self.epoll_fd = try posix.epoll_create1(0);

    var epoll_ev = std.mem.zeroes([2]linux.epoll_event);
    epoll_ev[0].events = linux.EPOLL.IN;
    epoll_ev[0].data.fd = self.inotify_fd;
    try posix.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, self.inotify_fd, &epoll_ev[0]);

    epoll_ev[1].events = linux.EPOLL.IN;
    epoll_ev[1].data.fd = self.shutdown_ev_fd;
    try posix.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, self.shutdown_ev_fd, &epoll_ev[1]);

    self.thread = try std.Thread.spawn(.{}, eventLoop, .{self});
    self.thread.setName("FileWatcher") catch {};
}

pub fn shutdown(self: *Self, wait: bool) void {
    const signal = std.mem.toBytes(@as(u64, 1));
    _ = posix.write(self.shutdown_ev_fd, &signal) catch unreachable;
    if (wait) self.thread.join();
}

pub fn watch(self: *Self, pathname: []const u8, user_id: u32) !void {
    const watch_fd = try posix.inotify_add_watch(self.inotify_fd, pathname, MASKS);
    self.mutex.lock();
    self.file_ids[self.file_ids_len] = FileId{ .watch_fd = watch_fd, .user_id = user_id };
    self.file_ids_len += 1;
    self.mutex.unlock();
}

/// Notifications are read in last in first out fashion
pub fn readNotifications(self: *Self, buffer: []u32) ?[]u32 {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.notifications_len == 0) return null;

    const pop_count = @min(buffer.len, self.notifications_len);
    for (0..pop_count) |i| {
        buffer[i] = self.notifications[self.notifications_len - 1].user_id;
        self.notifications_len -= 1;
    }

    return buffer[0..pop_count];
}

fn eventLoop(self: *Self) void {
    self.is_running = true;
    var inotify_ev_buff: [@sizeOf(linux.inotify_event) + linux.NAME_MAX]u8 = undefined;
    var epoll_evs: [2]linux.epoll_event = undefined;

    while (true) {
        const ready_fds_len = posix.epoll_wait(self.epoll_fd, &epoll_evs, -1);

        var has_file_updates = false;
        for (epoll_evs[0..ready_fds_len]) |ev| {
            if (ev.data.fd == self.shutdown_ev_fd) {
                self.is_running = false;
                posix.close(self.epoll_fd);
                for (self.file_ids[0..self.file_ids_len]) |id| {
                    posix.close(id.watch_fd);
                }
                posix.close(self.inotify_fd);
                posix.close(self.shutdown_ev_fd);
                return;
            } else if (ev.data.fd == self.inotify_fd) {
                has_file_updates = true;
            }
        }

        if (!has_file_updates) {
            continue;
        }

        // Wait until we have enough space to store notifications
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.notifications_len >= self.notifications.len) {
                std.time.sleep(std.time.ns_per_s);
                continue;
            }
        }

        const read_bytes = posix.read(self.inotify_fd, &inotify_ev_buff) catch |err| {
            if (err == error.WouldBlock) {
                continue;
            }

            std.log.err("FileWatcher failed: {!}", .{err});
            posix.exit(1);
        };

        self.mutex.lock();
        var read_cursor: usize = 0;
        while (read_cursor < read_bytes) {
            const ev = std.mem.bytesAsValue(linux.inotify_event, inotify_ev_buff[read_cursor..read_bytes]);
            if (MASKS & ev.mask == ev.mask and !self.isNotified(ev.wd)) {
                if (self.findFileId(ev.wd)) |file_id| {
                    std.debug.assert(self.notifications_len < self.notifications.len);
                    self.notifications[self.notifications_len] = file_id;
                    self.notifications_len += 1;
                }
            }

            read_cursor += @sizeOf(linux.inotify_event) + ev.len;
        }
        self.mutex.unlock();
    }
}

fn isNotified(self: *const Self, watch_fd: fd_t) bool {
    for (self.notifications[0..self.notifications_len]) |file_id| {
        if (file_id.watch_fd == watch_fd) return true;
    }

    return false;
}

fn findFileId(self: *const Self, watch_fd: fd_t) ?FileId {
    for (self.file_ids) |file_id| {
        if (file_id.watch_fd == watch_fd) {
            return file_id;
        }
    }

    return null;
}
