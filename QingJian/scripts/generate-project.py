#!/usr/bin/env python3
"""Generate the Xcode project using stable object identifiers."""
from pathlib import Path
import hashlib
import json
import plistlib

ROOT = Path(__file__).resolve().parents[1]

def ident(label):
    return hashlib.sha256(label.encode()).hexdigest()[:24].upper()

def quoted(text):
    return json.dumps(text, ensure_ascii=False)

def render(value):
    if isinstance(value, dict):
        return "{ " + " ".join(f"{k} = {render(v)};" for k, v in value.items()) + " }"
    if isinstance(value, list):
        return "( " + ", ".join(render(v) for v in value) + ("," if value else "") + " )"
    if isinstance(value, int):
        return str(value)
    return quoted(value)

objects = {}

def add(label, isa, **fields):
    key = ident(label)
    objects[key] = {"isa": isa, **fields}
    return key

swift_paths = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "DeepSeekPocket").rglob("*.swift"))
file_refs, source_builds = [], []
for path in swift_paths:
    ref = add("file:" + path, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=path, sourceTree="SOURCE_ROOT")
    file_refs.append(ref)
    source_builds.append(add("build:" + path, "PBXBuildFile", fileRef=ref))
info_ref = add("Info.plist", "PBXFileReference", lastKnownFileType="text.plist.xml", path="DeepSeekPocket/Info.plist", sourceTree="SOURCE_ROOT")
asset_ref = add("Assets", "PBXFileReference", lastKnownFileType="folder.assetcatalog", path="DeepSeekPocket/Assets.xcassets", sourceTree="SOURCE_ROOT")
asset_build = add("AssetBuild", "PBXBuildFile", fileRef=asset_ref)
extra_resource_refs, extra_resource_builds = [], []
for file in sorted((ROOT / "DeepSeekPocket/Resources").glob("*")):
    if not file.is_file(): continue
    path = file.relative_to(ROOT).as_posix()
    ref = add("resource:" + path, "PBXFileReference", lastKnownFileType="file", path=path, sourceTree="SOURCE_ROOT")
    extra_resource_refs.append(ref)
    extra_resource_builds.append(add("resource-build:" + path, "PBXBuildFile", fileRef=ref))
