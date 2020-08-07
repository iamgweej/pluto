const std = @import("std");
const AutoHashMap = std.AutoHashMap;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const vfs = @import("vfs.zig");
const mem = @import("../mem.zig");
var test_fat_bytes = @import("test_fat_bytes.zig").test_fat_bytes;

const BootRecord32 = struct {
    jmp: [3]u8,
    oem: [8]u8,
    bytes_per_sector: u16,
    sectors_per_cluster: u8,
    reserved_sectors: u16,
    fat_tables: u8,
    root_directory_size: u16,
    // Only FAT12/16
    total_sectors_16: u16,
    media_descriptor_type: u8,
    // Only for FAT12/16
    sectors_per_fat: u16,
    sectors_per_track: u16,
    head_count: u16,
    hidden_sectors: u32,
    total_sectors_32: u32,
    // FAT32 stuff:
    sectors_per_fat32: u32,
    flags: u16,
    fat_version_number: u16,
    root_directory_cluster_number: u32,
    sector_number_fsinfo: u16,
    sector_number_backup_boot: u16,
    reserved1: [12]u8,
    drive_number: u8,
    reserved2: u8,
    signature: u8,
    serial_number: u32,
    volume_label: [11]u8,
    // This will always be "FAT32   "
    filesystem_type: [8]u8,
    boot_code: [420]u8,
    boot_signature: u16,

    const FileSystemType = enum {
        FAT12,
        FAT16,
        FAT32,
        ExFAT,
    };

    const Error = error{
        BadMBRMagic,
        BadFSType,
    };

    pub fn rootDirSector(self: BootRecord32) usize {
        return ((self.root_directory_size * 32) + (self.bytes_per_sector - 1)) / self.bytes_per_sector;
    }

    pub fn firstDataSector(self: BootRecord32) usize {
        // Do I need the hidden sectors?
        return self.hidden_sectors + self.reserved_sectors + (self.fat_tables * self.sectors_per_fat32) + self.rootDirSector();
    }

    pub fn totalDataSectors(self: BootRecord32) usize {
        return self.total_sectors_32 - self.firstDataSector();
    }

    pub fn totalClusters(self: BootRecord32) usize {
        return self.totalDataSectors() / self.sectors_per_cluster;
    }

    // This will always return FAT32
    fn getFileSystemType(self: BootRecord32) FileSystemType {
        const total_clusters = self.totalClusters();
        std.debug.assert(totalClusters < 268435445 and totalClusters >= 65525);
        if (totalClusters < 4085) {
            return .FAT12;
        } else if (totalClusters < 65525) {
            return .FAT16;
        } else if (totalClusters < 268435445) {
            return .FAT32;
        } else {
            return .ExFAT;
        }
    }

    pub fn firstSectorOfCluster(self: BootRecord32, cluster: usize) usize {
        return ((cluster - 2) * self.sectors_per_cluster) + self.firstDataSector();
    }

    pub fn clusterToLBA(self: BootRecord32, cluster: usize) usize {
        return self.firstDataSector() + cluster * self.sectors_per_cluster - (2 * self.sectors_per_cluster);
    }

    pub fn getStartLBA(self: BootRecord32) u32 {
        const b = std.mem.asBytes(&self);
        const start = std.mem.bytesAsSlice(u32, b)[0x1C6 / 4];
        std.log.info(.NONE, "S: {X}\n", .{start});
        std.debug.assert(start == 0);
        return start;
    }

    pub fn init(boot_sector: []u8) Error!BootRecord32 {
        var ret = initStruct(BootRecord32, boot_sector);

        // Do some checks:
        if (ret.boot_signature != 0xAA55) {
            return Error.BadMBRMagic;
        }
        if (!std.mem.eql(u8, "FAT32   ", ret.filesystem_type[0..])) {
            std.log.info(.NONE, "{}:\n", .{ret.filesystem_type});
            return Error.BadFSType;
        }

        return ret;
    }

    pub fn print(self: BootRecord32) void {
        std.log.info(.NONE, "BootRecord32{{\n", .{});
        inline for (std.meta.fields(BootRecord32)) |item| {
            if (std.mem.eql(u8, item.name, "boot_code") or std.mem.eql(u8, item.name, "volume_label")) {
                std.log.info(.NONE, "  .{} = {X},\n", .{ item.name, @field(self, item.name) });
            } else {
                std.log.info(.NONE, "  .{} = {},\n", .{ item.name, @field(self, item.name) });
            }
        }
        std.log.info(.NONE, "}}\n", .{});
    }
};

