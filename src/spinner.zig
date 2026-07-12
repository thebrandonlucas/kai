//! Terminal loading spinner helpers shared by CLI/host subprocess runners.
const std = @import("std");
const builtin = @import("builtin");

pub const CLOCK_FRAMES = [_][]const u8{
    "🕛",
    "🕧",
    "🕐",
    "🕜",
    "🕑",
    "🕝",
    "🕒",
    "🕞",
    "🕓",
    "🕟",
    "🕔",
    "🕠",
    "🕕",
    "🕡",
    "🕖",
    "🕢",
    "🕗",
    "🕣",
    "🕘",
    "🕤",
    "🕙",
    "🕥",
    "🕚",
    "🕦",
};
pub const MUSIC_FRAMES = [_][]const u8{ "🎵", "🎶", "🎼", "🎹", "🥁", "🎸", "🎺", "🎷", "🪕" };
pub const ANIMAL_FRAMES = [_][]const u8{
    "🐶",
    "🐱",
    "🐭",
    "🐹",
    "🐰",
    "🦊",
    "🐻",
    "🐼",
    "🐨",
    "🐯",
    "🦁",
    "🐮",
};
pub const PLANT_FRAMES = [_][]const u8{
    "🌱",
    "🌿",
    "☘️",
    "🍀",
    "🎋",
    "🌵",
    "🌴",
    "🌳",
    "🌲",
    "🌷",
    "🌸",
};
pub const WEATHER_FRAMES = [_][]const u8{ "☀️", "🌤️", "⛅", "🌥️", "☁️", "🌦️", "🌧️", "⛈️", "🌨️", "🌈" };

pub const SPINNER_FRAME_SETS = [_][]const []const u8{
    CLOCK_FRAMES[0..],
    MUSIC_FRAMES[0..],
    ANIMAL_FRAMES[0..],
    PLANT_FRAMES[0..],
    WEATHER_FRAMES[0..],
};

pub const FramePreference = enum {
    random,
    animal,
};

pub const clear_line = "\r\x1b[2K";
const frame_interval_ms = 120;

const State = struct {
    allocator: std.mem.Allocator,
    message: []const u8,
    frames: []const []const u8,
    index: usize = 0,
};

pub const Spinner = struct {
    state: ?*State = null,

    pub fn start(allocator: std.mem.Allocator, io: std.Io, message: []const u8, preference: FramePreference) !Spinner {
        if (!try stderrIsTerminal(io)) return .{};

        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        const owned_message = try allocator.dupe(u8, message);
        errdefer allocator.free(owned_message);

        state.* = .{
            .allocator = allocator,
            .message = owned_message,
            .frames = chooseFrames(io, preference),
        };

        var spinner = Spinner{ .state = state };
        spinner.tick();
        return spinner;
    }

    pub fn isActive(self: Spinner) bool {
        return self.state != null;
    }

    pub fn tick(self: *Spinner) void {
        const state = self.state orelse return;
        writeStderrRaw(clear_line);
        writeStderrRaw(state.frames[state.index % state.frames.len]);
        writeStderrRaw(" ");
        writeStderrRaw(state.message);
        state.index += 1;
    }

    pub fn stop(self: *Spinner) void {
        const state = self.state orelse return;
        writeStderrRaw(clear_line);
        state.allocator.free(state.message);
        const allocator = state.allocator;
        allocator.destroy(state);
        self.state = null;
    }

    pub fn deinit(self: *Spinner) void {
        self.stop();
    }
};

fn writeStderrRaw(bytes: []const u8) void {
    switch (builtin.os.tag) {
        .linux => _ = std.os.linux.write(2, bytes.ptr, bytes.len),
        else => {},
    }
}

fn sleepMilliseconds(milliseconds: i64) void {
    switch (builtin.os.tag) {
        .linux => {
            const request = std.os.linux.timespec{
                .sec = @divTrunc(milliseconds, 1000),
                .nsec = @mod(milliseconds, 1000) * std.time.ns_per_ms,
            };
            _ = std.os.linux.nanosleep(&request, null);
        },
        else => {},
    }
}

