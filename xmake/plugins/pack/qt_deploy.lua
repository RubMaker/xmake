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
-- @file        qt_deploy.lua
--

import("lib.detect.find_tool")
import("lib.detect.find_program")

-- 跨平台Qt部署函数
-- @param executable_path   可执行文件路径
-- @param deploy_dir       部署目录
-- @param options          部署选项 (可选)
--   - qml_source_path: QML源码路径
--   - qt_version: "qt5" 或 "qt6"，自动检测如果未指定
--   - verbose: 详细输出等级 (0-3)
--   - debug: 部署调试版本
function qt_deploy_executable(executable_path, deploy_dir, options)
    options = options or {}
    
    if not os.isfile(executable_path) then
        raise("Executable not found: " .. executable_path)
    end
    
    print("Qt deploying:", executable_path, "->", deploy_dir)
    os.mkdir(deploy_dir)
    
    local deploy_tool = _get_qt_deploy_tool(options.qt_version)
    if not deploy_tool then
        raise("Qt deployment tool not found for current platform")
    end
    
    local success = false
    if is_host("windows") then
        success = _deploy_windows(deploy_tool, executable_path, deploy_dir, options)
    elseif is_host("linux") then
        success = _deploy_linux(deploy_tool, executable_path, deploy_dir, options)
    elseif is_host("macosx") then
        success = _deploy_macos(deploy_tool, executable_path, deploy_dir, options)
    end
    
    if not success then
        raise("Qt deployment failed")
    end
    
    print("Qt deployment completed:", deploy_dir)
    return deploy_dir
end

-- 获取Qt部署工具
function _get_qt_deploy_tool(qt_version)
    local tool_names = {}
    
    if is_host("windows") then
        table.insert(tool_names, "windeployqt")
    elseif is_host("linux") then
        table.insert(tool_names, "linuxdeployqt")
    elseif is_host("macosx") then
        table.insert(tool_names, "macdeployqt")
    end
    
    -- 查找工具
    for _, tool_name in ipairs(tool_names) do
        local tool = find_tool(tool_name) or find_program(tool_name)
        if tool then
            return tool
        end
        
        -- 尝试在Qt安装目录中查找
        local qt_paths = _get_qt_paths(qt_version)
        for _, qt_path in ipairs(qt_paths) do
            local tool_path = path.join(qt_path, "bin", tool_name)
            if is_host("windows") then
                tool_path = tool_path .. ".exe"
            end
            if os.isfile(tool_path) then
                return {program = tool_path}
            end
        end
    end
    
    return nil
end

-- 获取Qt安装路径
function _get_qt_paths(qt_version)
    local paths = {}
    
    -- 环境变量
    local env_vars = {"QTDIR", "QT_DIR"}
    if qt_version == "qt5" then
        table.insert(env_vars, "Qt5_DIR")
        table.insert(env_vars, "QT5_DIR")
    elseif qt_version == "qt6" then
        table.insert(env_vars, "Qt6_DIR")
        table.insert(env_vars, "QT6_DIR")
    end
    
    for _, var in ipairs(env_vars) do
        local qt_dir = os.getenv(var)
        if qt_dir and os.isdir(qt_dir) then
            table.insert(paths, qt_dir)
        end
    end
    
    -- 通过qmake查找
    local qmake = find_program("qmake")
    if qmake then
        table.insert(paths, path.directory(path.directory(qmake)))
    end
    
    return paths
end

-- Windows部署
function _deploy_windows(deploy_tool, executable_path, deploy_dir, options)
    local args = {
        "--dir", deploy_dir,
        "--compiler-runtime"
    }
    
    if options.qml_source_path then
        table.insert(args, "--qmlsource")
        table.insert(args, options.qml_source_path)
    end
    
    if options.verbose then
        table.insert(args, "--verbose")
        table.insert(args, tostring(options.verbose))
    end
    
    if options.debug then
        table.insert(args, "--debug")
    else
        table.insert(args, "--release")
    end
    
    table.insert(args, executable_path)
    
    local ok, err = os.iorunv(deploy_tool.program, args)
    return ok
end

-- Linux部署
function _deploy_linux(deploy_tool, executable_path, deploy_dir, options)
    -- 创建AppDir结构供linuxdeployqt使用
    local appdir = path.join(deploy_dir, "AppDir")
    os.mkdir(path.join(appdir, "usr/bin"))
    
    -- 复制可执行文件
    local exe_name = path.filename(executable_path)
    os.cp(executable_path, path.join(appdir, "usr/bin", exe_name))
    
    -- 创建desktop文件
    local desktop_content = string.format([[
[Desktop Entry]
Type=Application
Name=%s
Exec=%s
]], exe_name, exe_name)
    
    local desktop_file = path.join(appdir, exe_name .. ".desktop")
    io.writefile(desktop_file, desktop_content)
    
    local args = {desktop_file}
    
    if options.qml_source_path then
        table.insert(args, "-qmlsource=" .. options.qml_source_path)
    end
    
    if options.verbose then
        table.insert(args, "-verbose=" .. tostring(options.verbose))
    end
    
    local ok, err = os.iorunv(deploy_tool.program, args, {curdir = path.directory(appdir)})
    
    if ok then
        -- 将AppDir内容复制到deploy_dir
        os.cp(path.join(appdir, "usr"), path.join(deploy_dir, "usr"))
    end
    
    return ok
end

-- macOS部署
function _deploy_macos(deploy_tool, executable_path, deploy_dir, options)
    local app_bundle = executable_path
    
    -- 如果不是.app，创建临时bundle
    if path.extension(executable_path):lower() ~= ".app" then
        local exe_name = path.filename(executable_path)
        app_bundle = path.join(deploy_dir, exe_name .. ".app")
        
        local macos_dir = path.join(app_bundle, "Contents/MacOS")
        os.mkdir(macos_dir)
        os.cp(executable_path, path.join(macos_dir, exe_name))
        
        -- 创建Info.plist
        local plist = string.format([[
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>%s</string>
    <key>CFBundleIdentifier</key>
    <string>com.example.%s</string>
</dict>
</plist>
]], exe_name, exe_name)
        
        io.writefile(path.join(app_bundle, "Contents/Info.plist"), plist)
    end
    
    local args = {app_bundle}
    
    if options.qml_source_path then
        table.insert(args, "-qmlsource=" .. options.qml_source_path)
    end
    
    if options.verbose then
        table.insert(args, "-verbose=" .. tostring(options.verbose))
    end
    
    local ok, err = os.iorunv(deploy_tool.program, args)
    return ok
end