const std = @import("std");
const fmt = std.fmt;
const fs = std.fs;
const mem = std.mem;
const meta = std.meta;
const process = std.process;
const Allocator = mem.Allocator;
const assert = std.debug.assert;

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
    b: u8 = 0,
    g: u8 = 0,
    r: u8 = 0,
};

const TGAImage = struct {
    data: []TGAColor,
    width: usize,

    fn set(self: *TGAImage, t: Vec2i, color: TGAColor) void {
        // Bad, but just automatically make things in bound for convenience.
        const x = if (t[0] < self.width) t[0] else (self.width - 1);
        var idx = (t[1] * self.width) + x;
        if (idx >= self.data.len) {
            idx = self.data.len - 1;
        }
        self.data[idx] = color;
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
            const bytes = [_]u8{ pixel.b, pixel.g, pixel.r };
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

fn draw_line(image: *TGAImage, t0: Vec2i, t1: Vec2i, color: TGAColor) void {
    if (t0[0] == t1[0] and t0[1] == t1[1]) {
        image.set(t0, color);
        return;
    }

    var fx0: f32 = @floatFromInt(t0[0]);
    var fx1: f32 = @floatFromInt(t1[0]);
    var fy0: f32 = @floatFromInt(t0[1]);
    var fy1: f32 = @floatFromInt(t1[1]);

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
            image.set(Vec2i{ y, @as(u32, @intFromFloat(x)) }, color);
        } else {
            image.set(Vec2i{ @as(u32, @intFromFloat(x)), y }, color);
        }
    }
}

const WavefrontObjEntity = union(enum) {
    v: [3]f32,
    f: [3]u32,
};

const WavefrontObjIterator = struct {
    line_iter: mem.TokenIterator(u8, .any),

    pub fn next(self: *WavefrontObjIterator) !?WavefrontObjEntity {
        while (self.line_iter.next()) |line| {
            var parts_it = mem.tokenize(u8, line, " ");
            const typ_str = parts_it.next() orelse continue;
            const typ = meta.stringToEnum(meta.Tag(WavefrontObjEntity), typ_str) orelse continue;

            // TODO maybe this can be a return and each case returns something?
            switch (typ) {
                .v => {
                    return .{
                        .v = [3]f32{
                            try fmt.parseFloat(f32, parts_it.next().?),
                            try fmt.parseFloat(f32, parts_it.next().?),
                            try fmt.parseFloat(f32, parts_it.next().?),
                        },
                    };
                },

                .f => {
                    // Lots of different ways this line can appear, but we just
                    // support something that looks like
                    //
                    //   f 1201/1249/1201 1202/1248/1202 1200/1246/1200
                    //
                    // We also only care about the vertex index which is the first
                    // value.
                    var vertex_indices = [_]u32{0} ** 3;
                    var i: usize = 0;
                    while (parts_it.next()) |normal| {
                        const first = std.mem.indexOf(u8, normal, "/") orelse normal.len;
                        const idx = try fmt.parseInt(u32, normal[0..first], 10);
                        vertex_indices[i] = idx - 1;
                        i += 1;
                        if (i >= 3) {
                            break;
                        }
                    }
                    return .{ .f = vertex_indices };
                },
            }
        }
        return null;
    }
};

const Model = struct {
    vertices: std.ArrayList([3]f32),
    faces: std.ArrayList([3]u32),

    pub fn init(allocator: Allocator) Model {
        return .{
            .vertices = std.ArrayList([3]f32).init(allocator),
            .faces = std.ArrayList([3]u32).init(allocator),
        };
    }

    pub fn readFile(allocator: Allocator, path: []const u8) !Model {
        var model_file = try fs.cwd().openFile(path, .{ .mode = .read_only });
        defer model_file.close();

        const model_file_bytes = try model_file.reader().readAllAlloc(allocator, max_obj_file_size);
        defer allocator.free(model_file_bytes);

        var model = Model.init(allocator);
        errdefer model.deinit();

        var ent_it = WavefrontObjIterator{
            .line_iter = mem.tokenizeAny(u8, model_file_bytes, "\n"),
        };
        while (try ent_it.next()) |ent| {
            switch (ent) {
                .v => {
                    try model.vertices.append(ent.v);
                },
                .f => {
                    try model.faces.append(ent.f);
                },
            }
        }

        return model;
    }

    pub fn deinit(model: *Model) void {
        model.vertices.deinit();
        model.faces.deinit();
    }
};

