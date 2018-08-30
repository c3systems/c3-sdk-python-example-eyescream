require 'torch'

local nn_utils = {}

-- Sets the weights of a layer to random values within a range.
-- @param weights The weights module to change, e.g. mlp.modules[1].weight.
-- @param range Range for the new values (single number, e.g. 0.005)
function nn_utils.setWeights(weights, range)
    weights:randn(weights:size())
    weights:mul(range)
end

-- Initializes all weights of a multi layer network.
-- @param model The nn.Sequential() model with one or more layers
-- @param rangeWeights A range for the new weights values (single number, e.g. 0.005)
-- @param rangeBias A range for the new bias values (single number, e.g. 0.005)
function nn_utils.initializeWeights(model, rangeWeights, rangeBias)
    rangeWeights = rangeWeights or 0.005
    rangeBias = rangeBias or 0.001
    
    for m = 1, #model.modules do
        if model.modules[m].weight then
            nn_utils.setWeights(model.modules[m].weight, rangeWeights)
        end
        if model.modules[m].bias then
            nn_utils.setWeights(model.modules[m].bias, rangeBias)
        end
    end
end

-- Creates a tensor of N vectors, each of dimension OPT.noiseDim with random values
-- between -1 and +1.
-- @param N Number of vectors to generate
-- @returns Tensor of shape (N, OPT.noiseDim)
function nn_utils.createNoiseInputs(N)
    local noiseInputs = torch.Tensor(N, OPT.noiseDim)
    noiseInputs:uniform(-1.0, 1.0)
    return noiseInputs
end

