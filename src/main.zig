const std = @import("std");
const dvui = @import("dvui");
const eng = @import("engine");
const app = @import("zeditor");
var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
var gpa = gpa_instance.allocator();

pub fn main() !void {
    defer if (gpa_instance.deinit() != .ok) @panic("Memory leak on exit!");
    var zeditor = try app.zeditor.init(gpa);
    defer zeditor.deinit();

    State.instance = &zeditor;

    try eng.runApp(State.frameWrapper, gpa);
}

const State = struct {
    var instance: *app.zeditor = undefined;

    fn frameWrapper() !bool {
        return instance.runFrame();
    }
};