const Vec2i = [2]u32;

fn find_bounding_box(points: [3]Vec2i) [2]Vec2i {
    var bounding_box = [2]Vec2i{ points[0], points[0] };
    for (points[1..]) |p| {
        bounding_box[0][0] = @min(bounding_box[0][0], p[0]);
        bounding_box[0][1] = @min(bounding_box[0][1], p[1]);
        bounding_box[1][0] = @max(bounding_box[1][0], p[0]);
        bounding_box[1][1] = @max(bounding_box[1][1], p[1]);
    }
    return bounding_box;
}

fn inside(points: [3]Vec2i, p: Vec2i) bool {
    assert(p[0] >= 0 and p[0] <= 800);
    assert(p[1] >= 0 and p[1] <= 800);

    const a1: f32 = @as(f32, @floatFromInt(points[2][0])) - @as(f32, @floatFromInt(points[0][0]));
    const a2: f32 = @as(f32, @floatFromInt(points[1][0])) - @as(f32, @floatFromInt(points[0][0]));
    const a3: f32 = @as(f32, @floatFromInt(points[0][0])) - @as(f32, @floatFromInt(p[0]));

    const b1: f32 = @as(f32, @floatFromInt(points[2][1])) - @as(f32, @floatFromInt(points[0][1]));
    const b2: f32 = @as(f32, @floatFromInt(points[1][1])) - @as(f32, @floatFromInt(points[0][1]));
    const b3: f32 = @as(f32, @floatFromInt(points[0][1])) - @as(f32, @floatFromInt(p[1]));

    // a cross b
    const c1 = a2 * b3 - a3 * b2;
    const c2 = a3 * b1 - a1 * b3;
    const c3 = a1 * b2 - a2 * b1;

    // degenerate triangle case
    if (@abs(c3) < 1) return false;

    return ((c1 + c2) / c3 <= 1) and (c2 >= 0) and (c1 >= 0);
}

fn draw_triangle(image: *TGAImage, points2: [3]Vec2i, color: TGAColor) void {
    // not shown in psuedocode, but depends on the points being in counter
    // clockwise order.
    var points = points2;
    if (points[0][1] > points[1][1]) {
        mem.swap(Vec2i, &points[0], &points[1]);
    }
    if (points[0][1] > points[2][1]) {
        mem.swap(Vec2i, &points[0], &points[2]);
    }
    if (points[1][0] > points[2][0]) {
        mem.swap(Vec2i, &points[1], &points[2]);
    }

    const bounding_box = find_bounding_box(points);
    assert(bounding_box[0][0] >= 0 and bounding_box[0][1] >= 0);
    assert(bounding_box[1][0] <= 800 and bounding_box[1][1] <= 800);
    for (bounding_box[0][1]..bounding_box[1][1] + 1) |y| {
        for (bounding_box[0][0]..bounding_box[1][0] + 1) |x| {
            const p = Vec2i{ @as(u32, @intCast(x)), @as(u32, @intCast(y)) };
            if (inside(points, p)) {
                image.set(p, color);
            }
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

    var model = try Model.readFile(allocator, model_path);
    defer model.deinit();

    const width = 800;
    const height = 800;

    // neat, labelled blocks allow you to return a value
    var prng = std.rand.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const rand = prng.random();

    var data = [_]TGAColor{.{}} ** (width * height);
    var image = TGAImage{
        .data = data[0..],
        .width = width,
    };

    for (model.faces.items) |vertex_indices| {
        const v0 = model.vertices.items[vertex_indices[0]];
        const v1 = model.vertices.items[vertex_indices[1]];
        const v2 = model.vertices.items[vertex_indices[2]];
        const t0 = Vec2i{
            @intFromFloat((v0[0] + 1) * width / 2),
            @intFromFloat((v0[1] + 1) * height / 2),
        };
        const t1 = Vec2i{
            @intFromFloat((v1[0] + 1) * width / 2),
            @intFromFloat((v1[1] + 1) * height / 2),
        };
        const t2 = Vec2i{
            @intFromFloat((v2[0] + 1) * width / 2),
            @intFromFloat((v2[1] + 1) * height / 2),
        };
        const c = TGAColor{ .r = rand.int(u8), .g = rand.int(u8), .b = rand.int(u8) };
        draw_triangle(&image, .{ t0, t1, t2 }, c);
    }

    image.flip_vertically();
    try image.write_tga_file("output.tga");
}
