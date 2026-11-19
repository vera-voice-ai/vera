import Foundation

/// The one place the release version lives. Scripts read it from here to stamp the app bundle;
/// the changelog in docs/index.html uses the same number.
public enum VeraRelease {
    public static let version = "0.1.6"
    public static let build = 7
}
