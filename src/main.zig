const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const SDLBackend = @import("sdl3gpu-backend");
const c = SDLBackend.c;

const window_icon_png = @embedFile("resources/zig-favicon.png");

var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
const gpa = gpa_instance.allocator();

const vsync = true;
var scale_val: f32 = 1.0;

var show_dialog_outside_frame: bool = false;

//Custom Globally scoped values
var text_entry_buf: std.ArrayList(u8) = .empty;

var startSize: usize = 1;

var openFileName: ?[]const u8 = null;

const inputState = struct {
    load: bool = false,
    save: bool = false,
    saveAs: bool = false,
    newLine: bool = false,
    undo: bool = false,
};
//

pub fn main() !void {
    try text_entry_buf.resize(gpa, startSize);
    defer text_entry_buf.deinit(gpa);

    if (@import("builtin").os.tag == .windows) {
        dvui.Backend.Common.windowsAttachConsole() catch {};
    }

    SDLBackend.enableSDLLogging();
    std.log.info("SDL version: {f}", .{SDLBackend.getSDLVersion()});

    defer if (gpa_instance.deinit() != .ok) @panic("Memory leak on exit!");

    // init SDL3GPU backend (creates and owns OS window)
    var backend = try SDLBackend.initWindow(.{
        .allocator = gpa,
        .size = .{ .w = 800.0, .h = 600.0 },
        .min_size = .{ .w = 250.0, .h = 350.0 },
        .vsync = vsync,
        .title = " Zeditor - A Simple Text Editor",
        .icon = window_icon_png,
    });

    defer backend.deinit();

    _ = c.SDL_EnableScreenSaver();

    // init dvui Window (maps onto a single OS window)
    var win = try dvui.Window.init(@src(), gpa, backend.backend(), .{
        .theme = switch (backend.preferredColorScheme() orelse .light) {
            .light => dvui.Theme.builtin.adwaita_light,
            .dark => dvui.Theme.builtin.adwaita_dark,
        },
    });
    defer win.deinit();

    var interrupted = false;

    var state = inputState{ .load = false, .save = false, .newLine = false };

    main_loop: while (true) {
        // beginWait coordinates with waitTime below to run frames only when needed
        const nstime = win.beginWait(interrupted);

        // marks the beginning of a frame for dvui, can call dvui functions after this
        try win.begin(nstime);

        // send all SDL events to dvui for processing
        _ = try backend.addAllEvents(&win);

        // NOTE: SDL3GPU doesn't need manual clearing like SDL_Renderer
        // GPU backend handles clearing via render pass (LOAD_OP_CLEAR)

        const keep_running = try ZeditorFrame(&state);
        if (!keep_running) {
            std.log.info("Exiting main loop, keep_running = false", .{});
            break :main_loop;
        }

        // marks end of dvui frame, don't call dvui functions after this
        const end_micros = try win.end(.{});

        // cursor management
        try backend.setCursor(win.cursorRequested());
        try backend.textInputRect(win.textInputRequested());

        // render frame to OS
        try backend.renderPresent();

        // waitTime and beginWait combine to achieve variable framerates
        const wait_event_micros = win.waitTime(end_micros);
        interrupted = try backend.waitEventTimeout(wait_event_micros);

        // Example of dialog from another thread
        if (show_dialog_outside_frame) {
            show_dialog_outside_frame = false;
            dvui.dialog(@src(), .{}, .{
                .window = &win,
                .modal = false,
                .title = "Dialog from Outside",
                .message = "This is a non modal dialog that was created outside win.begin()/win.end(), usually from another thread.",
            });
        }
    }
}

fn setZero(list: []u8) void {
    for (list) |*e| {
        e.* = 0;
    }
}

//UI Functions
///Main Frame Function
fn ZeditorFrame(state: *inputState) !bool {
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .style = .window });
    defer scroll.deinit();

    const close: bool = try poolEvents(state);
    runToolBar(state);

    var text = dvui.textEntry(@src(), .{ .text = .{ .buffer = text_entry_buf.items } }, .{ .expand = .both, .style = .window });
    defer text.deinit();

    try runEvents(state, text);

    return !close;
}

