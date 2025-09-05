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
        assert(appimagetool, "appimagetool need to be downloaded!")
    end
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
    -- 获取安装根目录
    local install_rootdir = package:install_rootdir()
    
    -- 如果路径在安装根目录下，转换为相对路径
    if filepath:startswith(install_rootdir) then
        local relative_path = path.relative(filepath, install_rootdir)
        
        -- 移除开头的 usr/ 如果存在（因为我们会添加自己的 usr 前缀）
        if relative_path:startswith("usr/") then
            relative_path = relative_path:sub(5) -- 移除 "usr/"
        end
        
        -- 映射到AppDir的usr目录结构
        if relative_path:startswith("bin/") then
            return path.join(appdir, "usr", relative_path)
        elseif relative_path:startswith("lib/") then
            return path.join(appdir, "usr", relative_path)
        elseif relative_path:startswith("share/") then
            return path.join(appdir, "usr", relative_path)
        elseif relative_path:startswith("include/") then
            return path.join(appdir, "usr", relative_path)
        else
            -- 根据文件扩展名智能映射
            local filename = path.filename(filepath)
            local ext = path.extension(filename):lower()
            
            -- 二进制可执行文件 -> usr/bin
            if ext == "" or ext == ".exe" then
                return path.join(appdir, "usr", "bin", filename)
            -- 库文件 -> usr/lib
            elseif ext == ".so" or ext == ".dylib" or ext == ".dll" then
                return path.join(appdir, "usr", "lib", filename)
            -- 图标文件 -> usr/share/icons/hicolor
            elseif ext == ".png" or ext == ".svg" or ext == ".ico" or ext == ".xpm" then
                local icon_dir = path.join(appdir, "usr/share/icons/hicolor/256x256/apps")
                return path.join(icon_dir, filename)
            -- 桌面文件 -> usr/share/applications
            elseif ext == ".desktop" then
                return path.join(appdir, "usr/share/applications", filename)
            -- 其他文件 -> usr/share/<package-name> 或基于原始路径
            else
                -- 尝试保持原始目录结构
                local dirname = path.directory(relative_path)
                if dirname and dirname ~= "." then
                    return path.join(appdir, "usr", "share", package:name(), dirname, filename)
                else
                    return path.join(appdir, "usr", "share", package:name(), filename)
                end
            end
        end
    else
        -- 对于绝对路径或其他路径，根据文件类型智能映射
        local filename = path.filename(filepath)
        local ext = path.extension(filename):lower()
        
        -- 源代码文件不应该被安装到bin目录
        if ext == ".cpp" or ext == ".c" or ext == ".h" or ext == ".hpp" or 
           ext == ".py" or ext == ".js" or ext == ".java" or ext == ".go" then
            -- 源代码文件应该被跳过或放到开发目录
            return nil -- 返回nil表示不应该被复制
        -- 二进制文件
        elseif ext == "" or ext == ".exe" then
            return path.join(appdir, "usr", "bin", filename)
        -- 库文件
        elseif ext == ".so" or ext == ".dylib" or ext == ".dll" then
            return path.join(appdir, "usr", "lib", filename)
        -- 图标文件
        elseif ext == ".png" or ext == ".svg" or ext == ".ico" or ext == ".xpm" then
            local icon_dir = path.join(appdir, "usr/share/icons/hicolor/256x256/apps")
            return path.join(icon_dir, filename)
        -- 其他文件
        else
            return path.join(appdir, "usr", "share", package:name(), filename)
        end
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
            if dstfile then
                table.insert(installcmds, string.format("install -Dpm0755 \"%s\" \"%s\"", srcfile, dstfile))
            end
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
    local iconname = package:get("iconname") or package:name()
    local desktop_content = string.format([[
[Desktop Entry]
Type=Application
Name=%s
Comment=%s
Exec=%s
Icon=%s
Categories=%s
Version=1.0
]], 
        package:get("title") or package:name(),
        package:get("description") or package:get("title") or package:name(),
        package:name(),
        iconname,
        package:get("category") or "Utility"
    )
    
    local desktop_file = path.join(appdir, package:name() .. ".desktop")
    io.writefile(desktop_file, desktop_content)
    return desktop_file
end

