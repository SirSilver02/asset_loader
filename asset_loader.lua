local file_name_pattern = "([%w_]+)%."
local folder_name_pattern = "([%w_]+)$"
local extension_pattern = "%.(.+)"
local directory_pattern = "([%w_]+)/"

local assets = {}

local asset_threads = {
    audio = [[
        require("love.sound")
        require("love.audio")
        love.thread.getChannel("%s"):push({"%s", love.audio.newSource("%s", "static"), "%s"})
    ]],

    graphics = [[
        require("love.image")
        love.thread.getChannel("%s"):push({"%s", love.image.newImageData("%s"), "%s"})
    ]],

    video = [[
        require("love.video")
        love.thread.getChannel("%s"):push({"%s", love.video.newVideoStream("%s"), "%s"})
    ]]
}

local path_table = {} --for async loading communication between channels

--sync

local function load_image(file_name, path, table)
    table[file_name] = love.graphics.newImage(path)
end

local function load_shader(file_name, path, table)
    table[file_name] = love.graphics.newShader(path)
end

local function load_audio(file_name, path, table)
    table[file_name] = love.audio.newSource(path, "static")
end

local function load_video(file_name, path, table)
    table[file_name] = love.graphics.newVideo(path)
end

local function load_font(file_name, path, table)
    table[file_name] = setmetatable({}, {
        __index = function(t, size)
            if type(size) == "number" then
                local font = love.graphics.newFont(path, size)
                rawset(t, size, font)
    
                return font
            end
        end  
    })
end

--TODO could remove path_table and have it refer to a path_table stored on the pool?
local function load_image_async(file_name, path, table, pool)
    pool.progress.image.total = pool.progress.image.total + 1
    path_table[path] = table

    love.thread.newThread(asset_threads.graphics:format(pool.channels.image, file_name, path, path)):start()
end 

local function load_audio_async(file_name, path, table, pool)
    pool.progress.audio.total = pool.progress.audio.total + 1
    path_table[path] = table

    love.thread.newThread(asset_threads.audio:format(pool.channels.audio, file_name, path, path)):start()
end

local function load_video_async(file_name, path, table, pool)
    pool.progress.video.total = pool.progress.video.total + 1
    path_table[path] = table

    love.thread.newThread(asset_threads.video:format(pool.channels.video, file_name, path, path)):start()
end

local extension_loadfunc = {
    sync = {
        png = load_image,
        jpg = load_image,

        glsl = load_shader,

        wav = load_audio,
        mp3 = load_audio,
        ogg = load_audio,
        
        ogv = load_video,

        ttf = load_font,
        otf = load_font
    },

    async = {
        png = load_image_async,
        jpg = load_image_async,

        glsl = load_shader, --not async

        wav = load_audio_async,
        mp3 = load_audio_async,
        ogg = load_audio_async,
        
        ogv = load_video_async,

        ttf = load_font, --not async
        otf = load_font, --not async
    }
}

---------------

local pools = {}

local pool_id = 0

local function create_pool(callback)
    pool_id = pool_id + 1

    local pool = {
        callback = callback,

        channels = {
            audio = "audio" .. pool_id,
            video = "video" .. pool_id,
            image = "image" .. pool_id
        },

        progress = {
            audio = {complete = 0, total = 0},
            video = {complete = 0, total = 0},
            image = {complete = 0, total = 0}
        }
    }

    table.insert(pools, pool)

    return pool
end

----------

local channel_loader = {
    audio = function(audio_pool_progress, channel_name)
        local data = love.thread.getChannel(channel_name):pop()

        while data do
            audio_pool_progress.complete = audio_pool_progress.complete + 1
            path_table[data[3]][data[1]] = data[2]

            data = love.thread.getChannel(channel_name):pop()

            if audio_pool_progress.complete == audio_pool_progress.total then
                return true
            end
        end
    end,

    image = function(image_pool_progress, channel_name)
        local data = love.thread.getChannel(channel_name):pop()

        --making this a while loop will load more per frame, but can freeze the main thread
        if data then
            image_pool_progress.complete = image_pool_progress.complete + 1
            path_table[data[3]][data[1]] = love.graphics.newImage(data[2])

            if image_pool_progress.complete == image_pool_progress.total then
                return true
            end
        end
    end,

    video = function(video_pool_progress, channel_name)
        local data = love.thread.getChannel(channel_name):pop()

        if data then
            video_pool_progress.complete = video_pool_progress.complete + 1
            path_table[data[3]][data[1]] = love.graphics.newVideo(data[2])

            if video_pool_progress.complete == video_pool_progress.total then
                return true
            end
        end
    end
}

