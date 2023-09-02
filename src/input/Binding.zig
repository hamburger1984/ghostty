//! A binding maps some input trigger to an action. When the trigger
//! occurs, the action is performed.
const Binding = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const key = @import("key.zig");

/// The trigger that needs to be performed to execute the action.
trigger: Trigger,

/// The action to take if this binding matches
action: Action,

pub const Error = error{
    InvalidFormat,
    InvalidAction,
};

/// Parse the format "ctrl+a=csi:A" into a binding. The format is
/// specifically "trigger=action". Trigger is a "+"-delimited series of
/// modifiers and keys. Action is the action name and optionally a
/// parameter after a colon, i.e. "csi:A" or "ignore".
pub fn parse(input: []const u8) !Binding {
    // NOTE(mitchellh): This is not the most efficient way to do any
    // of this, I welcome any improvements here!

    // Find the first = which splits are mapping into the trigger
    // and action, respectively.
    const eqlIdx = std.mem.indexOf(u8, input, "=") orelse return Error.InvalidFormat;

    // Determine our trigger conditions by parsing the part before
    // the "=", i.e. "ctrl+shift+a" or "a"
    const trigger = trigger: {
        var result: Trigger = .{};
        var iter = std.mem.tokenize(u8, input[0..eqlIdx], "+");
        loop: while (iter.next()) |part| {
            // All parts must be non-empty
            if (part.len == 0) return Error.InvalidFormat;

            // Check if its a modifier
            const modsInfo = @typeInfo(key.Mods).Struct;
            inline for (modsInfo.fields) |field| {
                if (field.type == bool) {
                    if (std.mem.eql(u8, part, field.name)) {
                        // Repeat not allowed
                        if (@field(result.mods, field.name)) return Error.InvalidFormat;

                        @field(result.mods, field.name) = true;
                        continue :loop;
                    }
                }
            }

            // If the key starts with "physical" then this is an physical key.
            const physical = "physical:";
            const key_part = if (std.mem.startsWith(u8, part, physical)) key_part: {
                result.physical = true;
                break :key_part part[physical.len..];
            } else part;

            // Check if its a key
            const keysInfo = @typeInfo(key.Key).Enum;
            inline for (keysInfo.fields) |field| {
                if (!std.mem.eql(u8, field.name, "invalid")) {
                    if (std.mem.eql(u8, key_part, field.name)) {
                        // Repeat not allowed
                        if (result.key != .invalid) return Error.InvalidFormat;

                        result.key = @field(key.Key, field.name);
                        continue :loop;
                    }
                }
            }

            // We didn't recognize this value
            return Error.InvalidFormat;
        }

        break :trigger result;
    };

    // Find a matching action
    const action = try Action.parse(input[eqlIdx + 1 ..]);

    return Binding{ .trigger = trigger, .action = action };
}