/// The boot record for FAT32. See https://wiki.osdev.org/FAT32 for details on the fields.
const BootRecord = struct {
    jmp: [3]u8,
    oem: [8]u8,
    bytes_per_sector: u16,
    sectors_per_cluster: u8,
    reserved_sectors: u16,
    fat_tables: u8,
    root_directory_entries: u16,
    sectors_in_filesystem: u16,
    media_descriptor_type: u8,
    // Only for FAT12/16
    sectors_per_fat: u16,
    sectors_per_track: u16,
    head_count: u16,
    hidden_sectors: u32,
    large_sector_count: u32,

    sectors_per_fat_32: u32,
    flags: u16,
    fat_version_number: u16,
    root_directory_cluster_number: u32,
    sector_number_fsinfo: u16,
    sector_number_backup_boot: u16,
    reserved0: [12]u8,
    drive_number: u8,
    reserved1: u8,
    signature: u8,
    serial_number: u32,
    volume_label: [11]u8,
    // This will always be "FAT32   "
    filesystem_type: [8]u8,
    // We are ignoring the boot code and boot signature as they are not important and waste memory.

    ///
    /// Get the sector of the root directory.
    ///
    /// Arguments:
    ///     IN self: BootRecord - The boot sector parsed into a struct for easy access to the field.
    ///
    /// Return: usize
    ///     The sector number of the root directory. When reading this, will need to multiple this
    ///     number by `bytes_per_sector` to read the entire sector.
    ///
    pub fn getRootDirectorySector(self: *BootRecord) usize {
        return (self.sectors_per_fat_32 * self.fat_tables) + self.reserved_sectors + ((self.root_directory_cluster_number - 2) * self.sectors_per_cluster);
    }

    pub fn clusterToSector(self: *const BootRecord, cluster: usize) usize {
        std.log.info(.NONE, "Converting cluster: {}\n", .{cluster});
        // if (cluster > 2) return Error.InvalidCluster;
        return (self.sectors_per_fat_32 * self.fat_tables) + self.reserved_sectors + ((cluster - 2) * self.sectors_per_cluster);
    }

    ///
    /// Initialise a Boot record from the boot sector. This will ignore the boot code and boot
    /// signature as there aren't important.
    ///
    /// Argument:
    ///     IN bytes: []u8 - The boot sector bytes. This should be 512 bytes of the boot sector
    ///                      but can be at least 90 bytes.
    ///
    /// Return: BootRecord
    ///     The boot record struct.
    ///
    pub fn init(bytes: []u8) BootRecord {
        return initStruct(BootRecord, bytes);
    }

    ///
    /// Pretty print the boot record.
    ///
    /// Arguments:
    ///     IN self: BootRecord - Self.
    ///
    pub fn print(self: *BootRecord) void {
        std.log.info(.NONE, "BootRecord{{\n", .{});
        inline for (std.meta.fields(BootRecord)) |field| {
            if (std.mem.eql(u8, field.name, "volume_label")) {
                std.log.info(.NONE, "  .{} = {X},\n", .{ field.name, @field(self, field.name) });
            } else {
                std.log.info(.NONE, "  .{} = {},\n", .{ field.name, @field(self, field.name) });
            }
        }
        std.log.info(.NONE, "}}\n", .{});
    }
};

const FSInfo = struct {
    signature: u32,
    reserved: [480]u8,
    signature2: u32,
    last_free_cluster: u32,
    start_cluster_number: u32,
    reserved3: [12]u8,
    tail_signature: u32,
};

const LongName = struct {
    order: u8,
    first: [10]u8,
    attribute: u8,
    long_entry_type: u8,
    check_sum: u8,
    second: [12]u8,
    zero: u16,
    third: [4]u8,

    pub fn init(bytes: []u8) LongName {
        return initStruct(LongName, bytes);
    }
};

