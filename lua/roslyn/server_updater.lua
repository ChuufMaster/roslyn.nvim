local M = {}

local uv = vim.uv

---@type string The system type to download
M.system_type = "linux-x64"

---@type boolean turn on printing
M.debug = false

---@param cmd string|string[] A shell command same as vim.fn.system
---@see vim.fn.system
---@param input string? Input to pass to the command
local cmd = function(cmd, input)
    input = input or nil
    local command = vim.fn.system(cmd, input)
    if M.debug then
        vim.print(command)
    end
    return command
end

local joinpath = vim.fs.joinpath

local data_path = vim.fn.stdpath("data") --[[@as string]]

---@type string Path to where the Language Server should be saved
M.roslyn_path = joinpath(data_path, "roslyn")
M.tmp_roslyn = joinpath(data_path, "tmp_roslyn")
M.prev_roslyn = joinpath(data_path, "prev_roslyn")

local _local_version = nil

---@return string
---Gets the local version Language Server
M.get_local_version = function()
    if _local_version ~= nil then
        _local_version = M.get_local_version()
        return _local_version
    end
    _local_version = cmd({
        "dotnet",
        vim.fs.joinpath(M.roslyn_path, "Microsoft.CodeAnalysis.LanguageServer.dll"),
        "--version",
    })
    _local_version = vim.split(_local_version, "+")[1]
    return _local_version
end

---@type string Local version of the Language Server
M.local_version = M.get_local_version()

local package_table = {}

---@return table
---Queries the azure API for the most up to date language server package details
M.get_online_table = function()
    if next(package_table) ~= nil then
        return package_table
    end
    local online_package_info = cmd({
        "curl",
        "-s",
        "https://feeds.dev.azure.com/"
            .. "azure-public/"
            .. "vside/"
            .. "_apis/packaging/Feeds/vs-impl/packages?"
            .. "packageNameQuery="
            .. M.system_type
            .. "&api-version=7.1",
    })

    package_table = vim.json.decode(online_package_info).value[1]
    return package_table
end

---@type table A table representation of the JSON package details
M.online_table = M.get_online_table()

---@type string The online package name
M.package_name = M.online_table.name

---@type string The normalized online version
M.online_version = M.online_table.versions[1].normalizedVersion

---@type string
---This is used to later download the package from Azure DevOps API
M.feed_id = vim.split(M.online_table.url, "/")[9]

---@return boolean
---Returns True if the online version is newer (different) compared to the local
---server version
M.check_if_newer_versoin = function()
    return M.local_version ~= M.online_version and true
end

---Gets all the relevant details of the local and online versions of the
---language server and then downloads and unpackages the newest version of the
---language server if its version number is different to the local version
---number
M.download_language_server = function()
    if M.debug then
        vim.print("Online Version: " .. M.online_table.versions[1].normalizedVersion)
        vim.print("Local Version: " .. M.local_version)
        -- vim.print("Feed ID: " .. feed_id)
    end
    if not M.check_if_newer_versoin() then
        vim.print("Already at newest version")
        return
    end
    cmd({
        "rm",
        "-rf",
        M.prev_roslyn,
    })
    cmd({
        "mv",
        M.roslyn_path,
        M.prev_roslyn,
    })
    local commands = {
        {
            "curl",
            "-s",
            "-Lo",
            joinpath(data_path, "roslyn.zip"),
            "https://pkgs.dev.azure.com/"
                .. "azure-public/"
                .. "vside/"
                .. "_apis/packaging/feeds/"
                .. M.feed_id
                .. "/nuget/packages/"
                .. M.package_name
                .. "/versions/"
                .. M.online_version
                .. "/content?"
                .. "&api-version=7.1-preview.1",
        },
        {
            "unzip",
            joinpath(data_path, "roslyn.zip"),
            "content/LanguageServer/" .. M.system_type .. "/*",
            "-d",
            M.tmp_roslyn,
        },
        {
            "mv",
            joinpath(M.tmp_roslyn, "content/LanguageServer", M.system_type),
            M.roslyn_path,
        },
        {
            "rm",
            "-rf",
            M.tmp_roslyn,
        },
        {
            function()
                vim.print("Roslyn Server Updated")
                -- vim.print("Restarting Roslyn Server")
                -- vim.cmd("Roslyn restart")
            end,
        },
    }

    --[[ M.download_files(commands[1], function()
        vim.print("Download Completed")
        M.shell_command(
            commands[2],
            M.shell_command(
                commands[3],
                M.shell_command(commands[4], function()
                    vim.print("Roslyn Server Updated")
                    -- vim.print("Restarting Roslyn Server")
                    -- vim.cmd("Roslyn restart")
                end)
            )
        )
    end) ]]

    local function finalsteps()
        uv.fs_rename(joinpath(M.tmp_roslyn, "content/LanguageServer", M.system_type), M.roslyn_path, function(err)
            if err then
                vim.print("Error moving file:", err)
            else
                vim.print("File moved to:", M.roslyn_path)
            end
        end)
        uv.fs_rmdir(M.tmp_roslyn)
        vim.print("Roslyn Server Updated")
    end
    M.download_files(commands[1], function()
        vim.print("Download Completed")
        M.shell_command(commands[2], finalsteps())
    end)
end

M.shell_command = function(command, callback)
    local handle
    local shell_cmd = table.remove(command, 1)
    local args = command
    handle = uv.spawn(shell_cmd, {
        args = args,
    }, function(code, signal)
        handle:close()
        if code == 0 then
            if callback then
                vim.print(shell_cmd)
                callback()
            else
                vim.print(shell_cmd .. " " .. code)
            end
        end
    end)
end

M.download_files = function(command, callback)
    local stdout = uv.new_pipe(false)
    local stderr = uv.new_pipe(false)

    local shell_cmd = table.remove(command, 1)
    local args = command
    local handle, pid
    handle, pid = uv.spawn(shell_cmd, { args = args, stdio = { nil, stdout, stderr } }, function(code, signal)
        stdout:close()
        stderr:close()
        handle:close()

        if code == 0 then
            vim.print("Download completed successfully!")
            if callback then
                callback()
            end
        end
    end)

    -- Non-blocking output handlers to avoid blocking Neovim
    uv.read_start(stdout, function(err, data)
        assert(not err, err)
        if data then
            vim.print(data) -- Print periodically or handle progress
        end
    end)
    uv.read_start(stderr, function(err, data)
        assert(not err, err)
        if data then
            vim.print(data)
        end
    end)
end

return M
