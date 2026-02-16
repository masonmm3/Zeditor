const std = @import("std");
const dvui = @import("dvui");
const eng = @import("engine");
var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
const gpa = gpa_instance.allocator();
var state = inputState{ .load = false, .save = false, .newLine = false };

//Custom Globally scoped values
var text_entry_buf: std.ArrayList(u8) = .empty;
var redo_buf: std.ArrayList(removedSection) = .empty;

var startSize: usize = 1;

var openFileName: ?[]const u8 = null;

const inputState = struct {
    load: bool = false,
    save: bool = false,
    saveAs: bool = false,
    newLine: bool = false,
    undo: bool = false,
    redo: bool = false,
};

const removedSection = struct {
    text: []u8,
    index: usize = 0,
};
//

pub fn main() !void {
    defer if (gpa_instance.deinit() != .ok) @panic("Memory leak on exit!");
    try text_entry_buf.resize(gpa, startSize);
    defer text_entry_buf.deinit(gpa);
    try redo_buf.resize(gpa, 0);
    defer redo_buf.deinit(gpa);
    try eng.runApp(ZeditorFrame, gpa);
}

fn setZero(list: []u8) void {
    for (list) |*e| {
        e.* = 0;
    }
}

//UI Functions
///Main Frame Function
fn ZeditorFrame() !bool {
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .style = .window });
    defer scroll.deinit();

    const close: bool = try poolEvents();
    runToolBar();

    var text = dvui.textEntry(@src(), .{ .text = .{ .buffer = text_entry_buf.items } }, .{ .expand = .both, .style = .window });
    defer text.deinit();

    try runEvents(text);

    return !close;
}

///Runs the toolbar at the top of the window
fn runToolBar() void {
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

        if (dvui.menuItemLabel(@src(), "Redo", .{}, .{ .style = .window }) != null) {
            m.close();
            state.redo = true;
        }
    }
}

//UI Sub Action Functions

///Runs the current event state actions
fn runEvents(text: *dvui.TextEntryWidget) !void {
    try fileEvents();
    try typingEvents(text);

    clearInputState();
}

///handles typing related events such as enter and ctrl Z
fn typingEvents(text: *dvui.TextEntryWidget) !void {
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
        const removed = text_entry_buf.items[endPoint..startPoint];
        const removedCopy = try gpa.dupe(u8, removed);
        try redo_buf.append(gpa, removedSection{ .text = removedCopy, .index = endPoint });
        try text_entry_buf.replaceRange(gpa, endPoint, len, &[_]u8{});
        text.textSet(text_entry_buf.items, false);
        text.textLayout.selection.cursor = cursorPos - len;
    } else if (state.redo) {
        if (redo_buf.pop()) |last_action| {
            try text_entry_buf.insertSlice(gpa, last_action.index, last_action.text);

            text.textSet(text_entry_buf.items, false);

            text.textLayout.selection.cursor = last_action.index + last_action.text.len;

            gpa.free(last_action.text);
        }
    }
}

///handles events related to saving and opening files
fn fileEvents() !void {
    if (state.load == true) {
        try open();
    } else if (state.save) {
        try quickSave();
    } else if (state.saveAs) {
        try saveAs();
    }
}

fn clearInputState() void {
    state.load = false;
    state.save = false;
    state.saveAs = false;
    state.newLine = false;
    state.undo = false;
    state.redo = false;
}

///determines what events have occurred this frame
fn poolEvents() !bool {
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
                } else if (e.evt.key.code == .y) {
                    state.redo = true;
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
