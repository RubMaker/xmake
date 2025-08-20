--!A cross-platform build utility based on Lua
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
-- Copyright (C) 2015-present, TBOOX Open Source Group.
--
-- @author      RubMaker
-- @file        main.lua
--

-- imports
import("core.base.option")
import("core.base.semver")
import("core.base.hashset")
import("lib.detect.find_tool")
import("lib.detect.find_file")
import("utils.archive")
import(".batchcmds")

-- get hdiutil tool
function _get_hdiutil()
    local hdiutil = find_tool("hdiutil", {force = true})
    assert(hdiutil, "hdiutil not found, DMG creation requires macOS!")
    return hdiutil
end

-- get codesign tool (optional)
function _get_codesign()
    return find_tool("codesign", {force = false})
end

-- get create-dmg tool (optional, for better DMG creation)
function _get_create_dmg()
    return find_tool("create-dmg", {force = false})
end

-- get dmg file path
function _get_dmgfile(package)
    return path.absolute(path.join(path.directory(package:sourcedir()), package:name() .. "-" .. package:version() .. ".dmg"))
end

-- translate the file path for macOS
function _translate_filepath(package, filepath)
    return filepath:replace(package:install_rootdir(), "/Applications", {plain = true})
end

-- get install command for macOS
function _get_customcmd(package, installcmds, cmd)
    local opt = cmd.opt or {}
    local kind = cmd.kind
    if kind == "cp" then
        local srcfiles = os.files(cmd.srcpath)
        for _, srcfile in ipairs(srcfiles) do
            -- the destination is directory? append the filename
            local dstfile = _translate_filepath(package, cmd.dstpath)
            if #srcfiles > 1 or path.islastsep(dstfile) then
                if opt.rootdir then
                    dstfile = path.join(dstfile, path.relative(srcfile, opt.rootdir))
                else
                    dstfile = path.join(dstfile, path.filename(srcfile))
                end
            end
            table.insert(installcmds, string.format("cp -R \"%s\" \"%s\"", srcfile, dstfile))
        end
    elseif kind == "rm" then
        local filepath = _translate_filepath(package, cmd.filepath)
        table.insert(installcmds, string.format("rm -f \"%s\"", filepath))
    elseif kind == "rmdir" then
        local dir = _translate_filepath(package, cmd.dir)
        table.insert(installcmds, string.format("rm -rf \"%s\"", dir))
    elseif kind == "mv" then
        local srcpath = _translate_filepath(package, cmd.srcpath)
        local dstpath = _translate_filepath(package, cmd.dstpath)
        table.insert(installcmds, string.format("mv \"%s\" \"%s\"", srcpath, dstpath))
    elseif kind == "cd" then
        local dir = _translate_filepath(package, cmd.dir)
        table.insert(installcmds, string.format("cd \"%s\"", dir))
    elseif kind == "mkdir" then
        local dir = _translate_filepath(package, cmd.dir)
        table.insert(installcmds, string.format("mkdir -p \"%s\"", dir))
    elseif cmd.program then
        local argv = {}
        for _, arg in ipairs(cmd.argv) do
            if path.instance_of(arg) then
                arg = arg:clone():set(_translate_filepath(package, arg:rawstr())):str()
            elseif path.is_absolute(arg) then
                arg = _translate_filepath(package, arg)
            end
            table.insert(argv, arg)
        end
        table.insert(installcmds, string.format("%s", os.args(table.join(cmd.program, argv))))
    end
end

-- get build commands
function _get_buildcmds(package, buildcmds, cmds)
    for _, cmd in ipairs(cmds) do
        _get_customcmd(package, buildcmds, cmd)
    end
end

-- get install commands
function _get_installcmds(package, installcmds, cmds)
    for _, cmd in ipairs(cmds) do
        _get_customcmd(package, installcmds, cmd)
    end
end

