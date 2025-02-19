local spawn = require "mason-core.spawn"
local log = require "mason-core.log"
local fs = require "mason-core.fs"
local path = require "mason-core.path"
local platform = require "mason-core.platform"
local receipt = require "mason-core.receipt"
local Optional = require "mason-core.optional"
local _ = require "mason-core.functional"

---@class ContextualSpawn
---@field cwd CwdManager
---@field handle InstallHandle
local ContextualSpawn = {}

---@param cwd CwdManager
---@param handle InstallHandle
function ContextualSpawn.new(cwd, handle)
    return setmetatable({ cwd = cwd, handle = handle }, ContextualSpawn)
end

function ContextualSpawn.__index(self, cmd)
    return function(args)
        args.cwd = args.cwd or self.cwd:get()
        args.stdio_sink = args.stdio_sink or self.handle.stdio.sink
        local on_spawn = args.on_spawn
        local captured_handle
        args.on_spawn = function(handle, stdio, pid, ...)
            captured_handle = handle
            self.handle:register_spawn_handle(handle, pid, cmd, spawn._flatten_cmd_args(args))
            if on_spawn then
                on_spawn(handle, stdio, pid, ...)
            end
        end
        local function pop_spawn_stack()
            if captured_handle then
                self.handle:deregister_spawn_handle(captured_handle)
            end
        end
        -- We get_or_throw() here for convenience reasons.
        -- Almost every time spawn is called via context we want the command to succeed.
        return spawn[cmd](args):on_success(pop_spawn_stack):on_failure(pop_spawn_stack):get_or_throw()
    end
end

---@class ContextualFs
---@field private cwd CwdManager
local ContextualFs = {}
ContextualFs.__index = ContextualFs

---@param cwd CwdManager
function ContextualFs.new(cwd)
    return setmetatable({ cwd = cwd }, ContextualFs)
end

---@async
---@param rel_path string: The relative path from the current working directory to the file to append.
---@param contents string
function ContextualFs:append_file(rel_path, contents)
    return fs.async.append_file(path.concat { self.cwd:get(), rel_path }, contents)
end

---@async
---@param rel_path string: The relative path from the current working directory to the file to write.
---@param contents string
function ContextualFs:write_file(rel_path, contents)
    return fs.async.write_file(path.concat { self.cwd:get(), rel_path }, contents)
end

---@async
---@param rel_path string: The relative path from the current working directory.
function ContextualFs:file_exists(rel_path)
    return fs.async.file_exists(path.concat { self.cwd:get(), rel_path })
end

---@async
---@param rel_path string: The relative path from the current working directory.
function ContextualFs:dir_exists(rel_path)
    return fs.async.dir_exists(path.concat { self.cwd:get(), rel_path })
end

---@async
---@param rel_path string: The relative path from the current working directory.
function ContextualFs:rmrf(rel_path)
    return fs.async.rmrf(path.concat { self.cwd:get(), rel_path })
end

---@async
---@param rel_path string: The relative path from the current working directory.
function ContextualFs:unlink(rel_path)
    return fs.async.unlink(path.concat { self.cwd:get(), rel_path })
end

---@async
---@param old_path string
---@param new_path string
function ContextualFs:rename(old_path, new_path)
    return fs.async.rename(path.concat { self.cwd:get(), old_path }, path.concat { self.cwd:get(), new_path })
end

---@async
---@param dirpath string
function ContextualFs:mkdir(dirpath)
    return fs.async.mkdir(path.concat { self.cwd:get(), dirpath })
end

---@class CwdManager
---@field private install_prefix string: Defines the upper boundary for which paths are allowed as cwd.
---@field private cwd string
local CwdManager = {}
CwdManager.__index = CwdManager

function CwdManager.new(install_prefix)
    assert(type(install_prefix) == "string")
    return setmetatable({
        install_prefix = install_prefix,
        cwd = nil,
    }, CwdManager)
end

function CwdManager:get()
    assert(self.cwd ~= nil, "Tried to access cwd before it was set.")
    return self.cwd
end

---@param new_cwd string
function CwdManager:set(new_cwd)
    assert(type(new_cwd) == "string")
    assert(
        path.is_subdirectory(self.install_prefix, new_cwd),
        ("%q is not a subdirectory of %q"):format(new_cwd, self.install_prefix)
    )
    self.cwd = new_cwd
end

