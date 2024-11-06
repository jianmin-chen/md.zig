const std = @import("std");
const Element = @import("element.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const TableOfContents = struct {
    allocator: Allocator,
    slugs: ArrayList([]const u8),
    values: ArrayList([]const u8),
    mutate: bool,

    const Self = @This();

    pub fn init(
        allocator: Allocator, 
        options: struct {
            mutate: bool = true
        }
    ) Self {
        return .{
            .allocator = allocator,
            .slugs = ArrayList([]const u8).init(allocator),
            .values = ArrayList([]const u8).init(allocator),
            .mutate = options.mutate
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.slugs.items) |slug| {
            self.allocator.free(slug);
        }
        self.slugs.deinit();

        for (self.values.items) |value| {
            self.allocator.free(value);
        }
        self.values.deinit();
    }

    pub fn operate(self: *Self, ast: *Element) !void {
        for (ast.children.items) |child| {
            if (std.mem.startsWith(u8, child.name, "h")) {
                var node_value = ArrayList(u8).init(self.allocator);
                defer node_value.deinit();
                try child.toText(node_value.writer());

                try self.id(&node_value);

                if (self.mutate) {
                    const slug = self.slugs.items[self.slugs.items.len - 1];
                    try child.addProp("id", std.mem.trim(u8, slug, "#"));
                    try child.addProp("data-slug", slug);
                }
            }
        }
    }

    fn id(self: *Self, node_value: *ArrayList(u8)) !void {
        var hash = try node_value.clone();
        defer hash.deinit();

        var i: usize = 0;
        while (i < hash.items.len) {
            if (hash.items[i] == ' ') {
                hash.items[i] = '-';
            } else if (!std.ascii.isAlphabetic(hash.items[i])) {
                _ = hash.orderedRemove(i);
                continue;
            }

            hash.items[i] = std.ascii.toLower(hash.items[i]);
            i += 1;
        }

        const idx: usize = 0;
        if (idx > 0) {
            const writer = hash.writer();
            try writer.print("{d}", .{idx});
        }

        try hash.insert(0, '#');

        try self.slugs.append(try hash.toOwnedSlice());
        try self.values.append(try node_value.toOwnedSlice());
    }
};