-- create AppRun script
function _create_apprun(package, appdir)
    local main_executable = path.join("usr", "bin", package:name())
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
    local iconname = package:get("iconname") or package:name()
    
    if iconfile and os.isfile(iconfile) then
        -- 复制图标到usr/share/icons/hicolor目录
        local icon_dir = path.join(appdir, "usr/share/icons/hicolor/256x256/apps")
        os.mkdir(icon_dir)
        local icon_dst = path.join(icon_dir, iconname .. path.extension(iconfile))
        os.cp(iconfile, icon_dst)
        
        -- 同时复制到AppDir根目录供.desktop文件使用
        local root_icon = path.join(appdir, iconname .. path.extension(iconfile))
        os.cp(iconfile, root_icon)
        
        return icon_dst
    else
        print("Warning: No icon file specified for AppImage")
        return nil
    end
end

-- collect dependencies using linuxdeploy
function _collect_deps_with_linuxdeploy(package, appdir, linuxdeploy)
    print("Using linuxdeploy for dependency collection...")
    
    local main_executable = path.join(appdir, "usr/bin", package:name())
    local desktop_file = path.join(appdir, package:name() .. ".desktop")
    
    print("Checking files for linuxdeploy:")
    print("  Executable:", main_executable, "exists:", os.isfile(main_executable))
    print("  Desktop file:", desktop_file, "exists:", os.isfile(desktop_file))
    
    local args = {
        "--appdir", appdir
    }
    
    -- add executable
    if os.isfile(main_executable) then
        table.insert(args, "--executable")
        table.insert(args, main_executable)
    end
    
    -- add desktop file
    if os.isfile(desktop_file) then
        table.insert(args, "--desktop-file")
        table.insert(args, desktop_file)
    end
    
    print("Running linuxdeploy with args:", table.concat(args, " "))
    local ok, err = os.iorunv(linuxdeploy.program, args)
    if not ok then
        print("Warning: linuxdeploy failed:", err)
        return false
    end
    
    -- 检查linuxdeploy是否创建了lib目录
    local lib_dir = path.join(appdir, "usr/lib")
    if os.isdir(lib_dir) then
        local libs = os.files(path.join(lib_dir, "*.so*"))
        print("linuxdeploy collected", #libs, "libraries")
        for _, lib in ipairs(libs) do
            print("  -", lib)
        end
    else
        print("linuxdeploy did not create lib directory")
    end
    
    return true
end

-- manually collect common dependencies using ldd
function _collect_deps_manually(package, appdir)
    print("Collecting dependencies manually using ldd...")
    
    local main_executable = path.join(appdir, "usr/bin", package:name())
    if not os.isfile(main_executable) then
        print("Warning: Main executable not found, skipping dependency collection")
        return false
    end
    
    print("Analyzing executable:", main_executable)
    
    -- get dependencies using ldd
    local ldd_output = os.iorunv("ldd", {main_executable})
    if not ldd_output then
        print("Warning: ldd failed to analyze dependencies")
        return false
    end
    
    print("ldd output:")
    print(ldd_output)
    
    local lib_dir = path.join(appdir, "usr/lib")
    os.mkdir(lib_dir)
    
    local copied_count = 0
    
    -- parse ldd output and copy libraries
    for line in ldd_output:gmatch("[^\r\n]+") do
        local lib_path = line:match("=> ([^%s]+)")
        if lib_path and lib_path ~= "(0x" and os.isfile(lib_path) then
            -- skip system libraries that shouldn't be bundled
            local lib_name = path.filename(lib_path)
            local skip_libs = {
                "libc.so", "libm.so", "libdl.so", "libpthread.so",
                "librt.so", "libresolv.so", "libutil.so", "libnsl.so",
                "ld-linux-x86-64.so", "libgcc_s.so", "libstdc++.so"
            }
            
            local should_skip = false
            for _, skip_lib in ipairs(skip_libs) do
                if lib_name:find(skip_lib, 1, true) then
                    should_skip = true
                    break
                end
            end
            
            print("Checking library:", lib_path, "skip:", should_skip, "system:", lib_path:startswith("/lib/"))
            
            if not should_skip and not lib_path:startswith("/lib/") and not lib_path:startswith("/lib64/") then
                local dst_path = path.join(lib_dir, lib_name)
                if not os.isfile(dst_path) then
                    print("Copying library:", lib_path, "->", dst_path)
                    os.cp(lib_path, dst_path)
                    copied_count = copied_count + 1
                end
            end
        end
    end
    
    print("Total libraries copied:", copied_count)
    return true
end

-- pack appimage package
function _pack_appimage(appimagetool, package)
    -- create temporary AppDir
    local appdir_name = package:name() .. ".AppDir"
    local appdir = path.join(os.tmpdir(), appdir_name)
    os.tryrm(appdir)
    
    -- 创建标准的AppDir结构
    os.mkdir(appdir)
    os.mkdir(path.join(appdir, "usr"))
    os.mkdir(path.join(appdir, "usr/bin"))
    os.mkdir(path.join(appdir, "usr/lib"))
    os.mkdir(path.join(appdir, "usr/share"))
    os.mkdir(path.join(appdir, "usr/share/applications"))
    os.mkdir(path.join(appdir, "usr/share/icons"))
    os.mkdir(path.join(appdir, "usr/share/icons/hicolor"))
    os.mkdir(path.join(appdir, "usr/share/icons/hicolor/256x256"))
    os.mkdir(path.join(appdir, "usr/share/icons/hicolor/256x256/apps"))

    -- 设置prefixdir为/usr，这样文件会被安装到正确的usr目录
    local original_prefixdir = package:get("prefixdir")
    package:set("prefixdir", "/usr")
    
    -- 安装文件到AppDir
    local installcmds = {}
    _get_installcmds(package, appdir, installcmds, batchcmds.get_installcmds(package):cmds())
    for _, component in table.orderpairs(package:components()) do
        if component:get("default") ~= false then
            _get_installcmds(package, appdir, installcmds, batchcmds.get_installcmds(component):cmds())
        end
    end
    
    -- 执行安装命令
    for _, cmd in ipairs(installcmds) do
        print("Executing: " .. cmd)
        os.exec(cmd)
    end
    
    -- 恢复原始的prefixdir
    if original_prefixdir then
        package:set("prefixdir", original_prefixdir)
    end

    -- 复制源文件
    local srcfiles, dstfiles = package:sourcefiles()
    for idx, srcfile in ipairs(srcfiles) do
        local dstfile = _translate_filepath(package, dstfiles[idx], appdir)
        if dstfile then
            os.vcp(srcfile, dstfile)
        end
    end
    
    for _, component in table.orderpairs(package:components()) do
        if component:get("default") ~= false then
            local srcfiles, dstfiles = component:sourcefiles()
            for idx, srcfile in ipairs(srcfiles) do
                local dstfile = _translate_filepath(package, dstfiles[idx], appdir)
                if dstfile then
                    os.vcp(srcfile, dstfile)
                end
            end
        end
    end

    -- 创建AppImage所需的文件
    _create_desktop_file(package, appdir)
    _create_apprun(package, appdir)
    _copy_icon(package, appdir)

    -- 将.desktop文件复制到正确的位置
    local desktop_file = path.join(appdir, package:name() .. ".desktop")
    local desktop_usr_file = path.join(appdir, "usr/share/applications", package:name() .. ".desktop")
    os.cp(desktop_file, desktop_usr_file)

    -- 使用 linuxdeploy 收集依赖
    local linuxdeploy = _get_linuxdeploy()
    local deps_collected = false
    
    if linuxdeploy then
        print("Using linuxdeploy for dependency collection...")
        deps_collected = _collect_deps_with_linuxdeploy(package, appdir, linuxdeploy)
        if deps_collected then
            print("Dependencies collected successfully with linuxdeploy")
        end
    else
        print("linuxdeploy not available")
    end
    
    -- 如果 linuxdeploy 失败，使用手动方式作为后备
    if not deps_collected then
        print("Falling back to manual dependency collection...")
        _collect_deps_manually(package, appdir)
    end
    
    -- 检查最终的lib目录内容
    local lib_dir = path.join(appdir, "usr/lib")
    if os.isdir(lib_dir) then
        local all_files = os.files(path.join(lib_dir, "*"))
        print("Final lib directory contents (", #all_files, "files):")
        for _, file in ipairs(all_files) do
            print("  -", file)
        end
    else
        print("Warning: lib directory was not created!")
    end

    -- 使用 appimagetool 构建最终的 AppImage
    local appimage_file = package:outputfile() or _get_appimage_file(package)
    os.tryrm(appimage_file)
    
    -- 设置架构环境变量
    local arch = package:get("arch") or "x86_64"
    local envs = {ARCH = arch}
    
    print(string.format("Building AppImage: %s", appimage_file))
    os.vrunv(appimagetool.program, {appdir, appimage_file}, {envs = envs})

    -- 清理临时目录
    os.tryrm(appdir)
end

function main(package)
    if not is_host("linux") then
        print("AppImage packaging is only supported on Linux")
        return
    end

    cprint("packing %s", package:outputfile() or _get_appimage_file(package))

    -- get appimagetool
    local appimagetool = _get_appimagetool()

    -- pack appimage
    _pack_appimage(appimagetool, package)
    
    print("AppImage packaging completed!")
end