//! PostgreSQL's number templates (formatting.c, the NUM_* part):
//! to_char() of integers, floats and numerics, and to_number(). Pure
//! functions of their arguments; formatting.zig makes them SQL functions.
//!
//! The template is parsed as parse_format() and NUMDesc_prepare() do:
//! 9 0 . D G , S MI PL SG PR FM TH th L RN rn V EEEE (B, C, SP are read
//! and do nothing), "quoted text" with backslash escapes, other
//! characters copied (to_char) or skipped (to_number). The locale is C's:
//! the decimal point `.`, the group separator `,`, the currency symbol a
//! space, the signs `-` and `+`. NUM_processor() and its helpers are
//! ported as they are, quirks included (`FM9.9` of 0 is `0.`, a value
//! wider than the template is `#`s).
//!
//! A float is written as C's printf("%.*f") and ("%+.*e") write it: the
//! exact binary value rounded half to even (exactDigits()), its digits
//! limited to DBL_DIG (FLT_DIG for a real), as float8_to_char() does.

const std = @import("std");
const dec = @import("../decimal.zig");
const json = @import("json.zig");
const util = @import("../../sql/util.zig");

const Allocator = std.mem.Allocator;
const Dec = dec.Dec;

pub const Error = error{ OutOfMemory, Failed };

/// The error of a call of a number or a date/time template (also
/// dtformat.zig's): PostgreSQL's SQLSTATE, and the message with its
/// DETAIL and HINT.
pub const Diag = struct {
    state: [5]u8 = "22023".*,
    fields: util.ErrorFields = .{ .message = "" },

    /// The message `msg` (a DETAIL already given is kept).
    pub fn set(d: *Diag, comptime state: *const [5]u8, msg: []const u8) Error {
        d.state = state.*;
        d.fields.message = msg;
        return error.Failed;
    }
};

/// The bytes of the UTF-8 character at `i` (pg_mblen()).
pub const charLen = json.charLen;

/// get_th(): the ordinal suffix of the number whose text ends with
/// digit text `num` (also dtformat.zig's).
pub fn ordinal(num: []const u8, upper: bool) []const u8 {
    var k: usize = switch (num[num.len - 1]) {
        '1' => 0,
        '2' => 1,
        '3' => 2,
        else => 3,
    };
    if (num.len > 1 and num[num.len - 2] == '1') k = 3;
    const up = [_][]const u8{ "ST", "ND", "RD", "TH" };
    const lo = [_][]const u8{ "st", "nd", "rd", "th" };
    return if (upper) up[k] else lo[k];
}

// ============================================================ templates

const Id = enum { comma, dec, n0, n9, B, C, D, E, FM, G, L, MI, PL, PR, RN, SG, SP, S, TH, V, rn, th };

/// NUM_keywords, in its order: the first that is a prefix of the
/// template wins among those of the same first character.
const keywords = [_]struct { []const u8, Id }{
    .{ ",", .comma }, .{ ".", .dec },  .{ "0", .n0 },  .{ "9", .n9 },  .{ "B", .B },   .{ "C", .C },
    .{ "D", .D },     .{ "EEEE", .E }, .{ "FM", .FM }, .{ "G", .G },   .{ "L", .L },   .{ "MI", .MI },
    .{ "PL", .PL },   .{ "PR", .PR },  .{ "RN", .RN }, .{ "SG", .SG }, .{ "SP", .SP }, .{ "S", .S },
    .{ "TH", .TH },   .{ "V", .V },    .{ "b", .B },   .{ "c", .C },   .{ "d", .D },   .{ "eeee", .E },
    .{ "fm", .FM },   .{ "g", .G },    .{ "l", .L },   .{ "mi", .MI }, .{ "pl", .PL }, .{ "pr", .PR },
    .{ "rn", .rn },   .{ "sg", .SG },  .{ "sp", .SP }, .{ "s", .S },   .{ "th", .th }, .{ "v", .V },
};

const F_DECIMAL: u32 = 1 << 1;
const F_LDECIMAL: u32 = 1 << 2;
const F_ZERO: u32 = 1 << 3;
const F_BLANK: u32 = 1 << 4;
const F_FILLMODE: u32 = 1 << 5;
const F_LSIGN: u32 = 1 << 6;
const F_BRACKET: u32 = 1 << 7;
const F_MINUS: u32 = 1 << 8;
const F_PLUS: u32 = 1 << 9;
const F_ROMAN: u32 = 1 << 10;
const F_MULTI: u32 = 1 << 11;
const F_PLUS_POST: u32 = 1 << 12;
const F_MINUS_POST: u32 = 1 << 13;
const F_EEEE: u32 = 1 << 14;

const lsign_pre: i32 = -1;
const lsign_post: i32 = 1;
const lsign_none: i32 = 0;

/// NUMDesc: what the template asks for.
pub const Desc = struct {
    pre: i32 = 0,
    post: i32 = 0,
    lsign: i32 = lsign_none,
    flag: u32 = 0,
    pre_lsign_num: i32 = 0,
    multi: i32 = 0,
    zero_start: i32 = 0,
    zero_end: i32 = 0,

    fn has(d: Desc, f: u32) bool {
        return d.flag & f != 0;
    }
};

/// A FormatNode: a keyword, or a character (its bytes).
const Node = struct {
    id: ?Id = null,
    text: []const u8 = "",
};

pub const Template = struct {
    nodes: []Node,
    desc: Desc,
};

/// parse_format() of a number template, NUMDesc_prepare() on each
/// keyword.
pub fn parse(a: Allocator, fmt: []const u8, diag: *Diag) Error!Template {
    var nodes: std.ArrayList(Node) = .empty;
    var d: Desc = .{};
    var i: usize = 0;
    while (i < fmt.len) {
        if (keyword(fmt[i..])) |k| {
            try prepare(&d, k[1], diag);
            try nodes.append(a, .{ .id = k[1] });
            i += k[0].len;
            continue;
        }
        if (fmt[i] == '"') {
            i += 1;
            while (i < fmt.len) {
                if (fmt[i] == '"') {
                    i += 1;
                    break;
                }
                if (fmt[i] == '\\' and i + 1 < fmt.len) i += 1;
                const n = charLen(fmt, i);
                try nodes.append(a, .{ .text = fmt[i .. i + n] });
                i += n;
            }
            continue;
        }
        if (fmt[i] == '\\' and i + 1 < fmt.len and fmt[i + 1] == '"') i += 1;
        const n = charLen(fmt, i);
        try nodes.append(a, .{ .text = fmt[i .. i + n] });
        i += n;
    }
    return .{ .nodes = nodes.items, .desc = d };
}

