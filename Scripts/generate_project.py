"""Generates StitchPeek.xcodeproj.

    python3 Scripts/generate_project.py

The project is generated rather than hand-edited so target configuration stays reviewable in
a diff and can be regenerated if Xcode ever mangles it. Rerunning overwrites the .pbxproj and
the shared scheme; nothing else in the project directory is touched.
"""
import hashlib
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT = os.path.join(ROOT, "StitchPeek.xcodeproj")

BUNDLE_PREFIX = "com.bobbymarko.stitchpeek"
DEPLOYMENT_TARGET = "14.0"
SWIFT_VERSION = "6.0"


def uid(*parts):
    """Stable 24-hex-character object id, so regenerating produces a minimal diff."""
    return hashlib.md5("::".join(parts).encode()).hexdigest()[:24].upper()


APP = "StitchPeek"
PREVIEW = "StitchPeekPreview"
THUMBNAIL = "StitchPeekThumbnail"

TARGETS = {
    APP: {
        "sources": [
            "StitchPeekApp.swift", "AppDelegate.swift", "Library.swift",
            "CollectionWindow.swift", "IndexView.swift", "DetailView.swift",
            "DesignCanvasView.swift", "InspectorView.swift", "ViewerModel.swift",
            "Exporter.swift", "PDFReport.swift", "ContactSheet.swift", "ReportText.swift", "RecentDocuments.swift",
        ],
        "resources": ["Assets.xcassets"],
        "product": "StitchPeek.app",
        "product_type": "com.apple.product-type.application",
        "file_type": "wrapper.application",
        "bundle_id": BUNDLE_PREFIX,
    },
    PREVIEW: {
        "sources": ["PreviewProvider.swift"],
        "resources": [],
        "product": "StitchPeekPreview.appex",
        "product_type": "com.apple.product-type.app-extension",
        "file_type": "wrapper.app-extension",
        "bundle_id": BUNDLE_PREFIX + ".Preview",
    },
    THUMBNAIL: {
        "sources": ["ThumbnailProvider.swift"],
        "resources": [],
        "product": "StitchPeekThumbnail.appex",
        "product_type": "com.apple.product-type.app-extension",
        "file_type": "wrapper.app-extension",
        "bundle_id": BUNDLE_PREFIX + ".Thumbnail",
    },
}

EXTENSIONS = [PREVIEW, THUMBNAIL]

# --- ids -------------------------------------------------------------------------------

PROJECT_ID = uid("project")
MAIN_GROUP = uid("group", "main")
PRODUCTS_GROUP = uid("group", "products")
PACKAGES_GROUP = uid("group", "packages")
PROJECT_CONFIG_LIST = uid("configlist", "project")
PACKAGE_REF = uid("package", "StitchKit")

def group_id(t): return uid("group", t)
def target_id(t): return uid("target", t)
def product_ref(t): return uid("productref", t)
def config_list(t): return uid("configlist", t)
def build_config(t, name): return uid("config", t, name)
def sources_phase(t): return uid("phase", t, "sources")
def frameworks_phase(t): return uid("phase", t, "frameworks")
def resources_phase(t): return uid("phase", t, "resources")
def embed_phase(t): return uid("phase", t, "embed")
def source_file_ref(t, f): return uid("fileref", t, f)
def source_build_file(t, f): return uid("buildfile", t, f)
def resource_file_ref(t, f): return uid("resfileref", t, f)
def resource_build_file(t, f): return uid("resbuildfile", t, f)
def plist_ref(t): return uid("fileref", t, "Info.plist")
def entitlements_ref(t): return uid("fileref", t, "entitlements")
def package_product(t): return uid("packageproduct", t)
def package_build_file(t): return uid("buildfile", t, "StitchKit")
def embed_build_file(t): return uid("buildfile", "embed", t)
def dependency_id(t): return uid("dependency", t)
def container_proxy(t): return uid("proxy", t)

# --- sections --------------------------------------------------------------------------

out = []
def w(line=""):
    out.append(line)


