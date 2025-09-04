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

-- get the hdiutil tool
function _get_hdiutil()
    local hdiutil_path = "/usr/bin/hdiutil"
    if os.isfile(hdiutil_path) then
        hdiutil = {program = hdiutil_path}
    end
    assert(hdiutil, "hdiutil not found! DMG packaging requires macOS system tools.")
    return hdiutil
end

-- get the create-dmg tool (optional, for enhanced DMG creation)
function _get_create_dmg()
    local create_dmg = find_tool("create-dmg")
    if not create_dmg then
        print("Warning: create-dmg not found. Using basic hdiutil for DMG creation.")
        print("For better DMG appearance, install create-dmg: brew install create-dmg")
    end
    return create_dmg
end

-- get the codesign tool
function _get_codesign()
    local codesign = find_tool("codesign")
    if not codesign then
        print("Warning: codesign not found. Code signing will be skipped.")
    end
    return codesign
end

-- get dmg output file (修复文件名生成)
function _get_dmg_file(package)
    local filename = string.format("%s-%s.dmg", package:name(), package:version())
    local output_dir = path.directory(package:outputfile() or "build")
    local dmg_path = path.absolute(path.join(output_dir, filename))

    -- 确保只有一个.dmg扩展名
    if dmg_path:match("%.dmg%.dmg$") then
        dmg_path = dmg_path:gsub("%.dmg%.dmg$", ".dmg")
    end

    return dmg_path
end

-- translate the file path for app bundle structure
function _translate_filepath(package, filepath, appbundle_dir)
    local install_rootdir = package:install_rootdir()

    -- 如果路径在安装根目录下，转换为相对路径
    if filepath:startswith(install_rootdir) then
        local relative_path = path.relative(filepath, install_rootdir)

        -- 移除开头的 usr/ 如果存在
        if relative_path:startswith("usr/") then
            relative_path = relative_path:sub(5)
        end

        -- 映射到App bundle的Contents目录结构
        if relative_path:startswith("bin/") then
            return path.join(appbundle_dir, "Contents", "MacOS", path.filename(relative_path))
        elseif relative_path:startswith("lib/") then
            return path.join(appbundle_dir, "Contents", "Frameworks", path.filename(relative_path))
        elseif relative_path:startswith("share/") then
            return path.join(appbundle_dir, "Contents", "Resources", path.relative(relative_path, "share"))
        elseif relative_path:startswith("include/") then
            return path.join(appbundle_dir, "Contents", "Headers", path.relative(relative_path, "include"))
        else
            -- 根据文件扩展名智能映射
            local filename = path.filename(filepath)
            local ext = path.extension(filename):lower()

            -- 二进制可执行文件 -> Contents/MacOS
            if ext == "" or ext == ".exe" then
                return path.join(appbundle_dir, "Contents", "MacOS", filename)
            -- 库文件 -> Contents/Frameworks
            elseif ext == ".dylib" or ext == ".so" or ext == ".framework" then
                return path.join(appbundle_dir, "Contents", "Frameworks", filename)
            -- 图标文件 -> Contents/Resources
            elseif ext == ".png" or ext == ".svg" or ext == ".ico" or ext == ".icns" then
                return path.join(appbundle_dir, "Contents", "Resources", filename)
            -- 其他资源文件 -> Contents/Resources
            else
                local dirname = path.directory(relative_path)
                if dirname and dirname ~= "." then
                    return path.join(appbundle_dir, "Contents", "Resources", dirname, filename)
                else
                    return path.join(appbundle_dir, "Contents", "Resources", filename)
                end
            end
        end
    else
        -- 对于绝对路径，根据文件类型智能映射
        local filename = path.filename(filepath)
        local ext = path.extension(filename):lower()

        -- 跳过源代码文件
        if ext == ".cpp" or ext == ".c" or ext == ".h" or ext == ".hpp" or 
           ext == ".py" or ext == ".js" or ext == ".java" or ext == ".go" then
            return nil -- 源代码文件不应该被包含
        -- 二进制文件
        elseif ext == "" or ext == ".exe" then
            return path.join(appbundle_dir, "Contents", "MacOS", filename)
        -- 库文件
        elseif ext == ".dylib" or ext == ".so" or ext == ".framework" then
            return path.join(appbundle_dir, "Contents", "Frameworks", filename)
        -- 图标文件
        elseif ext == ".png" or ext == ".svg" or ext == ".ico" or ext == ".icns" then
            return path.join(appbundle_dir, "Contents", "Resources", filename)
        -- 其他文件
        else
            return path.join(appbundle_dir, "Contents", "Resources", filename)
        end
    end