-- Feeds noise vectors into G or AE+G and returns the result.
-- @param noiseInputs Tensor from createNoiseInputs()
-- @param outputAsList Whether to return the images as one list or as a tensor.
-- @returns Either list of images (as returned by G/AE) or tensor of images
function nn_utils.createImagesFromNoise(noiseInputs, outputAsList)
    local images
    local N = noiseInputs:size(1)
    local nBatches = math.ceil(N/OPT.batchSize)
    for i=1,nBatches do
        local batchStart = 1 + (i-1)*OPT.batchSize
        local batchEnd = math.min(i*OPT.batchSize, N)
        local generated = MODEL_G:forward(noiseInputs[{{batchStart, batchEnd}}]):clone()
        if images == nil then
            local img = generated[1]
            images = torch.Tensor(N, img:size(1), img:size(2), img:size(3))
        end
        images[{{batchStart, batchEnd}, {}, {}, {}}] = generated
    end
    
    if outputAsList then
        local imagesList = {}
        for i=1, images:size(1) do
            imagesList[#imagesList+1] = images[i]
        end
        return imagesList
    else
        return images
    end
end

-- Creates new random images with G or AE+G.
-- @param N Number of images to create.
-- @param outputAsList Whether to return the images as one list or as a tensor.
-- @param refineWithG Whether to allow AE+G or just AE (if AE was defined)
-- @returns Either list of images (as returned by G/AE) or tensor of images
function nn_utils.createImages(N, outputAsList, refineWithG)
    return nn_utils.createImagesFromNoise(nn_utils.createNoiseInputs(N), outputAsList, refineWithG)
end

-- Sorts images based on D's certainty that they are fake/real.
-- Descending order starts at y=1 (Y_NOT_GENERATOR) and ends with y=0 (Y_GENERATOR).
-- Therefore, in case of descending order, images for which D is very certain that they are real
-- come first and images that seem to be fake (according to D) come last.
-- @param images The images to sort. (Tensor)
-- @param ascending If true then images that seem most fake to D are placed at the start of the list.
--                  Otherwise the list starts with probably real images.
-- @param nbMaxOut Sets how many images may be returned max (cant be more images than provided).
-- @return Tuple (list of images, list of predictions between 0.0 and 1.0)
--                                where 1.0 means "probably real"
function nn_utils.sortImagesByPrediction(images, ascending, nbMaxOut)
    local predictions = torch.Tensor(images:size(1), 1)
    local nBatches = math.ceil(images:size(1)/OPT.batchSize)
    for i=1,nBatches do
        local batchStart = 1 + (i-1)*OPT.batchSize
        local batchEnd = math.min(i*OPT.batchSize, images:size(1))
        predictions[{{batchStart, batchEnd}, {1}}] = MODEL_D:forward(images[{{batchStart, batchEnd}, {}, {}, {}}])
    end
    
    local imagesWithPreds = {}
    for i=1,images:size(1) do
        imagesWithPreds[i] = {images[i], predictions[i][1]}
    end
    
    if ascending then
        table.sort(imagesWithPreds, function (a,b) return a[2] < b[2] end)
    else
        table.sort(imagesWithPreds, function (a,b) return a[2] > b[2] end)
    end
    
    local resultImages = {}
    local resultPredictions = {}
    for i=1,math.min(nbMaxOut,#imagesWithPreds) do
        resultImages[i] = imagesWithPreds[i][1]
        resultPredictions[i] = imagesWithPreds[i][2]
    end
    
    return resultImages, resultPredictions
end

-- Visualizes the current training status via Display (based on gfx.js) in the browser.
-- It shows:
--   Images generated from random noise (the noise vectors are set once at the start of the
--   training, so the images should end up similar at each epoch)
--   Images that were deemed "good" by D
--   Images that were deemed "bad" by D
--   Original images from the training set (as comparison)
--   If an Autoencoder is defined, it will show the results of that network (before G is applied
--   as refiner).
-- @param noiseInputs The noise vectors for the random images.
-- @returns void
function nn_utils.visualizeProgress(noiseInputs)
    -- deactivate dropout
    nn_utils.switchToEvaluationMode()
    
    -- Generate images from G based on the provided noiseInputs
    -- If an autoencoder is defined, the images will be first generated by the autoencoder
    -- and then refined by G
    local semiRandomImagesUnrefined
    if MODEL_AE then
        semiRandomImagesUnrefined = nn_utils.createImagesFromNoise(noiseInputs, true, false)
    end
    local semiRandomImagesRefined = nn_utils.createImagesFromNoise(noiseInputs, true, true)
    
    -- denoise
    local diList = {}
    if DENOISER ~= nil then
        local batch = torch.Tensor(#semiRandomImagesRefined, IMG_DIMENSIONS[1], IMG_DIMENSIONS[2], IMG_DIMENSIONS[3])
        for i=1,#semiRandomImagesRefined do
            batch[i] = semiRandomImagesRefined[i]:clone()
        end
        local denoisedImages = DENOISER:forward(batch)
        for i=1,denoisedImages:size(1) do
            table.insert(diList, denoisedImages[i]:clone())
        end
    end
    
    -- Generate a synthetic test image as sanity test
    -- This should be deemed very bad by D
    local sanityTestImage = torch.Tensor(IMG_DIMENSIONS[1], IMG_DIMENSIONS[2], IMG_DIMENSIONS[3])
    sanityTestImage:uniform(0.0, 0.50)
    for i=1,OPT.scale do
        for j=1,OPT.scale do
            if i == j then
                sanityTestImage[1][i][j] = 1.0
            elseif i % 4 == 0 and j % 4 == 0 then
                sanityTestImage[1][i][j] = 0.5
            end
        end
    end
    
    -- Collect original example images from the training set
    local trainImages = torch.Tensor(100, IMG_DIMENSIONS[1], IMG_DIMENSIONS[2], IMG_DIMENSIONS[3])
    for i=1,100 do
        trainImages[i] = TRAIN_DATA[i]
    end
    
    -- Create random images images, they will split into good and bad images
    local randomImages = nn_utils.createImages(300, false)
    
    -- Place the sanity test image and one original image from the training corpus among
    -- the random Images. The first should be deemed bad by D, the latter as good.
    randomImages[299] = TRAIN_DATA[1] -- one real face as sanity test
    randomImages[300] = sanityTestImage -- synthetic non-face as sanity test
    
    -- find bad images (according to D) among the randomly generated ones
    local badImages, _ = nn_utils.sortImagesByPrediction(randomImages, true, 50)
    
    -- find good images (according to D) among the randomly generated ones
    local goodImages, _ = nn_utils.sortImagesByPrediction(randomImages, false, 50)

    --if semiRandomImagesUnrefined then
        --DISP.image(semiRandomImagesUnrefined, {win=OPT.window, width=IMG_DIMENSIONS[3]*15, title="semi-random generated images (before G)"})
    --end
    --DISP.image(semiRandomImagesRefined, {win=OPT.window+1, width=IMG_DIMENSIONS[3]*15, title="semi-random generated images (after G)"})
    --if #diList > 0 then
        --DISP.image(diList, {win=OPT.window+2, width=IMG_DIMENSIONS[3]*15, title="images by G, denoised"})
    --end
    --DISP.image(goodImages, {win=OPT.window+3, width=IMG_DIMENSIONS[3]*15, title="best samples (first is best)"})
    --DISP.image(badImages, {win=OPT.window+4, width=IMG_DIMENSIONS[3]*15, title="worst samples (first is worst)"})
    --DISP.image(trainImages, {win=OPT.window+5, width=IMG_DIMENSIONS[3]*15, title="original images from training set"})
    
    -- reactivate dropout
    nn_utils.switchToTrainingMode()
end

-- Switch networks to training mode (activate Dropout)
function nn_utils.switchToTrainingMode()
    if MODEL_AE then
        MODEL_AE:training()
    end
    MODEL_G:training()
    MODEL_D:training()
end

-- Switch networks to evaluation mode (deactivate Dropout)
function nn_utils.switchToEvaluationMode()
    if MODEL_AE then
        MODEL_AE:evaluate()
    end
    MODEL_G:evaluate()
    MODEL_D:evaluate()
end

--[[
function nn_utils.prepareNetworkForSave(net)
    local modules = net:listModules()
    for i=1,#modules do
        local m = modules[i]
        if m.output then
            m.output = torch.Tensor()
            print(i, "Resetting m.output")
        else
            print(i, "Not setting m.output")
        end
        if m.gradInput then
            m.gradInput = torch.Tensor()
            print(i, "Resetting m.gradInput")
        else
            print(i, "Not setting m.gradInput")
        end
    end
end
--]]

-- from https://github.com/torch/DEPRECEATED-torch7-distro/issues/47
function nn_utils.zeroDataSize(data)
    if type(data) == 'table' then
        for i = 1, #data do
            data[i] = nn_utils.zeroDataSize(data[i])
        end
    elseif type(data) == 'userdata' then
        data = torch.Tensor():typeAs(data)
    end
    return data
end

-- from https://github.com/torch/DEPRECEATED-torch7-distro/issues/47
-- Resize the output, gradInput, etc temporary tensors to zero (so that the on disk size is smaller)
function nn_utils.prepareNetworkForSave(node)
    if node.output ~= nil then
        node.output = nn_utils.zeroDataSize(node.output)
    end
    if node.gradInput ~= nil then
        node.gradInput = nn_utils.zeroDataSize(node.gradInput)
    end
    if node.finput ~= nil then
        node.finput = nn_utils.zeroDataSize(node.finput)
    end
    -- Recurse on nodes with 'modules'
    if (node.modules ~= nil) then
        if (type(node.modules) == 'table') then
            for i = 1, #node.modules do
                local child = node.modules[i]
                nn_utils.prepareNetworkForSave(child)
            end
        end
    end
    collectgarbage()
end

function nn_utils.getNumberOfParameters(net)
    local nparams = 0
    local dModules = net:listModules()
    for i=1,#dModules do
        if dModules[i].weight ~= nil then
            nparams = nparams + dModules[i].weight:nElement()
        end
    end
    return nparams
end

function nn_utils.deactivateCuda(net)
    -- transferring to float first, so that the clone does not happen on the gpu (can cause
    -- out of memory otherwise)
    --[[
    print("A", torch.type(net), torch.type(net:get(1)))
    net:float()
    local newNet = net:clone()
    net:cuda()
    print("B", torch.type(net), torch.type(net:get(1)))
    if torch.type(newNet:get(1)) == 'nn.Copy' then
        return newNet:get(2)
    else
        return newNet
    end
    --]]
    
    if isInCudaMode(net) then
        -- [1] Copy
        -- [2] Sequential (the network)
        -- [3] Copy
        -- transferring to float first, so that the clone does not happen on the gpu (can cause
        -- out of memory otherwise)
        net:get(2):float()
        local newNet = net:clone()
        net:get(2):cuda()
        return newNet:get(2)
    else
        return net:clone()
    end
end

-- Activates CUDA mode on a network and returns the result.
-- This adds Copy layers at the start and end of the network.
-- Expects the default tensor to be FloatTensor.
-- @param net The network to activate CUDA mode on.
-- @returns The CUDA network
function nn_utils.activateCuda(net)
    --[[
    local newNet = net:clone()
    newNet:cuda()
    local tmp = nn.Sequential()
    tmp:add(nn.Copy('torch.FloatTensor', 'torch.CudaTensor'))
    tmp:add(newNet)
    tmp:add(nn.Copy('torch.CudaTensor', 'torch.FloatTensor'))
    return tmp
    --]]
    
    -- does the network already contain any copy layers?
    local containsCopyLayers = false
    local modules = net:listModules()
    for i=1,#modules do
        local t = torch.type(modules[i])
        if string.find(t, "Copy") ~= nil then
            containsCopyLayers = true
            break
        end
    end
    
    -- no copy layers in the network yet
    -- add them at the start and end
    if containsCopyLayers then
        return net
    else
        local newNet = net:clone()
        local tmp = nn.Sequential()
        tmp:add(nn.Copy('torch.FloatTensor', 'torch.CudaTensor'))
        tmp:add(newNet)
        tmp:add(nn.Copy('torch.CudaTensor', 'torch.FloatTensor'))
        newNet:cuda()
        newNet = tmp
        return newNet
    end
    
    --[[
    local firstCopyFound = false
    local lastCopyFound = false
    modules = newNet:listModules()
    for i=1,#modules do
        local t = torch.type(modules[i])
        if string.find(t, "Copy") ~= nil then
            if not firstCopyFound then
                firstCopyFound = true
                modules[i]:cuda()
                modules[i].intype = 'torch.FloatTensor'
                modules[i].outtype = 'torch.CudaTensor'
            else
                -- last copy found
                lastCopyFound = true
                modules[i]:float()
                modules[i].intype = 'torch.CudaTensor'
                modules[i].outtype = 'torch.FloatTensor'
            end
        elseif lastCopyFound then
            modules[i]:float()
        elseif firstCopyFound then
            modules[i]:cuda()
        else
            modules[i]:float()
        end
    end
    --]]
    
    return newNet
end

function isInCudaMode(net)
    -- TODO is there a function in cunn to check if :cuda() has been called on a sequential?
    local l1 = net:get(1)
    local l2 = net:get(2)
    local l3 = net:get(3)
    return torch.type(l1) == 'nn.Copy' and torch.type(l2) == 'nn.Sequential' and torch.type(l3) == 'nn.Copy'
end

return nn_utils