fn keyword(s: []const u8) ?struct { []const u8, Id } {
    for (keywords) |k| {
        if (k[0][0] != s[0]) continue;
        if (std.mem.startsWith(u8, s, k[0])) return k;
    }
    return null;
}

fn syntax(diag: *Diag, msg: []const u8) Error {
    return diag.set("42601", msg);
}

/// NUMDesc_prepare().
fn prepare(num: *Desc, id: Id, diag: *Diag) Error!void {
    if (num.has(F_EEEE) and id != .E) return syntax(diag, "\"EEEE\" must be the last pattern used");
    switch (id) {
        .n9 => {
            if (num.has(F_BRACKET)) return syntax(diag, "\"9\" must be ahead of \"PR\"");
            if (num.has(F_MULTI)) {
                num.multi += 1;
            } else if (num.has(F_DECIMAL)) {
                num.post += 1;
            } else {
                num.pre += 1;
            }
        },
        .n0 => {
            if (num.has(F_BRACKET)) return syntax(diag, "\"0\" must be ahead of \"PR\"");
            if (!num.has(F_ZERO) and !num.has(F_DECIMAL)) {
                num.flag |= F_ZERO;
                num.zero_start = num.pre + 1;
            }
            if (!num.has(F_DECIMAL)) num.pre += 1 else num.post += 1;
            num.zero_end = num.pre + num.post;
        },
        .B => if (num.pre == 0 and num.post == 0 and !num.has(F_ZERO)) {
            num.flag |= F_BLANK;
        },
        .D, .dec => {
            if (id == .D) num.flag |= F_LDECIMAL;
            if (num.has(F_DECIMAL)) return syntax(diag, "multiple decimal points");
            if (num.has(F_MULTI)) return syntax(diag, "cannot use \"V\" and decimal point together");
            num.flag |= F_DECIMAL;
        },
        .FM => num.flag |= F_FILLMODE,
        .S => {
            if (num.has(F_LSIGN)) return syntax(diag, "cannot use \"S\" twice");
            if (num.has(F_PLUS) or num.has(F_MINUS) or num.has(F_BRACKET)) return syntax(diag, "cannot use \"S\" and \"PL\"/\"MI\"/\"SG\"/\"PR\" together");
            if (!num.has(F_DECIMAL)) {
                num.lsign = lsign_pre;
                num.pre_lsign_num = num.pre;
                num.flag |= F_LSIGN;
            } else if (num.lsign == lsign_none) {
                num.lsign = lsign_post;
                num.flag |= F_LSIGN;
            }
        },
        .MI => {
            if (num.has(F_LSIGN)) return syntax(diag, "cannot use \"S\" and \"MI\" together");
            num.flag |= F_MINUS;
            if (num.has(F_DECIMAL)) num.flag |= F_MINUS_POST;
        },
        .PL => {
            if (num.has(F_LSIGN)) return syntax(diag, "cannot use \"S\" and \"PL\" together");
            num.flag |= F_PLUS;
            if (num.has(F_DECIMAL)) num.flag |= F_PLUS_POST;
        },
        .SG => {
            if (num.has(F_LSIGN)) return syntax(diag, "cannot use \"S\" and \"SG\" together");
            num.flag |= F_MINUS | F_PLUS;
        },
        .PR => {
            if (num.has(F_LSIGN) or num.has(F_PLUS) or num.has(F_MINUS)) return syntax(diag, "cannot use \"PR\" and \"S\"/\"PL\"/\"MI\"/\"SG\" together");
            num.flag |= F_BRACKET;
        },
        .RN, .rn => {
            if (num.has(F_ROMAN)) return syntax(diag, "cannot use \"RN\" twice");
            num.flag |= F_ROMAN;
        },
        .V => {
            if (num.has(F_DECIMAL)) return syntax(diag, "cannot use \"V\" and decimal point together");
            num.flag |= F_MULTI;
        },
        .E => {
            if (num.has(F_EEEE)) return syntax(diag, "cannot use \"EEEE\" twice");
            if (num.has(F_BLANK) or num.has(F_FILLMODE) or num.has(F_LSIGN) or num.has(F_BRACKET) or
                num.has(F_MINUS) or num.has(F_PLUS) or num.has(F_ROMAN) or num.has(F_MULTI))
            {
                diag.fields.detail = "\"EEEE\" may only be used together with digit and decimal point patterns.";
                return syntax(diag, "\"EEEE\" is incompatible with other formats");
            }
            num.flag |= F_EEEE;
        },
        else => {},
    }
    if (num.has(F_ROMAN) and num.flag & ~(F_ROMAN | F_FILLMODE) != 0) {
        diag.fields.detail = "\"RN\" may only be used together with \"FM\".";
        return syntax(diag, "\"RN\" is incompatible with other formats");
    }
}

// ============================================================ processor

/// The C locale's symbols (NUM_prepare_locale()).
const decimal_point = ".";
const thousands_sep = ",";
const currency_symbol = " ";

