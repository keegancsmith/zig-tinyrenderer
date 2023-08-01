const std = @import("std");

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

fn line(x0: u32, y0: u32, x1: u32, y1: u32, image: *TGAImage, color: TGAColor) void {
    var t: f32 = 0;

    const fx0: f32 = @floatFromInt(x0);
    const fx1: f32 = @floatFromInt(x1);
    const fy0: f32 = @floatFromInt(y0);
    const fy1: f32 = @floatFromInt(y1);

    while (t < 1) : (t += 0.1) {
        const x: u32 = @intFromFloat(fx0 * (1 - t) + fx1 * t);
        const y: u32 = @intFromFloat(fy0 * (1 - t) + fy1 * t);
        image.set(x, y, color);
    }
}

pub fn main() !void {
    var data = [_]TGAColor{.{}} ** (100 * 100);
    var image = TGAImage{
        .data = data[0..],
        .width = 100,
    };
    line(13, 20, 80, 40, &image, TGAColor{ .r = 255, .g = 255, .b = 255 });
    image.flip_vertically();
    try image.write_tga_file("output.tga");
}