end

-- get install command for app bundle
function _get_customcmd(package, appbundle_dir, installcmds, cmd)
    local opt = cmd.opt or {}
    local kind = cmd.kind
    if kind == "cp" then
        local srcfiles = os.files(cmd.srcpath)
        for _, srcfile in ipairs(srcfiles) do
            local dstfile = _translate_filepath(package, cmd.dstpath, appbundle_dir)
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
        local filepath = _translate_filepath(package, cmd.filepath, appbundle_dir)
        if filepath then
            table.insert(installcmds, string.format("rm -f \"%s\"", filepath))
        end
    elseif kind == "rmdir" then
        local dir = _translate_filepath(package, cmd.dir, appbundle_dir)
        if dir then
            table.insert(installcmds, string.format("rm -rf \"%s\"", dir))
        end
    elseif kind == "mv" then
        local srcpath = _translate_filepath(package, cmd.srcpath, appbundle_dir)
        local dstpath = _translate_filepath(package, cmd.dstpath, appbundle_dir)
        if srcpath and dstpath then
            table.insert(installcmds, string.format("mv \"%s\" \"%s\"", srcpath, dstpath))
        end
    elseif kind == "cd" then
        local dir = _translate_filepath(package, cmd.dir, appbundle_dir)
        if dir then
            table.insert(installcmds, string.format("cd \"%s\"", dir))
        end
    elseif kind == "mkdir" then
        local dir = _translate_filepath(package, cmd.dir, appbundle_dir)
        if dir then
            table.insert(installcmds, string.format("mkdir -p \"%s\"", dir))
        end
    elseif cmd.program then
        local argv = {}
        for _, arg in ipairs(cmd.argv) do
            if path.instance_of(arg) then
                arg = arg:clone():set(_translate_filepath(package, arg:rawstr(), appbundle_dir)):str()
            elseif path.is_absolute(arg) then
                arg = _translate_filepath(package, arg, appbundle_dir)
            end
            table.insert(argv, arg)
        end
        table.insert(installcmds, string.format("%s", os.args(table.join(cmd.program, argv))))
    end
end

-- get install commands for app bundle
function _get_installcmds(package, appbundle_dir, installcmds, cmds)
    for _, cmd in ipairs(cmds) do
        _get_customcmd(package, appbundle_dir, installcmds, cmd)
    end
end

-- create Info.plist file
function _create_info_plist(package, appbundle_dir)
    local bundle_id = string.format("app.%s", package:name())
    local executable_name = package:name()
    local icon_name = package:get("iconname") or package:name()

    -- 确保图标名有.icns扩展名
    if not icon_name:endswith(".icns") then
        icon_name = icon_name .. ".icns"
    end

    local plist_content = string.format([[<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>%s</string>
    <key>CFBundleExecutable</key>
    <string>%s</string>
    <key>CFBundleIconFile</key>
    <string>%s</string>
    <key>CFBundleIdentifier</key>
    <string>%s</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>%s</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>%s</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>CFBundleVersion</key>
    <string>%s</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
]], 
        package:get("title") or package:name(),
        executable_name,
        icon_name,
        bundle_id,
        package:name(),
        package:version(),
        package:version()
    )

    local plist_file = path.join(appbundle_dir, "Contents", "Info.plist")
    io.writefile(plist_file, plist_content)
    return plist_file
end