/// NUMProc of to_char().
const Out = struct {
    a: Allocator,
    num: Desc,
    out: std.ArrayList(u8) = .empty,
    number: []const u8,
    number_p: usize = 0,
    sign: u8,
    sign_wrote: bool = false,
    num_count: i32 = 0,
    num_in: bool = false,
    num_curr: i32 = 0,
    out_pre_spaces: i32,
    last_relevant: ?usize = null,

    fn add(o: *Out, s: []const u8) Error!void {
        try o.out.appendSlice(o.a, s);
    }

    fn addByte(o: *Out, c: u8) Error!void {
        try o.out.append(o.a, c);
    }

    fn cur(o: *const Out) u8 {
        return if (o.number_p < o.number.len) o.number[o.number_p] else 0;
    }

    fn lastIsPoint(o: *const Out) bool {
        const lr = o.last_relevant orelse return false;
        return o.number[lr] == '.';
    }

    /// IS_PREDEC_SPACE(): '0.1' of 9.9 is ' .1'.
    fn predecSpace(o: *const Out) bool {
        return !o.num.has(F_ZERO) and o.number_p == 0 and o.number.len > 0 and o.number[0] == '0' and o.num.post != 0;
    }

    /// NUM_numpart_to_char().
    fn part(o: *Out, id: Id) Error!void {
        if (o.num.has(F_ROMAN)) return;
        o.num_in = false;
        if (!o.sign_wrote and
            (o.num_curr >= o.out_pre_spaces or (o.num.has(F_ZERO) and o.num.zero_start == o.num_curr)) and
            (!o.predecSpace() or o.lastIsPoint()))
        {
            if (o.num.has(F_LSIGN)) {
                if (o.num.lsign == lsign_pre) {
                    try o.add(if (o.sign == '-') "-" else "+");
                    o.sign_wrote = true;
                }
            } else if (o.num.has(F_BRACKET)) {
                try o.addByte(if (o.sign == '+') ' ' else '<');
                o.sign_wrote = true;
            } else if (o.sign == '+') {
                if (!o.num.has(F_FILLMODE)) try o.addByte(' ');
                o.sign_wrote = true;
            } else if (o.sign == '-') {
                try o.addByte('-');
                o.sign_wrote = true;
            }
        }
        if (id == .n9 or id == .n0 or id == .D or id == .dec) {
            if (o.num_curr < o.out_pre_spaces and (o.num.zero_start > o.num_curr or !o.num.has(F_ZERO))) {
                if (!o.num.has(F_FILLMODE)) try o.addByte(' ');
            } else if (o.num.has(F_ZERO) and o.num_curr < o.out_pre_spaces and o.num.zero_start <= o.num_curr) {
                try o.addByte('0');
                o.num_in = true;
            } else {
                if (o.cur() == '.') {
                    if (o.last_relevant == null or !o.lastIsPoint()) {
                        try o.add(decimal_point);
                    } else if (o.num.has(F_FILLMODE) and o.lastIsPoint()) {
                        try o.add(decimal_point);
                    }
                } else {
                    if (o.last_relevant != null and o.number_p > o.last_relevant.? and id != .n0) {
                        // Trailing zeros of FM.
                    } else if (o.predecSpace()) {
                        if (!o.num.has(F_FILLMODE)) {
                            try o.addByte(' ');
                        } else if (o.lastIsPoint()) {
                            try o.addByte('0');
                        }
                    } else {
                        try o.addByte(o.cur());
                        o.num_in = true;
                    }
                }
                if (o.cur() != 0) o.number_p += 1;
            }
            var end = o.num_count + @as(i32, @intFromBool(o.out_pre_spaces != 0)) + @as(i32, @intFromBool(o.num.has(F_DECIMAL)));
            if (o.last_relevant) |lr| if (lr == o.number_p) {
                end = o.num_curr;
            };
            if (o.num_curr + 1 == end) {
                if (o.sign_wrote and o.num.has(F_BRACKET)) {
                    try o.addByte(if (o.sign == '+') ' ' else '>');
                } else if (o.num.has(F_LSIGN) and o.num.lsign == lsign_post) {
                    try o.add(if (o.sign == '-') "-" else "+");
                }
            }
        }
        o.num_curr += 1;
    }
};

/// get_last_relevant_decnum(): the last digit after the point that is
/// not 0, else the point; null without a point.
fn lastRelevant(num: []const u8) ?usize {
    const p = std.mem.indexOfScalar(u8, num, '.') orelse return null;
    var r = p;
    for (num[p + 1 ..], p + 1..) |c, i| if (c != '0') {
        r = i;
    };
    return r;
}

/// get_th(): the ordinal suffix of the number `num` ends with.
fn th(a: Allocator, num: []const u8, upper: bool, diag: *Diag) Error![]const u8 {
    const last = if (num.len > 0) num[num.len - 1] else 0;
    if (!std.ascii.isDigit(last)) return diag.set("22P02", try std.fmt.allocPrint(a, "\"{s}\" is not a number", .{num}));
    return ordinal(num, upper);
}

