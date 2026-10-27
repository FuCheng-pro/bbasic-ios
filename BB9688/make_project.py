#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成 BB9688.xcodeproj（纯手写 pbxproj，不依赖 Xcode 或 xcodegen）。

用法：
    python make_project.py

工程结构：
    BB9688/BB9688.xcodeproj
    BB9688/BB9688/*.swift          → 编译
    BB9688/BB9688/Resources/*.png  → 打进 bundle 根目录（Image("device-shell") 直接能找到）
    BB9688/BB9688/Resources/Programs → 以「文件夹引用」形式整体拷进 bundle
    BB9688/BB9688/Info.plist

增删 swift 文件后重跑本脚本即可。
"""

import os
import hashlib

ROOT = os.path.dirname(os.path.abspath(__file__))          # .../BB9688
SRC_DIR = os.path.join(ROOT, "BB9688")                     # 源码根
PROJ_DIR = os.path.join(ROOT, "BB9688.xcodeproj")
PROJ_NAME = "BB9688"

GROUP_ORDER = ["App", "Core", "Device", "Screen", "Launcher"]


def uid(seed):
    """稳定 24 位十六进制 ID"""
    h = hashlib.sha1(seed.encode("utf-8")).hexdigest().upper()
    return h[:24]


def swift_files():
    out = []
    for dirpath, dirnames, filenames in os.walk(SRC_DIR):
        dirnames.sort()
        for name in sorted(filenames):
            if not name.endswith(".swift"):
                continue
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, SRC_DIR).replace("\\", "/")
            group = rel.split("/")[0] if "/" in rel else ""
            out.append((rel, group))
    return out


def png_files():
    res = os.path.join(SRC_DIR, "Resources")
    return sorted(n for n in os.listdir(res)
                  if n.lower().endswith(".png"))


def build():
    sources = swift_files()
    pngs = png_files()

    # ---------- 文件引用 ----------
    refs = []          # (id, name, path, filetype, sourceTree)
    build_files = []   # (buildfile_id, fileref_id, name, phase)

    file_ref_ids = {}
    for rel, group in sources:
        fid = uid("ref:" + rel)
        file_ref_ids[rel] = fid
        refs.append((fid, os.path.basename(rel), os.path.basename(rel), "sourcecode.swift", "<group>"))

    png_ids = {}
    for name in pngs:
        fid = uid("ref:res:" + name)
        png_ids[name] = fid
        refs.append((fid, name, name, "image.png", "<group>"))

    folder_id = uid("ref:programs")
    refs.append((folder_id, "Programs", "Programs", "folder", "<group>"))

    info_id = uid("ref:infoplist")
    refs.append((info_id, "Info.plist", "Info.plist", "text.plist.xml", "<group>"))

    for rel, group in sources:
        build_files.append((uid("bf:" + rel), file_ref_ids[rel], os.path.basename(rel), "sources"))
    for name in pngs:
        build_files.append((uid("bf:res:" + name), png_ids[name], name, "resources"))
    build_files.append((uid("bf:programs"), folder_id, "Programs", "resources"))

    # ---------- 分组 ----------
    groups = []        # (id, name, children_ids)
    group_ids = {}
    for g in GROUP_ORDER:
        gid = uid("group:" + g)
        group_ids[g] = gid
    main_group = uid("group:main")
    src_group = uid("group:src")
    res_group = uid("group:resources")
    products_group = uid("group:products")

    for g in GROUP_ORDER:
        children = [file_ref_ids[rel] for rel, grp in sources if grp == g]
        groups.append((group_ids[g], g, children))

    # 根级 swift（如果有）
    root_swift = [file_ref_ids[rel] for rel, grp in sources if grp not in GROUP_ORDER]

    res_children = [png_ids[n] for n in pngs] + [folder_id]

    # ---------- target / project ----------
    target_id = uid("target")
    project_id = uid("project")
    product_ref = uid("ref:product")
    sources_phase = uid("phase:sources")
    resources_phase = uid("phase:resources")
    frameworks_phase = uid("phase:frameworks")
    project_cfg_list = uid("cfglist:project")
    target_cfg_list = uid("cfglist:target")
    cfg_proj_debug = uid("cfg:proj:debug")
    cfg_proj_release = uid("cfg:proj:release")
    cfg_tgt_debug = uid("cfg:tgt:debug")
    cfg_tgt_release = uid("cfg:tgt:release")

    common_proj = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ANALYZER_NONNULL": "YES",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
        "COPY_PHASE_STRIP": "NO",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "GCC_C_LANGUAGE_STANDARD": "gnu11",
        "IPHONEOS_DEPLOYMENT_TARGET": "16.0",
        "SDKROOT": "iphoneos",
        "SWIFT_VERSION": "5.0",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
    }
    proj_debug = dict(common_proj)
    proj_debug.update({
        "DEBUG_INFORMATION_FORMAT": "dwarf",
        "ENABLE_TESTABILITY": "YES",
        "GCC_OPTIMIZATION_LEVEL": "0",
        "GCC_PREPROCESSOR_DEFINITIONS": '(\n\t\t\t\t\t"DEBUG=1",\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t)',
        "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
        "ONLY_ACTIVE_ARCH": "YES",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
        "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
    })
    proj_release = dict(common_proj)
    proj_release.update({
        "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
        "ENABLE_NS_ASSERTIONS": "NO",
        "MTL_ENABLE_DEBUG_INFO": "NO",
        "SWIFT_COMPILATION_MODE": "wholemodule",
        "SWIFT_OPTIMIZATION_LEVEL": "-O",
        "VALIDATE_PRODUCT": "YES",
    })

    tgt_common = {
        "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": "BB9688/Info.plist",
        "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
        "INFOPLIST_KEY_UIStatusBarHidden": "YES",
        "LD_RUNPATH_SEARCH_PATHS": '(\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t\t"@executable_path/Frameworks",\n\t\t\t\t)',
        "MARKETING_VERSION": "0.5",
        "PRODUCT_BUNDLE_IDENTIFIER": "com.bbk.bb9688",
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "TARGETED_DEVICE_FAMILY": '"1,2"',
    }
    tgt_debug = dict(tgt_common)
    tgt_debug["SWIFT_OPTIMIZATION_LEVEL"] = "-Onone"
    tgt_release = dict(tgt_common)

    def settings_block(d, indent="\t\t\t\t"):
        lines = []
        for k, v in d.items():
            lines.append("%s%s = %s;" % (indent, k, v))
        return "\n".join(lines)

    # ---------- 拼装 ----------
    L = []
    A = L.append
    A("// !$*UTF8*$!")
    A("{")
    A("\tarchiveVersion = 1;")
    A("\tclasses = {")
    A("\t};")
    A("\tobjectVersion = 56;")
    A("\tobjects = {")

    # PBXBuildFile
    A("")
    A("/* Begin PBXBuildFile section */")
    for bid, fid, name, phase in build_files:
        A("\t\t%s /* %s in %s */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };"
          % (bid, name, "Sources" if phase == "sources" else "Resources", fid, name))
    A("/* End PBXBuildFile section */")

    # PBXFileReference
    A("")
    A("/* Begin PBXFileReference section */")
    A("\t\t%s /* %s.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; "
      "includeInIndex = 0; path = %s.app; sourceTree = BUILT_PRODUCTS_DIR; };"
      % (product_ref, PROJ_NAME, PROJ_NAME))
    for fid, name, path, ftype, tree in refs:
        A("\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = %s; path = \"%s\"; sourceTree = \"%s\"; };"
          % (fid, name, ftype, path, tree))
    A("/* End PBXFileReference section */")

    # PBXFrameworksBuildPhase
    A("")
    A("/* Begin PBXFrameworksBuildPhase section */")
    A("\t\t%s /* Frameworks */ = {" % frameworks_phase)
    A("\t\t\tisa = PBXFrameworksBuildPhase;")
    A("\t\t\tbuildActionMask = 2147483647;")
    A("\t\t\tfiles = (")
    A("\t\t\t);")
    A("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    A("\t\t};")
    A("/* End PBXFrameworksBuildPhase section */")

    # PBXGroup
    A("")
    A("/* Begin PBXGroup section */")
    A("\t\t%s = {" % main_group)
    A("\t\t\tisa = PBXGroup;")
    A("\t\t\tchildren = (")
    A("\t\t\t\t%s /* BB9688 */," % src_group)
    A("\t\t\t\t%s /* Products */," % products_group)
    A("\t\t\t);")
    A("\t\t\tsourceTree = \"<group>\";")
    A("\t\t};")

    A("\t\t%s /* BB9688 */ = {" % src_group)
    A("\t\t\tisa = PBXGroup;")
    A("\t\t\tchildren = (")
    for g in GROUP_ORDER:
        A("\t\t\t\t%s /* %s */," % (group_ids[g], g))
    for cid in root_swift:
        A("\t\t\t\t%s," % cid)
    A("\t\t\t\t%s /* Resources */," % res_group)
    A("\t\t\t\t%s /* Info.plist */," % info_id)
    A("\t\t\t);")
    A("\t\t\tpath = BB9688;")
    A("\t\t\tsourceTree = \"<group>\";")
    A("\t\t};")

    for gid, name, children in groups:
        A("\t\t%s /* %s */ = {" % (gid, name))
        A("\t\t\tisa = PBXGroup;")
        A("\t\t\tchildren = (")
        for cid in children:
            A("\t\t\t\t%s," % cid)
        A("\t\t\t);")
        A("\t\t\tpath = %s;" % name)
        A("\t\t\tsourceTree = \"<group>\";")
        A("\t\t};")

    A("\t\t%s /* Resources */ = {" % res_group)
    A("\t\t\tisa = PBXGroup;")
    A("\t\t\tchildren = (")
    for cid in res_children:
        A("\t\t\t\t%s," % cid)
    A("\t\t\t);")
    A("\t\t\tpath = Resources;")
    A("\t\t\tsourceTree = \"<group>\";")
    A("\t\t};")

    A("\t\t%s /* Products */ = {" % products_group)
    A("\t\t\tisa = PBXGroup;")
    A("\t\t\tchildren = (")
    A("\t\t\t\t%s /* %s.app */," % (product_ref, PROJ_NAME))
    A("\t\t\t);")
    A("\t\t\tname = Products;")
    A("\t\t\tsourceTree = \"<group>\";")
    A("\t\t};")
    A("/* End PBXGroup section */")

    # PBXNativeTarget
    A("")
    A("/* Begin PBXNativeTarget section */")
    A("\t\t%s /* %s */ = {" % (target_id, PROJ_NAME))
    A("\t\t\tisa = PBXNativeTarget;")
    A("\t\t\tbuildConfigurationList = %s;" % target_cfg_list)
    A("\t\t\tbuildPhases = (")
    A("\t\t\t\t%s /* Sources */," % sources_phase)
    A("\t\t\t\t%s /* Frameworks */," % frameworks_phase)
    A("\t\t\t\t%s /* Resources */," % resources_phase)
    A("\t\t\t);")
    A("\t\t\tbuildRules = (")
    A("\t\t\t);")
    A("\t\t\tdependencies = (")
    A("\t\t\t);")
    A("\t\t\tname = %s;" % PROJ_NAME)
    A("\t\t\tproductName = %s;" % PROJ_NAME)
    A("\t\t\tproductReference = %s /* %s.app */;" % (product_ref, PROJ_NAME))
    A("\t\t\tproductType = \"com.apple.product-type.application\";")
    A("\t\t};")
    A("/* End PBXNativeTarget section */")

    # PBXProject
    A("")
    A("/* Begin PBXProject section */")
    A("\t\t%s /* Project object */ = {" % project_id)
    A("\t\t\tisa = PBXProject;")
    A("\t\t\tattributes = {")
    A("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    A("\t\t\t\tLastSwiftUpdateCheck = 1520;")
    A("\t\t\t\tLastUpgradeCheck = 1520;")
    A("\t\t\t\tTargetAttributes = {")
    A("\t\t\t\t\t%s = {" % target_id)
    A("\t\t\t\t\t\tCreatedOnToolsVersion = 15.2;")
    A("\t\t\t\t\t};")
    A("\t\t\t\t};")
    A("\t\t\t};")
    A("\t\t\tbuildConfigurationList = %s;" % project_cfg_list)
    A("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
    A("\t\t\tdevelopmentRegion = zh_CN;")
    A("\t\t\thasScannedForEncodings = 0;")
    A("\t\t\tknownRegions = (")
    A("\t\t\t\tzh_CN,")
    A("\t\t\t\tBase,")
    A("\t\t\t);")
    A("\t\t\tmainGroup = %s;" % main_group)
    A("\t\t\tproductRefGroup = %s /* Products */;" % products_group)
    A("\t\t\tprojectDirPath = \"\";")
    A("\t\t\tprojectRoot = \"\";")
    A("\t\t\ttargets = (")
    A("\t\t\t\t%s /* %s */," % (target_id, PROJ_NAME))
    A("\t\t\t);")
    A("\t\t};")
    A("/* End PBXProject section */")

    # Resources phase
    A("")
    A("/* Begin PBXResourcesBuildPhase section */")
    A("\t\t%s /* Resources */ = {" % resources_phase)
    A("\t\t\tisa = PBXResourcesBuildPhase;")
    A("\t\t\tbuildActionMask = 2147483647;")
    A("\t\t\tfiles = (")
    for bid, fid, name, phase in build_files:
        if phase == "resources":
            A("\t\t\t\t%s /* %s */," % (bid, name))
    A("\t\t\t);")
    A("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    A("\t\t};")
    A("/* End PBXResourcesBuildPhase section */")

    # Sources phase
    A("")
    A("/* Begin PBXSourcesBuildPhase section */")
    A("\t\t%s /* Sources */ = {" % sources_phase)
    A("\t\t\tisa = PBXSourcesBuildPhase;")
    A("\t\t\tbuildActionMask = 2147483647;")
    A("\t\t\tfiles = (")
    for bid, fid, name, phase in build_files:
        if phase == "sources":
            A("\t\t\t\t%s /* %s */," % (bid, name))
    A("\t\t\t);")
    A("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    A("\t\t};")
    A("/* End PBXSourcesBuildPhase section */")

    # XCBuildConfiguration
    A("")
    A("/* Begin XCBuildConfiguration section */")
    A("\t\t%s /* Debug */ = {" % cfg_proj_debug)
    A("\t\t\tisa = XCBuildConfiguration;")
    A("\t\t\tbuildSettings = {")
    A(settings_block(proj_debug))
    A("\t\t\t};")
    A("\t\t\tname = Debug;")
    A("\t\t};")
    A("\t\t%s /* Release */ = {" % cfg_proj_release)
    A("\t\t\tisa = XCBuildConfiguration;")
    A("\t\t\tbuildSettings = {")
    A(settings_block(proj_release))
    A("\t\t\t};")
    A("\t\t\tname = Release;")
    A("\t\t};")
    A("\t\t%s /* Debug */ = {" % cfg_tgt_debug)
    A("\t\t\tisa = XCBuildConfiguration;")
    A("\t\t\tbuildSettings = {")
    A(settings_block(tgt_debug))
    A("\t\t\t};")
    A("\t\t\tname = Debug;")
    A("\t\t};")
    A("\t\t%s /* Release */ = {" % cfg_tgt_release)
    A("\t\t\tisa = XCBuildConfiguration;")
    A("\t\t\tbuildSettings = {")
    A(settings_block(tgt_release))
    A("\t\t\t};")
    A("\t\t\tname = Release;")
    A("\t\t};")
    A("/* End XCBuildConfiguration section */")

    # XCConfigurationList
    A("")
    A("/* Begin XCConfigurationList section */")
    A("\t\t%s /* Build configuration list for PBXProject */ = {" % project_cfg_list)
    A("\t\t\tisa = XCConfigurationList;")
    A("\t\t\tbuildConfigurations = (")
    A("\t\t\t\t%s /* Debug */," % cfg_proj_debug)
    A("\t\t\t\t%s /* Release */," % cfg_proj_release)
    A("\t\t\t);")
    A("\t\t\tdefaultConfigurationIsVisible = 0;")
    A("\t\t\tdefaultConfigurationName = Release;")
    A("\t\t};")
    A("\t\t%s /* Build configuration list for PBXNativeTarget */ = {" % target_cfg_list)
    A("\t\t\tisa = XCConfigurationList;")
    A("\t\t\tbuildConfigurations = (")
    A("\t\t\t\t%s /* Debug */," % cfg_tgt_debug)
    A("\t\t\t\t%s /* Release */," % cfg_tgt_release)
    A("\t\t\t);")
    A("\t\t\tdefaultConfigurationIsVisible = 0;")
    A("\t\t\tdefaultConfigurationName = Release;")
    A("\t\t};")
    A("/* End XCConfigurationList section */")

    A("\t};")
    A("\trootObject = %s /* Project object */;" % project_id)
    A("}")

    os.makedirs(PROJ_DIR, exist_ok=True)
    with open(os.path.join(PROJ_DIR, "project.pbxproj"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(L) + "\n")

    scheme_dir = os.path.join(PROJ_DIR, "xcshareddata", "xcschemes")
    os.makedirs(scheme_dir, exist_ok=True)
    with open(os.path.join(scheme_dir, PROJ_NAME + ".xcscheme"), "w",
              encoding="utf-8", newline="\n") as f:
        f.write(SCHEME % {"target": target_id, "project": PROJ_NAME})

    print("生成 %s" % os.path.join(PROJ_DIR, "project.pbxproj"))
    print("  Swift 源文件 %d 个" % len(sources))
    print("  图片资源 %d 个 + Programs 文件夹引用" % len(pngs))


SCHEME = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1520" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "%(target)s"
               BuildableName = "BB9688.app"
               BlueprintName = "BB9688"
               ReferencedContainer = "container:%(project)s.xcodeproj">
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
            BlueprintIdentifier = "%(target)s"
            BuildableName = "BB9688.app"
            BlueprintName = "BB9688"
            ReferencedContainer = "container:%(project)s.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "%(target)s"
            BuildableName = "BB9688.app"
            BlueprintName = "BB9688"
            ReferencedContainer = "container:%(project)s.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""


if __name__ == "__main__":
    build()
