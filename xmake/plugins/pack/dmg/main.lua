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

-- get the create-dmg tool
function _get_create_dmg()
    local create_dmg = find_tool("create-dmg")
    if not create_dmg then
        print("Error: create-dmg not found. Please install it first:")
        print("brew install create-dmg")
        return nil
    end
    return create_dmg
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
                return abs_location, appbundle_name
            else
                print("      Invalid .app structure")
            end
        end
    end
    
    print("1. Is your .app file actually built?")
    print("2. Run 'find . -name \"*.app\" -type d' to list all .app directories")
    print("3. Check if the .app has the correct internal structure (Contents/Info.plist, Contents/MacOS/)")
    
    return nil, nil
end


-- find background image
function _find_background_image(package)
    local bg_paths = {
        "bg.svg",
        "background.svg",
        "dmg_background.svg",
        "assets/bg.svg",
        "assets/background.svg",
        "resources/bg.svg",
        "resources/background.svg"
    }
    
    -- also check if user specified a custom background
    local custom_bg = package:get("dmg_background")
    if custom_bg then
        table.insert(bg_paths, 1, custom_bg)
    end
    
    for _, bg_path in ipairs(bg_paths) do
        if os.isfile(bg_path) then
            ab_bg_path = path.absolute(bg_path)
            print("Found background image at:", ab_bg_path)
            return ab_bg_path
        end
    end
    
    print("Warning: No background image found. Searched paths:")
    for _, p in ipairs(bg_paths) do
        print("  -", p)
    end
    print("You can specify custom background with package:set('dmg_background', 'path/to/bg.svg')")
    
    return nil
end

-- get dmg output file path
function _get_dmg_file(package)
    local filename = string.format("%s-%s.dmg", package:name(), package:version())
    local output_dir = path.directory(package:outputfile() or "build")
    local dmg_path = path.absolute(path.join(output_dir, filename))
    
    -- ensure single .dmg extension
    dmg_path = dmg_path:gsub("%.dmg+$", ".dmg")
    
    return dmg_path
end

-- create dmg staging directory
function _create_staging_dir(package, app_source, appbundle_name, bg_image)
    local staging_dir = path.join(os.tmpdir(), package:name() .. "_dmg_staging")
    -- clean and create staging directory
    if os.isdir(staging_dir) then
        os.vrunv("rm", {"-rf", staging_dir})
    end
    os.mkdir(staging_dir)
    print("Created staging directory:", staging_dir)
    
    -- copy .app bundle to staging
    local app_dest = path.join(staging_dir, appbundle_name)
    print("Copying app bundle...")
    print("  From:", app_source)
    print("  To:", app_dest)
    
    os.vcp(app_source, app_dest)
    if not os.isdir(app_dest) then
        print("Error: Failed to copy app bundle to staging directory")
        return nil
    end
    
    -- copy background image if exists
    if bg_image then
        local bg_dest = path.join(staging_dir, path.filename(bg_image))
        print("Copying background image...")
        print("  From:", bg_image)
        print("  To:", bg_dest)
        
        os.vcp(bg_image, bg_dest)
        if not os.isfile(bg_dest) then
            print("Warning: Failed to copy background image")
        end
    end
    
    -- create Applications symlink for easy installation
    -- local apps_link = path.join(staging_dir, "Applications")
    -- if not os.islink(apps_link) then
    --     os.runv("ln", {"-s", "/Applications", apps_link})
    --     print("Created Applications symlink")
    -- end
    
    return staging_dir
end

