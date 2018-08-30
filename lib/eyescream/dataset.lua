require 'torch'
require 'image'
require 'paths'

local dataset = {}

dataset.dirs = {}
dataset.fileExtension = ""

dataset.originalScale = 64
dataset.scale = 32
dataset.nbChannels = 3
-- cache for filepaths to all images
dataset.paths = nil

-- Set one or more directories to load images from
-- @param dirs Table of directories, e.g. {"/path/to/images", "/another/path"}
function dataset.setDirs(dirs)
  dataset.dirs = dirs
end

-- Set exactly one file extensions for the images.
-- Only images with that file extension will be loaded from the defined directories.
-- @param fileExtension The file extension, e.g. "jpg"-
function dataset.setFileExtension(fileExtension)
  dataset.fileExtension = fileExtension
end

-- Set the width and height in pixels to which the input images will be scaled.
-- @param scale The desired width/height of the images after scaling, e.g. 32.
function dataset.setScale(scale)
  dataset.scale = scale
end

-- Set the number of channels of your images, so 1 for grayscale or 3 for color.
-- If set to 1 then color images will be converted to grayscale.
-- @param nbChannels Number of channels, e.g. 1 (grayscale) or 3 (color).
function dataset.setNbChannels(nbChannels)
  dataset.nbChannels = nbChannels
end

-- Load images from the dataset.
-- @param startAt Number of the first image.
-- @param count Count of the images to load.
-- @return Table of images. You can call :size() on that table to get the number of loaded images.
function dataset.loadImages(startAt, count)
    local endBefore = startAt + count

    --[[
    local images = dataset.loadImagesFromDirs(dataset.dirs, dataset.fileExtension, startAt, count, true, dataset.scale)
    local data = torch.FloatTensor(#images, dataset.nbChannels, dataset.scale, dataset.scale)
    for i=1, #images do
        data[i] = images[i]
    end
    --]]
    local data = dataset.loadImagesFromDirs(dataset.dirs, dataset.fileExtension, startAt, count, true, dataset.scale)

    local result = {}
    result.data = data
    local N = data:size(1)
    
    function result:size()
        return N
    end

    setmetatable(result, {
        __index = function(self, index) return self.data[index] end,
        __len = function(self) return self.data:size(1) end
    })

    print(string.format('<dataset> loaded %d examples', N))

    return result
end

-- Loads a defined number of randomly selected images from
-- the cached paths (cached in loadPaths()).
-- @param count Number of random images.
-- @return List of Tensors
function dataset.loadRandomImages(count)
    if dataset.paths == nil then
        dataset.loadPaths()
    end

    local shuffle = torch.randperm(#dataset.paths)    
    
    local images = {}
    for i=1,math.min(shuffle:size(1), count) do
       -- load each image
       table.insert(images, image.load(dataset.paths[shuffle[i]], dataset.nbChannels, "float"))
    end
    
    local data = torch.FloatTensor(#images, dataset.nbChannels, dataset.scale, dataset.scale)
    for i=1, #images do
        data[i] = image.scale(images[i], dataset.scale, dataset.scale)
    end

    --local ker = torch.ones(3)
    --local m = nn.SpatialSubtractiveNormalization(1, ker)
    --data = m:forward(data)

    local N = data:size(1)
    local result = {}
    result.scaled = data

    function result:size()
        return N
    end

    setmetatable(result, {__index = function(self, index)
        return self.scaled[index]
    end})

    print(string.format('<dataset> loaded %d random examples', N))

    return result
end

-- Loads the paths of all images in the defined files
-- (with defined file extensions)
function dataset.loadPaths()
    local files = {}
    local dirs = dataset.dirs
    local ext = dataset.fileExtension

    for i=1, #dirs do
        local dir = dirs[i]
        -- Go over all files in directory. We use an iterator, paths.files().
        for file in paths.files(dir) do
            -- We only load files that match the extension
            if file:find(ext .. '$') then
                -- and insert the ones we care about in our table
                table.insert(files, paths.concat(dir,file))
            end
        end

        -- Check files
        if #files == 0 then
            error('given directory doesnt contain any files of type: ' .. ext)
        end
    end
    
    print(string.format("<dataset> Loaded %d filepaths", #files))
    
    dataset.paths = files
end

-- Loads defined range of images of given file extension from one or more directories.
-- @param dirs Tabel of directories.
-- @param ext One file extension as string.
-- @param startAt Number of first image.
-- @param count Count of images to load (max).
-- @param doSort Whether to sort the images before reducing to range [startAt:startAt+count].
-- @param scale Desired height/width of images.
-- @return FloatTensor
function dataset.loadImagesFromDirs(dirs, ext, startAt, count, doSort, scale)
    -- code from: https://github.com/andresy/torch-demos/blob/master/load-data/load-images.lua
    local files = {}

    for i=1, #dirs do
        local dir = dirs[i]
        -- Go over all files in directory. We use an iterator, paths.files().
        for file in paths.files(dir) do
            -- We only load files that match the extension
            if file:find(ext .. '$') then
                -- and insert the ones we care about in our table
                table.insert(files, paths.concat(dir,file))
            end
        end

        -- Check files
        if #files == 0 then
            error('given directory doesnt contain any files of type: ' .. ext)
        end
    end
    
    ----------------------------------------------------------------------
    -- 3. Sort file names

    -- We sort files alphabetically, it's quite simple with table.sort()
    if doSort then
        table.sort(files, function (a,b) return a < b end)
    end

    ----------------------------------------------------------------------
    -- Extract requested files from startAt to startAt+count
    local filesExtracted = {}
    local endAt = math.min(startAt+count-1, #files)
    for i=startAt, endAt do
        filesExtracted[#filesExtracted+1] = files[i]
    end
    
    ----------------------------------------------------------------------
    -- 4. Finally we load images

    -- Go over the file list:
    local images = torch.FloatTensor(#filesExtracted, dataset.nbChannels, scale, scale)
    for i,file in ipairs(filesExtracted) do
        -- load each image
        local img = image.load(file, dataset.nbChannels, "float")
        images[i] = image.scale(img, scale, scale)
        
        if i % 10000 == 0 then
            collectgarbage()
        end
    end
    
    return images
end

return dataset