/// The set of actions that a keybinding can take.
pub const Action = union(enum) {
    /// Ignore this key combination, don't send it to the child process,
    /// just black hole it.
    ignore: void,

    /// This action is used to flag that the binding should be removed
    /// from the set. This should never exist in an active set and
    /// `set.put` has an assertion to verify this.
    unbind: void,

    /// Send a CSI sequence. The value should be the CSI sequence
    /// without the CSI header ("ESC ]" or "\x1b]").
    csi: []const u8,

    /// Send data to the pty depending on whether cursor key mode is
    /// enabled ("application") or disabled ("normal").
    cursor_key: CursorKey,

    /// Copy and paste.
    copy_to_clipboard: void,
    paste_from_clipboard: void,

    /// Increase/decrease the font size by a certain amount
    increase_font_size: u16,
    decrease_font_size: u16,

    /// Reset the font size to the original configured size
    reset_font_size: void,

    /// Clear the screen. This also clears all scrollback.
    clear_screen: void,

    /// Scroll the screen varying amounts.
    scroll_to_top: void,
    scroll_to_bottom: void,
    scroll_page_up: void,
    scroll_page_down: void,
    scroll_page_fractional: f32,

    /// Jump the viewport forward or back by prompt. Positive
    /// number is the number of prompts to jump forward, negative
    /// is backwards.
    jump_to_prompt: i16,

    /// Write the entire scrollback into a temporary file and write the
    /// path to the file to the tty.
    write_scrollback_file: void,

    /// Open a new window
    new_window: void,

    /// Open a new tab
    new_tab: void,

    /// Go to the previous tab
    previous_tab: void,

    /// Go to the next tab
    next_tab: void,

    /// Go to the tab with the specific number, 1-indexed.
    goto_tab: usize,

    /// Create a new split in the given direction. The new split will appear
    /// in the direction given.
    new_split: SplitDirection,

    /// Focus on a split in a given direction.
    goto_split: SplitFocusDirection,

    /// Zoom and unzoom the current split.
    zoom_split: void,
    unzoom_split: void,

    /// Reload the configuration. The exact meaning depends on the app runtime
    /// in use but this usually involves re-reading the configuration file
    /// and applying any changes. Note that not all changes can be applied at
    /// runtime.
    reload_config: void,

    /// Close the current "surface", whether that is a window, tab, split,
    /// etc. This only closes ONE surface.
    close_surface: void,

    /// Close the window, regardless of how many tabs or splits there may be.
    close_window: void,

    /// Toggle fullscreen mode of window.
    toggle_fullscreen: void,

    /// Quit ghostty
    quit: void,

    pub const CursorKey = struct {
        normal: []const u8,
        application: []const u8,
    };

    // This is made extern (c_int) to make interop easier with our embedded
    // runtime. The small size cost doesn't make a difference in our union.
    pub const SplitDirection = enum(c_int) {
        right,
        down,

        // Note: we don't support top or left yet
    };

    // Extern because it is used in the embedded runtime ABI.
    pub const SplitFocusDirection = enum(c_int) {
        previous,
        next,

        top,
        left,
        bottom,
        right,
    };

    /// Parse an action in the format of "key=value" where key is the
    /// action name and value is the action parameter. The parameter
    /// is optional depending on the action.
    pub fn parse(input: []const u8) !Action {
        // Split our action by colon. A colon may not exist for some
        // actions so it is optional. The part preceding the colon is the
        // action name.
        const colonIdx = std.mem.indexOf(u8, input, ":");
        const action = input[0..(colonIdx orelse input.len)];

        // An action name is always required
        if (action.len == 0) return Error.InvalidFormat;

        const actionInfo = @typeInfo(Action).Union;
        inline for (actionInfo.fields) |field| {
            if (std.mem.eql(u8, action, field.name)) {
                // If the field type is void we expect no value
                switch (field.type) {
                    void => {
                        if (colonIdx != null) return Error.InvalidFormat;
                        return @unionInit(Action, field.name, {});
                    },

                    []const u8 => {
                        const idx = colonIdx orelse return Error.InvalidFormat;
                        const param = input[idx + 1 ..];
                        return @unionInit(Action, field.name, param);
                    },

                    // Cursor keys can't be set currently
                    Action.CursorKey => return Error.InvalidAction,

                    else => switch (@typeInfo(field.type)) {
                        .Enum => {
                            const idx = colonIdx orelse return Error.InvalidFormat;
                            const param = input[idx + 1 ..];
                            const value = std.meta.stringToEnum(
                                field.type,
                                param,
                            ) orelse return Error.InvalidFormat;

                            return @unionInit(Action, field.name, value);
                        },

                        .Int => {
                            const idx = colonIdx orelse return Error.InvalidFormat;
                            const param = input[idx + 1 ..];
                            const value = std.fmt.parseInt(field.type, param, 10) catch
                                return Error.InvalidFormat;
                            return @unionInit(Action, field.name, value);
                        },

                        .Float => {
                            const idx = colonIdx orelse return Error.InvalidFormat;
                            const param = input[idx + 1 ..];
                            const value = std.fmt.parseFloat(field.type, param) catch
                                return Error.InvalidFormat;
                            return @unionInit(Action, field.name, value);
                        },

                        else => unreachable,
                    },
                }
            }
        }

        return Error.InvalidAction;
    }

    /// Returns a hash code that can be used to uniquely identify this
    /// action.
    pub fn hash(self: Action) u64 {
        var hasher = std.hash.Wyhash.init(0);

        // Always has the active tag.
        const Tag = @typeInfo(Action).Union.tag_type.?;
        std.hash.autoHash(&hasher, @as(Tag, self));

        // Hash the value of the field.
        switch (self) {
            inline else => |field| {
                const FieldType = @TypeOf(field);
                switch (FieldType) {
                    // Do nothing for void
                    void => {},

                    // Floats are hashed by their bits. This is totally not
                    // portable and there are edge cases such as NaNs and
                    // signed zeros but these are not cases we expect for
                    // our bindings.
                    f32 => std.hash.autoHash(
                        &hasher,
                        @as(u32, @bitCast(field)),
                    ),
                    f64 => std.hash.autoHash(
                        &hasher,
                        @as(u64, @bitCast(field)),
                    ),

                    // Everything else automatically handle.
                    else => std.hash.autoHashStrat(
                        &hasher,
                        field,
                        .DeepRecursive,
                    ),
                }
            },
        }

        return hasher.final();
    }
};

