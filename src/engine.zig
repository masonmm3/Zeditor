const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const SDLBackend = @import("sdl3gpu-backend");
const c = SDLBackend.c;
const vsync = true;
var scale_val: f32 = 1.0;
var show_dialog_outside_frame: bool = false;
const window_icon_png = @embedFile("resources/zig-favicon.png");

pub fn runApp(frame: fn () anyerror!bool, gpa: std.mem.Allocator) !void {
    if (@import("builtin").os.tag == .windows) {
        dvui.Backend.Common.windowsAttachConsole() catch {};
    }

    SDLBackend.enableSDLLogging();
    std.log.info("SDL version: {f}", .{SDLBackend.getSDLVersion()});

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

    main_loop: while (true) {
        // beginWait coordinates with waitTime below to run frames only when needed
        const nstime = win.beginWait(interrupted);

        // marks the beginning of a frame for dvui, can call dvui functions after this
        try win.begin(nstime);

        // send all SDL events to dvui for processing
        _ = try backend.addAllEvents(&win);

        // NOTE: SDL3GPU doesn't need manual clearing like SDL_Renderer
        // GPU backend handles clearing via render pass (LOAD_OP_CLEAR)

        const keep_running = try frame();
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
