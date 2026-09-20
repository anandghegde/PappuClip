/// Every name that a rename would touch (PRD §14, architecture §1).
///
/// Nothing else in the code base may spell these out. The only other place that repeats the
/// bundle-identifier prefix is `App/project.yml`, because XcodeGen cannot read Swift constants.
public enum AppIdentity {
    public static let appName = "PappuClip"

    /// Prefix for the app, its XPC services and the CLI.
    public static let bundleIDPrefix = "app.pappuclip"
    public static let appBundleID = bundleIDPrefix + ".PappuClip"

    /// `pappuclip://` (SCR-2).
    public static let urlScheme = "pappuclip"

    /// Reserved for extensions signed by our directory (FMT-6).
    public static let reservedExtensionIdentifierPrefix = "app.pappuclip."

    /// Logging and signpost subsystem.
    public static let logSubsystem = bundleIDPrefix

    /// File types from the compatibility table in extension spec §8.1. Native forms first.
    public enum FileExtension {
        public static let package = ["pappuext", "popclipext"]
        public static let zippedPackage = ["pappuextz", "popclipextz"]
        public static let snippet = ["pappucliptxt", "popcliptxt"]
    }
}
