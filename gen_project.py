import os, uuid

ROOT = os.path.dirname(os.path.abspath(__file__))
APP = "MyVault"
TESTS = "MyVaultTests"
UITESTS = "MyVaultUITests"
WIDGET = "MyVaultWidget"

def uid():
    return uuid.uuid4().hex[:24].upper()

swift_files = []
for dp, dn, fn in os.walk(APP):
    for f in fn:
        if f.endswith(".swift"):
            p = os.path.join(dp, f).replace("\\", "/")
            swift_files.append(p)
swift_files.sort()

test_files = []
for dp, dn, fn in os.walk(TESTS):
    for f in fn:
        if f.endswith(".swift"):
            test_files.append(os.path.join(dp, f).replace("\\", "/"))
uitest_files = []
for dp, dn, fn in os.walk(UITESTS):
    for f in fn:
        if f.endswith(".swift"):
            uitest_files.append(os.path.join(dp, f).replace("\\", "/"))

widget_swift = [p for p in swift_files if "/Widgets/" in p]
app_swift = [p for p in swift_files if p not in widget_swift]

ids = {}
def nid(key):
    if key not in ids:
        ids[key] = uid()
    return ids[key]

# Fixed structural IDs
proj = nid("project")
app_target = nid("target.app")
test_target = nid("target.tests")
uitest_target = nid("target.uitests")
widget_target = nid("target.widget")
cfglist_proj = nid("cfglist.proj")
cfglist_app = nid("cfglist.app")
cfglist_tests = nid("cfglist.tests")
cfglist_uitests = nid("cfglist.uitests")
cfglist_widget = nid("cfglist.widget")
cfg_proj_dbg = nid("cfg.proj.dbg")
cfg_proj_rel = nid("cfg.proj.rel")
cfg_app_dbg = nid("cfg.app.dbg")
cfg_app_rel = nid("cfg.app.rel")
cfg_tests_dbg = nid("cfg.tests.dbg")
cfg_tests_rel = nid("cfg.tests.rel")
cfg_uitests_dbg = nid("cfg.uitests.dbg")
cfg_uitests_rel = nid("cfg.uitests.rel")
cfg_widget_dbg = nid("cfg.widget.dbg")
cfg_widget_rel = nid("cfg.widget.rel")

main_group = nid("group.main")
app_group = nid("group.app")
src_app_group = nid("group.src.app")
src_tests_group = nid("group.src.tests")
src_uitests_group = nid("group.src.uitests")
src_widget_group = nid("group.src.widget")
products_group = nid("group.products")

bf_app_src, bf_app_res, bf_app_fw = nid("bf.app.src"), nid("bf.app.res"), nid("bf.app.fw")
bf_tests_src, bf_tests_fw, bf_tests_res = nid("bf.tests.src"), nid("bf.tests.fw"), nid("bf.tests.res")
bf_uitests_src, bf_uitests_fw, bf_uitests_res = nid("bf.uitests.src"), nid("bf.uitests.fw"), nid("bf.uitests.res")
bf_widget_src, bf_widget_fw, bf_widget_res = nid("bf.widget.src"), nid("bf.widget.fw"), nid("bf.widget.res")
embed_ext = nid("bf.app.embed")

dep_tests_app = nid("dep.tests.app")
dep_uitests_app = nid("dep.uitests.app")
dep_app_widget = nid("dep.app.widget")
cont_tests_app = nid("cont.tests.app")
cont_uitests_app = nid("cont.uitests.app")
cont_app_widget = nid("cont.app.widget")

lines = []
A = lines.append

def fileref(path, ftype, name=None):
    fid = nid("file." + path)
    nm = name or os.path.basename(path)
    A(f"\t\t{fid} = {{isa = PBXFileReference; lastKnownFileType = {ftype}; name = \"{nm}\"; path = \"{path}\"; sourceTree = \"<group>\"; }};")
    return fid

A("// !$*UTF8*$!")
A("{")
A("\tarchiveVersion = 1;")
A("\tclasses = {};")
A("\tobjectVersion = 56;")
A("\tobjects = {")