-- copy and convert icon file
function _copy_icon(package, appbundle_dir)
    local iconfile = package:get("iconfile")
    local iconname = package:get("iconname") or package:name()

    if not iconname:endswith(".icns") then
        iconname = iconname .. ".icns"
    end

    local resources_dir = path.join(appbundle_dir, "Contents", "Resources")
    os.mkdir(resources_dir)

    if iconfile and os.isfile(iconfile) then
        local icon_dst = path.join(resources_dir, iconname)

        -- 如果源文件不是.icns格式，尝试转换
        if not iconfile:endswith(".icns") then
            print("Converting icon to .icns format...")
            -- 使用sips工具转换图标（macOS内置工具）
            local sips = find_tool("sips")
            if sips then
                local temp_iconset = path.join(os.tmpdir(), package:name() .. ".iconset")
                os.mkdir(temp_iconset)

                -- 创建不同尺寸的图标
                local sizes = {16, 32, 64, 128, 256, 512, 1024}
                for _, size in ipairs(sizes) do
                    local output_name = string.format("icon_%dx%d.png", size, size)
                    local output_path = path.join(temp_iconset, output_name)
                    os.runv(sips.program, {"-z", tostring(size), tostring(size), iconfile, "--out", output_path})

                    -- 创建@2x版本（除了最大的）
                    if size <= 512 then
                        local output_name_2x = string.format("icon_%dx%d@2x.png", size, size)
                        local output_path_2x = path.join(temp_iconset, output_name_2x)
                        os.runv(sips.program, {"-z", tostring(size * 2), tostring(size * 2), iconfile, "--out", output_path_2x})
                    end
                end

                -- 使用iconutil创建.icns文件
                local iconutil = find_tool("iconutil")
                if iconutil then
                    os.runv(iconutil.program, {"-c", "icns", "-o", icon_dst, temp_iconset})
                    os.tryrm(temp_iconset)
                else
                    print("Warning: iconutil not found, copying original icon file")
                    os.cp(iconfile, icon_dst)
                end
            else
                print("Warning: sips not found, copying original icon file")
                os.cp(iconfile, icon_dst)
            end
        else
            -- 直接复制.icns文件
            os.cp(iconfile, icon_dst)
        end

        return icon_dst
    else
        print("Warning: No icon file specified for DMG")
        return nil
    end
end

-- collect dependencies using otool and install_name_tool (改进版)
function _collect_deps_manually(package, appbundle_dir)
    print("Collecting dependencies manually using otool...")

    local main_executable = path.join(appbundle_dir, "Contents", "MacOS", package:name())
    if not os.isfile(main_executable) then
        print("Warning: Main executable not found at:", main_executable)

        -- 尝试查找可执行文件
        local macos_dir = path.join(appbundle_dir, "Contents", "MacOS")
        if os.isdir(macos_dir) then
            local files = os.files(path.join(macos_dir, "*"))
            for _, file in ipairs(files) do
                if os.isfile(file) then
                    print("Found executable candidate:", file)
                    main_executable = file
                    break
                end
            end
        end

        if not os.isfile(main_executable) then
            print("Error: No executable found, skipping dependency collection")
            return false
        end
    end

    print("Analyzing executable:", main_executable)

    -- 检查文件是否为可执行文件
    local file_info = os.iorunv("file", {main_executable})
    print("File type:", file_info)

    -- 如果不是Mach-O可执行文件，跳过依赖收集
    if not file_info or not file_info:match("Mach%-O") then
        print("Warning: File is not a Mach-O executable, skipping dependency collection")
        return true
    end

    -- get dependencies using otool
    local otool = find_tool("otool")
    if not otool then
        print("Warning: otool not found, cannot collect dependencies")
        return false
    end

    local otool_output, otool_errors = os.iorunv(otool.program, {"-L", main_executable})
    if not otool_output then
        print("Warning: otool failed to analyze dependencies")
        if otool_errors then
            print("otool error output:", otool_errors)
        end
        return false
    end

    print("otool output:")
    print(otool_output)

    local frameworks_dir = path.join(appbundle_dir, "Contents", "Frameworks")
    os.mkdir(frameworks_dir)

    local copied_count = 0
    local install_name_tool = find_tool("install_name_tool")

    -- parse otool output and copy libraries
    for line in otool_output:gmatch("[^\r\n]+") do
        local lib_path = line:match("^%s*([^%s]+%.dylib)")
        if lib_path and not lib_path:startswith("/usr/lib/") and not lib_path:startswith("/System/") and os.isfile(lib_path) then
            local lib_name = path.filename(lib_path)
            local dst_path = path.join(frameworks_dir, lib_name)

            if not os.isfile(dst_path) then
                print("Copying library:", lib_path, "->", dst_path)
                local copy_ok = os.runv("cp", {lib_path, dst_path})
                if copy_ok then
                    copied_count = copied_count + 1

                    -- 修改库的install name
                    if install_name_tool then
                        local new_install_name = "@executable_path/../Frameworks/" .. lib_name
                        os.runv(install_name_tool.program, {"-id", new_install_name, dst_path})
                    end
                else
                    print("Warning: Failed to copy library:", lib_path)
                end
            end
        end
    end

    -- 修改主可执行文件中的库路径引用
    if install_name_tool and copied_count > 0 then
        print("Updating library references in main executable...")
        for line in otool_output:gmatch("[^\r\n]+") do
            local lib_path = line:match("^%s*([^%s]+%.dylib)")
            if lib_path and not lib_path:startswith("/usr/lib/") and not lib_path:startswith("/System/") then
                local lib_name = path.filename(lib_path)
                local new_path = "@executable_path/../Frameworks/" .. lib_name
                local dst_lib = path.join(frameworks_dir, lib_name)
                if os.isfile(dst_lib) then
                    os.runv(install_name_tool.program, {"-change", lib_path, new_path, main_executable})
                end
            end
        end
    end

    print("Total libraries copied:", copied_count)
    return true
