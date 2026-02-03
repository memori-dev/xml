const std = @import("std");

// https://www.w3.org/TR/2008/REC-xml-20081126/
// https://github.com/ianprime0509/zig-xml

const expect = std.testing.expect;
const assert = std.debug.assert;

pub const Attribute = std.ArrayListUnmanaged(u8);
pub const Chardata = std.ArrayListUnmanaged(u8);

pub const ChardataContainer = struct {
	const Self = @This();

	chardata: Chardata = .{},

	pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
		self.chardata.deinit(alloc);
	}
};

// also test order does not important
fn testAttrs(comptime T: type, comptime attrs: []const struct{[]const u8, []const u8}, alloc: std.mem.Allocator) !void {
	const fields = std.meta.fields(T);
	var buf: [2048]u8 = undefined;
	var len: usize = 0;

	// none
	{
		var out = T {};
		defer out.deinit(alloc);
		const r = std.Io.Reader.fixed(">");
		var rdr = Reader{.reader = r};
		try parseAttrs(T, alloc, &out, &rdr, false);
		inline for (fields) |f| if (@TypeOf(f) == Attribute) expect(@field(out, f.name).items.len == 0);
	}

	// combinations
	inline for (0..attrs.len) |i| {
		try expect(@hasField(T, attrs[i][0]));

		len = (try std.fmt.bufPrint(&buf, " {s}=\"{s}\"", .{attrs[i][0], attrs[i][1]})).len;

		// individual
		{
			buf[len] = '>';
			len += 1;
			var out = T {};
			defer out.deinit(alloc);
			const r = std.Io.Reader.fixed(buf[0..len]);
			var rdr = Reader{.reader = r};
			try parseAttrs(T, alloc, &out, &rdr, false);

			len -= 1;

			inline for (fields) |f| if (@TypeOf(f) == Attribute) expect(@field(out, f.name).items.len == 0);
		}

		// combos - next index onwards
		if (i + 1 == attrs.len) break;
		for (i + 1..attrs.len) |j| {
			len += (try std.fmt.bufPrint(buf[len..], " {s}=\"{s}\"", .{attrs[j][0], attrs[j][1]})).len;

			buf[len] = '>';
			len += 1;
			var out = T {};
			defer out.deinit(alloc);
			const r = std.Io.Reader.fixed(buf[0..len]);
			var rdr = Reader{.reader = r};
			try parseAttrs(T, alloc, &out, &rdr, false);
			len -= 1;
		}
	}
}

pub const Xml = struct {
	const Self = @This();

	version:    Attribute = .{},
	encoding:   Attribute = .{},
	standalone: Attribute = .{},

	pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
		self.version.deinit(alloc);
		self.encoding.deinit(alloc);
		self.standalone.deinit(alloc);
	}

	test {
		var gpa = std.heap.GeneralPurposeAllocator(.{}){};
		const alloc = gpa.allocator();
		defer {
			const deinit_status = gpa.deinit();
			if (deinit_status == .leak) expect(false) catch @panic("TEST FAIL");
		}

		const attrs: []const struct{[]const u8, []const u8} = &.{
			.{"version", "1.0"},
			.{"encoding", "UTF-8"},
			.{"standalone", "yes"},
		};

		try testAttrs(Self, attrs, alloc);
	}
};

