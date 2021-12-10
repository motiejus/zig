const std = @import("std");
const builtin = @import("builtin");
const macho = std.macho;
const tests = @import("tests.zig");
const CrossTarget = std.zig.CrossTarget;

const macos_x86_64 = CrossTarget{
    .cpu_arch = .x86_64,
    .os_tag = .macos,
};
const macos_aarch64 = CrossTarget{
    .cpu_arch = .aarch64,
    .os_tag = .macos,
};
const all_targets = &[_]CrossTarget{
    macos_x86_64,
    macos_aarch64,
};

pub fn addCases(ctx: *tests.LinkContext) void {
    for (all_targets) |target| {
        {
            var case = ctx.createExe("hello world in C", target);
            case.addCSource("test.c",
                \\#include <stdio.h>
                \\
                \\int main(int argc, char* argv[]) {
                \\    fprintf(stdout, "Hello, World!\n");
                \\    return 0;
                \\}
            , &.{});
            ctx.addCase(case, &.{}, .{ .stdout = "Hello, World!\n" });
        }

        {
            var case = ctx.createExe("TLS support in Zig and C", target);
            case.addZigSource("main.zig",
                \\const std = @import("std");
                \\
                \\threadlocal var globl: usize = 0;
                \\extern threadlocal var other: u32;
                \\
                \\pub fn main() void {
                \\    std.debug.print("{d}, {d}\n", .{globl, other});
                \\    globl += other;
                \\    other -= 1;
                \\    std.debug.print("{d}, {d}\n", .{globl, other});
                \\}
            );
            case.addCSource("a.c",
                \\_Thread_local int other = 10;
            , &.{});
            ctx.addCase(case, &.{}, .{ .stderr = 
            \\0, 10
            \\10, 9
            \\
            });
        }

        {
            var case = ctx.createExe("rpaths in binary", target);
            case.addCSource("main.c",
                \\int main() {}
            , &.{});
            var rpath_cmd = macho.emptyGenericCommandWithData(macho.rpath_command{
                .cmd = macho.LC_RPATH,
                .cmdsize = @sizeOf(macho.rpath_command),
                .path = @sizeOf(macho.rpath_command),
            });
            _ = rpath_cmd;
            ctx.addCase(case, &.{
                "-rpath", "foo",
            }, .{
                .load_commands = &[_]macho.LoadCommand{
                    .{ .rpath = rpath_cmd },
                },
            });
        }
    }
}
