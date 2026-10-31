import Darwin
import Foundation

public enum DeleteCheck {
    /// Run right before deleting. Returns nil if `path` still leads to what the
    /// scan found, or a reason to stop: a folder on the way was replaced by a
    /// symlink (the delete would land somewhere else), or the item is gone or
    /// changed type.
    public static func problem(path: String, isDirectory: Bool) -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        guard let resolved = realpath(parent, nil) else {
            return "Its folder no longer exists. Rescan and try again."
        }
        let real = String(cString: resolved)
        free(resolved)
        if Paths.withoutDataVolume(real) != Paths.withoutDataVolume(parent) {
            return "A folder in its path changed since the scan and now leads to \(real). Rescan and try again."
        }
        var st = stat()
        guard lstat(path, &st) == 0 else {
            return "It no longer exists. Rescan to update the list."
        }
        if ((st.st_mode & S_IFMT) == S_IFDIR) != isDirectory {
            return "It changed since the scan. Rescan and try again."
        }
        return nil
    }
}