const Reader = struct {
	const Self = @This();

	reader: *std.Io.Reader,
	peek:   ?u8 = null,

	pub fn peekByte(self: *Self) !u8 {
		if (self.peek) |v| return v;

		self.peek = try self.reader.takeByte();
		return self.peek.?;
	}

	pub fn readByte(self: *Self) !u8 {
		// consume peek
		if (self.peek) |v| {
			self.peek = null;
			return v;
		}

		return self.reader.takeByte();
	}

	pub fn readUpToFirstScalar(self: *Self, buf: []u8, scalars: []const u8) ![]const u8 {
		var index: usize = 0;

		// check peek
		if (self.peek) |v| {
			if (std.mem.indexOfScalar(u8, scalars, v) != null) return buf[0..0];

			// consume peek
			self.peek = null;
			buf[index] = v;
			index += 1;
		}

		while (index < buf.len) {
			const v = try self.reader.takeByte();
			if (std.mem.indexOfScalar(u8, scalars, v) != null) {
				self.peek = v;
				return buf[0..index];
			}

			buf[index] = v;
			index += 1;
		}

		return error.ReadExceededBufLen;
	}

	pub fn readUpToScalar(self: *Self, buf: []u8, scalar: u8) ![]const u8 {
		var index: usize = 0;

		// check peek
		if (self.peek) |v| {
			if (v == scalar) return buf[0..0];

			// consume peek
			self.peek = null;
			buf[index] = v;
			index += 1;
		}

		while (index < buf.len) {
			const v = try self.reader.takeByte();
			if (v == scalar) {
				self.peek = v;
				return buf[0..index];
			}

			buf[index] = v;
			index += 1;
		}

		return error.ReadExceededBufLen;
	}

	pub fn dropUpToScalar(self: *Self, scalar: u8) !void {
		// check peek
		if (self.peek) |v| {
			if (v == scalar) return;

			// consume peek
			self.peek = null;
		}

		_ = try self.reader.discardDelimiterInclusive(scalar);
		self.peek = scalar;
	}

	pub fn appendUpToScalar(self: *Self, alloc: std.mem.Allocator, al: *std.ArrayListUnmanaged(u8), scalar: u8) !void {
		// check peek
		if (self.peek) |v| {
			if (v == scalar) return;

			// consume peek
			self.peek = null;
			try al.append(alloc, v);
		}

		while (true) {
			const v = try self.reader.takeByte();
			if (v == scalar) {
				self.peek = v;
				return;
			}

			try al.append(alloc, v);
		}
	}

	pub fn dropUpToIncludingScalar(self: *Self, scalar: u8) !void {
		// check peek
		if (self.peek) |v| {
			// consume peek
			self.peek = null;

			if (v == scalar) return;
		}

		while (true) if (try self.reader.takeByte() == scalar) return;
	}

	pub fn dropUpToIncludingClosingTag(self: *Self, name: []const u8) !void {
		if (name.len == 0) return error.dropUpToClosingTagEmptyName;

		var leftAngleBracketFound = false;
		var forwardSlashFound = false;
		var nameIndex: usize = 0;

		// check peek
		if (self.peek) |v| {
			// consume peek
			self.peek = null;

			if (v == '<') leftAngleBracketFound = true;
		}

		while (true) {
			const b = try self.reader.takeByte();

			// none found
			if (!leftAngleBracketFound and !forwardSlashFound) {
				if (b == '<') leftAngleBracketFound = true;
			}
			// lab found
			else if (leftAngleBracketFound and !forwardSlashFound) {
				if (b == '/') forwardSlashFound = true else leftAngleBracketFound = false;
			}
			// lab & fs found
			else if (leftAngleBracketFound and forwardSlashFound and nameIndex < name.len) {
				if (b == name[nameIndex]) {
					nameIndex += 1;
					continue;
				}

				leftAngleBracketFound = false;
				forwardSlashFound = false;
				nameIndex = 0;
			}
			else if (leftAngleBracketFound and forwardSlashFound and nameIndex == name.len) {
				if (b == '>') return;

				leftAngleBracketFound = false;
				forwardSlashFound = false;
				nameIndex = 0;
			}
			// invalid state
			else unreachable;
		}
	}
};

fn parseAttr(comptime Container: type, alloc: std.mem.Allocator, ptr: *Container, r: *Reader, ignoreUnknownFields: bool) !void {
	const fields = std.meta.fields(Container);

	var buf: [64]u8 = undefined;

	// read name
	const name = try r.readUpToScalar(&buf, '=');

	// get field
	inline for (fields) |f| if (std.mem.eql(u8, f.name, name)) {		
		// check field is of type Attribute
		if (f.type != Attribute) return error.AttrIncorrectType;

		// jump to start of attribute value bytes
		try r.dropUpToIncludingScalar('"');

		// allocate value
		try r.appendUpToScalar(alloc, &@field(ptr, f.name), '"');

		// drop '"'
		assert(try r.readByte() == '"');

		return;
	};

	// field not found
	if (!ignoreUnknownFields) return error.AttrNameMissingFromContainer;

	// drop remaining attribute bytes
	try r.dropUpToIncludingScalar('"');
	try r.dropUpToIncludingScalar('"');
	return;
}

fn parseAttrs(comptime t: type, alloc: std.mem.Allocator, ptr: *t, r: *Reader, ignoreUnknownFields: bool) !void {
	// read attributes until '>' is found
	while (true) switch (try r.peekByte()) { // TagEofBeforeClosingBracket
		'>' => {
			_ = try r.readByte();
			return;
		},
		// parse attribute
		// arraylists cannot have attributes
		'a'...'z', 'A'...'Z' => try parseAttr(t, alloc, ptr, r, ignoreUnknownFields),
		// consumes peek, cannot fail
		else => _ = r.readByte() catch unreachable,
	};
}

