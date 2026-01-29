const std = @import("std");
const Pkg = std.Build.Pkg;
const Compile = std.Build.Step.Compile;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .os_tag = .windows } });

    const optimize = b.standardOptimizeOption(.{});

    const dvui_dep = b.dependency("dvui", .{ .target = target, .optimize = optimize, .backend = .sdl3gpu });

    const name = "Zeditor";

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = name,
        .root_module = exe_mod,
    });

    exe.subsystem = .Windows;

    exe.root_module.addImport("dvui", dvui_dep.module("dvui_sdl3gpu"));
    exe.root_module.addImport("sdl3gpu-backend", dvui_dep.module("sdl3"));

    const compile_step = b.step("compile", "Compile " ++ name);
    compile_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    b.getInstallStep().dependOn(compile_step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(compile_step);

    const run_step = b.step("run", "run " ++ name);
    run_step.dependOn(&run_cmd.step);
}
