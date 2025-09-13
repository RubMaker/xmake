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
-- Copyright (C) 2015-present, Xmake Open Source Community.
--
-- @author      ruki
-- @file        main.lua
--

-- imports
import("core.base.option")
import("core.base.semver")
import("core.base.hashset")
import("lib.detect.find_tool")
import("lib.detect.find_file")
import("utils.archive")
import("detect.sdks.find_qt")
import("private.action.require.impl.packagenv")
import("private.action.require.impl.install_packages")
import(".batchcmds")

-- get the rpmbuild
function _get_rpmbuild()

    -- enter the environments of rpmbuild
    local oldenvs = packagenv.enter("rpm")

    -- find rpmbuild
    local packages = {}
    local rpmbuild = find_tool("rpmbuild")
    if not rpmbuild then
        table.join2(packages, install_packages("rpm"))
    end

    -- enter the environments of installed packages
    for _, instance in ipairs(packages) do
        instance:envs_enter()
    end

    -- we need to force detect and flush detect cache after loading all environments
    if not rpmbuild then
        rpmbuild = find_tool("rpmbuild", {force = true})
    end
    assert(rpmbuild, "rpmbuild not found!")
    return rpmbuild, oldenvs
end
-- detect if this is a Qt project
function _is_qt_project(package)
    -- Method 1: Check for Qt libraries in links
    local links = package:get("links")
    if links then
        for _, link in ipairs(links) do
            if link:lower():find("qt") then
                print("Qt project detected via link:", link)
                return true
            end
        end
    end

    -- Method 2: Check for Qt packages in requirements
    local requires = package:get("requires")
    if requires then
        for _, require in ipairs(requires) do
            if require:lower():find("qt") then
                print("Qt project detected via requirement:", require)
                return true
            end
        end
    end

    -- Method 3: Check executable for Qt dependencies using ldd (if available)
    local main_executable = nil
    
    -- Try to find the main executable path
    local install_rootdir = package:install_rootdir()
    if install_rootdir then
        local bin_dir = path.join(install_rootdir, "bin")
        if os.isdir(bin_dir) then
            local exe_path = path.join(bin_dir, package:name())
            if os.isfile(exe_path) then
                main_executable = exe_path
            end
        end
    end
    
    if main_executable and os.isfile(main_executable) then
        print("Checking executable for Qt dependencies:", main_executable)
        local ldd_output = os.iorunv("ldd", {main_executable})
        if ldd_output then
            -- Check for Qt libraries in ldd output
            if ldd_output:lower():find("libqt") or 
               ldd_output:lower():find("qt5") or 
               ldd_output:lower():find("qt6") then
                print("Qt project detected via ldd analysis")
                return true
            end
        end
    end

    -- Method 4: Check source files for Qt headers/includes
    local srcfiles, _ = package:sourcefiles()
    for _, srcfile in ipairs(srcfiles or {}) do
        if srcfile:endswith(".cpp") or srcfile:endswith(".cc") or srcfile:endswith(".cxx") then
            if os.isfile(srcfile) then
                local content = io.readfile(srcfile)
                if content and (content:find("#include.*[Qq][Tt]") or 
                               content:find("#include.*<Q") or
                               content:find("QApplication") or
                               content:find("QWidget") or
                               content:find("QMainWindow")) then
                    print("Qt project detected via source file analysis:", srcfile)
                    return true
                end
            end
        end
    end

    print("No Qt dependencies detected")
    return false
end

