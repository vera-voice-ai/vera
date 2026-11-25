"""Writes phone/Vera.xcodeproj — the iPhone app's Xcode project — from this description; run it again after changing it.

Why a project and not the old app package (VeraPhone.swiftpm/Package.swift): the Live Activity (Dynamic Island, lock
screen) is an app extension, and the app-package format has no extensions. The folders are *synchronized*: every file
in them belongs to its target, so adding a .swift file needs no change here.

  VeraPhone.swiftpm/Sources  → app «Vera» ($(VERA_BUNDLE_PREFIX).phone) — the app's Swift code (path kept as it was)
  Vera/                      → app: Info.plist (merged), Assets.xcassets
  Models/                    → app: a folder resource «Models» (ears and voice; filled by scripts/phone-assets.sh)
  Shared/                    → app + extension: the Live Activity's data
  VeraWidgets/               → extension «VeraWidgets» ($(VERA_BUNDLE_PREFIX).phone.widgets)
  Vera.xcconfig              → both targets: bundle prefix, signing team, tunnel host; the owner's own values go to
                               Local.xcconfig next to it (not in git; sample: Local.example.xcconfig)
Packages: ../app (PhoneWire, SileroVoice, VeraKit, VeraMusic, VeraListen), VeraPhoneDeps (C bridge + sherpa-onnx, onnxruntime),
Google's ios-navigation-sdk (exact version below).

Build: cd phone && xcodebuild -project Vera.xcodeproj -scheme Vera -destination 'platform=iOS Simulator,name=iPhone 18 Pro' build
"""
import hashlib
import os

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "phone")
APP_ID = "$(VERA_BUNDLE_PREFIX).phone"
WIDGETS_ID = APP_ID + ".widgets"
NAV_SDK = ("https://github.com/googlemaps/ios-navigation-sdk", "11.4.0")
IOS = "26.0"


def oid(name):
    return hashlib.md5(name.encode()).hexdigest()[:24].upper()


def q(v):
    """A pbxproj value: quoted unless it is a plain token."""
    s = str(v)
    if s and all(c.isalnum() or c in "._/$" for c in s) and not s[0].isdigit():
        return s
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def dump(v, ind):
    pad = "\t" * ind
    if isinstance(v, dict):
        lines = ["{"]
        for k, x in v.items():
            lines.append(f"{pad}\t{q(k)} = {dump(x, ind + 1)};")
        lines.append(pad + "}")
        return "\n".join(lines)
    if isinstance(v, list):
        if not v:
            return "(\n" + pad + ")"
        return "(\n" + "".join(f"{pad}\t{dump(x, ind + 1)},\n" for x in v) + pad + ")"
    return q(v)


objects = {}


def add(name, obj):
    objects[oid(name)] = obj
    return oid(name)


# Files and folders
app_product = add("product.app", {"isa": "PBXFileReference", "explicitFileType": "wrapper.application",
                                    "includeInIndex": "0", "path": "Vera.app", "sourceTree": "BUILT_PRODUCTS_DIR"})
ext_product = add("product.appex", {"isa": "PBXFileReference", "explicitFileType": "wrapper.app-extension",
                                     "includeInIndex": "0", "path": "VeraWidgets.appex", "sourceTree": "BUILT_PRODUCTS_DIR"})
xcconfig = add("ref.xcconfig", {"isa": "PBXFileReference", "lastKnownFileType": "text.xcconfig", "path": "Vera.xcconfig",
                                  "sourceTree": "<group>"})
models = add("ref.models", {"isa": "PBXFileReference", "lastKnownFileType": "folder", "path": "Models", "sourceTree": "<group>"})

vera_exc = add("exc.vera.plist", {"isa": "PBXFileSystemSynchronizedBuildFileExceptionSet",
                                  "membershipExceptions": ["Info.plist"], "target": oid("target.app")})
ext_exc = add("exc.widgets.plist", {"isa": "PBXFileSystemSynchronizedBuildFileExceptionSet",
                                    "membershipExceptions": ["Info.plist"], "target": oid("target.ext")})
g_sources = add("sync.sources", {"isa": "PBXFileSystemSynchronizedRootGroup", "path": "VeraPhone.swiftpm/Sources",
                                  "name": "Sources", "sourceTree": "<group>"})
g_vera = add("sync.vera", {"isa": "PBXFileSystemSynchronizedRootGroup", "exceptions": [vera_exc], "path": "Vera",
                            "sourceTree": "<group>"})
g_shared = add("sync.shared", {"isa": "PBXFileSystemSynchronizedRootGroup", "path": "Shared", "sourceTree": "<group>"})
g_widgets = add("sync.widgets", {"isa": "PBXFileSystemSynchronizedRootGroup", "exceptions": [ext_exc],
                                  "path": "VeraWidgets", "sourceTree": "<group>"})
products = add("group.products", {"isa": "PBXGroup", "children": [app_product, ext_product], "name": "Products",
                                  "sourceTree": "<group>"})
