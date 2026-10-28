#!/usr/bin/env python3
"""Regenerate Lumen.xcodeproj from the source tree. No third-party tools."""

import hashlib
import json
import os
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Lumen"
TESTS = ROOT / "LumenTests"


def pid(seed: str) -> str:
    return hashlib.sha1(seed.encode()).hexdigest()[:24].upper()


def chunk(tag: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)


def write_png(path: Path, size: int) -> None:
    pixels = bytearray()
    for y in range(size):
        pixels.append(0)
        for x in range(size):
            nx, ny = x / size, y / size
            r, g, b = 20, 22, 26
            # Amber rail.
            if 0.16 < nx < 0.28 and 0.18 < ny < 0.82:
                r, g, b = 232, 158, 46
            # Teal block.
            if 0.36 < nx < 0.58 and 0.58 < ny < 0.78:
                r, g, b = 46, 196, 171
            # Violet block.
            if 0.66 < nx < 0.84 and 0.22 < ny < 0.72:
                r, g, b = 158, 130, 245
            # Hairline frame.
            if min(nx, ny, 1 - nx, 1 - ny) < 0.04:
                r, g, b = 69, 74, 84
            pixels.extend((r, g, b))
    raw = bytes(pixels)
    ihdr = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    path.write_bytes(png)


