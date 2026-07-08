import Foundation
import Darwin

public struct FilePermissionState: Equatable, Sendable {
    public var posixMode: UInt16
    public var ownerID: UInt32
    public var groupID: UInt32
    public var isLocked: Bool
    public var isQuarantined: Bool

    public var octalMode: String {
        String(format: "%03o", posixMode & 0o777)
    }
}

public struct PermissionCommandPlan: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public enum PermissionTools {
    private static let quarantineXattr = "com.apple.quarantine"

    public static func state(for url: URL) -> FilePermissionState? {
        guard let attrs = try? FileManager.default.attributesOfItem(
            atPath: url.path) else { return nil }
        let mode = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        let owner = (attrs[.ownerAccountID] as? NSNumber)?.uint32Value ?? 0
        let group = (attrs[.groupOwnerAccountID] as? NSNumber)?.uint32Value ?? 0
        let flags = (attrs[.extensionHidden] as? NSNumber)?.uint32Value ?? 0
        let locked = (attrs[.immutable] as? Bool) ?? ((flags & UInt32(UF_IMMUTABLE)) != 0)
        return FilePermissionState(posixMode: mode,
                                   ownerID: owner,
                                   groupID: group,
                                   isLocked: locked,
                                   isQuarantined: hasQuarantine(url))
    }

    public static func chmodPlan(url: URL, octalMode: String,
                                 recursive: Bool) -> PermissionCommandPlan? {
        guard UInt16(octalMode, radix: 8) != nil else { return nil }
        var args = ["chmod"]
        if recursive { args.append("-R") }
        args += [octalMode, url.path]
        return PermissionCommandPlan(executable: "/bin/chmod", arguments: args)
    }

    public static func chownPlan(url: URL, owner: String?, group: String?,
                                 recursive: Bool) -> PermissionCommandPlan? {
        let trimmedOwner = owner?.trimmingCharacters(in: .whitespaces) ?? ""
        let trimmedGroup = group?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !trimmedOwner.isEmpty || !trimmedGroup.isEmpty else { return nil }
        var args = ["chown"]
        if recursive { args.append("-R") }
        args += ["\(trimmedOwner):\(trimmedGroup)", url.path]
        return PermissionCommandPlan(executable: "/usr/sbin/chown",
                                     arguments: args)
    }

    public static func lockedPlan(url: URL, locked: Bool,
                                  recursive: Bool) -> PermissionCommandPlan {
        var args = ["chflags"]
        if recursive { args.append("-R") }
        args += [locked ? "uchg" : "nouchg", url.path]
        return PermissionCommandPlan(executable: "/usr/bin/chflags",
                                     arguments: args)
    }

    public static func quarantinePlan(url: URL, quarantined: Bool,
                                      recursive: Bool) -> PermissionCommandPlan {
        var args = ["xattr"]
        if recursive { args.append("-r") }
        if quarantined {
            args += ["-w", quarantineXattr, "0081;FileExplorer;FileExplorer;", url.path]
        } else {
            args += ["-d", quarantineXattr, url.path]
        }
        return PermissionCommandPlan(executable: "/usr/bin/xattr",
                                     arguments: args)
    }

    public static func setLocked(_ locked: Bool, for url: URL) throws {
        var values = URLResourceValues()
        values.isUserImmutable = locked
        var editable = url
        try editable.setResourceValues(values)
    }

    public static func clearQuarantine(_ url: URL) throws {
        if removexattr(url.path, quarantineXattr, 0) != 0, errno != ENOATTR {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func hasQuarantine(_ url: URL) -> Bool {
        getxattr(url.path, quarantineXattr, nil, 0, 0, 0) >= 0
    }
}