-- get Qt build requirements
function _get_qt_buildrequires(package)
    local qt = find_qt()
    local qt_requires = {}
    
    if qt then
        local qt_version = qt.sdkver or "5.15"
        print("Found Qt SDK version:", qt_version)
        
        if qt_version:startswith("6") then
            -- Qt6 requirements
            table.insert(qt_requires, "BuildRequires: qt6-qtbase-devel")
            table.insert(qt_requires, "BuildRequires: qt6-qttools-devel")
            
            -- Check for specific Qt6 modules based on links
            local links = package:get("links") or {}
            for _, link in ipairs(links) do
                local link_lower = link:lower()
                if link_lower:find("qt6widgets") or link_lower:find("qtwidgets") then
                    table.insert(qt_requires, "BuildRequires: qt6-qtbase-devel")
                end
                if link_lower:find("qt6core") or link_lower:find("qtcore") then
                    -- Already included in qtbase-devel
                end
                if link_lower:find("qt6gui") or link_lower:find("qtgui") then
                    -- Already included in qtbase-devel
                end
                if link_lower:find("qt6network") or link_lower:find("qtnetwork") then
                    table.insert(qt_requires, "BuildRequires: qt6-qtbase-devel")
                end
                if link_lower:find("qt6multimedia") or link_lower:find("qtmultimedia") then
                    table.insert(qt_requires, "BuildRequires: qt6-qtmultimedia-devel")
                end
                if link_lower:find("qt6opengl") or link_lower:find("qtopengl") then
                    table.insert(qt_requires, "BuildRequires: qt6-qtbase-devel")
                end
                if link_lower:find("qt6svg") or link_lower:find("qtsvg") then
                    table.insert(qt_requires, "BuildRequires: qt6-qtsvg-devel")
                end
                if link_lower:find("qt6xml") or link_lower:find("qtxml") then
                    table.insert(qt_requires, "BuildRequires: qt6-qtbase-devel")
                end
            end
        else
            -- Qt5 requirements (default)
            table.insert(qt_requires, "BuildRequires: qt5-qtbase-devel")
            table.insert(qt_requires, "BuildRequires: qt5-qttools-devel")
            
            -- Check for specific Qt5 modules based on links
            local links = package:get("links") or {}
            for _, link in ipairs(links) do
                local link_lower = link:lower()
                if link_lower:find("qt5widgets") or link_lower:find("qtwidgets") then
                    table.insert(qt_requires, "BuildRequires: qt5-qtbase-devel")
                end
                if link_lower:find("qt5core") or link_lower:find("qtcore") then
                    -- Already included in qtbase-devel
                end
                if link_lower:find("qt5gui") or link_lower:find("qtgui") then
                    -- Already included in qtbase-devel
                end
                if link_lower:find("qt5network") or link_lower:find("qtnetwork") then
                    table.insert(qt_requires, "BuildRequires: qt5-qtbase-devel")
                end
                if link_lower:find("qt5multimedia") or link_lower:find("qtmultimedia") then
                    table.insert(qt_requires, "BuildRequires: qt5-qtmultimedia-devel")
                end
                if link_lower:find("qt5opengl") or link_lower:find("qtopengl") then
                    table.insert(qt_requires, "BuildRequires: qt5-qtbase-devel")
                end
                if link_lower:find("qt5svg") or link_lower:find("qtsvg") then
                    table.insert(qt_requires, "BuildRequires: qt5-qtsvg-devel")
                end
                if link_lower:find("qt5xml") or link_lower:find("qtxml") then
                    table.insert(qt_requires, "BuildRequires: qt5-qtbase-devel")
                end
                if link_lower:find("qt5quick") or link_lower:find("qtquick") then
                    table.insert(qt_requires, "BuildRequires: qt5-qtdeclarative-devel")
                end
                if link_lower:find("qt5qml") or link_lower:find("qtqml") then
                    table.insert(qt_requires, "BuildRequires: qt5-qtdeclarative-devel")
                end
            end
        end
    else
        print("Qt SDK not found, using default Qt5 requirements")
        -- Default to Qt5 if no Qt SDK is detected but project uses Qt
        table.insert(qt_requires, "BuildRequires: qt5-qtbase-devel")
        table.insert(qt_requires, "BuildRequires: qt5-qttools-devel")
    end
    
    -- Remove duplicates
    local unique_requires = {}
    local seen = {}
    for _, req in ipairs(qt_requires) do
        if not seen[req] then
            table.insert(unique_requires, req)
            seen[req] = true
        end
    end
    
    return unique_requires
end