def write_icons() -> None:
    iconset = APP / "Assets.xcassets" / "AppIcon.appiconset"
    iconset.mkdir(parents=True, exist_ok=True)
    specs = [
        (16, "1x", "16x16"),
        (32, "2x", "16x16"),
        (32, "1x", "32x32"),
        (64, "2x", "32x32"),
        (128, "1x", "128x128"),
        (256, "2x", "128x128"),
        (256, "1x", "256x256"),
        (512, "2x", "256x256"),
        (512, "1x", "512x512"),
        (1024, "2x", "512x512"),
    ]
    images = []
    for px, scale, size_name in specs:
        filename = f"icon_{size_name}_{scale}.png"
        write_png(iconset / filename, px)
        images.append({
            "filename": filename,
            "idiom": "mac",
            "scale": scale,
            "size": size_name,
        })
    (iconset / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    accent = APP / "Assets.xcassets" / "AccentColor.colorset"
    accent.mkdir(parents=True, exist_ok=True)
    (accent / "Contents.json").write_text(json.dumps({
        "colors": [{
            "color": {"color-space": "srgb", "components": {"alpha": "1.000", "red": "0.910", "green": "0.620", "blue": "0.180"}},
            "idiom": "universal",
        }],
        "info": {"author": "xcode", "version": 1},
    }, indent=2) + "\n")
    (APP / "Assets.xcassets" / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")


def write_rules() -> None:
    domains = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com",
        "google-analytics.com", "googletagmanager.com", "googletagservices.com",
        "2mdn.net", "adnxs.com", "adsrvr.org", "amazon-adsystem.com",
        "advertising.com", "adform.net", "adsafeprotected.com", "casalemedia.com",
        "criteo.com", "criteo.net", "demdex.net", "everesttech.net", "exelator.com",
        "krxd.net", "moatads.com", "openx.net", "outbrain.com", "pubmatic.com",
        "quantserve.com", "rubiconproject.com", "scorecardresearch.com",
        "serving-sys.com", "sharethrough.com", "smartadserver.com", "taboola.com",
        "tapad.com", "teads.tv", "bidswitch.net", "media.net", "contextweb.com",
        "bluekai.com", "agkn.com", "rlcdn.com", "chartbeat.com", "hotjar.com",
        "mixpanel.com", "segment.io", "segment.com", "nr-data.net", "omtrdc.net",
        "ads-twitter.com", "doubleverify.com", "adroll.com", "lijit.com",
    ]
    unless = ["*accounts.google.com", "*myaccount.google.com", "*accounts.youtube.com"]
    types = ["script", "image", "style-sheet", "font", "media", "raw", "svg-document", "popup"]
    rules = []
    for domain in domains:
        escaped = domain.replace(".", r"\.")
        rules.append({
            "trigger": {
                "url-filter": f"^https?://([^/?#]*\\.)?{escaped}([:/?#]|$)",
                "url-filter-is-case-sensitive": False,
                "resource-type": types,
                "unless-domain": unless,
            },
            "action": {"type": "block"},
        })
    path = APP / "Resources" / "blocker-rules.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(rules, indent=2) + "\n")


def swift_files(folder: Path) -> list[str]:
    files = []
    for dirpath, _, filenames in os.walk(folder):
        for name in sorted(filenames):
            if name.endswith(".swift"):
                files.append(str(Path(dirpath, name).relative_to(folder)))
    return files


def pbx_quote(value: str) -> str:
    if value.isalnum() or value in {".", ".."}:
        return value
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def write_project() -> None:
    sources = swift_files(APP)
    tests = swift_files(TESTS)
    objects = []

    def add(seed: str, text: str) -> str:
        objects.append((pid(seed), text))
        return pid(seed)

    app_sources = []
    app_resources = []
    file_refs = {}

    def file_ref(path: str, kind: str) -> str:
        key = f"ref:{path}"
        if key not in file_refs:
            file_refs[key] = add(key, f"""\t\t{pid(key)} /* {Path(path).name} */ = {{isa = PBXFileReference; lastKnownFileType = {kind}; path = {pbx_quote(path)}; sourceTree = "<group>"; }};""")
        return file_refs[key]

    build_ids = []
    for path in sources:
        ref = file_ref(path, "sourcecode.swift")
        bid = add(f"build:{path}", f"""\t\t{pid(f"build:{path}")} /* {Path(path).name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {Path(path).name} */; }};""")
        build_ids.append(bid)
        app_sources.append(bid)

    asset_ref = file_ref("Assets.xcassets", "folder.assetcatalog")
    rules_ref = file_ref("Resources/blocker-rules.json", "text.json")
    info_ref = file_ref("Info.plist", "text.plist.xml")
    ent_ref = file_ref("Lumen.entitlements", "text.plist.entitlements")
    asset_build = add("build:assets", f"""\t\t{pid("build:assets")} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {asset_ref} /* Assets.xcassets */; }};""")
    rules_build = add("build:rules", f"""\t\t{pid("build:rules")} /* blocker-rules.json in Resources */ = {{isa = PBXBuildFile; fileRef = {rules_ref} /* blocker-rules.json */; }};""")
    app_resources.extend([asset_build, rules_build])

    test_builds = []
    test_refs = []
    for path in tests:
        ref = add(f"tref:{path}", f"""\t\t{pid(f"tref:{path}")} /* {Path(path).name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {pbx_quote(path)}; sourceTree = "<group>"; }};""")
        bid = add(f"tbuild:{path}", f"""\t\t{pid(f"tbuild:{path}")} /* {Path(path).name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {Path(path).name} */; }};""")
        test_refs.append(ref)
        test_builds.append(bid)

    app_product = add("product:app", f"""\t\t{pid("product:app")} /* Lumen.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Lumen.app; sourceTree = BUILT_PRODUCTS_DIR; }};""")
    test_product = add("product:tests", f"""\t\t{pid("product:tests")} /* LumenTests.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = LumenTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};""")

    def group(seed: str, name: str, children: list[str], path: str | None) -> str:
        body = ",\n".join(f"\t\t\t\t{child}" for child in children)
        path_line = f"\n\t\t\tpath = {pbx_quote(path)};" if path else ""
        return add(seed, f"""\t\t{pid(seed)} /* {name} */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{body}
\t\t\t);{path_line}
\t\t\tname = {pbx_quote(name)};
\t\t\tsourceTree = "<group>";
\t\t}};""")

    app_children = [file_refs[f"ref:{path}"] for path in sources] + [asset_ref, rules_ref, info_ref, ent_ref]
    app_group = group("group:app", "Lumen", app_children, "Lumen")
    test_group = group("group:tests", "LumenTests", test_refs, "LumenTests")
    products = group("group:products", "Products", [app_product, test_product], None)
    main_group = group("group:main", "Lumen", [app_group, test_group, products], None)

    def phase(seed: str, isa: str, files: list[str]) -> str:
        body = ",\n".join(f"\t\t\t\t{item}" for item in files) if files else ""
        inner = f"\n{body}\n\t\t\t" if files else ""
        return add(seed, f"""\t\t{pid(seed)} /* {isa} */ = {{
\t\t\tisa = {isa};
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = ({inner});
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};""")

    app_sources_phase = phase("phase:app-sources", "PBXSourcesBuildPhase", app_sources)
    app_resources_phase = phase("phase:app-resources", "PBXResourcesBuildPhase", app_resources)
    app_frameworks_phase = phase("phase:app-frameworks", "PBXFrameworksBuildPhase", [])
    test_sources_phase = phase("phase:test-sources", "PBXSourcesBuildPhase", test_builds)
    test_frameworks_phase = phase("phase:test-frameworks", "PBXFrameworksBuildPhase", [])

    target_configs = {}
    project_configs = {}

    def xc(seed: str, settings: dict) -> str:
        lines = "\n".join(f"\t\t\t\t{key} = {value};" for key, value in settings.items())
        return add(seed, f"""\t\t{pid(seed)} /* {seed} */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{lines}
\t\t\t}};
\t\t\tname = {seed.split('-')[-1]};
\t\t}};""")

    common_project = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "COPY_PHASE_STRIP": "NO",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "GCC_NO_COMMON_BLOCKS": "YES",
        "SDKROOT": "macosx",
        "SWIFT_VERSION": "5.0",
        "MACOSX_DEPLOYMENT_TARGET": "14.0",
    }
    project_configs["Debug"] = xc("proj-Debug", {**common_project, "DEBUG_INFORMATION_FORMAT": "dwarf", "GCC_OPTIMIZATION_LEVEL": "0", "ONLY_ACTIVE_ARCH": "YES", "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"', "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG", "ENABLE_TESTABILITY": "YES", "GCC_PREPROCESSOR_DEFINITIONS": '"DEBUG=1 $(inherited)"'})
    project_configs["Release"] = xc("proj-Release", {**common_project, "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"', "GCC_OPTIMIZATION_LEVEL": "s", "SWIFT_OPTIMIZATION_LEVEL": '"-O"', "SWIFT_COMPILATION_MODE": "wholemodule"})

    app_common = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CODE_SIGN_ENTITLEMENTS": "Lumen/Lumen.entitlements",
        "CODE_SIGN_IDENTITY": '"-"',
        "CODE_SIGN_STYLE": "Manual",
        "CODE_SIGNING_ALLOWED": "YES",
        "CODE_SIGNING_REQUIRED": "YES",
        "COMBINE_HIDPI_IMAGES": "YES",
        "CURRENT_PROJECT_VERSION": "1",
        "DEVELOPMENT_TEAM": '""',
        "ENABLE_APP_SANDBOX": "YES",
        "ENABLE_HARDENED_RUNTIME": "NO",
        "ENABLE_OUTGOING_NETWORK_CONNECTIONS": "YES",
        "ENABLE_USER_SELECTED_FILES": "readwrite",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": "Lumen/Info.plist",
        "LD_RUNPATH_SEARCH_PATHS": '"$(inherited) @executable_path/../Frameworks"',
        "MARKETING_VERSION": "0.1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": "app.lumen.browser",
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "MACOSX_DEPLOYMENT_TARGET": "14.0",
    }
    target_configs["app-Debug"] = xc("app-Debug", app_common)
    target_configs["app-Release"] = xc("app-Release", app_common)
    test_common = {
        "BUNDLE_LOADER": '"$(TEST_HOST)"',
        "CODE_SIGN_STYLE": "Manual",
        "CODE_SIGN_IDENTITY": '"-"',
        "DEVELOPMENT_TEAM": '""',
        "ENABLE_HARDENED_RUNTIME": "NO",
        "GENERATE_INFOPLIST_FILE": "YES",
        "MACOSX_DEPLOYMENT_TARGET": "14.0",
        "PRODUCT_BUNDLE_IDENTIFIER": "app.lumen.browser.tests",
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SDKROOT": "macosx",
        "SWIFT_VERSION": "5.0",
        "TEST_HOST": '"$(BUILT_PRODUCTS_DIR)/Lumen.app/Contents/MacOS/Lumen"',
        "LD_RUNPATH_SEARCH_PATHS": '"$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks"',
    }
    target_configs["test-Debug"] = xc("test-Debug", test_common)
    target_configs["test-Release"] = xc("test-Release", test_common)

    def config_list(seed: str, items: list[str]) -> str:
        body = ",\n".join(f"\t\t\t\t{item}" for item in items)
        return add(seed, f"""\t\t{pid(seed)} /* {seed} */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
{body}
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};""")

    app_list = config_list("list:app", [target_configs["app-Debug"], target_configs["app-Release"]])
    test_list = config_list("list:test", [target_configs["test-Debug"], target_configs["test-Release"]])
    proj_list = config_list("list:proj", [project_configs["Debug"], project_configs["Release"]])

    proxy = add("proxy:test-app", f"""\t\t{pid("proxy:test-app")} /* PBXContainerItemProxy */ = {{
\t\t\tisa = PBXContainerItemProxy;
\t\t\tcontainerPortal = {pid("project")} /* Project object */;
\t\t\tproxyType = 1;
\t\t\tremoteGlobalIDString = {pid("target:app")};
\t\t\tremoteInfo = Lumen;
\t\t}};""")
    test_dep = add("dep:test-app", f"""\t\t{pid("dep:test-app")} /* PBXTargetDependency */ = {{
\t\t\tisa = PBXTargetDependency;
\t\t\ttarget = {pid("target:app")} /* Lumen */;
\t\t\ttargetProxy = {proxy} /* PBXContainerItemProxy */;
\t\t}};""")

    app_target = add("target:app", f"""\t\t{pid("target:app")} /* Lumen */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {app_list} /* list:app */;
\t\t\tbuildPhases = (
\t\t\t\t{app_sources_phase} /* PBXSourcesBuildPhase */,
\t\t\t\t{app_frameworks_phase} /* PBXFrameworksBuildPhase */,
\t\t\t\t{app_resources_phase} /* PBXResourcesBuildPhase */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = Lumen;
\t\t\tproductName = Lumen;
\t\t\tproductReference = {app_product} /* Lumen.app */;
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};""")

    test_target = add("target:tests", f"""\t\t{pid("target:tests")} /* LumenTests */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {test_list} /* list:test */;
\t\t\tbuildPhases = (
\t\t\t\t{test_sources_phase} /* PBXSourcesBuildPhase */,
\t\t\t\t{test_frameworks_phase} /* PBXFrameworksBuildPhase */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t\t{test_dep} /* PBXTargetDependency */,
\t\t\t);
\t\t\tname = LumenTests;
\t\t\tproductName = LumenTests;
\t\t\tproductReference = {test_product} /* LumenTests.xctest */;
\t\t\tproductType = "com.apple.product-type.bundle.unit-test";
\t\t}};""")

    project = add("project", f"""\t\t{pid("project")} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastUpgradeCheck = 1600;
\t\t\t\tTargetAttributes = {{
\t\t\t\t\t{app_target} = {{ CreatedOnToolsVersion = 16.0; }};
\t\t\t\t\t{test_target} = {{ CreatedOnToolsVersion = 16.0; }};
\t\t\t\t}};
\t\t\t}};
\t\t\tbuildConfigurationList = {proj_list} /* list:proj */;
\t\t\tcompatibilityVersion = "Xcode 14.0";
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {main_group} /* Lumen */;
\t\t\tproductRefGroup = {products} /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{app_target} /* Lumen */,
\t\t\t\t{test_target} /* LumenTests */,
\t\t\t);
\t\t}};""")

    # The file ref helper stored text that already contains the id line, but `add`
    # also wraps it. file_ref() calls add() with text that includes the id. Good.
    # However file_refs values are the ids, and the text was passed to add(). Good.

    sections: dict[str, list[str]] = {}
    # Re-parse objects into sections by isa. The stored text includes the id line.
    blob = "\n".join(text for _, text in objects) + "\n"
    out = f"""// !$*UTF8*$!
{{
\tarchiveVersion = 1;
\tclasses = {{
\t}};
\tobjectVersion = 56;
\tobjects = {{

{blob}\t}};
\trootObject = {project} /* Project object */;
}}
"""
    proj_dir = ROOT / "Lumen.xcodeproj"
    proj_dir.mkdir(exist_ok=True)
    (proj_dir / "project.pbxproj").write_text(out)
    scheme_dir = proj_dir / "xcshareddata" / "xcschemes"
    scheme_dir.mkdir(parents=True, exist_ok=True)
    (scheme_dir / "Lumen.xcscheme").write_text(f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{app_target}"
               BuildableName = "Lumen.app"
               BlueprintName = "Lumen"
               ReferencedContainer = "container:Lumen.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "NO"
            buildForProfiling = "NO"
            buildForArchiving = "NO"
            buildForAnalyzing = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{test_target}"
               BuildableName = "LumenTests.xctest"
               BlueprintName = "LumenTests"
               ReferencedContainer = "container:Lumen.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference
            skipped = "NO"
            parallelizable = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{test_target}"
               BuildableName = "LumenTests.xctest"
               BlueprintName = "LumenTests"
               ReferencedContainer = "container:Lumen.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{app_target}"
            BuildableName = "Lumen.app"
            BlueprintName = "Lumen"
            ReferencedContainer = "container:Lumen.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{app_target}"
            BuildableName = "Lumen.app"
            BlueprintName = "Lumen"
            ReferencedContainer = "container:Lumen.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
""")
    print(f"Wrote project with {len(sources)} app sources and {len(tests)} tests")


if __name__ == "__main__":
    write_icons()
    write_rules()
    write_project()