end

-- create DMG background and layout (simplified)
function _create_dmg_layout(package, dmg_staging_dir)
    -- 创建应用程序链接
    local applications_link = path.join(dmg_staging_dir, "Applications")
    if not os.islink(applications_link) then
        os.runv("ln", {"-s", "/Applications", applications_link})
    end
end

-- sign the app bundle
function _sign_app_bundle(package, appbundle_dir, codesign)
    -- 跳过代码签名，因为不是必需的
    print("Skipping code signing (not required)")
    return true
end

-- get dmg configuration (simplified)
function _get_dmg_config(package)
    local config = {
        title = package:get("title") or package:name(),
        format = "UDZO" -- compressed read-only format
    }
    return config
end

-- create basic DMG using hdiutil (完全修复版)
function _create_basic_dmg(hdiutil, package, dmg_staging_dir, dmg_file, config, appbundle_name)
    print("Starting basic DMG creation...")

    -- 检查可用磁盘空间
    local df_output = os.iorunv("df", {"-h", os.tmpdir()})
    print("Available disk space in temp directory:")
    print(df_output)

    -- 计算需要的磁盘大小
    local du_output = os.iorunv("du", {"-sm", dmg_staging_dir})
    print("du output:", du_output)

    local required_size = 100 -- 默认大小
    if du_output then
        local size_match = du_output:match("^(%d+)")
        if size_match then
            required_size = math.ceil(tonumber(size_match) * 1.5) -- 增加50%缓冲
        end
    end

    print("Required DMG size:", required_size .. "MB")

    -- 创建唯一的临时文件名，避免冲突
    local temp_name = string.format("%s_%s_temp.dmg", package:name(), os.date("%Y%m%d_%H%M%S"))
    local temp_dmg = path.join(os.tmpdir(), temp_name)
    os.tryrm(temp_dmg) -- 清理可能存在的旧文件

    print("Creating temporary DMG:", temp_dmg)

    -- 创建空白DMG，添加更多调试信息
    local create_args = {
        "create", 
        "-size", required_size .. "m", 
        "-fs", "HFS+", 
        "-volname", config.title, 
        temp_dmg
    }

    print("hdiutil create command:", hdiutil.program, table.concat(create_args, " "))

    local ok, errors = os.iorunv(hdiutil.program, create_args)
    if not ok then
        print("Error: hdiutil create failed")
        if errors then
            print("Error output:", errors)
        end

        -- 尝试备用方法：使用更小的初始大小
        print("Trying with smaller initial size...")
        create_args[3] = "50m"
        ok, errors = os.iorunv(hdiutil.program, create_args)

        if not ok then
            print("Error: Both attempts to create DMG failed")
            if errors then
                print("Final error output:", errors)
            end
            return false
        end
    end

    print("Temporary DMG created successfully")

    -- 验证临时文件存在
    if not os.isfile(temp_dmg) then
        print("Error: Temporary DMG file was not created:", temp_dmg)
        return false
    end

    -- 挂载DMG
    print("Mounting temporary DMG...")
    local mount_args = {"attach", "-readwrite", "-noverify", "-noautoopen", temp_dmg}
    print("hdiutil attach command:", hdiutil.program, table.concat(mount_args, " "))

    local mount_output, mount_errors = os.iorunv(hdiutil.program, mount_args)

    if not mount_output then
        print("Error: Failed to mount temporary DMG")
        if mount_errors then
            print("Mount error output:", mount_errors)
        end
        os.tryrm(temp_dmg)
        return false
    end

    print("Mount output:", mount_output)
    local mount_point = mount_output:match("/Volumes/[^\r\n]+")

    if not mount_point then
        print("Error: Could not determine mount point from output")
        print("Full mount output was:", mount_output)
        os.tryrm(temp_dmg)
        return false
    end

    print("DMG mounted at:", mount_point)

    -- 验证挂载点存在
    if not os.isdir(mount_point) then
        print("Error: Mount point directory does not exist:", mount_point)
        os.runv(hdiutil.program, {"detach", temp_dmg})
        os.tryrm(temp_dmg)
        return false
    end

    -- 复制内容到挂载的DMG
    print("Copying app bundle to DMG...")
    local app_source = path.join(dmg_staging_dir, appbundle_name)
    local app_dest = path.join(mount_point, appbundle_name)

    print("Copy command: cp -R", app_source, app_dest)
    local copy_ok, copy_errors = os.iorunv("cp", {"-R", app_source, app_dest})

    if not copy_ok then
        print("Error: Failed to copy app bundle to DMG")
        if copy_errors then
            print("Copy error output:", copy_errors)
        end
        os.runv(hdiutil.program, {"detach", mount_point})
        os.tryrm(temp_dmg)
        return false
    end

    print("App bundle copied successfully")

    -- 复制Applications链接
    local apps_link = path.join(dmg_staging_dir, "Applications")
    if os.islink(apps_link) then
        print("Copying Applications link...")
        os.runv("cp", {"-R", apps_link, mount_point})
    end

    -- 同步文件系统
    print("Syncing filesystem...")
    os.runv("sync")
    os.sleep(2000)

    -- 卸载DMG
    print("Detaching DMG...")
    local detach_ok, detach_errors = os.iorunv(hdiutil.program, {"detach", mount_point})
    if not detach_ok then
        print("Warning: Failed to detach DMG properly")
        if detach_errors then
            print("Detach error output:", detach_errors)
        end
        -- 强制卸载
        os.runv(hdiutil.program, {"detach", mount_point, "-force"})
    end

    -- 转换为只读压缩DMG（关键修复：确保正确的文件名）
    print("Converting to compressed DMG...")

    -- 确保最终文件名正确
    if dmg_file:match("%.dmg%.tmp%.dmg$") then
        dmg_file = dmg_file:gsub("%.dmg%.tmp%.dmg$", ".dmg")
        print("Fixed final DMG filename:", dmg_file)
    end

    local convert_args = {
        "convert", 
        temp_dmg, 
        "-format", config.format, 
        "-imagekey", "zlib-level=9", 
        "-o", dmg_file
    }

    print("Convert command:", hdiutil.program, table.concat(convert_args, " "))
    local convert_ok, convert_errors = os.iorunv(hdiutil.program, convert_args)

    if not convert_ok then
        print("Error: Failed to convert DMG to final format")
        if convert_errors then
            print("Convert error output:", convert_errors)
        end
        os.tryrm(temp_dmg)
        return false
    end

    -- 清理临时文件
    os.tryrm(temp_dmg)

    print("DMG conversion completed successfully")
    return true