main = add("group.main", {"isa": "PBXGroup", "children": [xcconfig, g_sources, g_vera, g_shared, g_widgets, models, products],
                          "sourceTree": "<group>"})

# Packages
pkg_app = add("pkg.app", {"isa": "XCLocalSwiftPackageReference", "relativePath": "../app"})
pkg_deps = add("pkg.deps", {"isa": "XCLocalSwiftPackageReference", "relativePath": "VeraPhoneDeps"})
pkg_nav = add("pkg.nav", {"isa": "XCRemoteSwiftPackageReference", "repositoryURL": NAV_SDK[0],
                          "requirement": {"kind": "exactVersion", "version": NAV_SDK[1]}})
app_products = [("PhoneWire", pkg_app), ("SileroVoice", pkg_app), ("VeraKit", pkg_app), ("VeraMusic", pkg_app), ("VeraListen", pkg_app),
                ("CSherpaPhone", pkg_deps), ("GoogleNavigation", pkg_nav)]
deps = []
link_files = []
for name, pkg in app_products:
    dep = add("dep." + name, {"isa": "XCSwiftPackageProductDependency", "package": pkg, "productName": name})
    deps.append(dep)
    link_files.append(add("bf.link." + name, {"isa": "PBXBuildFile", "productRef": dep}))

# Build phases
models_file = add("bf.models", {"isa": "PBXBuildFile", "fileRef": models})
embed_file = add("bf.embed", {"isa": "PBXBuildFile", "fileRef": ext_product,
                              "settings": {"ATTRIBUTES": ["RemoveHeadersOnCopy"]}})
app_phases = [
    add("phase.app.sources", {"isa": "PBXSourcesBuildPhase", "buildActionMask": "2147483647", "files": [],
                              "runOnlyForDeploymentPostprocessing": "0"}),
    add("phase.app.frameworks", {"isa": "PBXFrameworksBuildPhase", "buildActionMask": "2147483647",
                                 "files": link_files, "runOnlyForDeploymentPostprocessing": "0"}),
    add("phase.app.resources", {"isa": "PBXResourcesBuildPhase", "buildActionMask": "2147483647",
                                "files": [models_file], "runOnlyForDeploymentPostprocessing": "0"}),
    add("phase.app.embed", {"isa": "PBXCopyFilesBuildPhase", "buildActionMask": "2147483647", "dstPath": "",
                            "dstSubfolderSpec": "13", "files": [embed_file], "name": "Embed Foundation Extensions",
                            "runOnlyForDeploymentPostprocessing": "0"}),
]
ext_phases = [
    add("phase.ext.sources", {"isa": "PBXSourcesBuildPhase", "buildActionMask": "2147483647", "files": [],
                              "runOnlyForDeploymentPostprocessing": "0"}),
    add("phase.ext.frameworks", {"isa": "PBXFrameworksBuildPhase", "buildActionMask": "2147483647", "files": [],
                                 "runOnlyForDeploymentPostprocessing": "0"}),
    add("phase.ext.resources", {"isa": "PBXResourcesBuildPhase", "buildActionMask": "2147483647", "files": [],
                                "runOnlyForDeploymentPostprocessing": "0"}),
]


def configs(name, common, debug=None, release=None, base=None):
    extra = {"baseConfigurationReference": base} if base else {}
    d = add(f"cfg.{name}.debug", {"isa": "XCBuildConfiguration", **extra, "buildSettings": {**common, **(debug or {})}, "name": "Debug"})
    r = add(f"cfg.{name}.release", {"isa": "XCBuildConfiguration", **extra, "buildSettings": {**common, **(release or {})}, "name": "Release"})
    return add(f"cfglist.{name}", {"isa": "XCConfigurationList", "buildConfigurations": [d, r],
                                   "defaultConfigurationIsVisible": "0", "defaultConfigurationName": "Release"})


# DEVELOPMENT_TEAM is not set here: it comes from Vera.xcconfig (Local.xcconfig), a target setting would override it.
signing = {"CODE_SIGN_STYLE": "Automatic", "IPHONEOS_DEPLOYMENT_TARGET": IOS,
           "SWIFT_VERSION": "6.0", "TARGETED_DEVICE_FAMILY": "1", "MARKETING_VERSION": "0.3", "CURRENT_PROJECT_VERSION": "1",
           "GENERATE_INFOPLIST_FILE": "YES", "SWIFT_EMIT_LOC_STRINGS": "NO", "ENABLE_PREVIEWS": "NO"}
app_cfg = configs("app", {**signing, "PRODUCT_NAME": "Vera", "PRODUCT_BUNDLE_IDENTIFIER": APP_ID,
                          "INFOPLIST_FILE": "Vera/Info.plist", "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                          "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
                          "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
                          "INFOPLIST_KEY_UISupportedInterfaceOrientations": "UIInterfaceOrientationPortrait",
                          "INFOPLIST_KEY_LSApplicationCategoryType": "public.app-category.productivity",
                          "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"]}, base=xcconfig)
