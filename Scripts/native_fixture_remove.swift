#!/usr/bin/env swift
import CryptoKit
import Darwin
import Foundation

// Host-side removal or restoration for one identified native UI-test fixture.
// Usage: native_fixture_remove <absolute-path> <sha256> <ledger-uuid> [restore-path]
// This helper intentionally never discovers or enumerates Trash contents.

struct FixtureRemovalError: Error, CustomStringConvertible {
    let description: String
}

func fail(_ message: String) -> FixtureRemovalError {
    FixtureRemovalError(description: message)
}

func validatePath(_ path: String) throws -> URL {
    guard path.hasPrefix("/") else { throw fail("The fixture path must be absolute.") }
    let url = URL(fileURLWithPath: path).standardizedFileURL
    let trash = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".Trash", isDirectory: true).standardizedFileURL
    guard url.deletingLastPathComponent().path == trash.path,
          url.pathExtension == "tally",
          url.lastPathComponent.hasPrefix("Native-A-") else {
        throw fail("The path is not an allowed native test fixture in the current user's Trash.")
    }
    var parentAttributes = stat()
    if lstat(trash.path, &parentAttributes) == 0 {
        guard (parentAttributes.st_mode & S_IFMT) == S_IFDIR else {
            throw fail("The Trash parent is not a nonsymlink directory.")
        }
    } else if errno != ENOENT {
        throw fail("The Trash parent could not be inspected (errno \(errno)).")
    }
    return url
}

func validateRestorePath(_ path: String, source: URL) throws -> URL {
    guard path.hasPrefix("/") else { throw fail("The restore path must be absolute.") }
    let destination = URL(fileURLWithPath: path).standardizedFileURL
    let root = destination.deletingLastPathComponent()
    let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Containers/com.asherbloom.Tally/Data/Library/Caches", isDirectory: true
    ).standardizedFileURL
    let prefix = "TallyNativeDocumentTests-"
    guard root.deletingLastPathComponent() == cache,
          root.lastPathComponent.hasPrefix(prefix),
          let session = UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))),
          root.lastPathComponent == prefix + session.uuidString,
          destination.lastPathComponent == "Native-A-\(session.uuidString.prefix(8)).tally",
          destination.lastPathComponent == source.lastPathComponent else {
        throw fail("The restore destination does not belong to this fixture session.")
    }
    var attributes = stat()
    guard lstat(root.path, &attributes) == 0,
          (attributes.st_mode & S_IFMT) == S_IFDIR,
          root.resolvingSymlinksInPath() == root else {
        throw fail("The restore directory must be an existing nonsymlink fixture directory.")
    }
    let marker = root.appendingPathComponent(".test-owner")
    guard lstat(marker.path, &attributes) == 0,
          (attributes.st_mode & S_IFMT) == S_IFREG,
          try String(contentsOf: marker, encoding: .utf8) == session.uuidString else {
        throw fail("The restore directory ownership marker does not match.")
    }
    if lstat(destination.path, &attributes) == 0 || errno != ENOENT {
        throw fail("The restore destination must be absent.")
    }
    return destination
}