product_ref = add("Product", "PBXFileReference", explicitFileType="wrapper.application", includeInIndex=0, path="DeepSeekPocket.app", sourceTree="BUILT_PRODUCTS_DIR")
source_phase = add("Sources", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=source_builds, runOnlyForDeploymentPostprocessing=0)
resource_phase = add("Resources", "PBXResourcesBuildPhase", buildActionMask=2147483647, files=[asset_build] + extra_resource_builds, runOnlyForDeploymentPostprocessing=0)
framework_phase = add("Frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
product_group = add("Products", "PBXGroup", children=[product_ref], name="Products", sourceTree="<group>")
source_group = add("AppSources", "PBXGroup", children=file_refs + [info_ref, asset_ref] + extra_resource_refs, name="App", sourceTree="<group>")
main_group = add("MainGroup", "PBXGroup", children=[source_group, product_group], sourceTree="<group>")

project_configs, target_configs = [], []
for name in ["Debug", "Release"]:
    project_settings = {
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": "26.0",
        "SDKROOT": "iphoneos",
        "SWIFT_VERSION": "5.0",
        "SWIFT_STRICT_CONCURRENCY": "targeted",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "DEBUG_INFORMATION_FORMAT": "dwarf" if name == "Debug" else "dwarf-with-dsym",
        "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if name == "Debug" else "-O",
        "GCC_PREPROCESSOR_DEFINITIONS": ["$(inherited)", "DEBUG=1"] if name == "Debug" else ["$(inherited)"],
    }
    if name == "Debug":
        project_settings["ENABLE_TESTABILITY"] = "YES"
        project_settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
    target_settings = {
        "PRODUCT_BUNDLE_IDENTIFIER": "com.xiaolong.qingjian",
        "PRODUCT_NAME": "DeepSeekPocket",
        "INFOPLIST_FILE": "DeepSeekPocket/Info.plist",
        "GENERATE_INFOPLIST_FILE": "NO",
        "MARKETING_VERSION": "1.37.0",
        "CURRENT_PROJECT_VERSION": "74",
        "OTHER_LDFLAGS": ["$(inherited)", "-lsqlite3"],
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "TARGETED_DEVICE_FAMILY": "1,2",
        "CODE_SIGN_STYLE": "Automatic",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
        "SUPPORTS_MACCATALYST": "NO",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
    }
    project_configs.append(add("ProjectConfig:" + name, "XCBuildConfiguration", buildSettings=project_settings, name=name))
    target_configs.append(add("TargetConfig:" + name, "XCBuildConfiguration", buildSettings=target_settings, name=name))
project_list = add("ProjectConfigs", "XCConfigurationList", buildConfigurations=project_configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
target_list = add("TargetConfigs", "XCConfigurationList", buildConfigurations=target_configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
target = add("Target", "PBXNativeTarget", buildConfigurationList=target_list,
             buildPhases=[source_phase, framework_phase, resource_phase], buildRules=[], dependencies=[],
             name="QingJian", productName="DeepSeekPocket", productReference=product_ref,
             productType="com.apple.product-type.application")
ui_ref = add("UITestSource", "PBXFileReference", lastKnownFileType="sourcecode.swift", path="UITests/NavigationUITests.swift", sourceTree="SOURCE_ROOT")
ui_build = add("UITestBuild", "PBXBuildFile", fileRef=ui_ref)
ui_sources = add("UITestSources", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=[ui_build], runOnlyForDeploymentPostprocessing=0)
ui_frameworks = add("UITestFrameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
ui_resources = add("UITestResources", "PBXResourcesBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
ui_product = add("UITestProduct", "PBXFileReference", explicitFileType="wrapper.cfbundle", includeInIndex=0, path="QingJianUITests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
ui_configs = []
for name in ["Debug", "Release"]:
    ui_configs.append(add("UITestConfig:" + name, "XCBuildConfiguration", name=name, buildSettings={
        "PRODUCT_BUNDLE_IDENTIFIER": "com.xiaolong.qingjian.uitests", "PRODUCT_NAME": "QingJianUITests",
        "GENERATE_INFOPLIST_FILE": "YES", "TEST_TARGET_NAME": "QingJian", "TARGETED_DEVICE_FAMILY": "1,2",
        "CODE_SIGNING_ALLOWED": "NO", "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"]}))
ui_config_list = add("UITestConfigs", "XCConfigurationList", buildConfigurations=ui_configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Debug")
proxy = add("UITestProxy", "PBXContainerItemProxy", containerPortal=ident("Project"), proxyType=1, remoteGlobalIDString=target, remoteInfo="QingJian")
dependency = add("UITestDependency", "PBXTargetDependency", target=target, targetProxy=proxy)
ui_target = add("UITestTarget", "PBXNativeTarget", buildConfigurationList=ui_config_list, buildPhases=[ui_sources, ui_frameworks, ui_resources],
                buildRules=[], dependencies=[dependency], name="QingJianUITests", productName="QingJianUITests",
                productReference=ui_product, productType="com.apple.product-type.bundle.ui-testing")
objects[source_group]["children"].append(ui_ref)
objects[product_group]["children"].append(ui_product)
project = add("Project", "PBXProject", attributes={"LastUpgradeCheck": "1600", "LastSwiftUpdateCheck": "1600", "TargetAttributes": {target: {"CreatedOnToolsVersion": "16.0"}}},
              buildConfigurationList=project_list, compatibilityVersion="Xcode 14.0", developmentRegion="zh_CN",
              hasScannedForEncodings=0, knownRegions=["zh_CN", "en", "Base"], mainGroup=main_group,
              productRefGroup=product_group, projectDirPath="", projectRoot="", targets=[target, ui_target])
objects[project]["attributes"]["TargetAttributes"][ui_target] = {"CreatedOnToolsVersion": "26.0", "TestTargetID": target}

# Pinned upstream package for the ChatGPT sign-in token check; same revision as 研习.
DEPENDENCIES = [('JWTKit', 'https://github.com/vapor/jwt-kit.git', '13e7513b3ba0afa13967daf77af2fb4ad087306c'),
                ('FSRS', 'https://github.com/open-spaced-repetition/swift-fsrs.git', '4fbaf20184d62f82a9f44f343337c61a2c5483e9')]
package_refs, products = [], []
for product, url, revision in DEPENDENCIES:
    package = add("package:" + product, "XCRemoteSwiftPackageReference", repositoryURL=url,
                  requirement={"kind": "revision", "revision": revision})
    dependency = add("package-product:" + product, "XCSwiftPackageProductDependency", package=package, productName=product)
    build = add("package-build:" + product, "PBXBuildFile", productRef=dependency)
    package_refs.append(package); products.append(dependency)
    objects[framework_phase]["files"].append(build)
objects[target]["packageProductDependencies"] = products
objects[project]["packageReferences"] = package_refs

project_dir = ROOT / "QingJian.xcodeproj"
project_dir.mkdir(parents=True, exist_ok=True)
body = "\n".join(f"\t\t{key} = {render(value)};" for key, value in sorted(objects.items()))
(project_dir / "project.pbxproj").write_text("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n" + body + "\n\t};\n\trootObject = " + project + ";\n}\n", encoding="utf-8")
scheme_dir = project_dir / "xcshareddata" / "xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="DeepSeekPocket.app" BlueprintName="QingJian" ReferencedContainer="container:QingJian.xcodeproj"/>'
ui_reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ui_target}" BuildableName="QingJianUITests.xctest" BlueprintName="QingJianUITests" ReferencedContainer="container:QingJian.xcodeproj"/>'
(scheme_dir / "QingJian.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">{ui_reference}</BuildActionEntry></BuildActionEntries>
  </BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ui_reference}</TestableReference></Testables></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''', encoding="utf-8")
print(f"Generated Xcode project for {len(swift_paths)} Swift source files.")