const SmallFatDir = struct {
    name: [8]u8,
    ext: [3]u8,
    attributes: u8,
    reserved: u8,
    creation_time_length: u8, // Seconds, not sure what is this
    time_created: u32, // 0-4 H, 5-10 M, 11-15 S, 16-22 Y, 23-26 M, 27-31 D
    last_access: u16, // 16-22 Y, 23-26 M, 27-31 D
    cluster_high: u16,
    last_modification: u32, // 0-4 H, 5-10 M, 11-15 S, 16-22 Y, 23-26 M, 27-31 D
    cluster_low: u16,
    size: u32,

    pub fn isDir(self: *const SmallFatDir) bool {
        return self.attributes & 0x10 == 0x10;
    }

    pub fn getCluster(self: *const SmallFatDir) usize {
        return self.cluster_high << 15 | self.cluster_low;
    }

    pub fn print(self: *const SmallFatDir) void {
        const r: u8 = if (self.attributes & 0x01 == 0x01) 'R' else '.';
        const h: u8 = if (self.attributes & 0x02 == 0x02) 'H' else '.';
        const s: u8 = if (self.attributes & 0x04 == 0x04) 'S' else '.';
        const l: u8 = if (self.attributes & 0x08 == 0x08) 'L' else '.';
        const d: u8 = if (self.attributes & 0x10 == 0x10) 'D' else '.';
        const a: u8 = if (self.attributes & 0x20 == 0x20) 'A' else '.';

        std.log.info(.NONE, "Attr={c}{c}{c}{c}{c}{c} Cluster={X} Size={X} Name={}.{}\n", .{ r, h, s, l, d, a, self.getCluster(), self.size, self.name, self.ext });
    }

    pub fn init(bytes: []u8) SmallFatDir {
        return initStruct(SmallFatDir, bytes);
    }
};

///
/// Initialise a struct from bytes, as packed structs are hot garbage.
///
/// Argument:
///     IN comptime Type: type - The struct type to initialise
///     IN bytes: []u8         - The bytes to initialise the struct with.
///
/// Return: Type
///     The struct initialised with the bytes.
///
fn initStruct(comptime Type: type, bytes: []u8) Type {
    var ret: Type = undefined;
    comptime var index = 0;
    inline for (std.meta.fields(Type)) |item| {
        switch (item.field_type) {
            u8 => @field(ret, item.name) = bytes[index],
            u16 => @field(ret, item.name) = std.mem.bytesAsSlice(u16, bytes[index .. index + 2])[0],
            u32 => @field(ret, item.name) = std.mem.bytesAsSlice(u32, bytes[index .. index + 4])[0],
            else => {
                switch (@typeInfo(item.field_type)) {
                    .Array => |info| switch (info.child) {
                        u8 => {
                            comptime var i = 0;
                            inline while (i < info.len) : (i += 1) {
                                @field(ret, item.name)[i] = bytes[index + i];
                            }
                        },
                        else => @compileError("Unexpected field type: " ++ @typeName(info.child)),
                    },
                    else => @compileError("Unexpected field type: " ++ @typeName(item.field_type)),
                }
            },
        }
        index += @sizeOf(item.field_type);
    }

    return ret;
}