def section(name, body_lines):
    if not body_lines:
        return
    w(f"/* Begin {name} section */")
    out.extend(body_lines)
    w(f"/* End {name} section */")
    w()


# PBXBuildFile
build_files = []
for t, spec in TARGETS.items():
    for f in spec["sources"]:
        build_files.append(
            f'\t\t{source_build_file(t, f)} /* {f} in Sources */ = '
            f'{{isa = PBXBuildFile; fileRef = {source_file_ref(t, f)} /* {f} */; }};'
        )
    for f in spec.get("resources", []):
        build_files.append(
            f'\t\t{resource_build_file(t, f)} /* {f} in Resources */ = '
            f'{{isa = PBXBuildFile; fileRef = {resource_file_ref(t, f)} /* {f} */; }};'
        )
    build_files.append(
        f'\t\t{package_build_file(t)} /* StitchKit in Frameworks */ = '
        f'{{isa = PBXBuildFile; productRef = {package_product(t)} /* StitchKit */; }};'
    )
for t in EXTENSIONS:
    build_files.append(
        f'\t\t{embed_build_file(t)} /* {TARGETS[t]["product"]} in Embed Foundation Extensions */ = '
        f'{{isa = PBXBuildFile; fileRef = {product_ref(t)} /* {TARGETS[t]["product"]} */; '
        f'settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};'
    )

# PBXContainerItemProxy
proxies = []
for t in EXTENSIONS:
    proxies.append(f'''\t\t{container_proxy(t)} /* PBXContainerItemProxy */ = {{
\t\t\tisa = PBXContainerItemProxy;
\t\t\tcontainerPortal = {PROJECT_ID} /* Project object */;
\t\t\tproxyType = 1;
\t\t\tremoteGlobalIDString = {target_id(t)};
\t\t\tremoteInfo = {t};
\t\t}};''')

# PBXCopyFilesBuildPhase
copy_phases = [f'''\t\t{embed_phase(APP)} /* Embed Foundation Extensions */ = {{
\t\t\tisa = PBXCopyFilesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tdstPath = "";
\t\t\tdstSubfolderSpec = 13;
\t\t\tfiles = (
''' + "".join(
    f'\t\t\t\t{embed_build_file(t)} /* {TARGETS[t]["product"]} in Embed Foundation Extensions */,\n'
    for t in EXTENSIONS
) + '''\t\t\t);
\t\t\tname = "Embed Foundation Extensions";
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t};''']

# PBXFileReference
file_refs = []
for t, spec in TARGETS.items():
    for f in spec["sources"]:
        file_refs.append(
            f'\t\t{source_file_ref(t, f)} /* {f} */ = {{isa = PBXFileReference; '
            f'lastKnownFileType = sourcecode.swift; path = {f}; sourceTree = "<group>"; }};'
        )
    for f in spec.get("resources", []):
        file_refs.append(
            f'\t\t{resource_file_ref(t, f)} /* {f} */ = {{isa = PBXFileReference; '
            f'lastKnownFileType = folder.assetcatalog; path = {f}; sourceTree = "<group>"; }};'
        )
    file_refs.append(
        f'\t\t{plist_ref(t)} /* Info.plist */ = {{isa = PBXFileReference; '
        f'lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};'
    )
    file_refs.append(
        f'\t\t{entitlements_ref(t)} /* {t}.entitlements */ = {{isa = PBXFileReference; '
        f'lastKnownFileType = text.plist.entitlements; path = {t}.entitlements; sourceTree = "<group>"; }};'
    )
    file_refs.append(
        f'\t\t{product_ref(t)} /* {spec["product"]} */ = {{isa = PBXFileReference; '
        f'explicitFileType = {spec["file_type"]}; includeInIndex = 0; path = {spec["product"]}; '
        f'sourceTree = BUILT_PRODUCTS_DIR; }};'
    )

# PBXFrameworksBuildPhase
frameworks = []
for t in TARGETS:
    frameworks.append(f'''\t\t{frameworks_phase(t)} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t{package_build_file(t)} /* StitchKit in Frameworks */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};''')

