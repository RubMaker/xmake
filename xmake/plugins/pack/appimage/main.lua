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

-- get the appimagetool
function _get_appimagetool()
    local appimagetool = find_tool("appimagetool")
    if not appimagetool then
        -- try to download appimagetool if not found
        local appimagetool_url = "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage"
        local appimagetool_path = path.join(os.tmpdir(), "appimagetool")
        if not os.isfile(appimagetool_path) then
            print("appimagetool not found, downloading...")
            os.runv("wget", {"-O", appimagetool_path, appimagetool_url})
            os.runv("chmod", {"+x", appimagetool_path})
        end
        appimagetool = {program = appimagetool_path}
    end
    assert(appimagetool, "appimagetool not found and failed to download!")
    return appimagetool
end

-- get linuxdeploy tool
function _get_linuxdeploy()
    local linuxdeploy = find_tool("linuxdeploy")
    if not linuxdeploy then
        local linuxdeploy_url = "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage"
        local linuxdeploy_path = path.join(os.tmpdir(), "linuxdeploy")
        if not os.isfile(linuxdeploy_path) then
            print("linuxdeploy not found, downloading...")
            os.runv("wget", {"-O", linuxdeploy_path, linuxdeploy_url})
            os.runv("chmod", {"+x", linuxdeploy_path})
        end
        linuxdeploy = {program = linuxdeploy_path}
    end
    return linuxdeploy
end

-- get appimage output file
function _get_appimage_file(package)
    local filename = string.format("%s-%s-x86_64.AppImage", package:name(), package:version())
    return path.absolute(path.join(path.directory(package:outputfile() or ""), filename))
end

-- translate the file path for AppDir structure
function _translate_filepath(package, filepath, appdir)
    local prefix = package:get("prefixdir") or "/usr"
    local relative_path = filepath
    if filepath:startswith(package:install_rootdir()) then
        relative_path = path.relative(filepath, package:install_rootdir())
    end
    
    -- map standard directories to AppDir structure
    if relative_path:startswith("usr/bin/") then
        return path.join(appdir, "usr/bin", path.filename(relative_path))
    elseif relative_path:startswith("usr/lib/") then
        return path.join(appdir, "usr/lib", path.relative(relative_path, "usr/lib"))
    elseif relative_path:startswith("usr/share/") then
        return path.join(appdir, "usr/share", path.relative(relative_path, "usr/share"))
    else
        return path.join(appdir, relative_path)
    end
end

-- get install command for AppDir
function _get_customcmd(package, appdir, installcmds, cmd)
    local opt = cmd.opt or {}
    local kind = cmd.kind
    if kind == "cp" then
        local srcfiles = os.files(cmd.srcpath)
        for _, srcfile in ipairs(srcfiles) do
            local dstfile = _translate_filepath(package, cmd.dstpath, appdir)
            if #srcfiles > 1 or path.islastsep(dstfile) then
                if opt.rootdir then
                    dstfile = path.join(dstfile, path.relative(srcfile, opt.rootdir))
                else
                    dstfile = path.join(dstfile, path.filename(srcfile))
                end
            end
            table.insert(installcmds, string.format("install -Dpm0755 \"%s\" \"%s\"", srcfile, dstfile))
        end
    elseif kind == "rm" then
        local filepath = _translate_filepath(package, cmd.filepath, appdir)
        table.insert(installcmds, string.format("rm -f \"%s\"", filepath))
    elseif kind == "rmdir" then
        local dir = _translate_filepath(package, cmd.dir, appdir)
        table.insert(installcmds, string.format("rm -rf \"%s\"", dir))
    elseif kind == "mv" then
        local srcpath = _translate_filepath(package, cmd.srcpath, appdir)
        local dstpath = _translate_filepath(package, cmd.dstpath, appdir)
        table.insert(installcmds, string.format("mv \"%s\" \"%s\"", srcpath, dstpath))
    elseif kind == "cd" then
        local dir = _translate_filepath(package, cmd.dir, appdir)
        table.insert(installcmds, string.format("cd \"%s\"", dir))
    elseif kind == "mkdir" then
        local dir = _translate_filepath(package, cmd.dir, appdir)
        table.insert(installcmds, string.format("mkdir -p \"%s\"", dir))
    elseif cmd.program then
        local argv = {}
        for _, arg in ipairs(cmd.argv) do
            if path.instance_of(arg) then
                arg = arg:clone():set(_translate_filepath(package, arg:rawstr(), appdir)):str()
            elseif path.is_absolute(arg) then
                arg = _translate_filepath(package, arg, appdir)
            end
            table.insert(argv, arg)
        end
        table.insert(installcmds, string.format("%s", os.args(table.join(cmd.program, argv))))
    end
end

-- get install commands for AppDir
function _get_installcmds(package, appdir, installcmds, cmds)
    for _, cmd in ipairs(cmds) do
        _get_customcmd(package, appdir, installcmds, cmd)
    end
end

