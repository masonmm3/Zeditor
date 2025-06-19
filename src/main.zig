const std = @import("std");
const dvui = @import("dvui");
const RaylibBackend = dvui.backend;
comptime {
    std.debug.assert(@hasDecl(RaylibBackend, "RaylibBackend"));
}

const window_icon_png = @embedFile("resources/zig-favicon.png");

var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
const gpa = gpa_instance.allocator();

const vsync = true;
var scale_val: f32 = 1.0;

var show_dialog_outside_frame: bool = false;

pub const c = RaylibBackend.c;

// var text_entry_buf = std.mem.zeroes([50]u8);
var text_entry_buf = std.ArrayList(u8).init(gpa);

var startSize: usize = 10;

const inputState = struct {
    load: bool = false,
    save: bool = false,

    newLine: bool = false,
};

pub fn main() !void {
    defer _ = gpa_instance.deinit();
    defer _ = text_entry_buf.deinit();

    try text_entry_buf.resize(startSize);

    setZero(text_entry_buf.items);

    var backend = try RaylibBackend.initWindow(.{
        .gpa = gpa,
        .size = .{ .w = 800.0, .h = 600.0 },
        .vsync = vsync,
        .title = "Zeditor",
        .icon = window_icon_png, // can also call setIconFromFileContent()
    });
    defer backend.deinit();
    backend.log_events = true;

    var win = try dvui.Window.init(@src(), gpa, backend.backend(), .{});
    defer win.deinit();

    var input = inputState{
        .load = false,
        .save = false,
        .newLine = false,
    };

    main_loop: while (true) {
        c.BeginDrawing();
        const nstime = win.beginWait(true);

        try win.begin(nstime);
        const quit = try backend.addAllEvents(&win);
        if (quit) break :main_loop;
        backend.clear();
        //{

        //content of ui
        try dvui_frame(&input);

        const end_micros = try win.end(.{});

        // cursor management
        backend.setCursor(win.cursorRequested());

        const wait_event_micros = win.waitTime(end_micros, null);

        //}
        backend.EndDrawingWaitEventTimeout(wait_event_micros);
    }
}

fn setZero(list: []u8) void {
    for (list) |*e| {
        e.* = 0;
    }
}

fn dvui_frame(state: *inputState) !void {
    var scroll = try dvui.scrollArea(@src(), .{}, .{ .expand = .both, .color_fill = .fill_window });
    defer scroll.deinit();

    const evts = dvui.events();

    for (evts) |*e| {
        if (e.evt == .key) {
            if (e.evt.key.action == .down and (e.evt.key.mod.control() or e.evt.key.mod.command())) {
                if (e.evt.key.code == .o) {
                    state.load = true;
                } else if (e.evt.key.code == .s) {
                    state.save = true;
                }
            } else if (e.evt.key.action == .down and (e.evt.key.code == .enter or e.evt.key.code == .kp_enter)) {
                state.newLine = true;
            }

            if (e.evt.key.action == .down) {
                //TODO: varriable length buffer size
                startSize += 1;
                try text_entry_buf.resize(startSize);
            }
        }
    }

    {
        var m = try dvui.menu(@src(), .horizontal, .{ .background = true, .expand = .horizontal });
        defer m.deinit();

        if (try dvui.menuItemLabel(@src(), "File", .{ .submenu = true }, .{ .expand = .none })) |r| {
            var fw = try dvui.floatingMenu(@src(), .{ .from = r }, .{});
            defer fw.deinit();

            if (try dvui.menuItemLabel(@src(), "Save", .{}, .{}) != null) {
                m.close();
                state.save = true;
            }

            if (try dvui.menuItemLabel(@src(), "Open", .{}, .{}) != null) {
                m.close();
                state.load = true;
            }
        }
    }

    var text = try dvui.textEntry(@src(), .{ .text = .{ .buffer = text_entry_buf.items } }, .{ .expand = .both });
    defer text.deinit();

    if (state.load == true) {
        state.load = false;
        try open();
    } else if (state.save) {
        state.save = false;
        try save(text.text);
    } else if (state.newLine) {
        state.newLine = false;
        text.textTyped("\n", false);
    }
}

fn save(words: []u8) !void {
    _ = words;
    const fileName = try dvui.dialogNativeFileSave(gpa, .{});

    if (fileName) |fname| {
        var file = try std.fs.createFileAbsolute(fname, .{});
        defer file.close();
        try file.writeAll(text_entry_buf.items);
    }
}

fn open() !void {
    const fileName = try dvui.dialogNativeFileOpen(gpa, .{ .path = "*.txt" });
    if (fileName) |fname| {
        const file = try std.fs.openFileAbsolute(fname, .{ .mode = .read_only });
        defer file.close();
        const size = try file.getEndPos();
        _ = try text_entry_buf.resize(size);
        const bytes = try file.readAll(text_entry_buf.items);
        _ = try text_entry_buf.resize(bytes);
        startSize = text_entry_buf.items.len;
    }
}