pub const Fat32 = struct {
    fs: *vfs.FileSystem,
    allocator: *Allocator,
    instance: usize,
    root_node: RootSector,
    boot_record: BootRecord,

    /// A mapping of opened files so can easily retrieved opened files for reading, writing and closing.
    // TODO: replace OpenedNode with SmallFatDir, or even just the cluster.
    opened_files: AutoHashMap(*const vfs.Node, *OpenedNode),

    /// The underlying hardware device that the Fat32 file system will be operating on. This could
    /// be a ramdisk, hard drive, memory stick...
    stream: *std.io.FixedBufferStream([]u8),

    const RootSector = struct {
        node: *vfs.Node,
        /// The sector number for the root directory.
        sector: usize,
    };

    const OpenedNode = struct {
        fat_dir: *SmallFatDir,
        long_name: ?[]const u8,
    };

    const Error = error{
        BadMBRMagic,
        BadFSType,
    };

    // A directory iterator to help with parsing
    const DirIterator = struct {
        allocator: *Allocator,
        stream: *std.io.FixedBufferStream([]u8),
        sector_block: []u8,
        index: usize = 0,

        fn checkRead(self: *DirIterator) std.io.FixedBufferStream([]u8).ReadError!void {
            if (self.index >= self.sector_block.len) {
                // Read the next block
                const read_count = try self.stream.reader().readAll(self.sector_block);
                std.debug.assert(read_count == 512);
                errdefer self.allocator.free(self.sector_block);
                // Update the counters
                self.index = 0;
            }
        }

        pub fn next(self: *DirIterator) (Allocator.Error || std.io.FixedBufferStream([]u8).ReadError)!?OpenedNode {
            // Entries are 32 bytes long

            // Do we need to read the next block
            try self.checkRead();

            if (self.sector_block[self.index] != 0x00) {
                var long_name: ?[]u8 = null;
                var long_name_index: usize = undefined;

                // Deleted files
                // TODO: See if we can recover this file
                while (self.sector_block[self.index] == 0xE5) : ({
                    self.index += 32;
                    try self.checkRead();
                }) {}

                // A long name block
                // If attr is 0x0F, then is a long file name
                if (self.sector_block[self.index] & 0xF0 == 0x40 and self.sector_block[self.index + 11] == 0x0F) {
                    // A long name
                    var count = self.sector_block[self.index] & 0x0F;
                    // Long names have 13 characters in them
                    // FIXME: Magic, make a const
                    long_name = try self.allocator.alloc(u8, 13 * count);
                    errdefer if (long_name) |name| self.allocator.free(name);
                    long_name_index = long_name.?.len - 1;

                    // We create the long name backwards
                    // As the long name blocks are backwards, we append each clock to the long name array from the end forwards
                    while (count > 0) : ({
                        self.index += 32;
                        count -= 1;
                        try self.checkRead();
                    }) {
                        std.debug.assert(count == self.sector_block[self.index] & 0x0F);
                        // As we don't know how long the long name block is, we allocate a temporary name then copy it into the
                        // correct location in the main long name.
                        var long_name_temp = try parseLongNamePart(self.allocator, self.sector_block[self.index..]);
                        defer self.allocator.free(long_name_temp);
                        long_name_index -= long_name_temp.len;
                        for (long_name_temp) |char| {
                            long_name.?[long_name_index] = char;
                            long_name_index += 1;
                        }
                        long_name_index -= long_name_temp.len;
                    }
                    
                    // Move the long name to the beginning of the array
                    for (long_name.?[long_name_index..]) |char, i| {
                        long_name.?[i] = char;
                    }
                    // Shrink the array
                    long_name.? = long_name.?[0..long_name.?.len - long_name_index - 1];
                }

                var fat_mem = try self.allocator.create(SmallFatDir);
                fat_mem.* = SmallFatDir.init(self.sector_block[self.index..]);
                var ret = OpenedNode{ .fat_dir = fat_mem, .long_name = long_name };
                self.index += 32;
                return ret;
            }

            return null;
        }

        pub fn deinit(self: *DirIterator) void {
            self.allocator.free(self.sector_block);
        }

        pub fn init(allocator: *Allocator, sector: usize, stream: *std.io.FixedBufferStream([]u8)) (Allocator.Error || std.io.FixedBufferStream([]u8).ReadError)!DirIterator {
            // TODO: Add optimisation to read more than one sector at a time so less reading
            var sector_block = try allocator.alloc(u8, 512);
            try stream.seekTo(sector * 512);
            const read_count = try stream.reader().readAll(sector_block);
            var ret = .{
                .allocator = allocator,
                .stream = stream,
                .sector_block = sector_block,
            };
            return ret;
        }

        test "init - deinit" {
            var stream = std.io.fixedBufferStream(test_fat_bytes[0..]);
            var boot_record = BootRecord.init(test_fat_bytes[0..90]);
            const root_sector = boot_sector.clusterToSector(boot_sector.root_directory_cluster_number);
            var it = DirIterator.init(std.testing.allocator, root_sector, &stream);
            defer it.deinit();
        }
    };

    const Self = @This();

    /// See vfs.FileSystem.getRootNode
    fn getRootNode(fs: *const vfs.FileSystem) *const vfs.DirNode {
        var self = @fieldParentPtr(Fat32, "instance", fs.instance);
        return &self.root_node.node.Dir;
    }

    /// See vfs.FileSystem.close
    fn close(fs: *const vfs.FileSystem, node: *const vfs.FileNode) void {
        var self = @fieldParentPtr(Fat32, "instance", fs.instance);
        const cast_node = @ptrCast(*const vfs.Node, node);
        // As close can't error, if provided with a invalid Node that isn't opened or try to close
        // the same file twice, will just do nothing.
        // TODO: If implement caching, flush the output.
        if (self.opened_files.contains(cast_node)) {
            const opened_node = self.opened_files.remove(cast_node).?.value;
            //self.allocator.destroy(opened_node);
            self.allocator.destroy(node);
        }
    }

    /// See vfs.FileSystem.read
    fn read(fs: *const vfs.FileSystem, node: *const vfs.FileNode, len: usize) (Allocator.Error || vfs.Error)![]u8 {
        var self = @fieldParentPtr(Fat32, "instance", fs.instance);
        const cast_node = @ptrCast(*const vfs.Node, node);
        std.log.info(.NONE, "NODE read: {X}\n", .{@ptrToInt(cast_node)});
        // Get the open file
        var it = self.opened_files.iterator();
        while (it.next()) |entry| {
            std.log.info(.NONE, "OPENED FILE: {}\n", .{entry});
        }
        const opened_node = self.opened_files.get(cast_node) orelse return vfs.Error.NotOpened;
        const file_sector = self.boot_record.clusterToSector(opened_node.fat_dir.getCluster());
        std.log.info(.NONE, "Read: {} at S: {}\n", .{opened_node, file_sector});

        return self.readClusterChain(opened_node.fat_dir.getCluster(), opened_node.fat_dir.size);
    }

    /// See vfs.FileSystem.write
    fn write(fs: *const vfs.FileSystem, node: *const vfs.FileNode, bytes: []const u8) Allocator.Error!void {
        var self = @fieldParentPtr(Fat32, "instance", fs.instance);
        return error.OutOfMemory;
    }

    /// See vfs.FileSystem.open
    fn open(fs: *const vfs.FileSystem, dir: *const vfs.DirNode, name: []const u8, flags: vfs.OpenFlags) (Allocator.Error || std.io.FixedBufferStream([]u8).ReadError || vfs.Error)!*vfs.Node {
        var self = @fieldParentPtr(Fat32, "instance", fs.instance);
        std.log.info(.NONE, "Open: {}\n", .{name});

        var open_sector: usize = undefined;
        if (std.meta.eql(dir, fs.getRootNode(fs))) {
            open_sector = self.root_node.sector;
        } else {
            const parent = self.opened_files.get(@ptrCast(*const vfs.Node, dir)) orelse {
                std.log.info(.NONE, "Couldn't find: {*}\n", .{@ptrCast(*const vfs.Node, dir)});
                var it = self.opened_files.iterator();
                while (it.next()) |entry| {
                    std.log.info(.NONE, "OPENED FILE: {}\n", .{entry});
                }
                unreachable;
            };
            if (parent.fat_dir.getCluster() == 0) {
                // Then this is the root directory cluster
                std.log.info(.NONE, "P (ROOT): {} C: {}, S: {}\n", .{parent, self.boot_record.root_directory_cluster_number, self.boot_record.clusterToSector(self.boot_record.root_directory_cluster_number)});
                open_sector = self.boot_record.clusterToSector(self.boot_record.root_directory_cluster_number);
            } else {
                std.log.info(.NONE, "P: {} C: {}, S: {}\n", .{parent, parent.fat_dir.getCluster(), self.boot_record.clusterToSector(parent.fat_dir.getCluster())});
                open_sector = self.boot_record.clusterToSector(parent.fat_dir.getCluster());
            }
        }

        // Iterate over the directory and find the file/folder
        var it = try DirIterator.init(self.allocator, open_sector, self.stream);
        defer it.deinit();
        while (try it.next()) |entry| {
            //std.log.info(.NONE, "E: {}\n", .{entry});
            var match: bool = false;
            if (entry.long_name) |long_name| {
                //std.log.info(.NONE, "Long compare\n", .{});
                if (std.mem.eql(u8, name, long_name)) {
                    match = true;
                }
            } else {
                //std.log.info(.NONE, "Short compare\n", .{});
                // TODO: Re do all of this as it is a mess
                //       Idea: Remove spaces from fat name, then compare
                // Name can be 12 characters long (max)
                var short_name: [12]u8 = undefined;
                var i: usize = 0;
                while (entry.fat_dir.name[i] != 0x20) : (i += 1) {
                    short_name[i] = entry.fat_dir.name[i];
                }
                
                if (!entry.fat_dir.isDir()) {
                    // Add the '.'
                    short_name[i] = '.';
                    i += 1;
                    var j: usize = 0;
                    while (j < 3) : ({
                        i += 1;
                        j += 1;
                    }) {
                        short_name[i] = entry.fat_dir.ext[j];
                    }
                }
                // Shrink to the actual size
                //short_name = short_name[0.. i-1];
                //std.log.info(.NONE, "We have: {}\n", .{short_name[0 .. i]});
                
                if (std.ascii.eqlIgnoreCase(name, short_name[0 .. i])) {
                    match = true;
                }
            }
            if (match) {
                var node = try self.allocator.create(vfs.Node);
                if (entry.fat_dir.isDir()) {
                    node.* = .{ .Dir = .{ .fs = self.fs, .mount = null } };
                    //std.log.info(.NONE, "DIR\n", .{});
                } else {
                    node.* = .{ .File = .{ .fs = self.fs } };
                    //std.log.info(.NONE, "FILE\n", .{});
                }
                var alloc_entry = try self.allocator.create(OpenedNode);
                alloc_entry.* = entry;
                var value = try self.opened_files.getOrPut(node);
                if (value.found_existing) {
                    std.log.info(.NONE, "Oh\n", .{});
                    unreachable;
                }
                value.entry.value = alloc_entry;
                // try self.opened_files.put(node, alloc_entry);
                std.log.info(.NONE, "PUT, now listing\n", .{});
                for (self.opened_files.items()) |e| {
                    std.log.info(.NONE, "OPENED FILE: {}\n", .{e});
                }
                //std.log.info(.NONE, "NODE: {X} = {}\n", .{@ptrToInt(node), node});
                return node;
            }
        }

        switch (flags) {
            .NO_CREATION => return vfs.Error.NoSuchFileOrDir,
            .CREATE_DIR => return error.OutOfMemory,
            .CREATE_FILE => return error.OutOfMemory,
        }
    }

    ///
    /// Destroy this file system.
    ///
    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self.fs);
        self.allocator.destroy(self);
    }

    const FAT_ADDRESS_MASK: usize = 0x0FFFFFFF;
    const FAT_END: usize = 0x0FFFFFF8;

    // TODO: Add errdefer
    fn readClusterChain(self: *Self, first_cluster: usize, file_size: usize) (Allocator.Error || std.io.FixedBufferStream([]u8).ReadError)![]u8 {
        // Read the FAT
        // We can calculate the size for this
        // Always round up
        //const fat_size = ((file_size / (self.boot_record.bytes_per_sector * self.boot_record.sectors_per_cluster)) + 1) * @sizeOf(u32);
        // TODO: See if I can find the actual size of the FAT
        const fat_size = self.boot_record.bytes_per_sector;
        std.log.info(.NONE, "FAT size: {}\n", .{fat_size / 4});
        // *4 as we need u32
        var fat_temp = try self.allocator.alloc(u8, fat_size);
        defer self.allocator.free(fat_temp);

        // Seek to the FAT
        // The FAT is just after the reserved sectors
        try self.stream.seekTo(self.boot_record.reserved_sectors * self.boot_record.bytes_per_sector);
        var read_count = try self.stream.reader().readAll(fat_temp);
        if (read_count != fat_size) {
            std.log.info(.NONE, "Read error: {} != {}\n", .{read_count, fat_size});
            unreachable;
        }
        // Convert fat to u32's
        var fat = std.mem.bytesAsSlice(u32, fat_temp);

        // Follow the cluster chain
        var current_cluster = first_cluster;
        var sector_mem = try self.allocator.alloc(u8, file_size);
        var read_index: usize = 0;
        var read_index_next = std.math.min(file_size, (self.boot_record.bytes_per_sector * self.boot_record.sectors_per_cluster));
        std.log.info(.NONE, "Start reading from: {} to: {} at cluster: {}\n", .{read_index, read_index_next, current_cluster});
        while (current_cluster != 0 and (current_cluster & FAT_ADDRESS_MASK) < FAT_END): ({
            read_index = read_index_next;
            read_index_next = std.math.min(file_size, read_index_next + (self.boot_record.bytes_per_sector * self.boot_record.sectors_per_cluster));
            // Get the next cluster from the FAT
            current_cluster = fat[current_cluster];
        }) {
            // Seek to the sector where the cluster is
            const sector = self.boot_record.clusterToSector(first_cluster);
            try self.stream.seekTo(sector * self.boot_record.bytes_per_sector);

            // Read the sector
            std.log.info(.NONE, "Reading from: {} to: {} as cluster: {}\n", .{read_index, read_index_next, current_cluster});
            read_count = try self.stream.reader().readAll(sector_mem[read_index..read_index_next]);
        }
        std.log.info(.NONE, "E: {}\n", .{sector_mem});
        return sector_mem;
    }

    ///
    /// Parse a 32 byte block as part of a long name block defined in the FAT32.
    ///
    /// Arguments:
    ///     IN self: *Self - Self. For the allocator
    ///     IN bytes: []u8 - The bytes to parse.
    ///
    /// Return: []u8
    ///     The long name part parsed.
    ///
    /// Error: Allocator.Error
    ///     error.OutOfMemory - If there isn't enough memory to allocate the long name part.
    ///
    fn parseLongNamePart(allocator: *Allocator, bytes: []u8) Allocator.Error![]u8 {
        // Each entry can hold 13 characters
        var buff = try allocator.alloc(u8, 13);
        var buff_index: usize = 0;

        // This is the index into the bytes to parse.
        // We are going to assume that u8 characters not u16 (UTF-8).
        // We can skip the fist byte as this is the identifier for a long name, but we already know that.
        var index: usize = 1;

        // Characters are 2 bytes long
        // First 5 characters of this entry
        // Name is null terminated
        while (index < 11 and bytes[index] != 0x00) : ({
            index += 2;
            buff_index += 1;
        }) {
            buff[buff_index] = bytes[index];
            std.debug.assert(bytes[index + 1] == 0x00);
        }

        // Attribute should be 0x0F (as this indicates a long name)
        std.debug.assert(bytes[11] == 0x0F);
        std.debug.assert(bytes[12] == 0x00);

        // TODO: Check the check sum
        //std.log.info(.NONE, "Long name checksum: {X}\n", .{bytes[13]});
        // var i: usize = 0;
        // var sum: u8 = 0;
        // while (i < 11) : (i += 1) {
        //     const temp = if (sum & 1 > 0) 0x80 else 0;
        //     sum = temp + (sum >> 1) + short_name[i];
        // }

        // Set us to the next part of the long name if we null terminated early
        index = 14;
        // Next is 6 characters long
        // If the previous part of the name is done, then the rest of the parts will be 0xFF
        while (index < 26 and bytes[index] != 0x00 and bytes[index] != 0xFF) : ({
            index += 2;
            buff_index += 1;
        }) {
            buff[buff_index] = bytes[index];
            std.debug.assert(bytes[index + 1] == 0x00);
        }

        // Always zero
        std.debug.assert(bytes[26] == 0x00);
        std.debug.assert(bytes[27] == 0x00);

        index = 28;
        // Last 2 characters
        // If the previous part of the name is done, then the rest of the parts will be 0xFF
        while (index < 32 and bytes[index] != 0x00 and bytes[index] != 0xFF) : ({
            index += 2;
            buff_index += 1;
        }) {
            buff[buff_index] = bytes[index];
            std.debug.assert(bytes[index + 1] == 0x00);
        }

        return buff[0..buff_index];
    }

    // FAT32 can eat my ass, so can the wiki's as there is no good info on this, this was all reverse engineered >:(
    // Testing:
    // - A FAT32 with no files or folders
    // - A FAT32 with 1 file (short name)
    // - A FAT32 with 1 folder (short name)
    // - A FAT32 with 1 file and 1 folder (short name)
    // - A FAT32 with 1 file (long name)
    // - A FAT32 with 1 folder (long name)
    // - A FAT32 with 1 file and folder (long name)
    // - A FAT32 with 1 file (short) and 1 file (long)
    // - A FAT32 with 1 file (short) and 1 folder (long)
    // - ...
    // Maybe just one FAT with all of above:
    // - A FAT32 with:
    //   Nothing,
    //   1 file (short),
    //   1 file (short, start letter: A (This is the start byte for long names)),
    //   1 file (long),
    //   1 file (long, start letter: B (This is the start byte for long names - Will need to check this as it could be C depending on how long the name is)),
    //   1 file (longest name),
    //   1 file (short, deleted),
    //   1 file (long, deleted),
    //   1 folder (short),
    //   1 folder (short, start letter: A (This is the start byte for long names)),
    //   1 folder (long),
    //   1 folder (long, start letter: B (This is the start byte for long names - Will need to check this as it could be C depending on how long the name is)),
    //   1 folder (longest name),
    //   1 folder (short, deleted),
    //   1 folder (long, deleted),
    //   Ensure all ove the above is longer than a sector (512 bytes)
    //   Add files with different cases
    //   Also add a large file (more than a cluster), then delete it, add a smaller file, then re-add the large file. This will create fragmentation.
    // This will parse one entry
    pub fn listDirectory(self: *Self, boot_sector: *BootRecord) void {
        const root_sector = boot_sector.clusterToSector(boot_sector.root_directory_cluster_number);
        //const root_sector = (boot_sector.sectors_per_fat32 * boot_sector.fat_tables) + boot_sector.reserved_sectors + ((boot_sector.root_directory_cluster_number - 2) * boot_sector.sectors_per_cluster);
        //std.log.info(.NONE, "{} == {}\n", .{root_sector, root_sector2});
        //std.debug.assert(root_sector == root_sector2);
        std.log.info(.NONE, "FAT root directory LBA: {X}\n", .{root_sector * boot_sector.bytes_per_sector});

        var it = DirIterator.init(self.allocator, self.root_node.sector, self.stream) catch unreachable;
        defer it.deinit();
        while (it.next() catch |e| {
            std.log.info(.NONE, "AHHH: {}\n", .{e});
            unreachable;
        }) |entry| {
            std.log.info(.NONE, "Long name: {}\n", .{entry.long_name});
            entry.fat_dir.print();
            self.allocator.destroy(entry.fat_dir);
            if (entry.long_name) |name| self.allocator.free(name);
            //self.allocator.destroy(entry);
        }
        std.log.info(.NONE, "Done\n", .{});
    }

    ///
    /// Initialise a FAT32 filesystem.
    /// TODO: Deal with partitions
    ///
    /// Arguments
    ///     IN allocator: *Allocator - Allocate memory.
    ///
    /// Return: *Fat32
    ///     The pointer to a Fat32 filesystem.
    ///
    /// Error: Allocator.Error || std.io.FixedBufferStream([]u8).ReadError
    ///     error.OutOfMemory - If there is no more memory. Any memory allocated will be freed.
    ///
    pub fn init(stream: *std.io.FixedBufferStream([]u8), allocator: *Allocator) (Allocator.Error || Error)!*Fat32 {
        const fat32_fs = try allocator.create(Fat32);
        errdefer allocator.destroy(fat32_fs);
        const fs = try allocator.create(vfs.FileSystem);
        errdefer allocator.destroy(fs);

        const root_node = try allocator.create(vfs.Node);
        errdefer allocator.destroy(root_node);

        root_node.* = .{
            .Dir = .{
                .fs = fs,
                .mount = null,
            },
        };

        fs.* = .{
            .open = open,
            .close = close,
            .read = read,
            .write = write,
            .instance = &fat32_fs.instance,
            .getRootNode = getRootNode,
        };

        // We need to get the root directory sector. For this we need to read the boot sector.
        var boot_sector_raw: [512]u8 = undefined;
        const read_count = try stream.reader().readAll(boot_sector_raw[0..]);

        // Do some checks:
        if (boot_sector_raw[510] != 0x55 or boot_sector_raw[511] != 0xAA) {
            return Error.BadMBRMagic;
        }

        // FIXME: Test if we need to alloc memory for this
        var boot_sector = BootRecord.init(boot_sector_raw[0..90]);
        if (!std.mem.eql(u8, "FAT32   ", boot_sector.filesystem_type[0..])) {
            std.log.info(.NONE, "{}:\n", .{boot_sector.filesystem_type});
            return Error.BadFSType;
        }

        std.log.info(.NONE, "ROOT\n", .{});

        fat32_fs.* = .{
            .fs = fs,
            .allocator = allocator,
            .instance = 32,
            .boot_record = boot_sector,
            .stream = stream,
            .root_node = .{
                .node = root_node,
                .sector = boot_sector.clusterToSector(boot_sector.root_directory_cluster_number),
            },
            .opened_files = AutoHashMap(*const vfs.Node, *OpenedNode).init(allocator),
        };

        std.debug.assert(boot_sector.bytes_per_sector == 512);

        fat32_fs.listDirectory(&boot_sector);

        // This would be nice, but packed struts are butts
        // var boot_sec: [1]BootRecord = undefined;
        // std.mem.copy(u8, std.mem.sliceAsBytes(boot_sec[0..]), boot_sector);

        //std.log.info(.NONE, "{}\n", .{@sizeOf(BootRecord)});

        //std.debug.assert(@sizeOf(BootRecord) == 512);

        boot_sector.print();

        return fat32_fs;
    }
};