-- create desktop file
function _create_desktop_file(package, appdir)
    local desktop_content = string.format([[
[Desktop Entry]
Type=Application
Name=%s
Comment=%s
Exec=%s
Icon=%s
Categories=%s
Version=%s
]], 
        package:get("title") or package:name(),
        package:get("description") or package:get("title") or package:name(),
        package:name(),
        package:name(),
        package:get("category") or "Utility",
        package:version()
    )
    
    local desktop_file = path.join(appdir, package:name() .. ".desktop")
    io.writefile(desktop_file, desktop_content)
    return desktop_file
end

-- create AppRun script
function _create_apprun(package, appdir)
    local main_executable = package:get("bindir") and path.join("usr/bin", package:name()) or package:name()
    local apprun_content = string.format([[#!/bin/bash
HERE="$(dirname "$(readlink -f "${0}")")"
export PATH="${HERE}/usr/bin:${PATH}"
export LD_LIBRARY_PATH="${HERE}/usr/lib:${LD_LIBRARY_PATH}"
export XDG_DATA_DIRS="${HERE}/usr/share:${XDG_DATA_DIRS}"

exec "${HERE}/%s" "$@"
]], main_executable)
    
    local apprun_file = path.join(appdir, "AppRun")
    io.writefile(apprun_file, apprun_content)
    os.runv("chmod", {"+x", apprun_file})
    return apprun_file
end

-- copy icon file
function _copy_icon(package, appdir)
    local iconfile = package:get("iconfile")
    if iconfile and os.isfile(iconfile) then
        local icon_dst = path.join(appdir, package:name() .. path.extension(iconfile))
        os.cp(iconfile, icon_dst)
        return icon_dst
    else
        -- create a simple icon if not provided
        local icon_dst = path.join(appdir, package:name() .. ".png")
        -- This would need a default icon or skip if no icon provided
        print("Warning: No icon file specified for AppImage")
        return nil
    end
end

-- pack appimage package
function _pack_appimage(appimagetool, package)
    -- create temporary AppDir
    local appdir_name = package:name() .. ".AppDir"
    local appdir = path.join(os.tmpdir(), appdir_name)
    os.tryrm(appdir)
    os.mkdir(appdir)
    os.mkdir(path.join(appdir, "usr"))
    os.mkdir(path.join(appdir, "usr/bin"))
    os.mkdir(path.join(appdir, "usr/lib"))
    os.mkdir(path.join(appdir, "usr/share"))

    -- install files to AppDir
    local prefixdir = package:get("prefixdir")
    package:set("prefixdir", path.join(appdir, "usr"))
    
    local installcmds = {}
    _get_installcmds(package, appdir, installcmds, batchcmds.get_installcmds(package):cmds())
    for _, component in table.orderpairs(package:components()) do
        if component:get("default") ~= false then
            _get_installcmds(package, appdir, installcmds, batchcmds.get_installcmds(component):cmds())
        end
    end
    
    -- execute install commands
    for _, cmd in ipairs(installcmds) do
        print("Executing: " .. cmd)
        os.exec(cmd)
    end
    
    package:set("prefixdir", prefixdir)

    -- copy source files
    local srcfiles, dstfiles = package:sourcefiles()
    for idx, srcfile in ipairs(srcfiles) do
        local dstfile = _translate_filepath(package, dstfiles[idx], appdir)
        os.vcp(srcfile, dstfile)
    end
    
    for _, component in table.orderpairs(package:components()) do
        if component:get("default") ~= false then
            local srcfiles, dstfiles = component:sourcefiles()
            for idx, srcfile in ipairs(srcfiles) do
                local dstfile = _translate_filepath(package, dstfiles[idx], appdir)
                os.vcp(srcfile, dstfile)
            end
        end
    end

    -- create required AppImage files
    _create_desktop_file(package, appdir)
    _create_apprun(package, appdir)
    _copy_icon(package, appdir)

    -- use linuxdeploy for dependency resolution if available
    local linuxdeploy = _get_linuxdeploy()
    if linuxdeploy then
        local main_executable = path.join(appdir, "usr/bin", package:name())
        if os.isfile(main_executable) then
            print("Using linuxdeploy for dependency resolution...")
            os.vrunv(linuxdeploy.program, {
                "--appdir", appdir,
                "--executable", main_executable,
                "--desktop-file", path.join(appdir, package:name() .. ".desktop")
            })
        end
    end

    -- build AppImage
    local appimage_file = _get_appimage_file(package)
    os.tryrm(appimage_file)
    
    -- set ARCH environment variable
    local arch = package:get("arch") or "x86_64"
    local envs = {ARCH = arch}
    
    print(string.format("Building AppImage: %s", appimage_file))
    os.vrunv(appimagetool.program, {appdir, appimage_file}, {envs = envs})

    -- copy AppImage file to output location
    if package:outputfile() then
        os.vcp(appimage_file, package:outputfile())
    end

    -- cleanup
    os.tryrm(appdir)
end

function main(package)
    if not is_host("linux") then
        return
    end

    cprint("packing %s", package:outputfile() or _get_appimage_file(package))

    -- get appimagetool
    local appimagetool = _get_appimagetool()

    -- pack appimage
    _pack_appimage(appimagetool, package)
end