end

-- create enhanced DMG (修复版)
function _create_enhanced_dmg(hdiutil, create_dmg, package, dmg_staging_dir, dmg_file)
    local config = _get_dmg_config(package)
    local appbundle_name = (package:get("title") or package:name()) .. ".app"

    -- 确保输出文件名正确
    if dmg_file:match("%.dmg%.tmp%.dmg$") then
        dmg_file = dmg_file:gsub("%.dmg%.tmp%.dmg$", ".dmg")
        print("Corrected DMG filename:", dmg_file)
    end

    if create_dmg then
        print("Creating DMG with create-dmg...")
        local args = {
            "--volname", config.title,
            "--window-pos", "200", "120",
            "--window-size", "600", "400",
            "--icon-size", "100",
            "--icon", appbundle_name, "175", "220",
            "--hide-extension", appbundle_name,
            "--app-drop-link", "425", "220",
            dmg_file,
            dmg_staging_dir
        }

        local ok = os.runv(create_dmg.program, args)
        return ok
    else
        print("Creating basic DMG with hdiutil...")
        return _create_basic_dmg(hdiutil, package, dmg_staging_dir, dmg_file, config, appbundle_name)
    end
end

-- 主打包函数（修复版）
function _pack_dmg_main(hdiutil, create_dmg, codesign, package)
    local app_name = package:get("title") or package:name()
    local appbundle_name = app_name .. ".app"

    -- 创建临时工作目录
    local dmg_staging_dir = path.join(os.tmpdir(), package:name() .. "_dmg_staging")
    local appbundle_dir = path.join(dmg_staging_dir, appbundle_name)

    os.tryrm(dmg_staging_dir)
    os.mkdir(dmg_staging_dir)
    print("Created staging directory at:", dmg_staging_dir)

    -- 创建App bundle目录结构
    os.mkdir(appbundle_dir)
    os.mkdir(path.join(appbundle_dir, "Contents"))
    os.mkdir(path.join(appbundle_dir, "Contents", "MacOS"))
    os.mkdir(path.join(appbundle_dir, "Contents", "Resources"))
    os.mkdir(path.join(appbundle_dir, "Contents", "Frameworks"))

    print("Created app bundle structure at:", appbundle_dir)

    -- 安装文件到App bundle
    local installcmds = {}
    _get_installcmds(package, appbundle_dir, installcmds, batchcmds.get_installcmds(package):cmds())
    for _, component in table.orderpairs(package:components()) do
        if component:get("default") ~= false then
            _get_installcmds(package, appbundle_dir, installcmds, batchcmds.get_installcmds(component):cmds())
        end
    end

    -- 执行安装命令
    print("Executing installation commands...")
    for _, cmd in ipairs(installcmds) do
        print("Executing: " .. cmd)
        local ok = os.exec(cmd)
        if not ok then
            print("Warning: Command failed:", cmd)
        end
    end

    -- 复制源文件
    print("Copying source files...")
    local srcfiles, dstfiles = package:sourcefiles()
    for idx, srcfile in ipairs(srcfiles) do
        local dstfile = _translate_filepath(package, dstfiles[idx], appbundle_dir)
        if dstfile then
            print("Copying:", srcfile, "->", dstfile)
            os.vcp(srcfile, dstfile)
        end
    end

    -- 复制组件源文件
    for _, component in table.orderpairs(package:components()) do
        if component:get("default") ~= false then
            local srcfiles, dstfiles = component:sourcefiles()
            for idx, srcfile in ipairs(srcfiles) do
                local dstfile = _translate_filepath(package, dstfiles[idx], appbundle_dir)
                if dstfile then
                    print("Copying component file:", srcfile, "->", dstfile)
                    os.vcp(srcfile, dstfile)
                end
            end
        end
    end

    -- 创建必要的App bundle文件
    _create_info_plist(package, appbundle_dir)
    _copy_icon(package, appbundle_dir)

    -- 确保主可执行文件有执行权限
    local main_executable = path.join(appbundle_dir, "Contents", "MacOS", package:name())
    if os.isfile(main_executable) then
        os.runv("chmod", {"+x", main_executable})
        print("Main executable:", main_executable)
    else
        print("Warning: Main executable not found at expected location")
    end

    -- 收集依赖库
    _collect_deps_manually(package, appbundle_dir)

    -- 代码签名（如果配置了）
    if codesign then
        _sign_app_bundle(package, appbundle_dir, codesign)
    end

    -- 创建DMG布局文件
    _create_dmg_layout(package, dmg_staging_dir)

    -- 获取正确的DMG文件路径
    local dmg_file = package:outputfile() or _get_dmg_file(package)

    -- 关键修复：清理文件名中的重复扩展名
    if dmg_file:match("%.dmg%.tmp%.dmg$") then
        dmg_file = dmg_file:gsub("%.dmg%.tmp%.dmg$", ".dmg")
        print("Corrected final DMG filename:", dmg_file)
    elseif dmg_file:match("%.tmp%.dmg$") then
        dmg_file = dmg_file:gsub("%.tmp%.dmg$", ".dmg")
        print("Corrected final DMG filename:", dmg_file)
    end

    os.tryrm(dmg_file)
    
    print("Creating final DMG file:", dmg_file)
    local success = _create_enhanced_dmg(hdiutil, create_dmg, package, dmg_staging_dir, dmg_file)
    
    if success then
        -- 验证DMG
        _verify_dmg(hdiutil, dmg_file)
        
        -- 显示DMG信息
        local dmg_info = os.iorunv(hdiutil.program, {"imageinfo", dmg_file})
        if dmg_info then
            local size = dmg_info:match("Total Bytes: (%d+)")
            if size then
                local size_mb = math.ceil(tonumber(size) / 1024 / 1024)
                print(string.format("DMG created successfully: %s (%d MB)", dmg_file, size_mb))
            else
                print("DMG created successfully:", dmg_file)
            end
        end
    else
        print("Error: Failed to create DMG")
    end
    
    -- 清理临时目录
    os.tryrm(dmg_staging_dir)
    
    return success
