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

-- get dmg output file
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

-- find existing .app bundle in the build directory
function _find_app_bundle(package)
    -- 获取当前的构建信息
    local plat = os.host()  -- 获取当前平台 (macosx, linux, windows等)
    local arch = os.arch()  -- 获取当前架构 (arm64, x86_64等)
    local mode = is_mode("debug") and "debug" or "release"  -- 获取构建模式
    
    print("Current build configuration:")
    print("  Platform:", plat)
    print("  Architecture:", arch) 
    print("  Mode:", mode)
    
    local app_name = package:get("title") or package:name()
    local appbundle_name = app_name .. ".app"
    
    print("Looking for .app bundle:", appbundle_name)
    
    -- 构建平台特定的路径模式
    local platform_paths = {
        -- 标准的xmake平台目录结构
        path.join("build", plat, arch, mode),
        path.join("build", plat, arch, "release"),
        path.join("build", plat, arch, "debug"),
        path.join("build", plat, "release"),
        path.join("build", plat, "debug"),
        path.join("build", plat, arch),
        path.join("build", plat),
        
        -- 一些变体
        path.join("build", mode),
        path.join("build", "release"),
        path.join("build", "debug"),
        
        -- xpack输出目录
        path.join("build", "xpack"),
        
        -- 根build目录
        "build",
        
        -- 当前目录
        "."
    }
    
    -- 可能的.app位置
    local possible_locations = {}
    
    -- 为每个平台路径生成可能的.app位置
    for _, base_path in ipairs(platform_paths) do
        table.insert(possible_locations, path.join(base_path, appbundle_name))
        -- 也检查bin子目录
        table.insert(possible_locations, path.join(base_path, "bin", appbundle_name))
    end
    
    print("Checking possible locations:")
    for i, location in ipairs(possible_locations) do
        local abs_location = path.absolute(location)
        print(string.format("  [%d] Checking: %s", i, abs_location))
        
        if os.isdir(abs_location) then
            -- 验证这确实是一个.app bundle
            local info_plist = path.join(abs_location, "Contents", "Info.plist")
            local macos_dir = path.join(abs_location, "Contents", "MacOS")
            
            print("      Directory exists!")
            print("      Info.plist exists:", os.isfile(info_plist))
            print("      MacOS dir exists:", os.isdir(macos_dir))
            
            if os.isfile(info_plist) and os.isdir(macos_dir) then
                print("✓ Found valid .app bundle:", abs_location)
                return abs_location
            else
                print("      Invalid .app structure")
            end
        end
    end
    
    print("1. Is your .app file actually built?")
    print("2. Run 'find . -name \"*.app\" -type d' to list all .app directories")
    print("3. Check if the .app has the correct internal structure (Contents/Info.plist, Contents/MacOS/)")
    
    return nil
end

-- create DMG background and layout (simplified)
function _create_dmg_layout(package, dmg_staging_dir)
    -- 创建应用程序链接
    local applications_link = path.join(dmg_staging_dir, "Applications")
    if not os.islink(applications_link) then
        os.runv("ln", {"-s", "/Applications", applications_link})
    end
end

-- get dmg configuration
function _get_dmg_config(package)
    local config = {
        title = package:get("title") or package:name(),
        format = "UDZO" -- compressed read-only format
    }
    return config
end

-- create basic DMG using hdiutil
function _create_basic_dmg(hdiutil, package, dmg_staging_dir, dmg_file, config, appbundle_name)
    print("Starting basic DMG creation...")
    
    -- 计算需要的磁盘大小
    local du_output = os.iorunv("du", {"-sm", dmg_staging_dir})
    print("Staging directory size:", du_output)
    
    local required_size = 100 -- 默认大小
    if du_output then
        local size_match = du_output:match("^(%d+)")
        if size_match then
            required_size = math.ceil(tonumber(size_match) * 1.5) -- 增加50%缓冲
        end
    end
    
    print("Required DMG size:", required_size .. "MB")
    
    -- 创建唯一的临时文件名
    local temp_name = string.format("%s_%s_temp.dmg", package:name(), os.date("%Y%m%d_%H%M%S"))
    local temp_dmg = path.join(os.tmpdir(), temp_name)
    os.tryrm(temp_dmg)
    
    print("Creating temporary DMG:", temp_dmg)
    
    -- 创建空白DMG
    local create_args = {
        "create", 
        "-size", required_size .. "m", 
        "-fs", "HFS+", 
        "-volname", config.title, 
        temp_dmg
    }
    
    local ok, errors = os.iorunv(hdiutil.program, create_args)
    if not ok then
        print("Error: hdiutil create failed")
        if errors then
            print("Error output:", errors)
        end
        return false
    end
    
    print("Temporary DMG created successfully")
    
    -- 挂载DMG
    print("Mounting temporary DMG...")
    local mount_args = {"attach", "-readwrite", "-noverify", "-noautoopen", temp_dmg}
    local mount_output, mount_errors = os.iorunv(hdiutil.program, mount_args)
    
    if not mount_output then
        print("Error: Failed to mount temporary DMG")
        if mount_errors then
            print("Mount error output:", mount_errors)
        end
        os.tryrm(temp_dmg)
        return false
    end
    
    local mount_point = mount_output:match("/Volumes/[^\r\n]+")
    if not mount_point then
        print("Error: Could not determine mount point")
        os.tryrm(temp_dmg)
        return false
    end
    
    print("DMG mounted at:", mount_point)
    
    -- 复制内容到挂载的DMG
    print("Copying contents to DMG...")
    local copy_ok = os.runv("cp", {"-R", path.join(dmg_staging_dir, "*"), mount_point})
    
    if not copy_ok then
        -- 如果通配符复制失败，尝试逐个复制
        local items = os.dirs(path.join(dmg_staging_dir, "*"))
        table.join2(items, os.files(path.join(dmg_staging_dir, "*")))
        
        for _, item in ipairs(items) do
            local item_name = path.filename(item)
            local dest = path.join(mount_point, item_name)
            print("Copying:", item, "->", dest)
            os.runv("cp", {"-R", item, dest})
        end
    end
    
    -- 同步文件系统
    print("Syncing filesystem...")
    os.runv("sync")
    os.sleep(1000)
    
    -- 卸载DMG
    print("Detaching DMG...")
    local detach_ok = os.runv(hdiutil.program, {"detach", mount_point})
    if not detach_ok then
        print("Warning: Failed to detach DMG, trying force detach...")
        os.runv(hdiutil.program, {"detach", mount_point, "-force"})
    end
    
    -- 转换为只读压缩DMG
    print("Converting to compressed DMG...")
    local convert_args = {
        "convert", 
        temp_dmg, 
        "-format", config.format, 
        "-imagekey", "zlib-level=9", 
        "-o", dmg_file
    }
    
    local convert_ok, convert_errors = os.iorunv(hdiutil.program, convert_args)
    if not convert_ok then
        print("Error: Failed to convert DMG")
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

