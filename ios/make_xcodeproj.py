#!/usr/bin/env python3
"""Generates Proj.xcodeproj (Xcode 16+ format with a synchronized App/ folder and a
local Swift package reference to ProjKit). Re-run after changing settings below;
new .swift files in App/ are picked up by Xcode automatically, no regeneration needed.

    python3 ios/make_xcodeproj.py [--bundle-id com.example.proj]
"""
import argparse
import hashlib
from pathlib import Path

HERE = Path(__file__).resolve().parent


def oid(name: str) -> str:
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()


def settings(d: dict) -> str:
    def val(v):
        if isinstance(v, list):
            return "(\n" + "".join(f'\t\t\t\t\t"{x}",\n' for x in v) + "\t\t\t\t)"
        s = str(v)
        return s if s.replace("_", "").replace(".", "").isalnum() and s else f'"{s}"'
    return "".join(f"\t\t\t\t{k} = {val(v)};\n" for k, v in sorted(d.items()))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bundle-id", default="com.dmetzger57.proj")
    ap.add_argument("--team", default="NLHV6235N5", help="Apple Development team ID (\"\" to pick in Xcode)")
    args = ap.parse_args()

    I = {k: oid(k) for k in [
        "project", "target", "app", "appgroup", "maingroup", "products", "sources", "frameworks",
        "resources", "pkgref", "pkgdep", "pkgbuild", "projdebug", "projrelease", "tgtdebug",
        "tgtrelease", "projlist", "tgtlist"]}

    common = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "COPY_PHASE_STRIP": "NO",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "GCC_NO_COMMON_BLOCKS": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
        "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
        "SDKROOT": "iphoneos",
    }
    proj_debug = {**common, "DEBUG_INFORMATION_FORMAT": "dwarf", "ENABLE_TESTABILITY": "YES",
                  "GCC_OPTIMIZATION_LEVEL": "0", "ONLY_ACTIVE_ARCH": "YES",
                  "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)",
                  "SWIFT_OPTIMIZATION_LEVEL": "-Onone"}
    proj_release = {**common, "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym", "ENABLE_NS_ASSERTIONS": "NO",
                    "SWIFT_COMPILATION_MODE": "wholemodule", "VALIDATE_PRODUCT": "YES"}
    target = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "DEVELOPMENT_TEAM": args.team,
        "ENABLE_PREVIEWS": "YES",
        "GENERATE_INFOPLIST_FILE": "YES",
        "INFOPLIST_KEY_CFBundleDisplayName": "Proj",
        "INFOPLIST_KEY_ITSAppUsesNonExemptEncryption": "NO",
        "INFOPLIST_KEY_LSApplicationCategoryType": "public.app-category.productivity",
        "INFOPLIST_KEY_NSCameraUsageDescription": "Proj uses the camera to scan receipts.",
        "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
        "INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents": "YES",
        "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
        "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad": "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
        "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone": "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
        "MARKETING_VERSION": (Path(__file__).resolve().parent.parent / "VERSION").read_text().strip(),
        "PRODUCT_BUNDLE_IDENTIFIER": args.bundle_id,
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
        "SUPPORTS_MACCATALYST": "NO",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "SWIFT_VERSION": "6.0",
        "TARGETED_DEVICE_FAMILY": "1,2",
    }

    pbx = f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 77;
	objects = {{

/* Begin PBXBuildFile section */
		{I['pkgbuild']} /* ProjKitCore in Frameworks */ = {{isa = PBXBuildFile; productRef = {I['pkgdep']} /* ProjKitCore */; }};
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
		{I['app']} /* Proj.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Proj.app; sourceTree = BUILT_PRODUCTS_DIR; }};
/* End PBXFileReference section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
		{I['appgroup']} /* App */ = {{
			isa = PBXFileSystemSynchronizedRootGroup;
			path = App;
			sourceTree = "<group>";
		}};
/* End PBXFileSystemSynchronizedRootGroup section */

/* Begin PBXFrameworksBuildPhase section */
		{I['frameworks']} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{I['pkgbuild']} /* ProjKitCore in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		{I['maingroup']} = {{
			isa = PBXGroup;
			children = (
				{I['appgroup']} /* App */,
				{I['products']} /* Products */,
			);
			sourceTree = "<group>";
		}};
		{I['products']} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{I['app']} /* Proj.app */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{I['target']} /* Proj */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {I['tgtlist']} /* Build configuration list for PBXNativeTarget "Proj" */;
			buildPhases = (
				{I['sources']} /* Sources */,
				{I['frameworks']} /* Frameworks */,
				{I['resources']} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			fileSystemSynchronizedGroups = (
				{I['appgroup']} /* App */,
			);
			name = Proj;
			packageProductDependencies = (
				{I['pkgdep']} /* ProjKitCore */,
			);
			productName = Proj;
			productReference = {I['app']} /* Proj.app */;
			productType = "com.apple.product-type.application";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{I['project']} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1600;
				LastUpgradeCheck = 1600;
				TargetAttributes = {{
					{I['target']} = {{
						CreatedOnToolsVersion = 16.0;
					}};
				}};
			}};
			buildConfigurationList = {I['projlist']} /* Build configuration list for PBXProject "Proj" */;
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = {I['maingroup']};
			minimizedProjectReferenceProxies = 1;
			packageReferences = (
				{I['pkgref']} /* XCLocalSwiftPackageReference "ProjKit" */,
			);
			preferredProjectObjectVersion = 77;
			productRefGroup = {I['products']} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{I['target']} /* Proj */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		{I['resources']} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		{I['sources']} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		{I['projdebug']} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{settings(proj_debug)}			}};
			name = Debug;
		}};
		{I['projrelease']} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{settings(proj_release)}			}};
			name = Release;
		}};
		{I['tgtdebug']} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{settings(target)}			}};
			name = Debug;
		}};
		{I['tgtrelease']} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{settings(target)}			}};
			name = Release;
		}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{I['projlist']} /* Build configuration list for PBXProject "Proj" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{I['projdebug']} /* Debug */,
				{I['projrelease']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{I['tgtlist']} /* Build configuration list for PBXNativeTarget "Proj" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{I['tgtdebug']} /* Debug */,
				{I['tgtrelease']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */

/* Begin XCLocalSwiftPackageReference section */
		{I['pkgref']} /* XCLocalSwiftPackageReference "ProjKit" */ = {{
			isa = XCLocalSwiftPackageReference;
			relativePath = ProjKit;
		}};
/* End XCLocalSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
		{I['pkgdep']} /* ProjKitCore */ = {{
			isa = XCSwiftPackageProductDependency;
			productName = ProjKitCore;
		}};
/* End XCSwiftPackageProductDependency section */
	}};
	rootObject = {I['project']} /* Project object */;
}}
"""
    out = HERE / "Proj.xcodeproj"
    out.mkdir(exist_ok=True)
    (out / "project.pbxproj").write_text(pbx)
    ws = out / "project.xcworkspace"
    ws.mkdir(exist_ok=True)
    (ws / "contents.xcworkspacedata").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n<Workspace\n   version = "1.0">\n'
        '   <FileRef\n      location = "self:">\n   </FileRef>\n</Workspace>\n')
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