-- get Qt runtime requirements
function _get_qt_runtime_requires(package)
    local qt = find_qt()
    local qt_requires = {}
    
    if qt then
        local qt_version = qt.sdkver or "5.15"
        
        if qt_version:startswith("6") then
            -- Qt6 runtime requirements
            table.insert(qt_requires, "Requires: qt6-qtbase")
            
            -- Check for specific Qt6 modules
            local links = package:get("links") or {}
            for _, link in ipairs(links) do
                local link_lower = link:lower()
                if link_lower:find("qt6multimedia") or link_lower:find("qtmultimedia") then
                    table.insert(qt_requires, "Requires: qt6-qtmultimedia")
                end
                if link_lower:find("qt6svg") or link_lower:find("qtsvg") then
                    table.insert(qt_requires, "Requires: qt6-qtsvg")
                end
            end
        else
            -- Qt5 runtime requirements
            table.insert(qt_requires, "Requires: qt5-qtbase")
            
            -- Check for specific Qt5 modules
            local links = package:get("links") or {}
            for _, link in ipairs(links) do
                local link_lower = link:lower()
                if link_lower:find("qt5multimedia") or link_lower:find("qtmultimedia") then
                    table.insert(qt_requires, "Requires: qt5-qtmultimedia")
                end
                if link_lower:find("qt5svg") or link_lower:find("qtsvg") then
                    table.insert(qt_requires, "Requires: qt5-qtsvg")
                end
                if link_lower:find("qt5quick") or link_lower:find("qtquick") then
                    table.insert(qt_requires, "Requires: qt5-qtdeclarative")
                end
            end
        end
    else
        -- Default Qt5 runtime requirements
        table.insert(qt_requires, "Requires: qt5-qtbase")
    end
    
    -- Remove duplicates
    local unique_requires = {}
    local seen = {}
    for _, req in ipairs(qt_requires) do
        if not seen[req] then
            table.insert(unique_requires, req)
            seen[req] = true
        end
    end
    
    return unique_requires
end

-- get archive file
function _get_archivefile(package)
    return path.absolute(path.join(package:builddir(), package:basename() .. ".tar.gz"))
end

-- translate the file path
function _translate_filepath(package, filepath)
    return filepath:replace(package:install_rootdir(), "%{buildroot}/%{_exec_prefix}", {plain = true})
end

-- get install command
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
            table.insert(installcmds, string.format("install -Dpm0644 \"%s\" \"%s\"", srcfile, dstfile))
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
        table.insert(installcmds, string.format("mv \"%s\" \"%s\"", srcfile, dstfile))
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

-- get specvars
function _get_specvars(package)
    local is_qt = _is_qt_project(package)
    local specvars = table.clone(package:specvars())
    specvars.PACKAGE_ARCHIVEFILE = path.filename(_get_archivefile(package))
    local datestr = os.iorunv("date", {"+%a %b %d %Y"}, {envs = {LC_TIME = "en_US"}})
    if datestr then
        datestr = datestr:trim()
    end
    specvars.PACKAGE_PREFIXDIR = package:prefixdir() or ""
    specvars.PACKAGE_DATE = datestr or ""
    specvars.PACKAGE_INSTALLCMDS = function ()
        local prefixdir = package:get("prefixdir")
        package:set("prefixdir", nil)
        local installcmds = {}
        _get_installcmds(package, installcmds, batchcmds.get_installcmds(package):cmds())
        for _, component in table.orderpairs(package:components()) do
            if component:get("default") ~= false then
                _get_installcmds(package, installcmds, batchcmds.get_installcmds(component):cmds())
            end
        end
        package:set("prefixdir", prefixdir)
        return table.concat(installcmds, "\n")
    end
    specvars.PACKAGE_BUILDCMDS = function ()
        local buildcmds = {}
        _get_buildcmds(package, buildcmds, batchcmds.get_buildcmds(package):cmds())
        return table.concat(buildcmds, "\n")
    end
    specvars.PACKAGE_BUILDREQUIRES = function ()
        local requires = {}
        local buildrequires = package:get("buildrequires")
        if buildrequires then
            for _, buildrequire in ipairs(buildrequires) do
                table.insert(requires, "BuildRequires: " .. buildrequire)
            end
        else
            local programs = hashset.new()
            for _, cmd in ipairs(batchcmds.get_buildcmds(package):cmds()) do
                local program = cmd.program
                if program then
                    programs:insert(program)
                end
            end
            local map = {
                xmake = "xmake",
                cmake = "cmake",
                make = "make"
            }
            for _, program in programs:keys() do
                local requirename = map[program]
                if requirename then
                    table.insert(requires, "BuildRequires: " .. requirename)
                end
            end
            if #requires > 0 then
                table.insert(requires, "BuildRequires: gcc")
                table.insert(requires, "BuildRequires: gcc-c++")
            end
            if is_qt then
                local qt_buildrequires = _get_qt_buildrequires(package)
                for _, req in ipairs(qt_buildrequires) do
                    table.insert(requires, req)
                end
            end
        end
        
        return table.concat(requires, "\n")
    end
    
    -- Add Qt runtime requirements if this is a Qt project
    specvars.PACKAGE_REQUIRES = function ()
        local requires = {}
        local runtime_requires = package:get("requires")
        
        if runtime_requires then
            -- Use user-specified runtime requirements
            for _, require in ipairs(runtime_requires) do
                table.insert(requires, "Requires: " .. require)
            end
        end
        if is_qt then
            local qt_requires = _get_qt_runtime_requires(package)
            for _, req in ipairs(qt_requires) do
                table.insert(requires, req)
            end
        end
        return table.concat(requires, "\n")
    end
    return specvars
