const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const CrossTarget = std.zig.CrossTarget;
const io = std.io;
const fs = std.fs;
const macho = std.macho;
const mem = std.mem;
const fmt = std.fmt;
const tmpDir = std.testing.tmpDir;
const testing = std.testing;

pub const TestContext = struct {
    cases: std.ArrayList(Case),

    pub const Case = struct {
        name: []const u8,
        target: CrossTarget,
        zig_source: ?struct { basename: []const u8, bytes: []const u8 } = null,
        c_sources: std.ArrayList(CSource),
        link_flags: []const []const u8,
        expected_out: ExpectedOut = .{},

        const ExpectedOut = struct {
            stdout: []const u8 = &[0]u8{},
            stderr: []const u8 = &[0]u8{},
        };

        const CSource = struct {
            basename: []const u8,
            bytes: []const u8,
            flags: []const []const u8,
        };

        pub fn deinit(self: *Case) void {
            self.c_sources.deinit();
        }

        pub fn addZigSource(self: *Case, basename: []const u8, bytes: []const u8) void {
            assert(self.zig_source == null);
            self.zig_source = .{
                .basename = basename,
                .bytes = bytes,
            };
        }

        pub fn addCSource(self: *Case, basename: []const u8, bytes: []const u8, flags: []const []const u8) !void {
            try self.c_sources.append(.{
                .basename = basename,
                .bytes = bytes,
                .flags = flags,
            });
        }

        pub fn expectStdOut(self: *Case, stdout: []const u8) void {
            self.expected_out.stdout = stdout;
        }

        pub fn expectStdErr(self: *Case, stderr: []const u8) void {
            self.expected_out.stderr = stderr;
        }
    };

    pub fn createCase(self: *TestContext, name: []const u8, target: CrossTarget) !*Case {
        const index = self.cases.items.len;
        try self.cases.append(Case{
            .name = name,
            .target = target,
            .c_sources = ArrayList(Case.CSource).init(testing.allocator),
        });
        return &self.cases.items[index];
    }

    pub fn run(self: *TestContext) !void {
        for (self.cases.items) |case| {
            try self.runCase(case);
        }
    }

    fn runCase(self: *TestContext, case: Case) !void {
        var tmp = tmpDir(.{});
        defer tmp.cleanup();

        const target_triple = try case.target.zigTriple(testing.allocator);

        const write_src = b.addWriteFiles();
        if (case.zig_source) |zig_source| {
            write_src.add(zig_source.basename, zig_source.bytes);
        }

        for (case.c_sources.items) |source| {
            write_src.add(source.basename, source.bytes);
        }

        const main = switch (case.kind) {
            .exe => blk: {
                const exe = if (case.zig_source) |zig_source|
                    b.addExecutableSource("test", write_src.getFileSource(zig_source.basename).?)
                else
                    b.addExecutable("test", null);
                break :blk exe;
            },
            .lib => blk: {
                const shared = if (case.zig_source) |zig_source|
                    b.addSharedLibrarySource("test", write_src.getFileSource(zig_source.basename).?, b.version(1, 0, 0))
                else
                    b.addSharedLibrary("test", null, b.version(1, 0, 0));
                break :blk shared;
            },
        };
        main.setTarget(case.target);

        for (case.c_sources.items) |source| {
            main.addCSourceFileSource(.{
                .source = write_src.getFileSource(source.basename).?,
                .args = source.flags,
            });
        }

        const inspect = blk: {
            const inspect = b.allocator.create(MachoParseAndInspectStep) catch unreachable;
            inspect.* = MachoParseAndInspectStep.init(b, main);
            break :blk inspect;
        };
        for (expected.load_commands) |lc| {
            std.log.warn("{}", .{lc});
            inspect.addExpectedLoadCommand(lc);
        }
        inspect.step.dependOn(&main.step);

        const log = b.addLog("PASS {s}\n", .{annotated_case_name});
        log.step.dependOn(&inspect.step);

        if (case.kind == .exe) build_only: {
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
                    main.setExecCmd(args.items);
                } else break :build_only,
                .darling => |bin_name| if (b.enable_darling) {
                    main.setExecCmd(&.{bin_name});
                } else break :build_only,
                .wasmtime => |bin_name| if (b.enable_wasmtime) {
                    main.setExecCmd(&.{bin_name});
                } else break :build_only,
                .wine => |bin_name| if (b.enable_wine) {
                    main.setExecCmd(&.{bin_name});
                } else break :build_only,
                else => break :build_only,
            }

            const run = main.run();
            run.expectStdErrEqual(expected.stderr);
            run.expectStdOutEqual(expected.stdout);

            log.step.dependOn(&run.step);
        }

        self.step.dependOn(&log.step);
    }
};

const MachoParseAndInspectStep = struct {
    pub const base_id = .custom;

    step: build.Step,
    builder: *build.Builder,
    macho_file: *build.LibExeObjStep,
    load_commands: ArrayList(macho.LoadCommand),

    pub fn init(builder: *build.Builder, macho_file: *build.LibExeObjStep) MachoParseAndInspectStep {
        return MachoParseAndInspectStep{
            .builder = builder,
            .step = build.Step.init(.custom, builder.fmt("MachoParseAndInspect {s}", .{
                macho_file.getOutputSource().getDisplayName(),
            }), builder.allocator, make),
            .macho_file = macho_file,
            .load_commands = ArrayList(macho.LoadCommand).init(builder.allocator),
        };
    }

    pub fn addExpectedLoadCommand(self: *MachoParseAndInspectStep, lc: macho.LoadCommand) void {
        self.load_commands.append(lc) catch unreachable;
    }

    fn make(step: *build.Step) !void {
        const self = @fieldParentPtr(MachoParseAndInspectStep, "step", step);
        const executable_path = self.macho_file.installed_path orelse
            self.macho_file.getOutputSource().getPath(self.builder);

        const file = try fs.cwd().openFile(executable_path, .{});
        defer file.close();

        // TODO mmap the file, but remember to handle Windows as the host too.
        // The test should be possible to perform on ANY OS!
        const reader = file.reader();
        const header = try reader.readStruct(macho.mach_header_64);
        assert(header.filetype == macho.MH_EXECUTE or header.filetype == macho.MH_DYLIB);

        var load_commands = ArrayList(macho.LoadCommand).init(self.builder.allocator);
        try load_commands.ensureTotalCapacity(header.ncmds);

        var i: u16 = 0;
        while (i < header.ncmds) : (i += 1) {
            var cmd = try macho.LoadCommand.read(self.builder.allocator, reader);
            load_commands.appendAssumeCapacity(cmd);
        }

        outer: for (self.load_commands.items) |exp_lc| {
            for (load_commands.items) |given_lc| {
                if (exp_lc.eql(given_lc)) continue :outer;
            }

            std.debug.print(
                \\
                \\======== Expected to find this load command: ========
                \\{}
                \\
            , .{exp_lc});
            return error.TestFailed;
        }
    }
};