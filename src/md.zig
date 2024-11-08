const std = @import("std");
pub const Element = @import("element.zig");
pub const plugins = @import("plugins.zig");
pub const escape = @import("utils.zig").escape;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap([]const u8);
const assert = std.debug.assert;
const panic = std.debug.panic;

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " ");
}

pub const TokenType = enum {
    blockquote,
    frontmatter,
    heading,
    colon,
    exclaim,
    star,
    bracket,
    paren,
    code,
    code_block,
    ul,
    number,
    plain,
    nl,
    eof
};

const delimiters = [_]u8{ '>', '-', '#', ':', '!', '[', ']', '(', ')', '`', '*', '\n' };

const Token = struct {
    kind: TokenType,
    start: usize,
    length: usize
};

pub const Lexer = struct {
    raw: []const u8,
    start: usize,
    current: usize,
    col: usize,
    tokens: ArrayList(Token),

    fn init(allocator: Allocator, raw: []const u8) Lexer {
        return .{
            .raw = raw,
            .start = 0,
            .current = 0,
            .col = 0,
            .tokens = ArrayList(Token).init(allocator)
        };
    }

    fn deinit(self: *Lexer) void {
        self.tokens.deinit();
    }

    fn tokenize(self: *Lexer) !ArrayList(Token) {
        while (!self.isAtEnd()) {
            try self.scanToken();
        }
        self.start = self.current;
        try self.addToken(.eof);
        return self.tokens;
    }

    fn addToken(self: *Lexer, kind: TokenType) !void {
        try self.tokens.append(.{
            .kind = kind,
            .start = self.start,
            .length = self.current - self.start
        });
    }

    fn scanToken(self: *Lexer) !void {
        self.start = self.current;
        const chr = self.advance();
        switch (chr) {
            '-' => {
                if (self.col == 1 and self.peek() == '-' and self.peekAhead(1) == '-') {
                    _ = self.advance();
                    _ = self.advance();
                    try self.addToken(.frontmatter);
                } else if (self.col == 1 and self.peek() == ' ') {
                    _ = self.advance();
                    try self.addToken(.ul);
                    if (self.peek() == '[') {
                        _ = self.advance();
                        try self.wrap(.bracket, ']');
                    }
                } else try self.addToken(.plain);
            },
            '`' => {
                if (self.col == 1 and self.peek() == '`' and self.peekAhead(1) == '`') {
                    _ = self.advance();
                    _ = self.advance();
                    while (self.peek() != '`' or self.peekAhead(1) != '`' or self.peekAhead(2) != '`') {
                        _ = self.advance();
                        if (self.raw.len - self.current < 3) {
                            try self.addToken(.plain);
                            return;
                        }
                    }
                    _ = self.advance();
                    _ = self.advance();
                    _ = self.advance();
                    try self.addToken(.code_block);
                    return;
                }
                try self.wrap(.code, '`'); // `` is not a recursive element
            },
            '*' => {
                if (self.col == 1 and self.peek() == ' ') {
                    _ = self.advance();
                    try self.addToken(.ul);
                } else try self.addToken(.star);
            },
            '#' => {
                while (self.peek() == '#') {
                    _ = self.advance();
                    if (self.isAtEnd()) {
                        try self.addToken(.plain);
                        return;
                    }
                }

                if (self.peek() == ' ' and self.current - self.start <= 6) {
                    try self.addToken(.heading);
                    _ = self.advance();
                } else {
                    try self.addToken(.plain);
                }
            },
            '!' => {
                try self.addToken(.exclaim);
            },
            '[' => {
                try self.wrap(.bracket, ']');
            },
            '(' => {
                try self.wrap(.paren, ')');
            },
            '>' => {
                if (self.col == 1 and self.peek() == ' ') {
                    _ = self.advance();
                    try self.addToken(.blockquote);
                }
            },
            ':' => {
                try self.addToken(.colon);
            },
            '\n' => {
                try self.addToken(.nl);
                self.col = 0;
            },
            else => {
                while (!self.identifier()) {
                    _ = self.advance();
                    if (self.isAtEnd()) break;
                }
                try self.addToken(.plain);
            }
        }
    }

    fn wrap(self: *Lexer, kind: TokenType, closing: u8) !void {
        while (self.peek() != closing) {
            _ = self.advance();
            if (self.isAtEnd()) {
                try self.addToken(.plain);
                return;
            }
        }

        _ = self.advance(); // Advance on closing
        try self.addToken(kind);
    }

    fn identifier(self: *Lexer) bool {
        const chr = self.peek();
        if (std.mem.indexOf(u8, &delimiters, &[_]u8{chr}) != null) return true;
        return false;
    }

    fn prev(self: *Lexer) Token {
        assert(self.tokens.items.len > 0);
        return self.tokens.items[self.tokens.items.len - 1];
    }

    fn peek(self: *Lexer) u8 {
        assert(self.current < self.raw.len);
        return self.raw[self.current];
    }

    fn peekAhead(self: *Lexer, n: usize) u8 {
        assert(self.current + n < self.raw.len);
        return self.raw[self.current + n];
    }

    fn advance(self: *Lexer) u8 {
        assert(self.current < self.raw.len);
        const chr = self.peek();
        self.current += 1;
        self.col += 1;
        return chr;
    }

    fn isAtEnd(self: *Lexer) bool {
        return self.current >= self.raw.len;
    }
};