end

-- verify dmg integrity
function _verify_dmg(hdiutil, dmg_file)
    print("Verifying DMG integrity...")
    local ok = os.runv(hdiutil.program, {"verify", dmg_file})
    if ok then
        print("DMG verification passed")
        return true
    else
        print("Warning: DMG verification failed")
        return false
    end
end

-- main function 
function main(package)
    -- only for macOS
    if not is_host("macosx") then
        print("DMG packaging is only supported on macOS")
        return
    end

    -- 获取正确的DMG文件路径
    local dmg_file = package:outputfile() or _get_dmg_file(package)

    -- 关键修复：清理任何错误的文件名模式
    local original_dmg_file = dmg_file
    if dmg_file:match("%.dmg%.tmp%.dmg$") then
        dmg_file = dmg_file:gsub("%.dmg%.tmp%.dmg$", ".dmg")
    elseif dmg_file:match("%.tmp%.dmg$") then
        dmg_file = dmg_file:gsub("%.tmp%.dmg$", ".dmg")
    elseif dmg_file:match("%.dmg%.dmg$") then
        dmg_file = dmg_file:gsub("%.dmg%.dmg$", ".dmg")
    end

    if dmg_file ~= original_dmg_file then
        print("Corrected DMG filename from:", original_dmg_file)
        print("                        to:", dmg_file)
    end

    cprint("packing %s", dmg_file)

    -- get required tools
    local hdiutil = _get_hdiutil()
    local create_dmg = _get_create_dmg()
    local codesign = _get_codesign()

    -- pack dmg package
    local success = _pack_dmg_main(hdiutil, create_dmg, codesign, package)

    if success then
        print("DMG packaging completed successfully!")
        print("Final output file:", dmg_file)

        -- 验证文件确实存在且命名正确
        if os.isfile(dmg_file) then
            local file_info = os.iorunv("ls", {"-lh", dmg_file})
            print("File details:", file_info)
        else
            print("Warning: Expected DMG file not found at:", dmg_file)
        end
    else
        print("DMG packaging failed!")
        os.exit(1)
    end
end