# File references
app_product = fileref("MyVault.app", "wrapper.application", "MyVault.app")
tests_product = fileref("MyVaultTests.xctest", "wrapper.cfbundle", "MyVaultTests.xctest")
uitests_product = fileref("MyVaultUITests.xctest", "wrapper.cfbundle", "MyVaultUITests.xctest")
widget_product = fileref("MyVaultWidget.appex", "wrapper.app-extension", "MyVaultWidget.appex")

for p in app_swift:
    fileref(p, "sourcecode.swift")
for p in widget_swift:
    fileref(p, "sourcecode.swift")
for p in test_files:
    fileref(p, "sourcecode.swift")
for p in uitest_files:
    fileref(p, "sourcecode.swift")
fileref("MyVault/Info.plist", "text.plist.xml")
fileref("MyVault/MyVault.entitlements", "text.plist.entitlements")
fileref("MyVault/Resources/Assets.xcassets", "folder.assetcatalog")
fileref("MyVaultWidget/Info.plist", "text.plist.xml")
fileref("MyVaultWidget/MyVaultWidget.entitlements", "text.plist.entitlements")

# Build files
def buildfile(path):
    bid = nid("build." + path)
    A(f"\t\t{bid} = {{isa = PBXBuildFile; fileRef = {nid('file.' + path)}; }};")
    return bid

app_builds = [buildfile(p) for p in app_swift]
widget_builds = [buildfile(p) for p in widget_swift]
tests_builds = [buildfile(p) for p in test_files]
uitests_builds = [buildfile(p) for p in uitest_files]
asset_build = nid("build.assets")
A(f"\t\t{asset_build} = {{isa = PBXBuildFile; fileRef = {nid('file.MyVault/Resources/Assets.xcassets')}; }};")
# Embed the widget app extension into the app target.
widget_embed_build = nid("build.embed.widget")
A(f"\t\t{widget_embed_build} = {{isa = PBXBuildFile; fileRef = {widget_product}; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};")

# Groups
A(f"\t\t{main_group} = {{isa = PBXGroup; children = ({app_group}, {products_group}); sourceTree = \"<group>\"; }};")
A(f"\t\t{app_group} = {{isa = PBXGroup; children = ({src_app_group}, {src_tests_group}, {src_uitests_group}, {src_widget_group}); sourceTree = \"<group>\"; }};")
A(f"\t\t{src_app_group} = {{isa = PBXGroup; name = MyVault; path = MyVault; sourceTree = \"<group>\"; }};")
A(f"\t\t{src_tests_group} = {{isa = PBXGroup; name = MyVaultTests; path = MyVaultTests; sourceTree = \"<group>\"; }};")
A(f"\t\t{src_uitests_group} = {{isa = PBXGroup; name = MyVaultUITests; path = MyVaultUITests; sourceTree = \"<group>\"; }};")
A(f"\t\t{src_widget_group} = {{isa = PBXGroup; name = MyVaultWidget; path = MyVaultWidget; sourceTree = \"<group>\"; }};")
A(f"\t\t{products_group} = {{isa = PBXGroup; children = ({app_product}, {tests_product}, {uitests_product}, {widget_product}); name = Products; sourceTree = \"<group>\"; }};")

# Build phases
A(f"\t\t{bf_app_src} = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({' '.join(b + ',' for b in app_builds)}); runOnlyForDeploymentPostprocessing = 0; }};")
A(f"\t\t{bf_app_fw} = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};")
A(f"\t\t{bf_app_res} = {{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({asset_build},); runOnlyForDeploymentPostprocessing = 0; }};")
A(f"\t\t{embed_ext} = {{isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = \"\"; dstSubfolderSpec = 13; files = ({widget_embed_build},); name = \"Embed App Extensions\"; runOnlyForDeploymentPostprocessing = 0; }};")
A(f"\t\t{bf_tests_src} = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({' '.join(b + ',' for b in tests_builds)}); runOnlyForDeploymentPostprocessing = 0; }};")
A(f"\t\t{bf_tests_fw} = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};")
A(f"\t\t{bf_tests_res} = {{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};")
A(f"\t\t{bf_uitests_src} = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({' '.join(b + ',' for b in uitests_builds)}); runOnlyForDeploymentPostprocessing = 0; }};")
A(f"\t\t{bf_uitests_fw} = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};")
A(f"\t\t{bf_uitests_res} = {{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};")
A(f"\t\t{bf_widget_src} = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({' '.join(b + ',' for b in widget_builds)}); runOnlyForDeploymentPostprocessing = 0; }};")
A(f"\t\t{bf_widget_fw} = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};")
A(f"\t\t{bf_widget_res} = {{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};")