/// NUM_processor() of to_char(): the template filled with `number` (the
/// digits, a point, no sign; or a Roman numeral; or EEEE's text).
fn toChar(a: Allocator, t: Template, num_in: Desc, number: []const u8, out_pre_spaces: i32, sign: u8, diag: *Diag) Error![]u8 {
    var o: Out = .{ .a = a, .num = num_in, .number = number, .sign = sign, .out_pre_spaces = out_pre_spaces };
    if (o.num.zero_start != 0) o.num.zero_start -= 1;
    if (o.num.has(F_EEEE)) return a.dupe(u8, number);
    if (o.num.has(F_PLUS) or o.num.has(F_MINUS)) {
        o.sign_wrote = !(o.num.has(F_PLUS) and !o.num.has(F_MINUS));
    } else {
        if (o.sign != '-' and o.num.has(F_FILLMODE)) o.num.flag &= ~F_BRACKET;
        o.sign_wrote = o.sign == '+' and o.num.has(F_FILLMODE) and !o.num.has(F_LSIGN);
        if (o.num.lsign == lsign_pre and o.num.pre == o.num.pre_lsign_num) o.num.lsign = lsign_post;
    }
    o.num_count = o.num.post + o.num.pre - 1;
    if (o.num.has(F_FILLMODE) and o.num.has(F_DECIMAL)) {
        o.last_relevant = lastRelevant(number);
        if (o.last_relevant) |lr| if (o.num.zero_end > o.out_pre_spaces) {
            const lz: usize = @intCast(@min(@as(i64, @intCast(number.len)) - 1, o.num.zero_end - o.out_pre_spaces));
            if (lr < lz) o.last_relevant = lz;
        };
    }
    if (!o.sign_wrote and o.out_pre_spaces == 0) o.num_count += 1;

    for (t.nodes) |n| {
        const id = n.id orelse {
            try o.add(n.text);
            continue;
        };
        switch (id) {
            .n9, .n0, .dec, .D => try o.part(id),
            .comma => if (!o.num_in) {
                if (!o.num.has(F_FILLMODE)) try o.addByte(' ');
            } else try o.addByte(','),
            .G => if (!o.num_in) {
                if (!o.num.has(F_FILLMODE)) try o.addByte(' ');
            } else try o.add(thousands_sep),
            .L => try o.add(currency_symbol),
            .RN, .rn => {
                var buf: [16]u8 = undefined;
                const r = if (id == .rn) std.ascii.lowerString(&buf, o.number[o.number_p..]) else o.number[o.number_p..];
                if (!o.num.has(F_FILLMODE) and r.len < 15) try o.out.appendNTimes(a, ' ', 15 - r.len);
                try o.add(r);
            },
            .th, .TH => {
                if (o.num.has(F_ROMAN) or (number.len > 0 and number[0] == '#') or o.sign == '-' or o.num.has(F_DECIMAL)) continue;
                try o.add(try th(a, number, id == .TH, diag));
            },
            .MI => if (o.sign == '-') try o.addByte('-') else if (!o.num.has(F_FILLMODE)) try o.addByte(' '),
            .PL => if (o.sign == '+') try o.addByte('+') else if (!o.num.has(F_FILLMODE)) try o.addByte(' '),
            .SG => try o.addByte(o.sign),
            else => {},
        }
    }
    // A digit written past the end of the number is C's '\0': the
    // text ends there (strlen()).
    const z = o.out.items;
    return z[0 .. std.mem.indexOfScalar(u8, z, 0) orelse z.len];
}

/// `n` '#'s with a point after `pre` of them (a value wider than the
/// template).
fn hashes(a: Allocator, pre: i32, post: i32) Error![]u8 {
    const n: usize = @intCast(pre + post + 1);
    const z = try a.alloc(u8, n);
    @memset(z, '#');
    z[@intCast(pre)] = '.';
    return z;
}

/// EEEE's text of NaN and infinities: '#'s, a space first and a point.
fn eeeeHashes(a: Allocator, pre: i32, post: i32) Error![]u8 {
    const n: usize = @intCast(pre + post + 6);
    const z = try a.alloc(u8, n);
    @memset(z, '#');
    z[0] = ' ';
    z[@intCast(pre + 1)] = '.';
    return z;
}

/// int_to_roman(): 1..3999, else 15 '#'s.
fn roman(a: Allocator, v: i64) Error![]u8 {
    if (v < 1 or v > 3999) {
        const z = try a.alloc(u8, 15);
        @memset(z, '#');
        return z;
    }
    const rm1 = [_][]const u8{ "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX" };
    const rm10 = [_][]const u8{ "X", "XX", "XXX", "XL", "L", "LX", "LXX", "LXXX", "XC" };
    const rm100 = [_][]const u8{ "C", "CC", "CCC", "CD", "D", "DC", "DCC", "DCCC", "CM" };
    var out: std.ArrayList(u8) = .empty;
    var x: usize = @intCast(v);
    try out.appendNTimes(a, 'M', x / 1000);
    x %= 1000;
    if (x / 100 > 0) try out.appendSlice(a, rm100[x / 100 - 1]);
    x %= 100;
    if (x / 10 > 0) try out.appendSlice(a, rm10[x / 10 - 1]);
    x %= 10;
    if (x > 0) try out.appendSlice(a, rm1[x - 1]);
    return out.items;
}

/// The sign and digits of a number's text: what numstr is after the
/// sign is taken off, and the digits before its point.
const Split = struct { sign: u8, digits: []const u8, pre_len: i32 };

fn split(z: []const u8) Split {
    const neg = z.len > 0 and z[0] == '-';
    const digits = if (neg) z[1..] else z;
    const pre = std.mem.indexOfScalar(u8, digits, '.') orelse digits.len;
    return .{ .sign = if (neg) '-' else '+', .digits = digits, .pre_len = @intCast(pre) };
}

/// The common end of the to_char()s of numbers: numstr padded or made
/// '#'s, then the processor.
fn finish(a: Allocator, t: Template, num: Desc, s: Split, diag: *Diag) Error![]u8 {
    var out_pre: i32 = 0;
    var numstr = s.digits;
    if (s.pre_len < num.pre) {
        out_pre = num.pre - s.pre_len;
    } else if (s.pre_len > num.pre) {
        numstr = try hashes(a, num.pre, num.post);
    }
    return toChar(a, t, num, numstr, out_pre, s.sign, diag);
}

/// numeric_to_char().
pub fn numericToChar(a: Allocator, t: Template, value: Dec, diag: *Diag) Error![]u8 {
    var num = t.desc;
    if (num.has(F_ROMAN)) {
        const r = dec.round(a, value, 0) catch |e| return oom(e);
        const v = dec.toInt(a, r) catch std.math.maxInt(i32);
        const iv: i64 = if (v > std.math.maxInt(i32) or v < std.math.minInt(i32)) std.math.maxInt(i32) else v;
        return toChar(a, t, num, try roman(a, iv), 0, 0, diag);
    }
    if (num.has(F_EEEE)) {
        if (value.kind != .finite) return toChar(a, t, num, try eeeeHashes(a, num.pre, num.post), 0, 0, diag);
        const z = try sci(a, value, num.post);
        const numstr = if (z[0] != '-') try std.mem.concat(a, u8, &.{ " ", z }) else z;
        return toChar(a, t, num, numstr, 0, 0, diag);
    }
    var val = value;
    if (num.has(F_MULTI)) {
        if (val.kind == .finite and val.digits.len > 0) val.point += num.multi;
        num.pre += num.multi;
    }
    const x = dec.round(a, val, num.post) catch |e| return oom(e);
    const z = dec.toText(a, x) catch |e| return oom(e);
    return finish(a, t, num, split(z), diag);
}