///Runs the toolbar at the top of the window
fn runToolBar(state: *inputState) void {
    var m = dvui.menu(@src(), .horizontal, .{ .style = .window, .background = true, .expand = .horizontal });
    defer m.deinit();

    if (dvui.menuItemLabel(@src(), "File", .{ .submenu = true }, .{ .style = .window, .expand = .none })) |f| {
        var fw = dvui.floatingMenu(@src(), .{ .from = f }, .{ .style = .window });
        defer fw.deinit();

        if (dvui.menuItemLabel(@src(), "Save", .{}, .{ .style = .window }) != null) {
            m.close();
            state.save = true;
        }

        if (dvui.menuItemLabel(@src(), "Open", .{}, .{ .style = .window }) != null) {
            m.close();
            state.load = true;
        }

        if (dvui.menuItemLabel(@src(), "Save As", .{}, .{ .style = .window }) != null) {
            m.close();
            state.saveAs = true;
        }
    }

    if (dvui.menuItemLabel(@src(), "Edit", .{ .submenu = true }, .{ .style = .window, .expand = .none })) |e| {
        var ew = dvui.floatingMenu(@src(), .{ .from = e }, .{ .style = .window });
        defer ew.deinit();

        if (dvui.menuItemLabel(@src(), "Undo", .{}, .{ .style = .window }) != null) {
            m.close();
            state.undo = true;
        }
    }
}

//UI Sub Action Functions

///Runs the current event state actions
fn runEvents(state: *inputState, text: *dvui.TextEntryWidget) !void {
    try fileEvents(state);
    try typingEvents(state, text);

    clearInputState(state);
}

///handles typing related events such as enter and ctrl Z
fn typingEvents(state: *inputState, text: *dvui.TextEntryWidget) !void {
    if (state.newLine) {
        text.textTyped("\n", false);
    } else if (state.undo) {
        const cursorPos = text.textLayout.selection.cursor;
        const offset = 1;
        var startPoint = cursorPos;
        if (startPoint == 0) return;
        var endPoint = if (startPoint > offset) startPoint - offset else 0;

        //ensure a spcae is left if starting at the next word
        if (text_entry_buf.items[startPoint - 1] == ' ') {
            startPoint = if (startPoint > 1) startPoint - 1 else return;
            endPoint = if (endPoint > 1) endPoint - 1 else return;
        }

        while (endPoint > 0 and text_entry_buf.items[endPoint] != ' ') {
            endPoint -= 1;
        }

        const len = startPoint - endPoint;
        try text_entry_buf.replaceRange(gpa, endPoint, len, &[_]u8{});
        text.textSet(text_entry_buf.items, false);
        text.textLayout.selection.cursor = cursorPos - len;
    }
}

///handles events related to saving and opening files
fn fileEvents(state: *inputState) !void {
    if (state.load == true) {
        try open();
    } else if (state.save) {
        try quickSave();
    } else if (state.saveAs) {
        try saveAs();
    }
}

fn clearInputState(state: *inputState) void {
    state.load = false;
    state.save = false;
    state.saveAs = false;
    state.newLine = false;
    state.undo = false;
}

///determines what events have occurred this frame
fn poolEvents(state: *inputState) !bool {
    const events = dvui.events();

    var shouldClose = false;
    for (events) |*e| {
        if (e.evt == .key) {
            if (e.evt.key.action == .down and (e.evt.key.mod.control() or e.evt.key.mod.command())) {
                if (e.evt.key.code == .o) {
                    state.load = true;
                } else if (e.evt.key.code == .s) {
                    state.save = true;
                } else if (e.evt.key.code == .z) {
                    state.undo = true;
                }
            } else if (e.evt.key.action == .down and (e.evt.key.code == .enter or e.evt.key.code == .kp_enter)) {
                state.newLine = true;
            }

            if (e.evt.key.action == .down) {
                _ = try text_entry_buf.addOne(gpa);
            }
        }

        // assume we only have a single window
        if (e.evt == .window and e.evt.window.action == .close) shouldClose = true;
        if (e.evt == .app and e.evt.app.action == .quit) shouldClose = true;
    }

    return shouldClose;
}

// Event Functions

///Attempts to save the current file name before asking for a location
fn quickSave() !void {
    if (openFileName) |fname| {
        try save(fname);
    } else {
        try saveAs();
    }
}

///Saves the current file, always asks for location
fn saveAs() !void {
    const fileName = try dvui.dialogNativeFileSave(gpa, .{});

    try save(fileName);

    openFileName = fileName;
}

///Saves the current File
fn save(fileName: ?[]const u8) !void {
    if (fileName) |fname| {
        var file = try std.fs.createFileAbsolute(fname, .{});
        defer file.close();
        try file.writeAll(text_entry_buf.items);
    }
}

///Opens a file into the editor
fn open() !void {
    const fileName = try dvui.dialogNativeFileOpen(gpa, .{ .path = "*.txt" });
    if (fileName) |fname| {
        const file = try std.fs.openFileAbsolute(fname, .{ .mode = .read_only });
        defer file.close();
        const size = try file.getEndPos();
        _ = try text_entry_buf.resize(gpa, size);
        const bytes = try file.readAll(text_entry_buf.items);
        _ = try text_entry_buf.resize(gpa, bytes);
        startSize = text_entry_buf.items.len;
        openFileName = fname;
    }
}