pub fn stderrIsTerminal(io: std.Io) !bool {
    _ = io;
    return switch (builtin.os.tag) {
        .linux => blk: {
            var termios: std.os.linux.termios = undefined;
            const rc = std.os.linux.tcgetattr(2, &termios);
            break :blk std.os.linux.errno(rc) == .SUCCESS;
        },
        else => false,
    };
}

pub fn chooseFrames(io: std.Io, preference: FramePreference) []const []const u8 {
    return switch (preference) {
        .animal => ANIMAL_FRAMES[0..],
        .random => randomFrames(io),
    };
}

pub fn framePreferenceFromText(value: ?[]const u8) FramePreference {
    const text = value orelse return .random;
    if (containsIgnoreCase(text, "animal") or containsIgnoreCase(text, "animals") or containsIgnoreCase(text, "pet")) {
        return .animal;
    }
    return .random;
}

pub fn randomFrames(io: std.Io) []const []const u8 {
    const timestamp = std.Io.Clock.now(.real, io).nanoseconds;
    const positive_timestamp: u128 = @intCast(if (timestamp < 0) -timestamp else timestamp);
    const seed: usize = @truncate(positive_timestamp);
    return SPINNER_FRAME_SETS[seed % SPINNER_FRAME_SETS.len];
}

pub fn truncateDisplay(allocator: std.mem.Allocator, value: []const u8, max_chars: usize) ![]u8 {
    const char_count = std.unicode.utf8CountCodepoints(value) catch value.len;
    if (char_count <= max_chars) {
        return allocator.dupe(u8, value);
    }
    if (max_chars == 0) return allocator.dupe(u8, "");

    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    var it = std.unicode.Utf8Iterator{ .bytes = value, .i = 0 };
    var kept: usize = 0;
    while (kept + 1 < max_chars) : (kept += 1) {
        const cp = it.nextCodepointSlice() orelse break;
        try out.appendSlice(cp);
    }
    try out.appendSlice("…");
    return out.toOwnedSlice();
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

test "clock spinner frames move clockwise" {
    try std.testing.expectEqualStrings("🕛", CLOCK_FRAMES[0]);
    try std.testing.expectEqualStrings("🕧", CLOCK_FRAMES[1]);
    try std.testing.expectEqualStrings("🕐", CLOCK_FRAMES[2]);
    try std.testing.expectEqualStrings("🕦", CLOCK_FRAMES[CLOCK_FRAMES.len - 1]);
    try std.testing.expectEqual(@as(usize, 24), CLOCK_FRAMES.len);
}

test "spinner has themed frame sets including animals" {
    try std.testing.expectEqual(CLOCK_FRAMES[0..], SPINNER_FRAME_SETS[0]);
    try std.testing.expectEqual(MUSIC_FRAMES[0..], SPINNER_FRAME_SETS[1]);
    try std.testing.expectEqual(ANIMAL_FRAMES[0..], SPINNER_FRAME_SETS[2]);
    try std.testing.expectEqual(PLANT_FRAMES[0..], SPINNER_FRAME_SETS[3]);
    try std.testing.expectEqual(WEATHER_FRAMES[0..], SPINNER_FRAME_SETS[4]);
}

test "animal preference selects animal frames" {
    try std.testing.expectEqual(FramePreference.animal, framePreferenceFromText("animal loading screen"));
    try std.testing.expectEqual(ANIMAL_FRAMES[0..], chooseFrames(std.testing.io, .animal));
}

test "non terminal spinner is inactive" {
    var spinner = try Spinner.start(std.testing.allocator, std.testing.io, "working", .animal);
    defer spinner.deinit();
    try std.testing.expect(!spinner.isActive());
}

test "truncate display keeps short values and ellipsizes long values" {
    const short = try truncateDisplay(std.testing.allocator, "nix build", 20);
    defer std.testing.allocator.free(short);
    try std.testing.expectEqualStrings("nix build", short);

    const long = try truncateDisplay(std.testing.allocator, "abcdef", 4);
    defer std.testing.allocator.free(long);
    try std.testing.expectEqualStrings("abc…", long);
}