fn oom(e: dec.Error) Error {
    return if (e == error.OutOfMemory) error.OutOfMemory else error.Failed;
}

/// numeric_out_sci(): d.ddd (`scale` digits after the point, rounded half
/// away from zero) e+XX.
fn sci(a: Allocator, d: Dec, scale_in: i32) Error![]u8 {
    const scale: i32 = @max(scale_in, 0);
    var exponent: i32 = 0;
    var sig = d;
    if (d.digits.len > 0) {
        exponent = d.point - 1;
        sig.point = 1;
    }
    const r = dec.round(a, sig, scale) catch |e| return oom(e);
    const z = dec.toText(a, r) catch |e| return oom(e);
    const sign: u8 = if (exponent < 0) '-' else '+';
    return std.fmt.allocPrint(a, "{s}e{c}{d:0>2}", .{ z, sign, @abs(exponent) });
}

/// int4_to_char() (`wide` false: int2 and int4) and int8_to_char().
pub fn intToChar(a: Allocator, t: Template, value_in: i64, wide: bool, diag: *Diag) Error![]u8 {
    var num = t.desc;
    var value = value_in;
    if (num.has(F_ROMAN)) {
        const iv: i64 = if (value > std.math.maxInt(i32) or value < std.math.minInt(i32)) std.math.maxInt(i32) else value;
        return toChar(a, t, num, try roman(a, iv), 0, 0, diag);
    }
    if (num.has(F_EEEE)) {
        if (!wide) {
            var z = try fmtExp(a, @floatFromInt(value), @intCast(@max(num.post, 0)));
            if (z[0] == '+') z[0] = ' ';
            return toChar(a, t, num, z, 0, 0, diag);
        }
        const d = dec.fromInt(a, value) catch |e| return oom(e);
        const z = try sci(a, d, num.post);
        const numstr = if (z[0] != '-') try std.mem.concat(a, u8, &.{ " ", z }) else z;
        return toChar(a, t, num, numstr, 0, 0, diag);
    }
    if (num.has(F_MULTI)) {
        const range = if (wide) "bigint out of range" else "integer out of range";
        // dtoi4()/dtoi8() of 10^multi, then int4mul()/int8mul().
        const multi = std.math.pow(f64, 10, @floatFromInt(num.multi));
        const lim: f64 = if (wide) 0x1p63 else 0x1p31;
        if (!(multi < lim)) return diag.set("22003", range);
        const m: i64 = @intFromFloat(multi);
        value = std.math.mul(i64, value, m) catch return diag.set("22003", range);
        if (!wide and (value > std.math.maxInt(i32) or value < std.math.minInt(i32))) return diag.set("22003", range);
        num.pre += num.multi;
    }
    var buf: [24]u8 = undefined;
    const orgnum = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
    var s = split(orgnum);
    if (num.post > 0) {
        const z = try a.alloc(u8, s.digits.len + 1 + @as(usize, @intCast(num.post)));
        @memcpy(z[0..s.digits.len], s.digits);
        z[s.digits.len] = '.';
        @memset(z[s.digits.len + 1 ..], '0');
        s.digits = z;
    } else {
        s.digits = try a.dupe(u8, s.digits);
    }
    return finish(a, t, num, s, diag);
}

/// float4_to_char() (`real`) and float8_to_char().
pub fn floatToChar(a: Allocator, t: Template, value_in: f64, real: bool, diag: *Diag) Error![]u8 {
    var num = t.desc;
    const value: f64 = if (real) @floatCast(@as(f32, @floatCast(value_in))) else value_in;
    if (num.has(F_ROMAN)) {
        const r = @round(value);
        // rint(): half to even.
        const rv = if (@abs(value - @trunc(value)) == 0.5) 2 * @round(value / 2) else r;
        const iv: i64 = if (!std.math.isNan(rv) and rv >= -2147483648.0 and rv < 2147483648.0) @intFromFloat(rv) else std.math.maxInt(i32);
        return toChar(a, t, num, try roman(a, iv), 0, 0, diag);
    }
    if (num.has(F_EEEE)) {
        if (std.math.isNan(value) or std.math.isInf(value)) return toChar(a, t, num, try eeeeHashes(a, num.pre, num.post), 0, 0, diag);
        const z = try fmtExp(a, value, @intCast(@max(num.post, 0)));
        if (z[0] == '+') z[0] = ' ';
        return toChar(a, t, num, z, 0, 0, diag);
    }
    var val = value;
    if (num.has(F_MULTI)) {
        if (real) {
            const m: f32 = @floatCast(std.math.pow(f64, 10, @floatFromInt(num.multi)));
            val = @as(f32, @floatCast(value)) * m;
        } else {
            val = value * std.math.pow(f64, 10, @floatFromInt(num.multi));
        }
        num.pre += num.multi;
    }
    const dig: i32 = if (real) 6 else 15;
    // The digits before the point of "%.0f" of |val|: the expansion of
    // val once, rounded twice.
    const finite = !std.math.isNan(val) and !std.math.isInf(val);
    const x: Exact = if (finite and val != 0) try exactDigits(a, val) else .zero;
    const pre_len: i32 = if (!finite) @intCast((try fmtFixed(a, @abs(val), 0)).len) else blk: {
        const r = try roundExact(a, x, x.point);
        break :blk if (r.point <= 0 or r.digits.len == 0) 1 else @intCast(r.point);
    };
    if (pre_len >= dig) {
        num.post = 0;
    } else if (pre_len + num.post > dig) {
        num.post = dig - pre_len;
    }
    const prec: usize = @intCast(@max(num.post, 0));
    const z = if (finite) try fixed(a, val, x, prec) else try fmtFixed(a, val, prec);
    return finish(a, t, num, split(z), diag);
}

// ============================================================ to_number