const TagName = struct {
	const Self = @This();

	name: []const u8 = undefined,
	isClosing: bool = false,
	isProcessingInstruction: bool = false,

	pub fn parse(buf: []u8, r: *Reader) !Self {
		var out = Self {}; 
		
		// read '<'
		if (try r.readByte() != '<') return error.TagIncorrectFirstByte;

		// check if closing tag
		const peek = try r.peekByte();
		if (peek == '/') {
			out.isClosing = true;

			// consumes peek, cannot fail
			_ = r.readByte() catch unreachable;
		}
		else if (peek == '?') {
			out.isProcessingInstruction = true;

			// consumes peek, cannot fail
			_ = r.readByte() catch unreachable;
		}

		// read name
		out.name = try r.readUpToFirstScalar(buf, " ?>");
		if (out.name.len == 0) return error.EmptyTagName;
		if (out.name[0] == '?') {
			out.name = out.name[1..];
			out.isProcessingInstruction = true;
		}

		return out;
	}
};

fn parseStruct(comptime Container: type, alloc: std.mem.Allocator, tag: TagName, ptr: *Container, r: *Reader, ignoreUnknownFields: bool) !void {
	if (tag.isClosing) return error.CannotParseStructFromClosingTag;

	const fields = std.meta.fields(Container);
	var buf: [64]u8 = undefined;

	inline for (fields) |f| if (@typeInfo(f.type) == .@"struct" and std.mem.eql(u8, f.name, tag.name)) {
		const field = &@field(ptr, f.name);

		// https://ziggit.dev/t/how-to-determine-if-anytype-is-std-arraylist/6825/2
		if (
			f.type != Attribute and
			f.type != Chardata and
			@typeInfo(f.type) == .@"struct" and
			@hasDecl(f.type, "Slice") and
			@typeInfo(f.type.Slice) == .pointer
		) {
			const ptr_info = @typeInfo(f.type.Slice).pointer;

			if (
				f.type == std.ArrayListAlignedUnmanaged(ptr_info.child, null) or
				f.type == std.ArrayListAlignedUnmanaged(ptr_info.child, ptr_info.alignment)
			) {
				// arraylists cannot contain attributes
				try r.dropUpToIncludingScalar('>');

				// parse body
				var out: ptr_info.child = .{};
				while (true) {
					// drop up to next tag
					try r.dropUpToScalar('<');

					const innerTag = try TagName.parse(&buf, r);

					// handle closing tag
					if (innerTag.isClosing) {
						if (std.mem.eql(u8, tag.name, innerTag.name)) return try field.append(alloc, out);
						return error.IncorrectClosingTag;
					}

					try parseStruct(ptr_info.child, alloc, innerTag, &out, r, ignoreUnknownFields);
				}
				
			}
		}

		try parseAttrs(f.type, alloc, field, r, ignoreUnknownFields);

		// Processing Instructions do not have a closing tag
		if (tag.isProcessingInstruction) return;

		// parse body
		while (true) {
			// append or drop up to next tag
			if (@hasField(f.type, "chardata") and @TypeOf(@field(field, "chardata")) == Chardata) try r.appendUpToScalar(alloc, &@field(field, "chardata"), '<')
			else try r.dropUpToScalar('<');

			const innerTag = try TagName.parse(&buf, r);

			// handle closing tag
			if (innerTag.isClosing) {
				if (std.mem.eql(u8, tag.name, innerTag.name)) return;
				return error.IncorrectClosingTag;
			}

			try parseStruct(f.type, alloc, innerTag, field, r, ignoreUnknownFields);
		}
	};

	// field not found
	if (!ignoreUnknownFields) return error.TagNameMissingFromContainer;
	
	// Processing Instructions do not have a closing tag
	// drop everything until matching closing tag is found
	if (!tag.isProcessingInstruction) try r.dropUpToIncludingClosingTag(tag.name);
}

pub fn parse(comptime T: type, alloc: std.mem.Allocator, ignoreUnknownFields: bool, reader: *std.Io.Reader) !T {
	var r = Reader{.reader = reader};
	var out = T {};
	var buf: [64]u8 = undefined;

	while (true) {
		r.dropUpToScalar('<') catch |err| switch (err) {
			error.EndOfStream => break,
			else => return err,
		};

		const tag = try TagName.parse(&buf, &r);
		if (tag.isClosing) return error.UnexpectedClosingTag;

		try parseStruct(T, alloc, tag, &out, &r, ignoreUnknownFields);
	}

	return out;
}

test {
	_ = Xml;
}