-- get specvars for DMG
function _get_specvars(package)
    local specvars = table.clone(package:specvars())
    specvars.PACKAGE_DATE = os.date("%Y-%m-%d %H:%M:%S")
    local author = package:get("author") or "Unknown Developer"
    specvars.PACKAGE_COPYRIGHT = "Copyright © " .. os.date("%Y") .. " " .. author
    specvars.PACKAGE_IDENTIFIER = package:get("identifier") or ("com.example." .. package:name())
    specvars.PACKAGE_BUNDLE_VERSION = package:version()
    specvars.PACKAGE_BUNDLE_SHORT_VERSION = package:version()
    
    -- Get codesign identity if available
    local identity = package:get("codesign_identity") or os.getenv("CODESIGN_IDENTITY")
    specvars.CODESIGN_IDENTITY = identity or ""
    
    -- DMG appearance settings
    specvars.DMG_WINDOW_X = package:get("dmg_window_x") or 100
    specvars.DMG_WINDOW_Y = package:get("dmg_window_y") or 100  
    specvars.DMG_WINDOW_WIDTH = package:get("dmg_window_width") or 540
    specvars.DMG_WINDOW_HEIGHT = package:get("dmg_window_height") or 380
    specvars.DMG_BACKGROUND = package:get("dmg_background") or ""
    specvars.DMG_ICON_SIZE = package:get("dmg_icon_size") or 80
    
    return specvars
end

-- create app bundle structure
function _create_app_bundle(package, bundle_dir)
    -- Create basic app bundle structure
    local app_name = package:name() .. ".app"
    local app_path = path.join(bundle_dir, app_name)
    local contents_dir = path.join(app_path, "Contents")
    local macos_dir = path.join(contents_dir, "MacOS")
    local resources_dir = path.join(contents_dir, "Resources")
    
    os.mkdir(contents_dir)
    os.mkdir(macos_dir)
    os.mkdir(resources_dir)
    
    -- Copy executable and resources
    local srcfiles, dstfiles = package:sourcefiles()
    for idx, srcfile in ipairs(srcfiles) do
        local dstfile = dstfiles[idx]
        if dstfile:find("MacOS") then
            dstfile = path.join(macos_dir, path.filename(dstfile))
        elseif dstfile:find("Resources") then
            dstfile = path.join(resources_dir, path.filename(dstfile))
        else
            dstfile = path.join(contents_dir, path.relative(dstfile, package:install_rootdir()))
        end
        os.vcp(srcfile, dstfile)
        
        -- Make executable files executable
        if dstfile:find("MacOS") then
            os.runv("chmod", {"+x", dstfile})
        end
    end
    
    -- Copy component files
    for _, component in table.orderpairs(package:components()) do
        if component:get("default") ~= false then
            local srcfiles, dstfiles = component:sourcefiles()
            for idx, srcfile in ipairs(srcfiles) do
                local dstfile = dstfiles[idx]
                if dstfile:find("MacOS") then
                    dstfile = path.join(macos_dir, path.filename(dstfile))
                elseif dstfile:find("Resources") then
                    dstfile = path.join(resources_dir, path.filename(dstfile))
                else
                    dstfile = path.join(contents_dir, path.relative(dstfile, package:install_rootdir()))
                end
                os.vcp(srcfile, dstfile)
                
                if dstfile:find("MacOS") then
                    os.runv("chmod", {"+x", dstfile})
                end
            end
        end
    end
    
    -- Generate Info.plist
    _generate_info_plist(package, path.join(contents_dir, "Info.plist"))
    
    return app_path
end

-- generate Info.plist file
function _generate_info_plist(package, plist_path)
    local specvars = _get_specvars(package)
    local plist_content = string.format([[<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>%s</string>
    <key>CFBundleIdentifier</key>
    <string>%s</string>
    <key>CFBundleName</key>
    <string>%s</string>
    <key>CFBundleDisplayName</key>
    <string>%s</string>
    <key>CFBundleVersion</key>
    <string>%s</string>
    <key>CFBundleShortVersionString</key>
    <string>%s</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>%s</string>
</dict>
</plist>]], 
        package:name(),
        specvars.PACKAGE_IDENTIFIER,
        package:name(),
        package:displayname() or package:name(),
        specvars.PACKAGE_BUNDLE_VERSION,
        specvars.PACKAGE_BUNDLE_SHORT_VERSION,
        specvars.PACKAGE_COPYRIGHT
    )
    
    io.writefile(plist_path, plist_content)
end

-- code sign the app bundle
function _codesign_bundle(codesign, app_path, identity)
    if codesign and identity and identity ~= "" then
        cprint("Code signing %s with identity: %s", path.filename(app_path), identity)
        os.vrunv(codesign.program, {
            "--force",
            "--sign", identity,
            "--timestamp",
            "--options", "runtime",
            app_path
        })
    end
end