const ParserError = error{
    UnexpectedToken,
    ExpectedFrontmatter
} || error{OutOfMemory};

const Self = @This();

allocator: Allocator,
raw: []const u8,
frontmatter: StringHashMap,
tokens: *ArrayList(Token) = undefined,
ast: *Element,
output: []const u8 = "",

start: usize,
current: usize,

temp_strings: ArrayList([]u8),

pub fn toFrontmatter(allocator: Allocator, raw: []const u8) ParserError!Self {
    // Strip raw down to just frontmatter
    var lexer = Lexer.init(allocator, raw);
    defer lexer.deinit();

    if (lexer.isAtEnd()) return ParserError.ExpectedFrontmatter;
    try lexer.scanToken();
    if (lexer.prev().kind != .frontmatter or lexer.isAtEnd())
        return ParserError.ExpectedFrontmatter;

    try lexer.scanToken();
    while (lexer.prev().kind != .frontmatter) {
        if (lexer.isAtEnd()) return ParserError.ExpectedFrontmatter;
        try lexer.scanToken();
    }

    var self: Self = .{
        .allocator = allocator,
        .raw = raw[0..lexer.current],
        .frontmatter = StringHashMap.init(allocator),
        .tokens = &lexer.tokens,
        .ast = try Element.init(allocator, ""),

        .start = 0,
        .current = 0,

        .temp_strings = ArrayList([]u8).init(allocator)
    };
    self.parseFrontmatter() catch {
        defer self.deinit();
        return ParserError.ExpectedFrontmatter;
    };
    return self;
}

pub fn toHtml(allocator: Allocator, raw: []const u8, pipeline: anytype) !Self {
    var self: Self = .{
        .allocator = allocator,
        .raw = raw,
        .frontmatter = StringHashMap.init(allocator),
        .ast = try Element.init(allocator, "div"),

        .start = 0,
        .current = 0,

        .temp_strings = ArrayList([]u8).init(allocator)
    };

    var lexer = Lexer.init(allocator, raw);
    defer lexer.deinit();
    _ = try lexer.tokenize();
    self.tokens = &lexer.tokens;

    self.parseFrontmatter() catch |err| {
        if (err == ParserError.UnexpectedToken) {
            self.start = 0;
            self.current = 0;
            self.clearFrontmatter();
        }
    };
    try self.parse();

    inline for (pipeline) |stage| {
        try stage.operate(self.ast);
    }

    var html = ArrayList(u8).init(self.allocator);
    defer html.deinit();
    try self.ast.toHtml(html.writer());

    self.output = try self.allocator.dupe(u8, html.items);

    return self;
}

pub fn deinit(self: *Self) void {
    self.frontmatter.deinit();
    self.ast.deinit();
    self.allocator.free(self.output);
    for (self.temp_strings.items) |str| {
        self.allocator.free(str);
    }
    self.temp_strings.deinit();
}