-- create enhanced DMG using create-dmg
function _create_enhanced_dmg(hdiutil, create_dmg, package, dmg_staging_dir, dmg_file)
    local config = _get_dmg_config(package)
    local appbundle_name = (package:get("title") or package:name()) .. ".app"
    
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

-- main packaging function (simplified version)
function _pack_dmg_main(hdiutil, create_dmg, package)
    -- 查找现有的.app bundle
    local existing_app = _find_app_bundle(package)
    if not existing_app then
        print("Error: Could not find existing .app bundle!")
        print("Please ensure your .app bundle is built and located in the output directory.")
        return false
    end
    
    local appbundle_name = path.filename(existing_app)
    print("Using existing .app bundle:", existing_app)
    print("App bundle name:", appbundle_name)
    
    -- 创建临时工作目录
    local dmg_staging_dir = path.join(os.tmpdir(), package:name() .. "_dmg_staging")
    os.runv("rm", {"-rf", dmg_staging_dir})
    -- 创建新的临时目录
    local tmpok, err_message = os.mkdir(dmg_staging_dir)
    if not tmpok then
        print("Error: Failed to create temporary staging directory.")
        print("Details:", err_message)
        -- 如果创建失败，立即返回 false，停止后续操作
        return false
    end

    print("mkdir_tmp_dir_ok:", mkdir_tmp_dir_ok)

    -- 复制.app bundle到staging目录
    print("Copying .app bundle to staging directory...")
    local staging_app = path.join(dmg_staging_dir, appbundle_name)
    local copy_ok = os.runv("cp", {"-R", existing_app, staging_app})

    if not copy_ok then
        print("Error: Failed to copy .app bundle to staging directory")
        os.tryrm(dmg_staging_dir)
        return false
    end
    
    print("App bundle copied to:", staging_app)
    
    -- 创建DMG布局（Applications链接）
    _create_dmg_layout(package, dmg_staging_dir)
    
    -- 获取正确的DMG文件路径
    local dmg_file = package:outputfile() or _get_dmg_file(package)
    
    -- 清理文件名中的重复扩展名
    local original_dmg_file = dmg_file
    if dmg_file:match("%.dmg%.dmg$") then
        dmg_file = dmg_file:gsub("%.dmg%.dmg$", ".dmg")
    elseif dmg_file:match("%.tmp%.dmg$") then
        dmg_file = dmg_file:gsub("%.tmp%.dmg$", ".dmg")
    end
    
    if dmg_file ~= original_dmg_file then
        print("Corrected DMG filename:", dmg_file)
    end
    
    -- 删除已存在的DMG文件
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
        else
            print("DMG created successfully:", dmg_file)
        end
    else
        print("Error: Failed to create DMG")
    end
    
    -- 清理临时目录
    os.tryrm(dmg_staging_dir)
    
    return success
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
    
    -- 清理任何错误的文件名模式
    local original_dmg_file = dmg_file
    if dmg_file:match("%.dmg%.dmg$") then
        dmg_file = dmg_file:gsub("%.dmg%.dmg$", ".dmg")
    elseif dmg_file:match("%.tmp%.dmg$") then
        dmg_file = dmg_file:gsub("%.tmp%.dmg$", ".dmg")
    end
    
    if dmg_file ~= original_dmg_file then
        print("Corrected DMG filename from:", original_dmg_file)
        print("                        to:", dmg_file)
    end

    cprint("packing %s", dmg_file)

    -- get required tools
    local hdiutil = _get_hdiutil()
    local create_dmg = _get_create_dmg()

    -- pack dmg package
    local success = _pack_dmg_main(hdiutil, create_dmg, package)
    
    if success then
        print("DMG packaging completed successfully!")
        print("Final output file:", dmg_file)
        
        -- 验证文件确实存在
        if os.isfile(dmg_file) then
            local file_info = os.iorunv("ls", {"-lh", dmg_file})
            if file_info then
                print("File details:", file_info)
            end
        else
            print("Warning: Expected DMG file not found at:", dmg_file)
        end
    else
        print("DMG packaging failed!")
        os.exit(1)
    end
end