---@class InstallContext
---@field public receipt InstallReceiptBuilder
---@field public requested_version Optional
---@field public fs ContextualFs
---@field public spawn JobSpawn
---@field public handle InstallHandle
---@field public package Package
---@field public cwd CwdManager
---@field public stdio_sink StdioSink
local InstallContext = {}
InstallContext.__index = InstallContext

---@class InstallContextOpts
---@field requested_version string|nil

---@param handle InstallHandle
---@param opts InstallContextOpts
function InstallContext.new(handle, opts)
    local cwd_manager = CwdManager.new(path.install_prefix())
    return setmetatable({
        cwd = cwd_manager,
        spawn = ContextualSpawn.new(cwd_manager, handle),
        handle = handle,
        package = handle.package, -- for convenience
        fs = ContextualFs.new(cwd_manager),
        receipt = receipt.InstallReceiptBuilder.new(),
        requested_version = Optional.of_nilable(opts.requested_version),
        stdio_sink = handle.stdio.sink,
    }, InstallContext)
end

---@async
function InstallContext:promote_cwd()
    local cwd = self.cwd:get()
    local install_path = self.package:get_install_path()
    if install_path == cwd then
        log.fmt_debug("cwd %s is already promoted (at %s)", cwd, install_path)
        return
    end
    log.fmt_debug("Promoting cwd %s to %s", cwd, install_path)
    -- 1. Unlink any existing installation
    self.handle.package:unlink()
    -- 2. Prepare for renaming cwd to destination
    if platform.is_unix then
        -- Some Unix systems will raise an error when renaming a directory to a destination that does not already exist.
        fs.async.mkdir(install_path)
    end
    -- 3. Move the cwd to the final installation directory
    fs.async.rename(cwd, install_path)
    -- 4. Update cwd
    self.cwd:set(install_path)
end

---@param rel_path string: The relative path from the current working directory to change cwd to. Will only restore to the initial cwd after execution of fn (if provided).
---@param fn async (fun()): (optional) The function to run in the context of the given path.
function InstallContext:chdir(rel_path, fn)
    local old_cwd = self.cwd:get()
    self.cwd:set(path.concat { old_cwd, rel_path })
    if fn then
        local ok, result = pcall(fn)
        self.cwd:set(old_cwd)
        if not ok then
            error(result, 0)
        end
        return result
    end
end

---@param new_executable_rel_path string: Relative path to the executable file to create.
---@param script_rel_path string: Relative path to the Node.js script.
function InstallContext:write_node_exec_wrapper(new_executable_rel_path, script_rel_path)
    return self:write_shell_exec_wrapper(
        new_executable_rel_path,
        ("node %q"):format(path.concat {
            self.package:get_install_path(),
            script_rel_path,
        })
    )
end

---@param new_executable_rel_path string: Relative path to the executable file to create.
---@param target_executable_rel_path string
function InstallContext:write_exec_wrapper(new_executable_rel_path, target_executable_rel_path)
    return self:write_shell_exec_wrapper(
        new_executable_rel_path,
        ("%q"):format(path.concat {
            self.package:get_install_path(),
            target_executable_rel_path,
        })
    )
end

---@param new_executable_rel_path string: Relative path to the executable file to create.
---@param command string: The shell command to run.
---@return string: The created executable filename.
function InstallContext:write_shell_exec_wrapper(new_executable_rel_path, command)
    return platform.when {
        unix = function()
            local std = require "mason-core.managers.std"
            self.fs:write_file(
                new_executable_rel_path,
                _.dedent(([[
                    #!/bin/bash
                    exec %s "$@"
                ]]):format(command))
            )
            std.chmod("+x", { new_executable_rel_path })
            return new_executable_rel_path
        end,
        win = function()
            local executable_file = ("%s.cmd"):format(new_executable_rel_path)
            self.fs:write_file(
                executable_file,
                _.dedent(([[
                    @ECHO off
                    %s %%*
                ]]):format(command))
            )
            return executable_file
        end,
    }
end

function InstallContext:link_bin(executable, rel_path)
    self.receipt:with_link("bin", executable, rel_path)
end

---@param patches string[]
function InstallContext:apply_patches(patches)
    for _, patch in ipairs(patches) do
        self.spawn.patch {
            "-g",
            "0",
            "-f",
            on_spawn = function(_, stdio)
                local stdin = stdio[1]
                stdin:write(patch)
                stdin:close()
            end,
        }
    end
end

return InstallContext