/// numeric_to_number(): the number `in` spells in the template.
pub fn toNumber(a: Allocator, t: Template, in: []const u8, diag: *Diag) Error!Dec {
    var num = t.desc;
    if (num.zero_start != 0) num.zero_start -= 1;
    if (num.has(F_EEEE)) return diag.set("0A000", "\"EEEE\" not supported for input");
    var r: Reader = .{ .num = &num, .in = in };
    try r.number.append(a, ' ');
    var i: usize = 0;
    while (i < t.nodes.len) : (i += 1) {
        const n = t.nodes[i];
        if (r.p >= in.len) break;
        const id = n.id orelse {
            r.p += charLen(in, r.p);
            continue;
        };
        switch (id) {
            .n9, .n0, .dec, .D => try r.part(a, id),
            .comma => {
                if (num.has(F_FILLMODE)) continue;
                if (in[r.p] != ',') continue;
            },
            .G => {
                if (num.has(F_FILLMODE)) continue;
                if (!std.mem.startsWith(u8, in[r.p..], thousands_sep)) continue;
            },
            .L => {
                r.eatNonData(1);
                continue;
            },
            .RN, .rn => {
                const v = r.romanToInt() orelse return diag.set("22P02", "invalid Roman numeral");
                const before = r.number.items.len;
                try r.number.print(a, "{d}", .{v});
                num.pre = @intCast(r.number.items.len - before);
                num.post = 0;
                continue;
            },
            .th, .TH => {
                if (num.has(F_ROMAN) or r.number.items[0] == '#' or num.has(F_DECIMAL)) continue;
                r.eatNonData(2);
                continue;
            },
            .MI => if (in[r.p] == '-') {
                r.number.items[0] = '-';
            } else {
                r.eatNonData(1);
                continue;
            },
            .PL => if (in[r.p] == '+') {
                r.number.items[0] = '+';
            } else {
                r.eatNonData(1);
                continue;
            },
            .SG => if (in[r.p] == '-' or in[r.p] == '+') {
                r.number.items[0] = in[r.p];
            } else {
                r.eatNonData(1);
                continue;
            },
            else => continue,
        }
        r.p += 1;
    }
    var numstr = r.number.items;
    if (numstr.len > 0 and numstr[numstr.len - 1] == '.') numstr = numstr[0 .. numstr.len - 1];
    num.post = r.read_post;
    const scale = num.post;
    const precision = num.pre + num.multi + scale;
    var d = dec.parse(a, numstr) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => return diag.set("22P02", try std.fmt.allocPrint(a, "invalid input syntax for type numeric: \"{s}\"", .{numstr})),
        else => return diag.set("22003", "value overflows numeric format"),
    };
    d = dec.applyTypmod(a, d, precision, scale) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            var buf: [160]u8 = undefined;
            diag.fields.detail = try a.dupe(u8, dec.overflowDetail(&buf, d, precision, scale));
            return diag.set("22003", "numeric field overflow");
        },
    };
    if (num.has(F_MULTI)) {
        // numeric_mul() by numeric_power(10, -multi), of display scale
        // 16 + multi.
        if (d.digits.len > 0) d.point -= num.multi;
        d.dscale += @intCast(16 + num.multi);
        dec.check(d) catch return diag.set("22003", "value overflows numeric format");
    }
    return d;
}

/// NUMProc of to_number().
const Reader = struct {
    num: *Desc,
    in: []const u8,
    p: usize = 0,
    /// number[0] is the sign (' ' for none).
    number: std.ArrayList(u8) = .empty,
    read_dec: bool = false,
    read_post: i32 = 0,
    read_pre: i32 = 0,

    fn at(r: *const Reader, i: usize) u8 {
        return if (i < r.in.len) r.in[i] else 0;
    }

    /// NUM_eat_non_data_chars().
    fn eatNonData(r: *Reader, n_in: usize) void {
        var n = n_in;
        while (n > 0) : (n -= 1) {
            if (r.p >= r.in.len) break;
            if (std.mem.indexOfScalar(u8, "0123456789.,+-", r.in[r.p]) != null) break;
            r.p += charLen(r.in, r.p);
        }
    }

    /// NUM_numpart_from_char().
    fn part(r: *Reader, a: Allocator, id: Id) Error!void {
        const num = r.num;
        if (r.p >= r.in.len) return;
        if (r.in[r.p] == ' ') r.p += 1;
        if (r.p >= r.in.len) return;
        if (r.number.items[0] == ' ' and (id == .n0 or id == .n9) and r.read_pre + r.read_post == 0) {
            if (num.has(F_LSIGN) and num.lsign == lsign_pre) {
                if (r.in[r.p] == '-') {
                    r.p += 1;
                    r.number.items[0] = '-';
                } else if (r.in[r.p] == '+') {
                    r.p += 1;
                    r.number.items[0] = '+';
                }
            } else {
                if (r.in[r.p] == '-' or (num.has(F_BRACKET) and r.in[r.p] == '<')) {
                    r.number.items[0] = '-';
                    r.p += 1;
                } else if (r.in[r.p] == '+') {
                    r.number.items[0] = '+';
                    r.p += 1;
                }
            }
        }
        if (r.p >= r.in.len) return;
        var isread = false;
        if (std.ascii.isDigit(r.in[r.p])) {
            if (r.read_dec and r.read_post == num.post) return;
            try r.number.append(a, r.in[r.p]);
            if (r.read_dec) r.read_post += 1 else r.read_pre += 1;
            isread = true;
        } else if (num.has(F_DECIMAL) and !r.read_dec) {
            if (r.in[r.p] == '.') {
                try r.number.append(a, '.');
                r.read_dec = true;
                isread = true;
            }
        }
        if (r.p >= r.in.len) return;
        if (r.number.items[0] == ' ' and r.read_pre + r.read_post > 0) {
            if (num.has(F_LSIGN) and isread and r.p + 1 < r.in.len and !std.ascii.isDigit(r.in[r.p + 1])) {
                const c = r.in[r.p + 1];
                if (c == '-' or c == '+') {
                    r.p += 1;
                    r.number.items[0] = c;
                }
            } else if (!isread and !num.has(F_LSIGN) and (num.has(F_PLUS) or num.has(F_MINUS))) {
                if (r.in[r.p] == '-' or r.in[r.p] == '+') r.number.items[0] = r.in[r.p];
            }
        }
    }

    /// roman_to_int(): null if invalid.
    fn romanToInt(r: *Reader) ?i32 {
        while (r.p < r.in.len and std.ascii.isWhitespace(r.in[r.p])) r.p += 1;
        var chars: [15]u8 = undefined;
        var vals: [15]i32 = undefined;
        var len: usize = 0;
        while (len < 15 and r.p < r.in.len) : (len += 1) {
            const c = std.ascii.toUpper(r.in[r.p]);
            const v = romanVal(c);
            if (v == 0) break;
            chars[len] = c;
            vals[len] = v;
            r.p += 1;
        }
        if (len == 0) return null;
        var result: i32 = 0;
        var repeat: i32 = 1;
        var v_count: i32 = 0;
        var l_count: i32 = 0;
        var d_count: i32 = 0;
        var subtracted = false;
        var last_sub: i32 = 0;
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const c = chars[i];
            const v = vals[i];
            if (subtracted and v >= last_sub) return null;
            if ((v_count != 0 and v >= 5) or (l_count != 0 and v >= 50) or (d_count != 0 and v >= 500)) return null;
            if (c == 'V') v_count += 1 else if (c == 'L') l_count += 1 else if (c == 'D') d_count += 1;
            if (i < len - 1) {
                const nc = chars[i + 1];
                const nv = vals[i + 1];
                if (v < nv) {
                    const ok = (c == 'I' and (nc == 'V' or nc == 'X')) or (c == 'X' and (nc == 'L' or nc == 'C')) or (c == 'C' and (nc == 'D' or nc == 'M'));
                    if (!ok) return null;
                    if (repeat > 1) return null;
                    if ((v_count != 0 and nv >= 5) or (l_count != 0 and nv >= 50) or (d_count != 0 and nv >= 500)) return null;
                    if (nc == 'V') v_count += 1 else if (nc == 'L') l_count += 1 else if (nc == 'D') d_count += 1;
                    i += 1;
                    repeat = 1;
                    subtracted = true;
                    last_sub = v;
                    result += nv - v;
                } else {
                    if (c == nc) {
                        repeat += 1;
                        if (repeat > 3) return null;
                    } else repeat = 1;
                    result += v;
                }
            } else {
                result += v;
            }
        }
        return result;
    }
};

