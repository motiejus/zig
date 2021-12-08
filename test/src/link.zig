const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const build = std.build;
const CrossTarget = std.zig.CrossTarget;
const io = std.io;
const fs = std.fs;
const mem = std.mem;
const fmt = std.fmt;
const ArrayList = std.ArrayList;
const Mode = std.builtin.Mode;
const LibExeObjStep = build.LibExeObjStep;
const tmpDir = std.testing.tmpDir;

pub const LinkContext = struct {
    b: *build.Builder,
    step: *build.Step,
    test_index: usize,
    test_filter: ?[]const u8,
    enable_macos_sdk: bool,
    target: CrossTarget,

    pub const TestCase = struct {
        name: []const u8,
        target: CrossTarget,
        zig_source: ?struct { basename: []const u8, bytes: []const u8 } = null,
        c_sources: ArrayList(CSource),
        expected_out: ExpectedOutput = .{},

        const CSource = struct {
            basename: []const u8,
            bytes: []const u8,
            flags: []const []const u8,
        };

        const ExpectedOutput = struct {
            stdout: ?[]const u8 = null,
            stderr: ?[]const u8 = null,
        };

        pub fn addZigSource(self: *TestCase, basename: []const u8, bytes: []const u8) void {
            assert(self.zig_source == null);
            self.zig_source = .{
                .basename = basename,
                .bytes = bytes,
            };
        }

        pub fn addCSource(
            self: *TestCase,
            basename: []const u8,
            bytes: []const u8,
            flags: []const []const u8,
        ) void {
            self.c_sources.append(.{
                .basename = basename,
                .bytes = bytes,
                .flags = flags,
            }) catch unreachable;
        }

        pub fn expectStdOut(self: *TestCase, stdout: []const u8) void {
            self.expected_out.stdout = stdout;
        }

        pub fn expectStdErr(self: *TestCase, stderr: []const u8) void {
            self.expected_out.stderr = stderr;
        }
    };

    pub fn create(self: *LinkContext, name: []const u8, target: CrossTarget) TestCase {
        return TestCase{
            .name = name,
            .target = target,
            .c_sources = ArrayList(TestCase.CSource).init(self.b.allocator),
        };
    }

    pub fn addCase(self: *LinkContext, case: TestCase) void {
        const b = self.b;
        const target_triple = case.target.zigTriple(b.allocator) catch unreachable;
        const annotated_case_name = b.fmt("link ({s}) {s}", .{ target_triple, case.name });
        if (self.test_filter) |filter| {
            if (mem.indexOf(u8, annotated_case_name, filter) == null) return;
        }

        const write_src = b.addWriteFiles();
        if (case.zig_source) |zig_source| {
            write_src.add(zig_source.basename, zig_source.bytes);
        }

        for (case.c_sources.items) |source| {
            write_src.add(source.basename, source.bytes);
        }

        const exe = if (case.zig_source) |zig_source|
            b.addExecutableSource("test", write_src.getFileSource(zig_source.basename).?)
        else
            b.addExecutable("test", null);

        exe.setTarget(case.target);

        for (case.c_sources.items) |source| {
            exe.addCSourceFileSource(.{
                .source = write_src.getFileSource(source.basename).?,
                .args = source.flags,
            });
        }

        build_only: {
            const host = std.zig.system.NativeTargetInfo.detect(b.allocator, .{}) catch
                break :build_only;
            const target_info = std.zig.system.NativeTargetInfo.detect(b.allocator, case.target) catch
                break :build_only;

            const need_cross_glibc = case.target.isGnuLibC() and case.c_sources.items.len > 0;

            switch (host.getExternalExecutor(target_info, .{})) {
                .native => {},
                .rosetta => if (!b.enable_rosetta) break :build_only,
                .qemu => |bin_name| if (b.enable_qemu) {
                    const glibc_dir_arg = if (need_cross_glibc)
                        b.glibc_runtimes_dir orelse break :build_only
                    else
                        null;

                    var args = ArrayList(?[]const u8).init(b.allocator);
                    defer args.deinit();

                    args.append(bin_name) catch unreachable;
                    if (glibc_dir_arg) |dir| {
                        // TODO look into making this a call to `linuxTriple`. This
                        // needs the directory to be called "i686" rather than
                        // "i386" which is why we do it manually here.
                        const fmt_str = "{s}" ++ fs.path.sep_str ++ "{s}-{s}-{s}";
                        const cpu_arch = case.target.getCpuArch();
                        const os_tag = case.target.getOsTag();
                        const abi = case.target.getAbi();
                        const cpu_arch_name: []const u8 = if (cpu_arch == .i386)
                            "i686"
                        else
                            @tagName(cpu_arch);
                        const full_dir = fmt.allocPrint(b.allocator, fmt_str, .{
                            dir, cpu_arch_name, @tagName(os_tag), @tagName(abi),
                        }) catch unreachable;

                        args.append("-L") catch unreachable;
                        args.append(full_dir) catch unreachable;
                    }
                    exe.setExecCmd(args.items);
                } else break :build_only,
                .darling => |bin_name| if (b.enable_darling) {
                    exe.setExecCmd(&.{bin_name});
                } else break :build_only,
                .wasmtime => |bin_name| if (b.enable_wasmtime) {
                    exe.setExecCmd(&.{bin_name});
                } else break :build_only,
                .wine => |bin_name| if (b.enable_wine) {
                    exe.setExecCmd(&.{bin_name});
                } else break :build_only,
                else => break :build_only,
            }

            const run = exe.run();
            run.expectStdErrEqual(case.expected_out.stderr orelse "");
            run.expectStdOutEqual(case.expected_out.stdout orelse "");

            const log = b.addLog("PASS {s}\n", .{annotated_case_name});
            log.step.dependOn(&run.step);
            self.step.dependOn(&log.step);

            return;
        }

        const log = b.addLog("PASS (build only) {s}\n", .{annotated_case_name});
        log.step.dependOn(&exe.step);
        self.step.dependOn(&log.step);
    }
};
