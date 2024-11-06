// TODO: No actual testing yet... this is just testing functionality.
const std = @import("std");
const md = @import("md");

const Allocator = std.mem.Allocator;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    const allocator = gpa.allocator();

    var toc = md.plugins.TableOfContents.init(allocator, .{});
    defer toc.deinit();

    const markdown = 
        \\---
        \\key: value
        \\---
        \\
        \\## Heading
        \\
        \\This is a paragraph.
        \\
    ;

    var output = try md.toHtml(allocator, markdown, .{&toc});
    defer output.deinit();

    std.debug.print("{s}\n", .{output.output});
}