fn romanVal(c: u8) i32 {
    return switch (c) {
        'I' => 1,
        'V' => 5,
        'X' => 10,
        'L' => 50,
        'C' => 100,
        'D' => 500,
        'M' => 1000,
        else => 0,
    };
}

// ================================================================ floats

/// The exact decimal value of finite `v` (not 0): digits 0..9 (the first
/// not 0), value 0.d1 d2 ... x 10^point.
const Exact = struct {
    digits: []u8,
    point: i64,

    /// Of 0: no digits.
    const zero: Exact = .{ .digits = &.{}, .point = 0 };
};

fn exactDigits(a: Allocator, v: f64) Error!Exact {
    const bits: u64 = @bitCast(@abs(v));
    const biased: i64 = @intCast(bits >> 52);
    var m: u64 = bits & ((1 << 52) - 1);
    var e2: i64 = undefined;
    if (biased == 0) {
        e2 = -1074;
    } else {
        m |= 1 << 52;
        e2 = biased - 1075;
    }
    const Big = std.math.big.int.Managed;
    var n = Big.initSet(a, m) catch return error.OutOfMemory;
    defer n.deinit();
    var k: i64 = 0;
    if (e2 >= 0) {
        n.shiftLeft(&n, @intCast(e2)) catch return error.OutOfMemory;
    } else {
        k = -e2;
        var five = Big.initSet(a, 5) catch return error.OutOfMemory;
        defer five.deinit();
        var p = Big.init(a) catch return error.OutOfMemory;
        defer p.deinit();
        p.pow(&five, @intCast(k)) catch return error.OutOfMemory;
        var r = Big.init(a) catch return error.OutOfMemory;
        defer r.deinit();
        r.mul(&n, &p) catch return error.OutOfMemory;
        n.swap(&r);
    }
    const z = n.toString(a, 10, .lower) catch return error.OutOfMemory;
    for (z) |*c| c.* -= '0';
    return .{ .digits = z, .point = @as(i64, @intCast(z.len)) - k };
}

/// Digits `x` rounded to keep those of powers down to 10^-keep_frac, half
/// to even: the digits (leading ones may be 0) of 10^(point) ... and the
/// point after rounding.
fn roundExact(a: Allocator, x: Exact, keep: i64) Error!Exact {
    // `keep`: the number of digits of x.digits kept (may be <= 0).
    if (keep >= x.digits.len) return x;
    var up = false;
    if (keep >= 0) {
        const next = x.digits[@intCast(keep)];
        if (next > 5) {
            up = true;
        } else if (next == 5) {
            var rest_zero = true;
            for (x.digits[@intCast(keep + 1)..]) |c| if (c != 0) {
                rest_zero = false;
            };
            up = !rest_zero or (keep > 0 and x.digits[@intCast(keep - 1)] % 2 == 1);
        }
    }
    if (keep <= 0) {
        if (!up) return .{ .digits = &.{}, .point = x.point };
        const one = try a.dupe(u8, &.{1});
        return .{ .digits = one, .point = x.point - keep + 1 };
    }
    const kept = try a.alloc(u8, @intCast(keep + 1));
    kept[0] = 0;
    @memcpy(kept[1..], x.digits[0..@intCast(keep)]);
    if (up) {
        var i = kept.len;
        while (i > 0) {
            i -= 1;
            if (kept[i] == 9) {
                kept[i] = 0;
            } else {
                kept[i] += 1;
                break;
            }
        }
    }
    if (kept[0] == 0) return .{ .digits = kept[1..], .point = x.point };
    return .{ .digits = kept, .point = x.point + 1 };
}

/// printf("%.*f", prec, v), PostgreSQL's (src/port/snprintf.c: NaN,
/// Infinity, -Infinity).
pub fn fmtFixed(a: Allocator, v: f64, prec: usize) Error![]u8 {
    if (std.math.isNan(v)) return a.dupe(u8, "NaN");
    if (std.math.isInf(v)) return a.dupe(u8, if (v < 0) "-Infinity" else "Infinity");
    return fixed(a, v, if (v != 0) try exactDigits(a, v) else .zero, prec);
}

