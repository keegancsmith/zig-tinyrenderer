const std = @import("std");
const fmt = std.fmt;
const fs = std.fs;
const mem = std.mem;
const meta = std.meta;
const process = std.process;

const max_obj_file_size = 10 * 1024 * 1024;

const TGAHeader = packed struct {
    idlength: u8,
    colormaptype: u8,
    datatypecode: u8,
    colormaporigin: u16,
    colormaplength: u16,
    colormapdepth: u8,
    x_origin: u16,
    y_origin: u16,
    width: u16,
    height: u16,
    bitsperpixel: u8,
    imagedescriptor: u8,
};

const TGAColor = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
};

const TGAImage = struct {
    data: []TGAColor,
    width: usize,

    fn set(self: *TGAImage, x: u32, y: u32, color: TGAColor) void {
        self.data[(y * self.width) + x] = color;
    }

    fn flip_vertically(self: *TGAImage) void {
        const height = self.data.len / self.width;
        const half = height / 2;
        for (0..half) |row| {
            const lower = row * self.width;
            const upper = (height - row - 1) * self.width;
            for (lower..(lower + self.width), upper..(upper + self.width)) |l, u| {
                const tmp = self.data[l];
                self.data[l] = self.data[u];
                self.data[u] = tmp;
            }
        }
    }

    fn write_tga_file(self: *TGAImage, filename: []const u8) !void {
        const file = try std.fs.cwd().createFile(
            filename,
            .{ .read = true },
        );
        defer file.close();
        var bw = std.io.bufferedWriter(file.writer());

        const header = TGAHeader{
            .bitsperpixel = 3 << 3,
            .width = @as(u16, @intCast(self.width)),
            .height = @as(u16, @intCast(self.data.len / self.width)),
            .datatypecode = 2, // rle=false && RGB
            .imagedescriptor = 0x20, // top-left origin

            // unset
            .idlength = 0,
            .colormaptype = 0,
            .colormaporigin = 0,
            .colormaplength = 0,
            .colormapdepth = 0,
            .x_origin = 0,
            .y_origin = 0,
        };
        _ = try bw.write(std.mem.asBytes(&header));

        for (self.data) |pixel| {
            const bytes = [_]u8{ pixel.r, pixel.g, pixel.b };
            _ = try bw.write(bytes[0..]);
        }

        const developer_area_ref = [_]u8{ 0, 0, 0, 0 };
        _ = try bw.write(developer_area_ref[0..]);
        const extension_area_ref = [_]u8{ 0, 0, 0, 0 };
        _ = try bw.write(extension_area_ref[0..]);
        const footer = "TRUEVISION-XFILE.\x00";
        _ = try bw.write(footer[0..]);

        try bw.flush();
    }
};

fn dist(comptime T: type, x0: T, x1: T) T {
    if (x0 < x1) {
        return x1 - x0;
    } else {
        return x0 - x1;
    }
}

fn draw_line(image: *TGAImage, x0: u32, y0: u32, x1: u32, y1: u32, color: TGAColor) void {
    var fx0: f32 = @floatFromInt(x0);
    var fx1: f32 = @floatFromInt(x1);
    var fy0: f32 = @floatFromInt(y0);
    var fy1: f32 = @floatFromInt(y1);

    // algorithm longs along x axis, so transpose if the line is longer in the
    // y axis for better fidelity.
    const transposed = dist(f32, fx0, fx1) < dist(f32, fy0, fy1);
    if (transposed) {
        std.mem.swap(f32, &fx0, &fy0);
        std.mem.swap(f32, &fx1, &fy1);
    }

    if (fx0 > fx1) {
        std.mem.swap(f32, &fx0, &fx1);
        std.mem.swap(f32, &fy0, &fy1);
    }

    var x: f32 = fx0;
    while (x <= fx1) : (x += 1) {
        const t: f32 = (x - fx0) / (fx1 - fx0);
        const y: u32 = @intFromFloat(fy0 * (1 - t) + fy1 * t);
        if (transposed) {
            image.set(y, @as(u32, @intFromFloat(x)), color);
        } else {
            image.set(@as(u32, @intFromFloat(x)), y, color);
        }
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var args_it = try process.argsWithAllocator(allocator);
    defer args_it.deinit();

    if (!args_it.skip()) @panic("expected self arg");

    const model_path = args_it.next() orelse "obj/african_head.obj";

    var model_file = try fs.cwd().openFile(model_path, .{ .mode = .read_only });
    defer model_file.close();

    const model_file_bytes = try model_file.reader().readAllAlloc(allocator, max_obj_file_size);
    defer allocator.free(model_file_bytes);

    const ObjLineTypes = enum { v, f, g, s, vn, vt, @"#" };

    var tok_it = mem.tokenizeAny(u8, model_file_bytes, "\n");
    while (tok_it.next()) |line| {
        var parts_it = mem.tokenize(u8, line, " ");
        const typ_str = parts_it.next() orelse continue;
        const typ = meta.stringToEnum(ObjLineTypes, typ_str) orelse @panic("unknown obj line type");
        switch (typ) {
            .v => {
                const x = try fmt.parseFloat(f32, parts_it.next().?);
                const y = try fmt.parseFloat(f32, parts_it.next().?);
                const z = try fmt.parseFloat(f32, parts_it.next().?);
                std.debug.print("v {d} {d} {d}\n", .{ x, y, z });
            },

            .vt => {
                const x = try fmt.parseFloat(f32, parts_it.next().?);
                const y = try fmt.parseFloat(f32, parts_it.next().?);
                const z = try fmt.parseFloat(f32, parts_it.next().?);
                std.debug.print("vt {d} {d} {d}\n", .{ x, y, z });
            },

            .vn => {
                const x = try fmt.parseFloat(f32, parts_it.next().?);
                const y = try fmt.parseFloat(f32, parts_it.next().?);
                const z = try fmt.parseFloat(f32, parts_it.next().?);
                std.debug.print("vn {d} {d} {d}\n", .{ x, y, z });
            },

            .g => {
                const name = parts_it.next().?;
                std.debug.print("g {s}\n", .{name});
            },

            .s => {
                const v = parts_it.next().?;
                const smooth_shading_on = std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "on");
                std.debug.print("s {any}\n", .{smooth_shading_on});
            },

            .f => {
                var count: u8 = 0;
                var weird = false;
                while (parts_it.next()) |normal| {
                    weird = weird or std.mem.count(u8, normal, "/") != 2;
                    count += 1;
                }
                weird = weird or count != 3;
                if (weird) {
                    std.debug.print("weird line {s}\n", .{line});
                }
                // TODO parse 3 normals
            },

            .@"#" => {},
        }
    }

    const white = TGAColor{ .r = 255, .g = 255, .b = 255 };
    const red = TGAColor{ .r = 255 };
    const width = 800;
    const height = 800;

    var data = [_]TGAColor{.{}} ** (width * height);
    var image = TGAImage{
        .data = data[0..],
        .width = width,
    };

    draw_line(&image, 13, 20, 80, 40, white);
    draw_line(&image, 20, 13, 40, 80, red);
    draw_line(&image, 80, 40, 13, 20, red);

    image.flip_vertically();
    try image.write_tga_file("output.tga");
}