ext_cfg = configs("ext", {**signing, "PRODUCT_NAME": "VeraWidgets", "PRODUCT_BUNDLE_IDENTIFIER": WIDGETS_ID,
                          "INFOPLIST_FILE": "VeraWidgets/Info.plist", "SKIP_INSTALL": "YES",
                          "APPLICATION_EXTENSION_API_ONLY": "YES",
                          "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks",
                                                      "@executable_path/../../Frameworks"]}, base=xcconfig)
project_cfg = configs("project", {
    "ALWAYS_SEARCH_USER_PATHS": "NO", "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES", "ENABLE_USER_SCRIPT_SANDBOXING": "YES", "GCC_NO_COMMON_BLOCKS": "YES",
    "IPHONEOS_DEPLOYMENT_TARGET": IOS, "SDKROOT": "iphoneos", "SWIFT_VERSION": "6.0", "COPY_PHASE_STRIP": "NO",
    "MTL_FAST_MATH": "YES", "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES"},
    debug={"DEBUG_INFORMATION_FORMAT": "dwarf", "ENABLE_TESTABILITY": "YES", "GCC_OPTIMIZATION_LEVEL": "0",
           "ONLY_ACTIVE_ARCH": "YES", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)",
           "SWIFT_OPTIMIZATION_LEVEL": "-Onone", "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE"},
    release={"DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym", "SWIFT_COMPILATION_MODE": "wholemodule",
             "VALIDATE_PRODUCT": "YES", "MTL_ENABLE_DEBUG_INFO": "NO"})

# Targets
proxy = add("proxy.ext", {"isa": "PBXContainerItemProxy", "containerPortal": oid("project"), "proxyType": "1",
                          "remoteGlobalIDString": oid("target.ext"), "remoteInfo": "VeraWidgets"})
dependency = add("tdep.ext", {"isa": "PBXTargetDependency", "target": oid("target.ext"), "targetProxy": proxy})
add("target.app", {"isa": "PBXNativeTarget", "buildConfigurationList": app_cfg, "buildPhases": app_phases,
                   "buildRules": [], "dependencies": [dependency],
                   "fileSystemSynchronizedGroups": [g_sources, g_vera, g_shared], "name": "Vera",
                   "packageProductDependencies": deps, "productName": "Vera", "productReference": app_product,
                   "productType": "com.apple.product-type.application"})
add("target.ext", {"isa": "PBXNativeTarget", "buildConfigurationList": ext_cfg, "buildPhases": ext_phases,
                   "buildRules": [], "dependencies": [], "fileSystemSynchronizedGroups": [g_widgets, g_shared],
                   "name": "VeraWidgets", "packageProductDependencies": [], "productName": "VeraWidgets",
                   "productReference": ext_product, "productType": "com.apple.product-type.app-extension"})
add("project", {"isa": "PBXProject",
                "attributes": {"BuildIndependentTargetsInParallel": "1", "LastSwiftUpdateCheck": "2720",
                               "LastUpgradeCheck": "2720",
                               "TargetAttributes": {oid("target.app"): {"CreatedOnToolsVersion": "27.2"},
                                                    oid("target.ext"): {"CreatedOnToolsVersion": "27.2"}}},
                "buildConfigurationList": project_cfg, "developmentRegion": "ru", "hasScannedForEncodings": "0",
                "knownRegions": ["ru", "Base"], "mainGroup": main, "minimizedProjectReferenceProxies": "1",
                "packageReferences": [pkg_app, pkg_deps, pkg_nav], "preferredProjectObjectVersion": "77",
                "productRefGroup": products, "projectDirPath": "", "projectRoot": "",
                "targets": [oid("target.app"), oid("target.ext")]})

body = "// !$*UTF8*$!\n" + dump({"archiveVersion": "1", "classes": {}, "objectVersion": "77",
                                   "objects": dict(sorted(objects.items())), "rootObject": oid("project")}, 0) + "\n"
proj = os.path.join(ROOT, "Vera.xcodeproj")
os.makedirs(os.path.join(proj, "xcshareddata", "xcschemes"), exist_ok=True)
open(os.path.join(proj, "project.pbxproj"), "w", encoding="utf-8").write(body)

ref = lambda: (f'<BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{oid("target.app")}" '
               f'BuildableName = "Vera.app" BlueprintName = "Vera" ReferencedContainer = "container:Vera.xcodeproj"></BuildableReference>')
scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2720" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            {ref()}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <LaunchAction buildConfiguration = "Debug" launchStyle = "0" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         {ref()}
      </BuildableProductRunnable>
   </LaunchAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"></ArchiveAction>
</Scheme>
"""
open(os.path.join(proj, "xcshareddata", "xcschemes", "Vera.xcscheme"), "w", encoding="utf-8").write(scheme)
print(proj)