fn fix(self: *Self) void {
    // TODO: Unexpected token, adopt as plain text.
    _ = self;
}

fn clearFrontmatter(self: *Self) void {
    var it = self.frontmatter.keyIterator();
    while (it.next()) |key| {
        _ = self.frontmatter.remove(key.*);
    }
}

fn parseFrontmatter(self: *Self) ParserError!void {
    if (self.peek().kind == .frontmatter) {
        _ = self.advance();
        _ = try self.eat(.nl);
        while (!self.match(.frontmatter)) {
            if (self.isAtEnd()) return ParserError.UnexpectedToken;

            const k_token = try self.eat(.plain);
            _ = try self.eat(.colon);
            const v_token = self.gather(.nl);

            const k = trim(self.raw[k_token.start..k_token.start + k_token.length]);
            const v = trim(self.raw[v_token.start..v_token.start + v_token.length]);

            try self.frontmatter.put(k, v);

            _ = try self.eat(.nl);
        }
        _ = try self.eat(.frontmatter);
    }
}

fn parse(self: *Self) !void {
    self.start = self.current;
    while (!self.isAtEnd()) {
        self.skipNewlines();
        if (!self.isAtEnd())
            try self.parseBlock(self.ast);
    }
}

fn parseBlock(self: *Self, parent: *Element) !void {
    const token = self.advance();
    switch (token.kind) {
        .blockquote => {
            const blockquote = try Element.init(self.allocator, "blockquote");
            const p = try Element.init(self.allocator, "p");
            while (!self.match(.nl))
                try self.parseInline(p);
            try blockquote.addChild(p);
            try parent.addChild(blockquote);
        },
        .heading => {
            try self.temp_strings.append(try std.fmt.allocPrint(self.allocator, "h{d}", .{token.length}));
            const heading = try Element.init(self.allocator, self.temp_strings.items[self.temp_strings.items.len - 1]);
            while (!self.match(.nl))
                try self.parseInline(heading);
            try parent.addChild(heading);
        },
        .exclaim => {
            const alt = try self.eat(.bracket);
            const src = try self.eat(.paren);
            const img = try Element.init(self.allocator, "img");
            try img.addProp("alt", trim(self.raw[alt.start + 1..alt.start + alt.length - 1]));
            try img.addProp("src", trim(self.raw[src.start + 1..src.start + src.length - 1]));
            try parent.addChild(img);
        },
        .code_block => {
            const block = self.raw[token.start..token.start + token.length];
            const end = std.mem.indexOf(u8, block, "\n") orelse unreachable;
            try self.temp_strings.append(try std.fmt.allocPrint(self.allocator, "language-{s}", .{block[3..end]}));
            const pre = try Element.init(self.allocator, "pre");
            try pre.addProp("class", self.temp_strings.items[self.temp_strings.items.len - 1]);

            var lines = std.mem.splitScalar(u8, self.raw[token.start + end + 1 .. token.start + token.length - 4], '\n');
            while (lines.next()) |line| {
                var div = try Element.init(self.allocator, "div");
                try div.addProp("class", self.temp_strings.items[self.temp_strings.items.len - 1]);
                try div.addChild(try Element.textNode(self.allocator, if (line.len == 0) "\n" else line));
                try pre.addChild(div);
            }

            try parent.addChild(pre);
        },
        .ul => {
            const ul = try Element.init(self.allocator, "ul");
            var kind = token.kind;
            while (kind == .ul) {
                const li = try Element.init(self.allocator, "li");
                const next = self.peek();
                if (next.kind == .bracket and
                    next.length == 3 and
                    std.mem.eql(u8, self.raw[next.start + 1 .. next.start + 2], " "))
                {
                    const space = self.raw[self.peekAhead(1).start];
                    if (space == ' ') {}
                }
                while (!self.match(.nl)) 
                    try self.parseInline(li);
                try ul.addChild(li);
                kind = self.peek().kind;
            }
            try parent.addChild(ul);
        },
        else => {
            const p = try Element.init(self.allocator, "p");
            try p.addChild(try Element.textNode(self.allocator, self.raw[token.start .. token.start + token.length]));
            while (!self.match(.nl))
                try self.parseInline(p);
            try parent.addChild(p);
        }
    }
}