// A key for the C API to execute an action. This must be kept in sync
// with include/ghostty.h.
pub const Key = enum(c_int) {
    copy_to_clipboard,
    paste_from_clipboard,
    new_tab,
    new_window,
};

/// Trigger is the associated key state that can trigger an action.
/// This is an extern struct because this is also used in the C API.
///
/// This must be kept in sync with include/ghostty.h ghostty_input_trigger_s
pub const Trigger = extern struct {
    /// The key that has to be pressed for a binding to take action.
    key: key.Key = .invalid,

    /// The key modifiers that must be active for this to match.
    mods: key.Mods = .{},

    /// key is the "physical" version. This is the same as mapped for
    /// standard US keyboard layouts. For non-US keyboard layouts, this
    /// is used to bind to a physical key location rather than a translated
    /// key.
    physical: bool = false,

    /// Returns a hash code that can be used to uniquely identify this trigger.
    pub fn hash(self: Trigger) u64 {
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hasher, self.key);
        std.hash.autoHash(&hasher, self.mods.binding());
        std.hash.autoHash(&hasher, self.physical);
        return hasher.final();
    }
};

/// A structure that contains a set of bindings and focuses on fast lookup.
/// The use case is that this will be called on EVERY key input to look
/// for an associated action so it must be fast.
pub const Set = struct {
    const HashMap = std.HashMapUnmanaged(
        Trigger,
        Action,
        Context(Trigger),
        std.hash_map.default_max_load_percentage,
    );

    const ReverseMap = std.HashMapUnmanaged(
        Action,
        Trigger,
        Context(Action),
        std.hash_map.default_max_load_percentage,
    );

    /// The set of bindings.
    bindings: HashMap = .{},

    /// The reverse mapping of action to binding. Note that multiple
    /// bindings can map to the same action and this map will only have
    /// the most recently added binding for an action.
    reverse: ReverseMap = .{},

    pub fn deinit(self: *Set, alloc: Allocator) void {
        self.bindings.deinit(alloc);
        self.reverse.deinit(alloc);
        self.* = undefined;
    }

    /// Add a binding to the set. If the binding already exists then
    /// this will overwrite it.
    pub fn put(
        self: *Set,
        alloc: Allocator,
        t: Trigger,
        action: Action,
    ) !void {
        // unbind should never go into the set, it should be handled prior
        assert(action != .unbind);

        const gop = try self.bindings.getOrPut(alloc, t);

        // If we have an existing binding for this trigger, we have to
        // update the reverse mapping to remove the old action.
        if (gop.found_existing) {
            const t_hash = t.hash();
            var it = self.reverse.iterator();
            while (it.next()) |reverse_entry| it: {
                if (t_hash == reverse_entry.value_ptr.hash()) {
                    self.reverse.removeByPtr(reverse_entry.key_ptr);
                    break :it;
                }
            }
        }

        gop.value_ptr.* = action;
        errdefer _ = self.bindings.remove(t);
        try self.reverse.put(alloc, action, t);
        errdefer _ = self.reverse.remove(action);
    }

    /// Get a binding for a given trigger.
    pub fn get(self: Set, t: Trigger) ?Action {
        return self.bindings.get(t);
    }

    /// Get a trigger for the given action. An action can have multiple
    /// triggers so this will return the first one found.
    pub fn getTrigger(self: Set, a: Action) ?Trigger {
        return self.reverse.get(a);
    }

    /// Remove a binding for a given trigger.
    pub fn remove(self: *Set, t: Trigger) void {
        const action = self.bindings.get(t) orelse return;
        _ = self.bindings.remove(t);

        // Look for a matching action in bindings and use that.
        // Note: we'd LIKE to replace this with the most recent binding but
        // our hash map obviously has no concept of ordering so we have to
        // choose whatever. Maybe a switch to an array hash map here.
        const action_hash = action.hash();
        var it = self.bindings.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.hash() == action_hash) {
                self.reverse.putAssumeCapacity(action, entry.key_ptr.*);
                break;
            }
        } else {
            // No over trigger points to this action so we remove
            // the reverse mapping completely.
            _ = self.reverse.remove(action);
        }
    }

    /// The hash map context for the set. This defines how the hash map
    /// gets the hash key and checks for equality.
    fn Context(comptime KeyType: type) type {
        return struct {
            pub fn hash(ctx: @This(), k: KeyType) u64 {
                _ = ctx;
                return k.hash();
            }

            pub fn eql(ctx: @This(), a: KeyType, b: KeyType) bool {
                return ctx.hash(a) == ctx.hash(b);
            }
        };
    }
};

