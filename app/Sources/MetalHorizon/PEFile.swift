import Foundation

// Wine tells its builtin DLLs apart by the name in their export directory. The DirectX 12 shim is d3d12.dll and loads
// Apple's d3d12.dll from a copy named apd12.dll: that copy's export name must say apd12.dll too, or Wine hands back the
// shim. Ported from Highball's PEExportName.swift (GPL-3.0) and tools/pe_tools.py. Apple's file itself is never
// changed or redistributed changed: the copy is made and renamed on this Mac, as Highball does.

enum PEFile {
    enum Failure: Error, CustomStringConvertible {
        case notPE(String), noExportName(String), nameTooLong(String)
        var description: String {
            switch self {
            case .notPE(let p): return "\(p) is not a PE file"
            case .noExportName(let p): return "\(p) has no export name"
            case .nameTooLong(let n): return "\(n) is longer than the name it replaces"
            }
        }
    }

    private static func u16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ o: Int) -> Int { u16(b, o) | u16(b, o + 2) << 16 }

    /// File offset of the export directory's name, or nil.
    static func exportNameOffset(_ b: [UInt8]) -> Int? {
        guard b.count > 0x40, b[0] == 0x4D, b[1] == 0x5A else { return nil }
        let pe = u32(b, 0x3C)
        guard pe + 24 < b.count, b[pe..<pe + 4] == [0x50, 0x45, 0, 0] else { return nil }
        let sections = u16(b, pe + 6), optSize = u16(b, pe + 20), opt = pe + 24
        guard optSize >= 96, opt + optSize <= b.count else { return nil }
        let dataDirectories = opt + (u16(b, opt) == 0x20B ? 112 : 96)
        guard dataDirectories + 8 <= b.count else { return nil }
        let exportRVA = u32(b, dataDirectories), exportSize = u32(b, dataDirectories + 4)
        guard exportRVA != 0, exportSize != 0 else { return nil }
        var table: [(va: Int, size: Int, raw: Int)] = []
        for i in 0..<sections {
            let s = opt + optSize + 40 * i
            guard s + 40 <= b.count else { return nil }
            table.append((u32(b, s + 12), max(u32(b, s + 8), u32(b, s + 16)), u32(b, s + 20)))
        }
        func offset(_ rva: Int) -> Int? {
            table.first { $0.va <= rva && rva < $0.va + max($0.size, 1) }.map { rva - $0.va + $0.raw }
        }
        guard let directory = offset(exportRVA), directory + 40 <= b.count,
              let name = offset(u32(b, directory + 12)), name < b.count else { return nil }
        return name
    }

    /// Writes `newName` over the export name of the DLL at `path`, padding with zeros.
    static func renameExport(at path: String, to newName: String) throws {
        var b = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        guard b.count > 2, b[0] == 0x4D, b[1] == 0x5A else { throw Failure.notPE(path) }
        guard let start = exportNameOffset(b) else { throw Failure.noExportName(path) }
        var end = start
        while end < b.count && b[end] != 0 { end += 1 }
        let name = Array(newName.utf8)
        guard name.count <= end - start else { throw Failure.nameTooLong(newName) }
        b.replaceSubrange(start..<end, with: name + [UInt8](repeating: 0, count: end - start - name.count))
        try Data(b).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