# PBXGroup
groups = []
groups.append(f'''\t\t{MAIN_GROUP} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{group_id(APP)} /* StitchPeek */,
\t\t\t\t{group_id(PREVIEW)} /* StitchPeekPreview */,
\t\t\t\t{group_id(THUMBNAIL)} /* StitchPeekThumbnail */,
\t\t\t\t{PRODUCTS_GROUP} /* Products */,
\t\t\t);
\t\t\tsourceTree = "<group>";
\t\t}};''')
groups.append(f'''\t\t{PRODUCTS_GROUP} /* Products */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
''' + "".join(
    f'\t\t\t\t{product_ref(t)} /* {TARGETS[t]["product"]} */,\n' for t in TARGETS
) + '''\t\t\t);
\t\t\tname = Products;
\t\t\tsourceTree = "<group>";
\t\t};''')
for t, spec in TARGETS.items():
    children = "".join(
        f'\t\t\t\t{source_file_ref(t, f)} /* {f} */,\n' for f in spec["sources"]
    )
    for f in spec.get("resources", []):
        children += f'\t\t\t\t{resource_file_ref(t, f)} /* {f} */,\n'
    children += f'\t\t\t\t{plist_ref(t)} /* Info.plist */,\n'
    children += f'\t\t\t\t{entitlements_ref(t)} /* {t}.entitlements */,\n'
    groups.append(f'''\t\t{group_id(t)} /* {t} */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{children}\t\t\t);
\t\t\tpath = {t};
\t\t\tsourceTree = "<group>";
\t\t}};''')

# PBXNativeTarget
targets = []
for t, spec in TARGETS.items():
    phases = [
        f'\t\t\t\t{sources_phase(t)} /* Sources */,',
        f'\t\t\t\t{frameworks_phase(t)} /* Frameworks */,',
        f'\t\t\t\t{resources_phase(t)} /* Resources */,',
    ]
    dependencies = ""
    if t == APP:
        phases.append(f'\t\t\t\t{embed_phase(APP)} /* Embed Foundation Extensions */,')
        dependencies = "".join(
            f'\t\t\t\t{dependency_id(e)} /* PBXTargetDependency */,\n' for e in EXTENSIONS
        )
    targets.append(f'''\t\t{target_id(t)} /* {t} */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {config_list(t)} /* Build configuration list for PBXNativeTarget "{t}" */;
\t\t\tbuildPhases = (
''' + "\n".join(phases) + f'''
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
{dependencies}\t\t\t);
\t\t\tname = {t};
\t\t\tpackageProductDependencies = (
\t\t\t\t{package_product(t)} /* StitchKit */,
\t\t\t);
\t\t\tproductName = {t};
\t\t\tproductReference = {product_ref(t)} /* {spec["product"]} */;
\t\t\tproductType = "{spec["product_type"]}";
\t\t}};''')

# PBXProject
project_targets = "".join(f'\t\t\t\t{target_id(t)} /* {t} */,\n' for t in TARGETS)
project = [f'''\t\t{PROJECT_ID} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 2650;
\t\t\t\tLastUpgradeCheck = 2650;
\t\t\t\tTargetAttributes = {{
''' + "".join(
    f'\t\t\t\t\t{target_id(t)} = {{\n\t\t\t\t\t\tCreatedOnToolsVersion = 26.5;\n\t\t\t\t\t}};\n'
    for t in TARGETS
) + f'''\t\t\t\t}};
\t\t\t}};
\t\t\tbuildConfigurationList = {PROJECT_CONFIG_LIST} /* Build configuration list for PBXProject "StitchPeek" */;
\t\t\tcompatibilityVersion = "Xcode 14.0";
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {MAIN_GROUP};
\t\t\tpackageReferences = (
\t\t\t\t{PACKAGE_REF} /* XCLocalSwiftPackageReference "Packages/StitchKit" */,
\t\t\t);
\t\t\tproductRefGroup = {PRODUCTS_GROUP} /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
{project_targets}\t\t\t);
\t\t}};''']

