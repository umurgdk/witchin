const std = @import("std");
const rl = @import("raylib");
const FileWatcher = @import("file_watcher.zig");

const Vec2 = rl.Vector2;
const vec2 = rl.Vector2.init;
const vec2_zero = rl.Vector2{ .x = 0, .y = 0 };

const Vec3 = rl.Vector3;
const vec3 = rl.Vector3.init;
const vec3_zero = rl.Vector3{ .x = 0, .y = 0, .z = 0 };

const color = Color.init;

const Color = rl.Color;

const AssetName = enum(u32) {
    player_school,
};

const AseColorDepth = enum(u16) {
    rgba = 32,
    grayscale = 16,
    indexed = 8,
};
const AseHeader = struct {
    pub const MAGIC = 0xA5E0;

    file_size: u32,
    magic_num: u16,
    num_frames: u16,
    width: u16,
    height: u16,
    color_depth: AseColorDepth,
    flags: u32,
    /// ms between frame
    /// DEPRECATED: use the frame duration from each frame header
    speed: u16,
    _reserved1: u32,
    _reserved2: u32,
    transparent_index: u8,
    _reserved3: [3]u8,
    /// 0 means 256 for old sprites
    num_colors: u16,
    pixel_width: u8,
    pixel_height: u8,
    grid_x: i16,
    grid_y: i16,
    /// zero means there is no grid
    grid_width: u16,
    /// zero means there is no grid
    grid_height: u16,
    _reserved4: [84]u8,
};

const AseFrameHeader = struct {
    pub const MAGIC = 0xF1FA;
    size: u32,
    magic: u16,
    deprecated_num_chunks: u16,
    duration_ms: u16,
    _reserved1: u16,
    /// if this is zero use the deprecated one
    num_chunks: u32,
};

const AseChunkType = enum(u16) {
    old_palette = 0x0004,
    old_palette1 = 0x0011,
    layer = 0x2004,
    cel = 0x2005,
    cel_extra = 0x2006,
    color_profile = 0x2007,
    external_files = 0x2008,
    /// Deprecated
    mask = 0x2016,
    /// Never used
    path = 0x2017,
    tags = 0x2018,
    palette = 0x2019,
    user_data = 0x2020,
    slice = 0x2022,
    tileset = 0x2023,
};

pub fn main() !void {
    rl.setConfigFlags(.{ .window_resizable = true, .vsync_hint = true });

    rl.initWindow(800, 600, "Witchin");

    var file_watcher = FileWatcher{};
    try file_watcher.start();
    defer file_watcher.shutdown(true);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const ase_path = "asset_src/player_school.ase";
    const ase_file = try std.fs.cwd().openFile(ase_path, .{});
    const ase_reader = ase_file.reader();

    const endianness = std.builtin.Endian.little;
    var ase_header: AseHeader = undefined;
    ase_header.file_size = try ase_reader.readInt(u32, endianness);
    ase_header.magic_num = try ase_reader.readInt(u16, endianness);
    ase_header.num_frames = try ase_reader.readInt(u16, endianness);
    ase_header.width = try ase_reader.readInt(u16, endianness);
    ase_header.height = try ase_reader.readInt(u16, endianness);
    ase_header.color_depth = try ase_reader.readEnum(AseColorDepth, endianness);
    ase_header.flags = try ase_reader.readInt(u32, endianness);
    ase_header.speed = try ase_reader.readInt(u16, endianness);
    ase_header._reserved1 = try ase_reader.readInt(u32, endianness);
    ase_header._reserved2 = try ase_reader.readInt(u32, endianness);
    ase_header.transparent_index = try ase_reader.readInt(u8, endianness);
    ase_header._reserved3[0] = try ase_reader.readByte();
    ase_header._reserved3[1] = try ase_reader.readByte();
    ase_header._reserved3[2] = try ase_reader.readByte();
    ase_header.num_colors = try ase_reader.readInt(u16, endianness);
    ase_header.pixel_width = try ase_reader.readInt(u8, endianness);
    ase_header.pixel_height = try ase_reader.readInt(u8, endianness);
    ase_header.grid_x = try ase_reader.readInt(i16, endianness);
    ase_header.grid_y = try ase_reader.readInt(i16, endianness);
    ase_header.grid_width = try ase_reader.readInt(u16, endianness);
    ase_header.grid_height = try ase_reader.readInt(u16, endianness);

    try ase_reader.skipBytes(84, .{});
    std.debug.print("{any}\n", .{ase_header});
    std.debug.assert(ase_header.magic_num == AseHeader.MAGIC);

    for (0..ase_header.num_frames) |frame| {
        var frame_header: AseFrameHeader = undefined;
        frame_header.size = try ase_reader.readInt(u32, endianness);
        frame_header.magic = try ase_reader.readInt(u16, endianness);
        frame_header.deprecated_num_chunks = try ase_reader.readInt(u16, endianness);
        frame_header.duration_ms = try ase_reader.readInt(u16, endianness);
        frame_header._reserved1 = try ase_reader.readInt(u16, endianness);
        frame_header.num_chunks = try ase_reader.readInt(u32, endianness);

        std.debug.assert(frame_header.magic == AseFrameHeader.MAGIC);

        std.log.info("Frame {d} duration={d}ms num_chunks={d}", .{ frame, frame_header.duration_ms, frame_header.num_chunks });

        var color_palette: []Color = &.{};

        for (0..frame_header.num_chunks) |chunk| {
            const chunk_size = try ase_reader.readInt(u32, endianness);
            const chunk_type = try ase_reader.readEnum(AseChunkType, endianness);
            const chunk_data_size = chunk_size - @sizeOf(u32) - @sizeOf(AseChunkType);

            const chunk_data = try allocator.alloc(u8, chunk_data_size);
            const read_chunk_len = try ase_reader.read(chunk_data);
            std.debug.assert(read_chunk_len == chunk_data.len);

            var chunk_stream = std.io.fixedBufferStream(chunk_data);
            const chunk_reader = chunk_stream.reader();

            const indent = "    ";
            std.log.info("{s}Chunk {d} type={s} data={*}", .{ indent, chunk, @tagName(chunk_type), chunk_data.ptr });

            switch (chunk_type) {
                .old_palette => {
                    var packets = try chunk_reader.readInt(u16, endianness);
                    while (packets > 0) : (packets += 1) {
                        const num_entries_skip = try chunk_reader.readInt(u8, endianness);
                        _ = num_entries_skip;

                        const num_entries = try chunk_reader.readInt(u8, endianness);

                        const color_index_start = color_palette.len;
                        color_palette = try allocator.realloc(color_palette, color_palette.len + num_entries);

                        for (0..num_entries) |entry| {
                            const red = try chunk_reader.readInt(u8, endianness);
                            const green = try chunk_reader.readInt(u8, endianness);
                            const blue = try chunk_reader.readInt(u8, endianness);
                            color_palette[color_index_start + entry] = color(red, green, blue, 255);
                        }
                    }
                },
                .layer => {},
                else => {},
            }
        }
    }

    try file_watcher.watch(ase_path, @intFromEnum(AssetName.player_school));

    var updated_assets_buff: [32]u32 = undefined;
    while (!rl.windowShouldClose()) {
        while (file_watcher.readNotifications(&updated_assets_buff)) |asset_ids| {
            for (asset_ids) |asset_id| {
                const asset_name: AssetName = @enumFromInt(asset_id);
                switch (asset_name) {
                    .player_school => std.log.err("{s} is updated!", .{ase_path}),
                }
            }
        }

        rl.beginDrawing();
        rl.clearBackground(Color.red);
        rl.endDrawing();
    }
}

test "simple test" {}