# Targets
A(f"\t\t{app_target} = {{isa = PBXNativeTarget; buildConfigurationList = {cfglist_app}; buildPhases = ({bf_app_src}, {bf_app_fw}, {bf_app_res}, {embed_ext}); buildRules = (); dependencies = ({dep_app_widget}); name = MyVault; productName = MyVault; productReference = {app_product}; productType = \"com.apple.product-type.application\"; }};")
A(f"\t\t{test_target} = {{isa = PBXNativeTarget; buildConfigurationList = {cfglist_tests}; buildPhases = ({bf_tests_src}, {bf_tests_fw}, {bf_tests_res}); buildRules = (); dependencies = ({dep_tests_app}); name = MyVaultTests; productName = MyVaultTests; productReference = {tests_product}; productType = \"com.apple.product-type.bundle.unit-test\"; }};")
A(f"\t\t{uitest_target} = {{isa = PBXNativeTarget; buildConfigurationList = {cfglist_uitests}; buildPhases = ({bf_uitests_src}, {bf_uitests_fw}, {bf_uitests_res}); buildRules = (); dependencies = ({dep_uitests_app}); name = MyVaultUITests; productName = MyVaultUITests; productReference = {uitests_product}; productType = \"com.apple.product-type.bundle.ui-testing\"; }};")
A(f"\t\t{widget_target} = {{isa = PBXNativeTarget; buildConfigurationList = {cfglist_widget}; buildPhases = ({bf_widget_src}, {bf_widget_fw}, {bf_widget_res}); buildRules = (); dependencies = (); name = MyVaultWidget; productName = MyVaultWidget; productReference = {widget_product}; productType = \"com.apple.product-type.app-extension\"; }};")

# Dependencies
A(f"\t\t{dep_tests_app} = {{isa = PBXTargetDependency; target = {app_target}; targetProxy = {cont_tests_app}; }};")
A(f"\t\t{cont_tests_app} = {{isa = PBXContainerItemProxy; containerPortal = {proj}; proxyType = 1; remoteGlobalIDString = {app_target}; remoteInfo = MyVault; }};")
A(f"\t\t{dep_uitests_app} = {{isa = PBXTargetDependency; target = {app_target}; targetProxy = {cont_uitests_app}; }};")
A(f"\t\t{cont_uitests_app} = {{isa = PBXContainerItemProxy; containerPortal = {proj}; proxyType = 1; remoteGlobalIDString = {app_target}; remoteInfo = MyVault; }};")
A(f"\t\t{dep_app_widget} = {{isa = PBXTargetDependency; target = {widget_target}; targetProxy = {cont_app_widget}; }};")
A(f"\t\t{cont_app_widget} = {{isa = PBXContainerItemProxy; containerPortal = {proj}; proxyType = 1; remoteGlobalIDString = {widget_target}; remoteInfo = MyVaultWidget; }};")

# Project
A(f"\t\t{proj} = {{isa = PBXProject; buildConfigurationList = {cfglist_proj}; compatibilityVersion = \"Xcode 15.0\"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en); mainGroup = {main_group}; productRefGroup = {products_group}; projectDirPath = \"\"; targets = ({app_target}, {test_target}, {uitest_target}, {widget_target}); }};")

def cfg(cid, name, settings):
    A(f"\t\t{cid} = {{isa = XCBuildConfiguration; buildSettings = {{{settings}}}; name = {name}; }};")