# PBXResourcesBuildPhase
resources = []
for t, spec in TARGETS.items():
    files = "".join(
        f'\t\t\t\t{resource_build_file(t, f)} /* {f} in Resources */,\n'
        for f in spec.get("resources", [])
    )
    resources.append(f'''\t\t{resources_phase(t)} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{files}\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};''')

# PBXSourcesBuildPhase
sources = []
for t, spec in TARGETS.items():
    files = "".join(
        f'\t\t\t\t{source_build_file(t, f)} /* {f} in Sources */,\n' for f in spec["sources"]
    )
    sources.append(f'''\t\t{sources_phase(t)} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{files}\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};''')

# PBXTargetDependency
dependencies = []
for t in EXTENSIONS:
    dependencies.append(f'''\t\t{dependency_id(t)} /* PBXTargetDependency */ = {{
\t\t\tisa = PBXTargetDependency;
\t\t\ttarget = {target_id(t)} /* {t} */;
\t\t\ttargetProxy = {container_proxy(t)} /* PBXContainerItemProxy */;
\t\t}};''')

# XCBuildConfiguration
PROJECT_COMMON = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "COPY_PHASE_STRIP": "NO",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "GCC_NO_COMMON_BLOCKS": "YES",
    "MACOSX_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
    "SDKROOT": "macosx",
    "SWIFT_VERSION": SWIFT_VERSION,
    # Personal machine only: no notarization, so no hardened runtime to work around.
    "ENABLE_HARDENED_RUNTIME": "NO",
    # Sign to Run Locally. Ad-hoc needs no private key, so builds never stop on a
    # keychain prompt. Switch to a Development team in Xcode if you ever distribute.
    "CODE_SIGN_STYLE": "Manual",
    "CODE_SIGN_IDENTITY": '"-"',
    "CODE_SIGNING_REQUIRED": "YES",
    "CODE_SIGNING_ALLOWED": "YES",
    "DEVELOPMENT_TEAM": '""',
    "PROVISIONING_PROFILE_SPECIFIER": '""',
}
PROJECT_DEBUG = {
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ENABLE_TESTABILITY": "YES",
    "GCC_OPTIMIZATION_LEVEL": "0",
    "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
    "ONLY_ACTIVE_ARCH": "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": '"DEBUG $(inherited)"',
    "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"',
}
PROJECT_RELEASE = {
    "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
    "ENABLE_NS_ASSERTIONS": "NO",
    "MTL_ENABLE_DEBUG_INFO": "NO",
    "SWIFT_COMPILATION_MODE": "wholemodule",
}


def target_settings(t):
    spec = TARGETS[t]
    settings = {
        "CODE_SIGN_ENTITLEMENTS": f"{t}/{t}.entitlements",
        "COMBINE_HIDPI_IMAGES": "YES",
        "CURRENT_PROJECT_VERSION": "1",
        "ENABLE_PREVIEWS": "YES",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": f"{t}/Info.plist",
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": spec["bundle_id"],
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
        "SWIFT_EMIT_LOC_STRINGS": "YES",
    }
    if t == APP:
        settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
        settings["LD_RUNPATH_SEARCH_PATHS"] = '(\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t\t"@executable_path/../Frameworks",\n\t\t\t\t)'
    else:
        settings["SKIP_INSTALL"] = "YES"
        settings["LD_RUNPATH_SEARCH_PATHS"] = (
            '(\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t\t"@executable_path/../Frameworks",\n'
            '\t\t\t\t\t"@executable_path/../../../../Frameworks",\n\t\t\t\t)'
        )
    return settings


def render_settings(settings, indent="\t\t\t\t"):
    lines = []
    for key in sorted(settings):
        lines.append(f"{indent}{key} = {settings[key]};")
    return "\n".join(lines)