/// fmtFixed() of finite `v`, whose exact digits are `exact`.
fn fixed(a: Allocator, v: f64, exact: Exact, prec: usize) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    if (std.math.signbit(v)) try out.append(a, '-');
    const x = try roundExact(a, exact, exact.point + @as(i64, @intCast(prec)));
    const digitAt = struct {
        fn f(e: Exact, p: i64) u8 {
            // The digit of power 10^p.
            const i = e.point - 1 - p;
            if (i < 0 or i >= e.digits.len) return 0;
            return e.digits[@intCast(i)];
        }
    }.f;
    if (x.point <= 0 or x.digits.len == 0) {
        try out.append(a, '0');
    } else {
        var p: i64 = x.point - 1;
        while (p >= 0) : (p -= 1) try out.append(a, '0' + digitAt(x, p));
    }
    if (prec > 0) {
        try out.append(a, '.');
        var p: i64 = -1;
        while (p >= -@as(i64, @intCast(prec))) : (p -= 1) try out.append(a, '0' + digitAt(x, p));
    }
    return out.items;
}

/// printf("%+.*e", prec, v) of finite `v`.
pub fn fmtExp(a: Allocator, v: f64, prec: usize) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, if (std.math.signbit(v)) '-' else '+');
    var exp: i64 = 0;
    var digits: []const u8 = &.{};
    if (v != 0) {
        const x = try exactDigits(a, v);
        const r = try roundExact(a, x, @intCast(prec + 1));
        digits = r.digits;
        exp = r.point - 1;
    }
    try out.append(a, '0' + (if (digits.len > 0) digits[0] else 0));
    if (prec > 0) {
        try out.append(a, '.');
        for (1..prec + 1) |i| try out.append(a, '0' + (if (i < digits.len) digits[i] else 0));
    }
    try out.print(a, "e{c}{d:0>2}", .{ @as(u8, if (exp < 0) '-' else '+'), @abs(exp) });
    return out.items;
}

// ================================================================ tests

const testing = std.testing;

fn expectNum(fmt: []const u8, v: []const u8, want: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diag = .{};
    const t = try parse(a, fmt, &diag);
    const d = try dec.parse(a, v);
    try testing.expectEqualStrings(want, try numericToChar(a, t, d, &diag));
}

fn expectInt(fmt: []const u8, v: i64, wide: bool, want: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diag = .{};
    const t = try parse(a, fmt, &diag);
    try testing.expectEqualStrings(want, try intToChar(a, t, v, wide, &diag));
}

fn expectFloat(fmt: []const u8, v: f64, real: bool, want: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diag = .{};
    const t = try parse(a, fmt, &diag);
    try testing.expectEqualStrings(want, try floatToChar(a, t, v, real, &diag));
}

fn expectToNumber(in: []const u8, fmt: []const u8, want: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diag = .{};
    const t = try parse(a, fmt, &diag);
    const d = try toNumber(a, t, in, &diag);
    try testing.expectEqualStrings(want, try dec.toText(a, d));
}

test "numformat: to_char of numerics, integers and floats" {
    try expectNum("9G999G999G999G999G999", "-34338492", "           -34,338,492");
    try expectNum("FM9999999999999999.999999999999999THPR", "-34338492.215397047", "<34338492.215397047>");
    try expectNum("9.999EEEE", "-34338492.215397047", "-3.434e+07");
    try expectNum("FMRN", "4.31", "IV");
    try expectNum("FM999.", "100", "100");
    try expectNum("FM999.9", "100", "100.");
    try expectNum("foo999", "100", "foo 100");
    try expectNum("f\"ool\\\"999", "100", "fool\"999");
    try expectInt("9G999G999G999G999G999", 4567890123456789, true, " 4,567,890,123,456,789");
    try expectInt("FM9999999999999999THPR", 4567890123456789, true, "4567890123456789TH");
    try expectInt("SG9999999999999999th", -4567890123456789, true, "-4567890123456789");
    try expectInt("9.99EEEE", 1234, false, " 1.23e+03");
    try expectInt("99999V99", 1234, false, "  123400");
    try expectInt("FMRN", 456, true, "CDLVI");
    try expectFloat("FM9999999999D9999900000000000000000", 12345678901, false, "##########.####");
    try expectFloat("rn", 1235, true, "        mccxxxv");
    try expectFloat("99999V99", 1234.56, true, "  123456");
}

test "numformat: to_number" {
    try expectToNumber("-34,338,492", "99G999G999", "-34338492");
    try expectToNumber("<564646.654564>", "999999.999999PR", "-564646.654564");
    try expectToNumber("0.00001-", "9.999999S", "-0.00001");
    try expectToNumber("5.01-", "FM9.999999MI", "-5.01");
    try expectToNumber(".0", "99999999.99999999", "0.0");
    try expectToNumber("$1,234.56", "L99,999.99", "1234.56");
    try expectToNumber("42nd", "99th", "42");
    try expectToNumber("123456", "99999V99", "1234.560000000000000000");
    try expectToNumber("CvIiI", "rn", "108");
}

test "numformat: printf of doubles" {
    const a = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const x = arena.allocator();
    try testing.expectEqualStrings("0.12", try fmtFixed(x, 0.125, 2));
    try testing.expectEqualStrings("2.67", try fmtFixed(x, 2.675, 2));
    try testing.expectEqualStrings("2", try fmtFixed(x, 2.5, 0));
    try testing.expectEqualStrings("4", try fmtFixed(x, 3.5, 0));
    try testing.expectEqualStrings("-0.00", try fmtFixed(x, -0.001, 2));
    try testing.expectEqualStrings("+1.234e+03", try fmtExp(x, 1234.5, 3));
    try testing.expectEqualStrings("+0.000e+00", try fmtExp(x, 0, 3));
    try testing.expectEqualStrings("-4.200e+00", try fmtExp(x, -4.2, 3));
}