common_app = "ALWAYS_SEARCH_USER_PATHS = NO; CLANG_ENABLE_MODULES = YES; CODE_SIGN_ENTITLEMENTS = MyVault/MyVault.entitlements; CODE_SIGN_STYLE = Automatic; CURRENT_PROJECT_VERSION = 1; DEVELOPMENT_TEAM = \"$(DEVELOPMENT_TEAM)\"; INFOPLIST_FILE = MyVault/Info.plist; IPHONEOS_DEPLOYMENT_TARGET = 17.0; MARKETING_VERSION = 1.0.0; PRODUCT_BUNDLE_IDENTIFIER = \"$(BUNDLE_IDENTIFIER)\"; PRODUCT_NAME = MyVault; SDKROOT = iphoneos; SWIFT_VERSION = 5.9; ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon; SWIFT_EMIT_LOC_STRINGS = NO; TARGETED_DEVICE_FAMILY = \"1,2\";"
cfg(cfg_app_dbg, "Debug", common_app + " CODE_SIGN_IDENTITY = \"Apple Development\"; SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG; SWIFT_OPTIMIZATION_LEVEL = \"-Onone\";")
cfg(cfg_app_rel, "Release", common_app + " CODE_SIGN_IDENTITY = \"Apple Distribution\"; SWIFT_OPTIMIZATION_LEVEL = \"-O\";")
cfg(cfg_tests_dbg, "Debug", "BUNDLE_LOADER = \"$(TEST_HOST)\"; CODE_SIGN_STYLE = Automatic; IPHONEOS_DEPLOYMENT_TARGET = 17.0; PRODUCT_BUNDLE_IDENTIFIER = \"$(BUNDLE_IDENTIFIER)Tests\"; PRODUCT_NAME = MyVaultTests; SWIFT_VERSION = 5.9; TEST_HOST = \"$(BUILT_PRODUCTS_DIR)/MyVault.app/MyVault\";")
cfg(cfg_tests_rel, "Release", "BUNDLE_LOADER = \"$(TEST_HOST)\"; CODE_SIGN_STYLE = Automatic; IPHONEOS_DEPLOYMENT_TARGET = 17.0; PRODUCT_BUNDLE_IDENTIFIER = \"$(BUNDLE_IDENTIFIER)Tests\"; PRODUCT_NAME = MyVaultTests; SWIFT_VERSION = 5.9; TEST_HOST = \"$(BUILT_PRODUCTS_DIR)/MyVault.app/MyVault\";")
cfg(cfg_uitests_dbg, "Debug", "CODE_SIGN_STYLE = Automatic; IPHONEOS_DEPLOYMENT_TARGET = 17.0; PRODUCT_BUNDLE_IDENTIFIER = \"$(BUNDLE_IDENTIFIER)UITests\"; PRODUCT_NAME = MyVaultUITests; SWIFT_VERSION = 5.9; TEST_TARGET_NAME = MyVault;")
cfg(cfg_uitests_rel, "Release", "CODE_SIGN_STYLE = Automatic; IPHONEOS_DEPLOYMENT_TARGET = 17.0; PRODUCT_BUNDLE_IDENTIFIER = \"$(BUNDLE_IDENTIFIER)UITests\"; PRODUCT_NAME = MyVaultUITests; SWIFT_VERSION = 5.9; TEST_TARGET_NAME = MyVault;")
cfg(cfg_widget_dbg, "Debug", "CODE_SIGN_ENTITLEMENTS = MyVaultWidget/MyVaultWidget.entitlements; CODE_SIGN_STYLE = Automatic; CURRENT_PROJECT_VERSION = 1; INFOPLIST_FILE = MyVaultWidget/Info.plist; IPHONEOS_DEPLOYMENT_TARGET = 17.0; MARKETING_VERSION = 1.0.0; PRODUCT_BUNDLE_IDENTIFIER = \"$(BUNDLE_IDENTIFIER).widget\"; PRODUCT_NAME = MyVaultWidget; SDKROOT = iphoneos; SWIFT_VERSION = 5.9; SKIP_INSTALL = YES;")
cfg(cfg_widget_rel, "Release", "CODE_SIGN_ENTITLEMENTS = MyVaultWidget/MyVaultWidget.entitlements; CODE_SIGN_STYLE = Automatic; CURRENT_PROJECT_VERSION = 1; INFOPLIST_FILE = MyVaultWidget/Info.plist; IPHONEOS_DEPLOYMENT_TARGET = 17.0; MARKETING_VERSION = 1.0.0; PRODUCT_BUNDLE_IDENTIFIER = \"$(BUNDLE_IDENTIFIER).widget\"; PRODUCT_NAME = MyVaultWidget; SDKROOT = iphoneos; SWIFT_VERSION = 5.9; SKIP_INSTALL = YES;")
# Default bundle identifier (override via CI or `xcodebuild BUNDLE_IDENTIFIER=...`).
# Change to your own reverse-DNS prefix before shipping.
# SDKROOT + SUPPORTED_PLATFORMS are REQUIRED for Xcode to recognize this as an iOS
# (not macOS) target — without them xcodebuild only lists "Any Mac" destinations.
cfg(cfg_proj_dbg, "Debug", "ALWAYS_SEARCH_USER_PATHS = NO; BUNDLE_IDENTIFIER = com.ktapex.myvault; CLANG_ENABLE_MODULES = YES; MARKETING_VERSION = 1.0.0; SDKROOT = iphoneos; SUPPORTED_PLATFORMS = \"iphoneos iphonesimulator\"; SWIFT_VERSION = 5.9;")
cfg(cfg_proj_rel, "Release", "ALWAYS_SEARCH_USER_PATHS = NO; BUNDLE_IDENTIFIER = com.ktapex.myvault; CLANG_ENABLE_MODULES = YES; MARKETING_VERSION = 1.0.0; SDKROOT = iphoneos; SUPPORTED_PLATFORMS = \"iphoneos iphonesimulator\"; SWIFT_VERSION = 5.9;")

