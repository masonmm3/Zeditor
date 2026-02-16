const std = @import("std");
const dvui = @import("dvui");

pub const zeditor = struct {
    gpa: std.mem.Allocator,
    state: inputState,
    text_entry_buf: std.ArrayList(u8),
    redo_buf: std.ArrayList(removedSection),
    open_file_name: ?[]const u8,

    /// Returns a new initialized zeditor struct
    pub fn init(gpa: std.mem.Allocator) !zeditor {
        var self: zeditor = .{
            .gpa = gpa,
            .state = .{},
            .text_entry_buf = .empty,
            .redo_buf = .empty,
            .open_file_name = null,
        };

        try self.text_entry_buf.resize(gpa, 1);
        try self.redo_buf.resize(gpa, 1);

        return self;
    }

    /// deinits the internal objects
    pub fn deinit(self: *zeditor) void {
        self.text_entry_buf.deinit(self.gpa);
        self.redo_buf.deinit(self.gpa);
    }

    ///creates a new frame of Zeditor
    pub fn runFrame(self: *zeditor) !bool {
        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .style = .window });
        defer scroll.deinit();

        const close: bool = try self.poolEvents();
        self.runToolBar();

        var text = dvui.textEntry(@src(), .{ .text = .{ .buffer = self.text_entry_buf.items } }, .{ .expand = .both, .style = .window });
        defer text.deinit();

        try self.runEvents(text);

        return !close;
    }

    ///Runs the toolbar at the top of the window
    fn runToolBar(self: *zeditor) void {
        var m = dvui.menu(@src(), .horizontal, .{ .style = .window, .background = true, .expand = .horizontal });
        defer m.deinit();

        if (dvui.menuItemLabel(@src(), "File", .{ .submenu = true }, .{ .style = .window, .expand = .none })) |f| {
            var fw = dvui.floatingMenu(@src(), .{ .from = f }, .{ .style = .window });
            defer fw.deinit();

            if (dvui.menuItemLabel(@src(), "Save", .{}, .{ .style = .window }) != null) {
                m.close();
                self.state.save = true;
            }

            if (dvui.menuItemLabel(@src(), "Open", .{}, .{ .style = .window }) != null) {
                m.close();
                self.state.load = true;
            }

            if (dvui.menuItemLabel(@src(), "Save As", .{}, .{ .style = .window }) != null) {
                m.close();
                self.state.saveAs = true;
            }
        }

        if (dvui.menuItemLabel(@src(), "Edit", .{ .submenu = true }, .{ .style = .window, .expand = .none })) |e| {
            var ew = dvui.floatingMenu(@src(), .{ .from = e }, .{ .style = .window });
            defer ew.deinit();

            if (dvui.menuItemLabel(@src(), "Undo", .{}, .{ .style = .window }) != null) {
                m.close();
                self.state.undo = true;
            }

            if (dvui.menuItemLabel(@src(), "Redo", .{}, .{ .style = .window }) != null) {
                m.close();
                self.state.redo = true;
            }
        }
    }

    //UI Sub Action Functions

    ///Runs the current event state actions
    fn runEvents(self: *zeditor, text: *dvui.TextEntryWidget) !void {
        try self.fileEvents();
        try self.typingEvents(text);

        self.clearInputState();
    }

    ///handles typing related events such as enter and ctrl Z
    fn typingEvents(self: *zeditor, text: *dvui.TextEntryWidget) !void {
        if (self.state.newLine) {
            text.textTyped("\n", false);
        } else if (self.state.undo) {
            const cursorPos = text.textLayout.selection.cursor;
            const offset = 1;
            var startPoint = cursorPos;
            if (startPoint == 0) return;
            var endPoint = if (startPoint > offset) startPoint - offset else 0;

            //ensure a spcae is left if starting at the next word
            if (self.text_entry_buf.items[startPoint - 1] == ' ') {
                startPoint = if (startPoint > 1) startPoint - 1 else return;
                endPoint = if (endPoint > 1) endPoint - 1 else return;
            }

            while (endPoint > 0 and self.text_entry_buf.items[endPoint] != ' ') {
                endPoint -= 1;
            }

            const len = startPoint - endPoint;
            const removed = self.text_entry_buf.items[endPoint..startPoint];
            const removedCopy = try self.gpa.dupe(u8, removed);
            try self.redo_buf.append(self.gpa, removedSection{ .text = removedCopy, .index = endPoint });
            try self.text_entry_buf.replaceRange(self.gpa, endPoint, len, &[_]u8{});
            text.textSet(self.text_entry_buf.items, false);
            text.textLayout.selection.cursor = cursorPos - len;
        } else if (self.state.redo) {
            if (self.redo_buf.pop()) |last_action| {
                try self.text_entry_buf.insertSlice(self.gpa, last_action.index, last_action.text);

                text.textSet(self.text_entry_buf.items, false);

                text.textLayout.selection.cursor = last_action.index + last_action.text.len;

                self.gpa.free(last_action.text);
            }
        }
    }

    ///handles events related to saving and opening files
    fn fileEvents(self: *zeditor) !void {
        if (self.state.load == true) {
            try self.open();
        } else if (self.state.save) {
            try self.quickSave();
        } else if (self.state.saveAs) {
            try self.saveAs();
        }
    }

    fn clearInputState(self: *zeditor) void {
        self.state.load = false;
        self.state.save = false;
        self.state.saveAs = false;
        self.state.newLine = false;
        self.state.undo = false;
        self.state.redo = false;
    }

    ///determines what events have occurred this frame
    fn poolEvents(self: *zeditor) !bool {
        const events = dvui.events();

        var shouldClose = false;
        for (events) |*e| {
            if (e.evt == .key) {
                if (e.evt.key.action == .down and (e.evt.key.mod.control() or e.evt.key.mod.command())) {
                    if (e.evt.key.code == .o) {
                        self.state.load = true;
                    } else if (e.evt.key.code == .s) {
                        self.state.save = true;
                    } else if (e.evt.key.code == .z) {
                        self.state.undo = true;
                    } else if (e.evt.key.code == .y) {
                        self.state.redo = true;
                    }
                } else if (e.evt.key.action == .down and (e.evt.key.code == .enter or e.evt.key.code == .kp_enter)) {
                    self.state.newLine = true;
                }

                if (e.evt.key.action == .down) {
                    _ = try self.text_entry_buf.addOne(self.gpa);
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
    fn quickSave(self: *zeditor) !void {
        if (self.open_file_name) |fname| {
            try self.save(fname);
        } else {
            try self.saveAs();
        }
    }

    ///Saves the current file, always asks for location
    fn saveAs(self: *zeditor) !void {
        const fileName = try dvui.dialogNativeFileSave(self.gpa, .{});

        try self.save(fileName);

        self.open_file_name = fileName;
    }

    ///Saves the current File
    fn save(self: *zeditor, fileName: ?[]const u8) !void {
        if (fileName) |fname| {
            var file = try std.fs.createFileAbsolute(fname, .{});
            defer file.close();
            try file.writeAll(self.text_entry_buf.items);
        }
    }

    ///Opens a file into the editor
    fn open(self: *zeditor) !void {
        const fileName = try dvui.dialogNativeFileOpen(self.gpa, .{ .path = "*.txt" });
        if (fileName) |fname| {
            const file = try std.fs.openFileAbsolute(fname, .{ .mode = .read_only });
            defer file.close();
            const size = try file.getEndPos();
            _ = try self.text_entry_buf.resize(self.gpa, size);
            const bytes = try file.readAll(self.text_entry_buf.items);
            _ = try self.text_entry_buf.resize(self.gpa, bytes);
            self.open_file_name = fname;
        }
    }
};

pub const inputState = struct {
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