function assets.update(dt)
    for i = #pools, 1, -1 do
        local pool = pools[i]
        local pool_complete = true

        for channel_type, channel_name in pairs(pool.channels) do
            if pool.progress[channel_type].total == 0 then
                pool.channels[channel_type] = nil
            end

            pool_complete = false

            if channel_loader[channel_type](pool.progress[channel_type], channel_name) then
                pool.channels[channel_type] = nil
            end
        end

        if pool_complete then
            if pool.callback then
                pool.callback()
            end

            table.remove(pools, i)
        end
    end
end

local function load_from_table(table, name_asset_table, is_async, pool)
    for _, path in pairs(table) do
        local info = love.filesystem.getInfo(path)

        if info then
            local asset_table = name_asset_table

            for folder_name in path:gmatch(directory_pattern) do
                asset_table[folder_name] = asset_table[folder_name] or {}
                asset_table = asset_table[folder_name]
            end

            if info.type == "file" then
                local extension = path:match(extension_pattern):lower()
                local file_name = path:match(file_name_pattern)
    
                print(file_name)
                local load_func = extension_loadfunc[is_async and "async" or "sync"][extension]
    
                if load_func then
                    load_func(file_name, path, asset_table, pool)
                end
            elseif info.type == "directory" then
                local folder_name = path .. "/"
                local next_table = {}

                for _, next_path in pairs(love.filesystem.getDirectoryItems(path)) do
                    next_table[#next_table + 1] = folder_name .. next_path
                end

                load_from_table(next_table, name_asset_table, is_async, pool)
            end
        end
    end
end

local function recursive_load(paths, name_asset_table, is_async, pool)
    for _, path in pairs(love.filesystem.getDirectoryItems(paths)) do
        local full_path = paths .. "/" .. path
        local info = love.filesystem.getInfo(full_path)

        local asset_table = name_asset_table

        for folder_name in full_path:gmatch(directory_pattern) do
            asset_table[folder_name] = asset_table[folder_name] or {}
            asset_table = asset_table[folder_name]
        end

        if info.type == "file" then
            local extension = path:match(extension_pattern):lower()
            local file_name = path:match(file_name_pattern)

            local load_func = extension_loadfunc[is_async and "async" or "sync"][extension]

            if load_func then
                load_func(file_name, full_path, asset_table, pool)
            end
        elseif info.type == "directory" then
            recursive_load(full_path, name_asset_table, is_async, pool)
        end
    end
end

local thing = function(folder_or_filename, table, is_async, pool)
    if type(folder_or_filename) == "table" then
        load_from_table(folder_or_filename, table, is_async, pool)
    else 
        local info = love.filesystem.getInfo(folder_or_filename)

        if info.type == "file" then
            local extension = folder_or_filename:match(extension_pattern)
            local load_func = extension_loadfunc.sync[extension]

            local asset_table = table

            for folder_name in full_path:gmatch(directory_pattern) do
                asset_table[folder_name] = asset_table[folder_name] or {}
                asset_table = asset_table[folder_name]
            end

            if load_func then
                local extension = folder_or_filename:match(extension_pattern):lower()
                local file_name = folder_or_filename:match(file_name_pattern)
                local path = folder_or_filename

                load_func(file_name, path, asset_table)
            end
        elseif info.type == "directory" then
            recursive_load(folder_or_filename, table, is_async, pool)
        end
    end
end

function assets.load(folder_or_filename, table, callback)
    thing(folder_or_filename, table, false, nil)

    if callback then
        callback()
    end
end

function assets.load_async(folder_or_filename, table, callback)
    local pool = create_pool(callback)

    thing(folder_or_filename, table, true, pool)

    return setmetatable({}, {
        __index = function(t, k)
            return pool.progress[k]
        end,

        __newindex = function(t, k, v)
            --do nothing
        end
    })
end

function assets.unload()
    
end

return assets

--handle freeing resources with weak table as optional?, if its not in the table, try to load it? way to clear it out, progress checks?
--linking the table to the root file
--when loading, only load it if its NOT there
--also way to unload data?
--way to mark data as please unload this? 

--master table for storing assets? when unloading call release, nil out the thing
--have it unload by passing a path?
--or a folder
--or table or paths
--or table of paths and directories