def cfglist(lid, cfgs):
    A(f"\t\t{lid} = {{isa = XCConfigurationList; buildConfigurations = ({cfgs[0]}, {cfgs[1]}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};")

cfglist(cfglist_proj, [cfg_proj_dbg, cfg_proj_rel])
cfglist(cfglist_app, [cfg_app_dbg, cfg_app_rel])
cfglist(cfglist_tests, [cfg_tests_dbg, cfg_tests_rel])
cfglist(cfglist_uitests, [cfg_uitests_dbg, cfg_uitests_rel])
cfglist(cfglist_widget, [cfg_widget_dbg, cfg_widget_rel])

A("\t};")
A(f"\trootObject = {proj};")
A("}")

outdir = os.path.join(ROOT, "MyVault.xcodeproj")
os.makedirs(outdir, exist_ok=True)
with open(os.path.join(outdir, "project.pbxproj"), "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
print("wrote project.pbxproj with", len(app_swift), "app +", len(widget_swift), "widget files")

# Regenerate the shared scheme so its BlueprintIdentifiers always match the
# freshly-generated target IDs above (the widget is built but not wired into
# the test action; unit + UI tests are).
scheme_dir = os.path.join(outdir, "xcshareddata", "xcschemes")
os.makedirs(scheme_dir, exist_ok=True)
scheme = (
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<Scheme LastUpgradeVersion="1620" version="1.3">\n'
    '   <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">\n'
    '      <BuildActionEntries>\n'
    f'         <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">\n'
    f'            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="MyVault.app" BlueprintName="MyVault" ReferencedContainer="container:MyVault.xcodeproj"/>\n'
    '         </BuildActionEntry>\n'
    '      </BuildActionEntries>\n'
    '   </BuildAction>\n'
    '   <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">\n'
    '      <Testables>\n'
    f'         <TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test_target}" BuildableName="MyVaultTests.xctest" BlueprintName="MyVaultTests" ReferencedContainer="container:MyVault.xcodeproj"/></TestableReference>\n'
    f'         <TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uitest_target}" BuildableName="MyVaultUITests.xctest" BlueprintName="MyVaultUITests" ReferencedContainer="container:MyVault.xcodeproj"/></TestableReference>\n'
    '      </Testables>\n'
    '   </TestAction>\n'
    '   <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">\n'
    f'      <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="MyVault.app" BlueprintName="MyVault" ReferencedContainer="container:MyVault.xcodeproj"/></BuildableProductRunnable>\n'
    '   </LaunchAction>\n'
    '   <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">\n'
    f'      <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="MyVault.app" BlueprintName="MyVault" ReferencedContainer="container:MyVault.xcodeproj"/></BuildableProductRunnable>\n'
    '   </ProfileAction>\n'
    '   <AnalyzeAction buildConfiguration="Debug"/>\n'
    '   <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>\n'
    '</Scheme>\n'
)
with open(os.path.join(scheme_dir, "MyVault.xcscheme"), "w", encoding="utf-8") as f:
    f.write(scheme)
print("wrote shared scheme with target IDs", app_target, test_target, uitest_target)