fn parseInline(self: *Self, parent: *Element) !void {
    var push = parent;
    const token = self.advance();
    switch (token.kind) {
        .code => {
            const code = try Element.init(self.allocator, "code");
            try code.addChild(try Element.textNode(self.allocator, self.raw[token.start + 1..token.start + token.length - 1]));
            try push.addChild(code);
        },
        .bracket => {
            // TODO: Recursive
            const a = try Element.init(self.allocator, "a");
            const source = try self.eat(.paren);
            const href = self.raw[source.start + 1..source.start + source.length - 1];
            if (!std.mem.startsWith(u8, href, "#") and !std.mem.startsWith(u8, href, "/"))
                try a.addProp("target", "_blank");
            try a.addProp("href", href);
            try a.addChild(try Element.textNode(self.allocator, self.raw[token.start + 1..token.start + token.length - 1]));
            try push.addChild(a);
        },
        // .star => {
        //     if (self.match(.star)) {
        //         _ = self.advance();

        //         const b = try Element.init(self.allocator, "b");

        //         // while (!self.match(.star) and !self.matchAhead(1, .star)) {
        //         //     if (self.matchAhead(1, .eof))
        //         //         std.debug.panic("this shouldn't happen", .{});  // ! This should fall through and attempt to parse as italic, not throw an error.
        //         //     try self.parseInline(&b);
        //         //     break;
        //         // }

        //         _ = try self.eat(.plain);
        //         _ = try self.eat(.star);
        //         try push.addChild(b);
        //         return;
        //     }

        //     const i = try Element.init(self.allocator, "i");
        //     while (!self.match(.star)) {
        //         if (self.isAtEnd())
        //             return ParserError.UnexpectedToken;
        //         try self.parseInline(i);
        //     }
        //     _ = try self.eat(.star);
        //     try push.addChild(i);
        // },
        else => {
            try push.addChild(try Element.textNode(self.allocator, self.raw[token.start..token.start + token.length]));
        }
    }
}

fn skipNewlines(self: *Self) void {
    while (self.consume(.nl)) {
        if (self.isAtEnd()) break;
    }
}

fn gather(self: *Self, kind: TokenType) Token {
    var token = self.advance();
    while (!self.match(kind)) {
        const next = self.advance();
        token.length += next.length;
    }
    return token;
}

fn same(self: *Self, kind: TokenType) ParserError!Token {
    if (!self.match(kind))
        return ParserError.UnexpectedToken;
    var token = self.advance();
    while (self.match(kind)) {
        const next = self.advance();
        token.length += next.length;
    }
    return token;
}

fn advance(self: *Self) Token {
    assert(self.current + 1 <= self.tokens.items.len);
    const token = self.tokens.items[self.current];
    self.current += 1;
    return token;
}

fn eat(self: *Self, kind: TokenType) ParserError!Token {
    assert(self.current < self.tokens.items.len);
    if (self.peek().kind == kind)
        return self.advance();
    return ParserError.UnexpectedToken;
}

fn peek(self: *Self) Token {
    assert(self.current < self.tokens.items.len);
    return self.tokens.items[self.current];
}

fn peekAhead(self: *Self, n: usize) Token {
    assert(self.current + n < self.tokens.items.len);
    return self.tokens.items[self.current + n];
}

fn match(self: *Self, kind: TokenType) bool {
    if (self.peek().kind == kind)
        return true;
    return false;
}

fn matchAhead(self: *Self, n: usize, kind: TokenType) bool {
    if (self.peekAhead(n).kind == kind)
        return true;
    return false;
}

fn consume(self: *Self, kind: TokenType) bool {
    if (self.peek().kind == kind) {
        _ = self.advance();
        return true;
    }
    return false;
}

fn isAtEnd(self: *Self) bool {
    return self.match(.eof);
}