-- create dmg using create-dmg
function _create_dmg_with_create_dmg(create_dmg, package, staging_dir, dmg_file, appbundle_name, bg_image)
    print("Creating DMG with create-dmg...")
    
    local config = {
        title = (package:get("title") or package:name() .. " Installer"),
        window_pos = package:get("dmg_window_pos") or "400,200",
        window_size = package:get("dmg_window_size") or "660,400", 
        icon_size = package:get("dmg_icon_size") or 100,
        app_position = package:get("dmg_icon_position") or "160,185",
        apps_link_position = package:get("dmg_applications_pos") or "500,185"
    }
    
    -- parse window position
    local window_pos_x, window_pos_y = config.window_pos:match("(%d+),(%d+)")
    window_pos_x = window_pos_x or "400"
    window_pos_y = window_pos_y or "200"
    
    -- parse window size
    local window_w, window_h = config.window_size:match("(%d+),(%d+)")
    if not window_w then
        window_w, window_h = config.window_size:match("(%d+)x(%d+)")
    end
    window_w = window_w or "660"
    window_h = window_h or "400"
    
    -- parse app position
    local app_x, app_y = config.app_position:match("(%d+),(%d+)")
    app_x = app_x or "160"
    app_y = app_y or "185"
    
    -- parse Applications link position
    local apps_x, apps_y = config.apps_link_position:match("(%d+),(%d+)")
    apps_x = apps_x or "500"
    apps_y = apps_y or "185"
    
    -- build create-dmg arguments following the reference format
    local args = {
        "--volname", config.title,
        "--window-pos", window_pos_x, window_pos_y,
        "--window-size", window_w, window_h,
        "--icon-size", tostring(config.icon_size),
        "--icon", appbundle_name, app_x, app_y,
        "--hide-extension", appbundle_name,
        "--app-drop-link", apps_x, apps_y
    }
    if bg_image then
        local bg_name = path.filename(bg_image)
        -- insert background after volname
        table.insert(args, 3, "--background")
        table.insert(args, 4, bg_name)
    end
    print ("DMG configuration:", args)

    -- add output file and source directory at the end
    table.insert(args, dmg_file)
    table.insert(args, staging_dir)
    
    print("create-dmg command:")
    print("  " .. create_dmg.program .. " \\\n    " .. table.concat(args, " \\\n    "))
    
    -- ensure output directory exists
    os.vrunv("mkdir", {"-p", path.directory(dmg_file)})
    
    -- remove existing dmg file if exists
    os.vrunv("rm", {"-f", dmg_file})
    
    -- run create-dmg
    local ok, errors = os.iorunv(create_dmg.program, args)
    
    if ok then
        print("DMG created successfully!")
        return true
    else
        print("Error: create-dmg failed")
        if errors then
            print("Error output:", errors)
        end
        return false
    end
end


-- verify dmg file
function _verify_dmg(dmg_file)
    if not os.isfile(dmg_file) then
        print("Error: DMG file was not created:", dmg_file)
        return false
    end
    
    -- get file size
    local file_info = os.iorunv("ls", {"-lh", dmg_file})
    if file_info then
        print("DMG file details:", file_info:trim())
    end
    
    -- try to verify with hdiutil if available
    local hdiutil = find_tool("hdiutil")
    if hdiutil then
        print("Verifying DMG integrity...")
        local verify_ok = os.runv(hdiutil.program, {"verify", dmg_file})
        if verify_ok then
            print("DMG verification passed")
        else
            print("Warning: DMG verification failed")
        end
    end
    
    return true
end

-- main packing function
function _pack_dmg(package)
    
    -- find required tools
    local create_dmg = _get_create_dmg()
    if not create_dmg then
        return false
    end
    
    -- find existing .app bundle
    local app_source, appbundle_name = _find_app_bundle(package)
    if not app_source then
        return false
    end
    
    -- find background image (optional)
    local bg_image = _find_background_image(package)
    
    -- get output dmg path
    local dmg_file = package:outputfile() or _get_dmg_file(package)
    dmg_file = dmg_file:gsub("%.dmg+$", ".dmg")  -- clean up extension
    
    print("Output DMG will be:", dmg_file)
    
    -- create staging directory
    local staging_dir = _create_staging_dir(package, app_source, appbundle_name, bg_image)
    if not staging_dir then
        return false
    end
    
    -- create dmg
    local success = _create_dmg_with_create_dmg(create_dmg, package, staging_dir, dmg_file, appbundle_name, bg_image)
    
    if success then
        -- verify the result
        success = _verify_dmg(dmg_file)
    end
    
    -- cleanup staging directory
    os.tryrm(staging_dir)
    print("Cleaned up staging directory")
    
    return success
end

-- main function 
function main(package)
    -- only for macOS
    if not is_host("macosx") then
        print("DMG packaging is only supported on macOS")
        return
    end
    
    local dmg_file = package:outputfile() or _get_dmg_file(package)
    dmg_file = dmg_file:gsub("%.dmg+$", ".dmg")
    
    cprint("packing %s", dmg_file)
    
    local success = _pack_dmg(package)
    
    if success then
        print("=== DMG Packaging Completed Successfully! ===")
        print("Final DMG file:", dmg_file)
    else
        print("=== DMG Packaging Failed! ===")
        os.exit(1)
    end
end