test "parse: triggers" {
    const testing = std.testing;

    // single character
    try testing.expectEqual(
        Binding{
            .trigger = .{ .key = .a },
            .action = .{ .ignore = {} },
        },
        try parse("a=ignore"),
    );

    // single modifier
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true },
            .key = .a,
        },
        .action = .{ .ignore = {} },
    }, try parse("shift+a=ignore"));
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .ctrl = true },
            .key = .a,
        },
        .action = .{ .ignore = {} },
    }, try parse("ctrl+a=ignore"));

    // multiple modifier
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true, .ctrl = true },
            .key = .a,
        },
        .action = .{ .ignore = {} },
    }, try parse("shift+ctrl+a=ignore"));

    // key can come before modifier
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true },
            .key = .a,
        },
        .action = .{ .ignore = {} },
    }, try parse("a+shift=ignore"));

    // physical keys
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true },
            .key = .a,
            .physical = true,
        },
        .action = .{ .ignore = {} },
    }, try parse("shift+physical:a=ignore"));

    // invalid key
    try testing.expectError(Error.InvalidFormat, parse("foo=ignore"));

    // repeated control
    try testing.expectError(Error.InvalidFormat, parse("shift+shift+a=ignore"));

    // multiple character
    try testing.expectError(Error.InvalidFormat, parse("a+b=ignore"));
}

test "parse: action invalid" {
    const testing = std.testing;

    // invalid action
    try testing.expectError(Error.InvalidAction, parse("a=nopenopenope"));
}

test "parse: action no parameters" {
    const testing = std.testing;

    // no parameters
    try testing.expectEqual(
        Binding{ .trigger = .{ .key = .a }, .action = .{ .ignore = {} } },
        try parse("a=ignore"),
    );
    try testing.expectError(Error.InvalidFormat, parse("a=ignore:A"));
}

test "parse: action with string" {
    const testing = std.testing;

    // parameter
    {
        const binding = try parse("a=csi:A");
        try testing.expect(binding.action == .csi);
        try testing.expectEqualStrings("A", binding.action.csi);
    }
}

test "parse: action with enum" {
    const testing = std.testing;

    // parameter
    {
        const binding = try parse("a=new_split:right");
        try testing.expect(binding.action == .new_split);
        try testing.expectEqual(Action.SplitDirection.right, binding.action.new_split);
    }
}

test "parse: action with int" {
    const testing = std.testing;

    // parameter
    {
        const binding = try parse("a=jump_to_prompt:-1");
        try testing.expect(binding.action == .jump_to_prompt);
        try testing.expectEqual(@as(i16, -1), binding.action.jump_to_prompt);
    }
    {
        const binding = try parse("a=jump_to_prompt:10");
        try testing.expect(binding.action == .jump_to_prompt);
        try testing.expectEqual(@as(i16, 10), binding.action.jump_to_prompt);
    }
}

test "parse: action with float" {
    const testing = std.testing;

    // parameter
    {
        const binding = try parse("a=scroll_page_fractional:-0.5");
        try testing.expect(binding.action == .scroll_page_fractional);
        try testing.expectEqual(@as(f32, -0.5), binding.action.scroll_page_fractional);
    }
    {
        const binding = try parse("a=scroll_page_fractional:+0.5");
        try testing.expect(binding.action == .scroll_page_fractional);
        try testing.expectEqual(@as(f32, 0.5), binding.action.scroll_page_fractional);
    }
}

test "set: maintains reverse mapping" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.put(alloc, .{ .key = .a }, .{ .new_window = {} });
    {
        const trigger = s.getTrigger(.{ .new_window = {} }).?;
        try testing.expect(trigger.key == .a);
    }

    // should be most recent
    try s.put(alloc, .{ .key = .b }, .{ .new_window = {} });
    {
        const trigger = s.getTrigger(.{ .new_window = {} }).?;
        try testing.expect(trigger.key == .b);
    }

    // removal should replace
    s.remove(.{ .key = .b });
    {
        const trigger = s.getTrigger(.{ .new_window = {} }).?;
        try testing.expect(trigger.key == .a);
    }
}

test "set: overriding a mapping updates reverse" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.put(alloc, .{ .key = .a }, .{ .new_window = {} });
    {
        const trigger = s.getTrigger(.{ .new_window = {} }).?;
        try testing.expect(trigger.key == .a);
    }

    // should be most recent
    try s.put(alloc, .{ .key = .a }, .{ .new_tab = {} });
    {
        const trigger = s.getTrigger(.{ .new_window = {} });
        try testing.expect(trigger == null);
    }
}