end

-- pack srpm package
function _pack_srpm(rpmbuild, package)

    -- ensure prefixdir
    local prefixdir = package:get("prefixdir")
    if not prefixdir then
        prefixdir = package:name() .. "-" .. package:version()
        package:set("prefixdir", prefixdir)
    end

    -- install the initial specfile
    local specfile = path.join(package:builddir(), package:basename() .. ".spec")
    if not os.isfile(specfile) then
        local specfile_template = package:get("specfile") or path.join(os.programdir(), "scripts", "xpack", "srpm", "srpm.spec")
        os.cp(specfile_template, specfile, {writeable = true})
    end

    -- replace variables in specfile
    -- and we need to avoid `attempt to yield across a C-call boundary` in io.gsub
    local specvars = _get_specvars(package)
    local pattern = package:extraconf("specfile", "pattern") or "%${([^\n]-)}"
    local specvars_names = {}
    local specvars_values = {}
    io.gsub(specfile, "(" .. pattern .. ")", function(_, name)
        table.insert(specvars_names, name)
    end)
    for _, name in ipairs(specvars_names) do
        name = name:trim()
        if specvars_values[name] == nil then
            local value = specvars[name]
            if type(value) == "function" then
                value = value()
            end
            if value ~= nil then
                dprint("  > replace %s -> %s", name, value)
            end
            if type(value) == "table" then
                dprint("invalid variable value", value)
            end
            specvars_values[name] = value
        end
    end
    io.gsub(specfile, "(" .. pattern .. ")", function(_, name)
        name = name:trim()
        return specvars_values[name]
    end)

    -- archive source files
    local srcfiles, dstfiles = package:sourcefiles()
    for idx, srcfile in ipairs(srcfiles) do
        os.vcp(srcfile, dstfiles[idx])
    end
    for _, component in table.orderpairs(package:components()) do
        if component:get("default") ~= false then
            local srcfiles, dstfiles = component:sourcefiles()
            for idx, srcfile in ipairs(srcfiles) do
                os.vcp(srcfile, dstfiles[idx])
            end
        end
    end

    -- archive install files
    local rootdir = package:source_rootdir()
    local oldir = os.cd(rootdir)
    local archivefiles = os.files("**")
    os.cd(oldir)
    local archivefile = _get_archivefile(package)
    os.tryrm(archivefile)
    archive.archive(archivefile, archivefiles, {curdir = rootdir, compress = "best"})

    -- pack srpm package
    os.vrunv(rpmbuild, {"-bs", specfile,
        "--define", "_topdir " .. package:builddir(),
        "--define", "_sourcedir " .. package:builddir(),
        "--define", "_srcrpmdir " .. package:outputdir()})

    -- pack rpm package
    if package:format() == "rpm" then
        local srpmfile = find_file("*.src.rpm", package:outputdir())
        if srpmfile then
            os.vrunv(rpmbuild, {"--rebuild", srpmfile, "--define", "_rpmdir " .. package:outputdir()})
        end
    end
end

function main(package)

    if not is_host("linux") then
        return
    end

    cprint("packing %s", package:outputfile())
    
    -- Check if this is a Qt project and inform the user
    local is_qt = _is_qt_project(package)
    if is_qt then
        cprint("Qt project detected - adding Qt dependencies to RPM spec")
    end

    -- get rpmbuild
    local rpmbuild, oldenvs = _get_rpmbuild()

    -- pack srpm package
    _pack_srpm(rpmbuild.program, package)

    -- done
    os.setenvs(oldenvs)
end