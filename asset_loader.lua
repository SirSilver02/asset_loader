local file_name_pattern = "([%w_]+)%."
local extension_pattern = "%.(.+)"
local directory_pattern = "([%w_]+)/"

--consider making these work on multiple assets and returning a table of them to be popped?
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

--TODO could remove pool.pool.path_table and have it refer to a pool.path_table stored on the pool?
local function load_image_async(file_name, path, table, pool)
    pool.progress.image.total = pool.progress.image.total + 1
    pool.path_table[path] = table

    love.thread.newThread(asset_threads.graphics:format(pool.channels.image, file_name, path, path)):start()
end 

local function load_audio_async(file_name, path, table, pool)
    pool.progress.audio.total = pool.progress.audio.total + 1
    pool.path_table[path] = table

    love.thread.newThread(asset_threads.audio:format(pool.channels.audio, file_name, path, path)):start()
end

local function load_video_async(file_name, path, table, pool)
    pool.progress.video.total = pool.progress.video.total + 1
    pool.path_table[path] = table

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
        },

        path_table = {}
    }

    table.insert(pools, pool)

    return pool
end

----------

local channel_loader = {
    audio = function(audio_pool_progress, channel_name, pool)
        local data = love.thread.getChannel(channel_name):pop()

        while data do
            audio_pool_progress.complete = audio_pool_progress.complete + 1
            pool.path_table[data[3]][data[1]] = data[2]

            data = love.thread.getChannel(channel_name):pop()

            if audio_pool_progress.complete == audio_pool_progress.total then
                return true
            end
        end
    end,

    image = function(image_pool_progress, channel_name, pool)
        local data = love.thread.getChannel(channel_name):pop()

        --making this a while loop will load more per frame, but can freeze the main thread
        if data then
            image_pool_progress.complete = image_pool_progress.complete + 1
            pool.path_table[data[3]][data[1]] = love.graphics.newImage(data[2])

            if image_pool_progress.complete == image_pool_progress.total then
                return true
            end
        end
    end,

    video = function(video_pool_progress, channel_name, pool)
        local data = love.thread.getChannel(channel_name):pop()

        if data then
            video_pool_progress.complete = video_pool_progress.complete + 1
            pool.path_table[data[3]][data[1]] = love.graphics.newVideo(data[2])

            if video_pool_progress.complete == video_pool_progress.total then
                return true
            end
        end
    end
}

local function load_file(file_path, storage, is_async, pool)
    local asset_table = storage

    for folder_name in file_path:gmatch(directory_pattern) do
        asset_table[folder_name] = asset_table[folder_name] or {}
        asset_table = asset_table[folder_name]
    end

    local extension = file_path:match(extension_pattern):lower()
    local file_name = file_path:match(file_name_pattern)

    local load_func = extension_loadfunc[is_async and "async" or "sync"][extension]
    
    if load_func then
        load_func(file_name, file_path, asset_table, pool)
    end
end

local function load_impl(path, storage, is_async, pool)
    local info = love.filesystem.getInfo(path)

    if info then
        if info.type == "file" then
            load_file(path, storage, is_async, pool)
        elseif info.type == "directory" then
            for _, file in pairs(love.filesystem.getDirectoryItems(path)) do
                load_impl(path .. "/" .. file, storage, is_async, pool)
            end
        end
    end
end

local function load_from_table(paths, storage, is_async, pool)
    for _, path in pairs(paths) do
        load_impl(path, storage, is_async, pool)
    end
end

----------

local assets = {}

function assets.update(dt)
    for i = #pools, 1, -1 do
        local pool = pools[i]
        local pool_complete = true

        for channel_type, channel_name in pairs(pool.channels) do
            if pool.progress[channel_type].total == 0 then
                pool.channels[channel_type] = nil
            end

            pool_complete = false

            if channel_loader[channel_type](pool.progress[channel_type], channel_name, pool) then
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

function assets.load(asset, storage, callback)
    if type(asset) == "table" then
        load_from_table(asset, storage, false, nil)
    else
        load_impl(asset, storage, false, nil)
    end

    if callback then
        callback()
    end
end

function assets.load_async(asset, storage, callback)
    local pool = create_pool(callback)

    if type(asset) == "table" then
        load_from_table(asset, storage, true, pool)
    else
        load_impl(asset, storage, true, pool)
    end

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

--[[
	way to add your own custom loaders for your own datatypes
	global resource lookup
	hand them reference of file if it exists instead of reloading asset
	store path_table on pool
	index metamethod for the asset_table with path baked in, so when u unload and nil out the global resource, its gone!
	proceese functions to run callbakc for each specific asset type?? to generate animations or set imageFilter or something
]]
