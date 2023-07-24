const std = @import("std");

const TGAColor = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,
};

const TGAImage = struct {
    data: []TGAColor,
    width: usize,

    fn set(self: *TGAImage, x: u32, y: u32, color: TGAColor) void {
        self.data[(x * self.width) + y] = color;
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
        for (self.data) |pixel| {
            const bytes = [_]u8{ pixel.r, pixel.g, pixel.b, pixel.a };
            _ = try bw.write(bytes[0..]);
        }
        try bw.flush();
    }
};

pub fn main() !void {
    var data: [100 * 100]TGAColor = undefined;
    var image = TGAImage{
        .data = data[0..],
        .width = 100,
    };
    image.set(52, 41, TGAColor{ .r = 255 });
    image.flip_vertically();
    try image.write_tga_file("output.tga");
}