-- create DMG using hdiutil
function _create_dmg_hdiutil(hdiutil, package, bundle_dir, dmg_file)
    local temp_dmg = dmg_file .. ".temp.dmg"
    local volume_name = package:displayname() or package:name()
    
    -- Create temporary DMG
    cprint("Creating temporary DMG...")
    os.vrunv(hdiutil.program, {
        "create",
        "-srcfolder", bundle_dir,
        "-volname", volume_name,
        "-fs", "HFS+",
        "-fsargs", "-c c=64,a=16,e=16",
        "-format", "UDRW",
        temp_dmg
    })
    
    -- Mount the temporary DMG
    cprint("Mounting DMG for customization...")
    local mount_output = os.iorunv(hdiutil.program, {"attach", "-readwrite", "-noverify", temp_dmg})
    local mount_point = mount_output:match("/Volumes/[^\r\n]*")
    
    if mount_point then
        -- Create Applications symlink
        os.runv("ln", {"-sf", "/Applications", path.join(mount_point, "Applications")})
        
        -- Copy background image if provided
        local background = package:get("dmg_background")
        if background and os.isfile(background) then
            local background_dir = path.join(mount_point, ".background")
            os.mkdir(background_dir)
            os.cp(background, path.join(background_dir, path.filename(background)))
        end
        
        -- Unmount
        os.vrunv(hdiutil.program, {"detach", mount_point})
    end
    
    -- Convert to final compressed DMG
    cprint("Creating final compressed DMG...")
    os.tryrm(dmg_file)
    os.vrunv(hdiutil.program, {
        "convert", temp_dmg,
        "-format", "UDZO",
        "-imagekey", "zlib-level=9",
        "-o", dmg_file
    })
    
    -- Clean up
    os.tryrm(temp_dmg)
end

-- create DMG using create-dmg tool (if available)
function _create_dmg_advanced(create_dmg, package, bundle_dir, dmg_file)
    local volume_name = package:displayname() or package:name()
    local specvars = _get_specvars(package)
    local args = {
        "--volname", volume_name,
        "--window-size", specvars.DMG_WINDOW_WIDTH, specvars.DMG_WINDOW_HEIGHT,
        "--icon-size", specvars.DMG_ICON_SIZE,
        "--app-drop-link", "450", "150"
    }
    
    -- Add background if specified
    if specvars.DMG_BACKGROUND ~= "" and os.isfile(specvars.DMG_BACKGROUND) then
        table.insert(args, "--background")
        table.insert(args, specvars.DMG_BACKGROUND)
    end
    
    table.insert(args, dmg_file)
    table.insert(args, bundle_dir)
    
    cprint("Creating DMG with create-dmg...")
    os.vrunv(create_dmg.program, args)
end

-- pack DMG package
function _pack_dmg(hdiutil, codesign, create_dmg, package)
    local dmg_file = _get_dmgfile(package)
    local bundle_dir = path.join(os.tmpdir(), "dmg_build_" .. package:name())
    
    -- Clean and create bundle directory
    os.tryrm(bundle_dir)
    os.mkdir(bundle_dir)
    
    -- Create app bundle
    local app_path = _create_app_bundle(package, bundle_dir)
    
    -- Code sign if identity is provided
    local specvars = _get_specvars(package)
    if specvars.CODESIGN_IDENTITY ~= "" then
        _codesign_bundle(codesign, app_path, specvars.CODESIGN_IDENTITY)
    end
    
    -- Create DMG
    if create_dmg then
        _create_dmg_advanced(create_dmg, package, bundle_dir, dmg_file)
    else
        _create_dmg_hdiutil(hdiutil, package, bundle_dir, dmg_file)
    end
    
    -- Copy to output location
    os.vcp(dmg_file, package:outputfile())
    
    -- Clean up
    os.tryrm(bundle_dir)
    os.tryrm(dmg_file)
end

function main(package)
    if not is_host("macosx") then
        return
    end

    cprint("packing %s", package:outputfile())

    -- Get required tools
    local hdiutil = _get_hdiutil()
    local codesign = _get_codesign()
    local create_dmg = _get_create_dmg()
    
    if create_dmg then
        cprint("Using create-dmg for enhanced DMG creation")
    else
        cprint("Using hdiutil for basic DMG creation")
        cprint("Install create-dmg for better DMG appearance: brew install create-dmg")
    end

    -- Pack DMG package
    _pack_dmg(hdiutil, codesign, create_dmg, package)
end