/// Returns false only if the exact fixture is already absent. An open descriptor
/// prevents following a symlink swapped in between metadata and content checks.
func verifyFixture(at url: URL, sha256 expectedHash: String, ledgerID: UUID) throws -> Bool {
    var attributes = stat()
    guard lstat(url.path, &attributes) == 0 else {
        if errno == ENOENT { return false }
        throw fail("The fixture could not be inspected (errno \(errno)).")
    }
    guard (attributes.st_mode & S_IFMT) == S_IFREG else {
        throw fail("The fixture is not a regular nonsymlink file.")
    }

    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
        if errno == ENOENT { return false }
        throw fail("The fixture could not be opened safely (errno \(errno)).")
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var openedAttributes = stat()
    guard fstat(descriptor, &openedAttributes) == 0,
          (openedAttributes.st_mode & S_IFMT) == S_IFREG,
          openedAttributes.st_dev == attributes.st_dev,
          openedAttributes.st_ino == attributes.st_ino,
          openedAttributes.st_size >= 0,
          openedAttributes.st_size <= 10 * 1_024 * 1_024 else {
        throw fail("The fixture changed identity or has an invalid size.")
    }
    let data = try handle.read(upToCount: 10 * 1_024 * 1_024 + 1) ?? Data()
    guard data.count <= 10 * 1_024 * 1_024,
          Int64(data.count) == openedAttributes.st_size else {
        throw fail("The fixture changed size while being read.")
    }
    let actualHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard actualHash == expectedHash else { throw fail("The fixture SHA256 does not match.") }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let idText = object["id"] as? String,
          UUID(uuidString: idText) == ledgerID else {
        throw fail("The fixture ledger UUID does not match.")
    }
    var finalAttributes = stat()
    guard lstat(url.path, &finalAttributes) == 0 else {
        if errno == ENOENT { return false }
        throw fail("The fixture could not be rechecked (errno \(errno)).")
    }
    guard (finalAttributes.st_mode & S_IFMT) == S_IFREG,
          finalAttributes.st_dev == openedAttributes.st_dev,
          finalAttributes.st_ino == openedAttributes.st_ino else {
        throw fail("The fixture changed identity during verification.")
    }
    return true
}

do {
    guard CommandLine.arguments.count == 4 || CommandLine.arguments.count == 5 else {
        throw fail("Usage: native_fixture_remove <absolute-path> <sha256> <ledger-uuid> [restore-path]")
    }
    let url = try validatePath(CommandLine.arguments[1])
    let expectedHash = CommandLine.arguments[2].lowercased()
    guard expectedHash.utf8.count == 64,
          expectedHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
          let expectedID = UUID(uuidString: CommandLine.arguments[3]) else {
        throw fail("A valid SHA256 and ledger UUID are required.")
    }
    if CommandLine.arguments.count == 5 {
        let destination = try validateRestorePath(CommandLine.arguments[4], source: url)
        guard try verifyFixture(at: url, sha256: expectedHash, ledgerID: expectedID) else {
            throw fail("The fixture to restore is absent.")
        }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var moveError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forMoving,
                               writingItemAt: destination, options: [], error: &coordinationError) { from, to in
            do {
                guard from.standardizedFileURL == url, to.standardizedFileURL == destination,
                      try verifyFixture(at: from, sha256: expectedHash, ledgerID: expectedID) else {
                    throw fail("The fixture changed before restoration.")
                }
                _ = try validateRestorePath(to.path, source: from)
                coordinator.item(at: from, willMoveTo: to)
                try FileManager.default.moveItem(at: from, to: to)
                coordinator.item(at: from, didMoveTo: to)
            } catch { moveError = error }
        }
        if let moveError { throw moveError }
        if let coordinationError { throw coordinationError }
        exit(0)
    }
    guard try verifyFixture(at: url, sha256: expectedHash, ledgerID: expectedID) else {
        exit(0)
    }

    var coordinationError: NSError?
    var removalError: Error?
    NSFileCoordinator(filePresenter: nil).coordinate(
        writingItemAt: url, options: .forDeleting, error: &coordinationError
    ) { coordinatedURL in
        do {
            let checkedURL = try validatePath(coordinatedURL.path)
            guard checkedURL.path == url.path else {
                throw fail("File coordination changed the expected fixture path.")
            }
            guard try verifyFixture(at: checkedURL, sha256: expectedHash, ledgerID: expectedID) else {
                return
            }
            // unlink cannot recursively remove a directory if the path changes
            // unexpectedly after verification. Missing is idempotent success.
            if unlink(checkedURL.path) != 0, errno != ENOENT {
                throw fail("The verified fixture could not be removed (errno \(errno)).")
            }
        } catch {
            removalError = error
        }
    }
    if let removalError { throw removalError }
    if let coordinationError {
        // Another cleanup may have removed the exact item before coordination.
        if try verifyFixture(at: url, sha256: expectedHash, ledgerID: expectedID) {
            throw coordinationError
        }
    }
} catch {
    FileHandle.standardError.write(Data("native_fixture_remove: \(error)\n".utf8))
    exit(1)
}