configurations = []
for name, extra in (("Debug", PROJECT_DEBUG), ("Release", PROJECT_RELEASE)):
    merged = dict(PROJECT_COMMON)
    merged.update(extra)
    configurations.append(f'''\t\t{build_config("project", name)} /* {name} */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{render_settings(merged)}
\t\t\t}};
\t\t\tname = {name};
\t\t}};''')
for t in TARGETS:
    for name in ("Debug", "Release"):
        configurations.append(f'''\t\t{build_config(t, name)} /* {name} */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{render_settings(target_settings(t))}
\t\t\t}};
\t\t\tname = {name};
\t\t}};''')

# XCConfigurationList
config_lists = [f'''\t\t{PROJECT_CONFIG_LIST} /* Build configuration list for PBXProject "StitchPeek" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{build_config("project", "Debug")} /* Debug */,
\t\t\t\t{build_config("project", "Release")} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};''']
for t in TARGETS:
    config_lists.append(f'''\t\t{config_list(t)} /* Build configuration list for PBXNativeTarget "{t}" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{build_config(t, "Debug")} /* Debug */,
\t\t\t\t{build_config(t, "Release")} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};''')

# Local package: linked statically into all three targets with Do Not Embed, which is why
# there is no embedded framework to sign or to chase @rpath problems through.
package_refs = [f'''\t\t{PACKAGE_REF} /* XCLocalSwiftPackageReference "Packages/StitchKit" */ = {{
\t\t\tisa = XCLocalSwiftPackageReference;
\t\t\trelativePath = Packages/StitchKit;
\t\t}};''']
package_products = []
for t in TARGETS:
    package_products.append(f'''\t\t{package_product(t)} /* StitchKit */ = {{
\t\t\tisa = XCSwiftPackageProductDependency;
\t\t\tproductName = StitchKit;
\t\t}};''')

# --- assemble --------------------------------------------------------------------------

w("// !$*UTF8*$!")
w("{")
w("\tarchiveVersion = 1;")
w("\tclasses = {")
w("\t};")
w("\tobjectVersion = 56;")
w("\tobjects = {")
w()
section("PBXBuildFile", build_files)
section("PBXContainerItemProxy", proxies)
section("PBXCopyFilesBuildPhase", copy_phases)
section("PBXFileReference", file_refs)
section("PBXFrameworksBuildPhase", frameworks)
section("PBXGroup", groups)
section("PBXNativeTarget", targets)
section("PBXProject", project)
section("PBXResourcesBuildPhase", resources)
section("PBXSourcesBuildPhase", sources)
section("PBXTargetDependency", dependencies)
section("XCBuildConfiguration", configurations)
section("XCConfigurationList", config_lists)
section("XCLocalSwiftPackageReference", package_refs)
section("XCSwiftPackageProductDependency", package_products)
w("\t};")
w(f"\trootObject = {PROJECT_ID} /* Project object */;")
w("}")

os.makedirs(PROJECT, exist_ok=True)
with open(os.path.join(PROJECT, "project.pbxproj"), "w") as f:
    f.write("\n".join(out) + "\n")

# A shared scheme, so `xcodebuild -scheme StitchPeek` works from a clean checkout.
schemes = os.path.join(PROJECT, "xcshareddata", "xcschemes")
os.makedirs(schemes, exist_ok=True)
with open(os.path.join(schemes, "StitchPeek.xcscheme"), "w") as f:
    f.write(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2650" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{target_id(APP)}"
               BuildableName = "StitchPeek.app"
               BlueprintName = "StitchPeek"
               ReferencedContainer = "container:StitchPeek.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target_id(APP)}"
            BuildableName = "StitchPeek.app"
            BlueprintName = "StitchPeek"
            ReferencedContainer = "container:StitchPeek.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target_id(APP)}"
            BuildableName = "StitchPeek.app"
            BlueprintName = "StitchPeek"
            ReferencedContainer = "container:StitchPeek.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug"></AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"></ArchiveAction>
</Scheme>
''')

print(f"wrote {os.path.join(PROJECT, 'project.pbxproj')}")
print(f"wrote {os.path.join(schemes, 'StitchPeek.xcscheme')}")
