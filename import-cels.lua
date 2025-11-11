--[[
Aseprite Script: Imports PNG files named "Frame-X-Layer-Y.png" from a folder,
reconstructs them into a new sprite with proper layers and frames.
]] --

-- ============================================================================
-- FILE SCANNING
-- ============================================================================

local function palettesMatch(pal1, pal2)
    if #pal1 ~= #pal2 then
        return false
    end

    for i = 0, #pal1 - 1 do
        if pal1:getColor(i) ~= pal2:getColor(i) then
            return false
        end
    end

    return true
end

local function scanPngFiles(folderPath)
    local files = {}
    local minFrame = math.huge
    local maxFrame = 0
    local maxWidth = 0
    local maxHeight = 0
    local allIndexed = true
    local firstPalette = nil
    local firstPaletteFile = nil
    local samePalette = true
    local layerGroups = {}
    local mismatchedPaletteFiles = {}

    for _, filename in ipairs(app.fs.listFiles(folderPath)) do
        local fullPath = app.fs.joinPath(folderPath, filename)
        local lowerFilename = filename:lower()

        if lowerFilename:match("%.png$") then
            local frameNum, layerNum = lowerFilename:match("^frame%-(%d+)%-layer%-(%d+)%.png$")

            if frameNum and layerNum then
                local img = Image({ fromFile = fullPath })

                if img then
                    maxWidth = math.max(maxWidth, img.width)
                    maxHeight = math.max(maxHeight, img.height)

                    local frame = tonumber(frameNum)
                    local layer = tonumber(layerNum)

                    if frame then
                        minFrame = math.min(minFrame, frame)
                        maxFrame = math.max(maxFrame, frame)
                    end

                    local palette = nil
                    if img.colorMode ~= ColorMode.INDEXED then
                        allIndexed = false
                        samePalette = false
                    else
                        palette = Palette { fromFile = fullPath }
                        if not firstPalette then
                            firstPalette = palette
                            firstPaletteFile = { frame = frame, layer = layer }
                        elseif not palettesMatch(firstPalette, palette) then
                            samePalette = false
                            table.insert(mismatchedPaletteFiles, { frame = frame, layer = layer })
                        end
                    end

                    local fileData = {
                        path = fullPath,
                        filename = filename,
                        frame = frame,
                        layer = layer,
                        width = img.width,
                        height = img.height,
                        colorMode = img.colorMode,
                        image = img,
                        palette = palette
                    }

                    table.insert(files, fileData)

                    if layer and not layerGroups[layer] then
                        layerGroups[layer] = {
                            layerIndex = layer,
                            cels = {}
                        }
                    end
                    table.insert(layerGroups[layer].cels, fileData)
                end
            end
        end
    end

    local frameOffset = (minFrame == 0) and 1 or 0
    for _, file in ipairs(files) do
        file.frame = file.frame + frameOffset
    end
    maxFrame = maxFrame + frameOffset

    if firstPaletteFile then
        firstPaletteFile.frame = firstPaletteFile.frame + frameOffset
    end

    table.sort(files, function(a, b)
        if a.layer ~= b.layer then
            return a.layer < b.layer
        end
        return a.frame < b.frame
    end)

    local sortedLayers = {}
    for _, group in pairs(layerGroups) do
        table.insert(sortedLayers, group)
    end
    table.sort(sortedLayers, function(a, b)
        return a.layerIndex < b.layerIndex
    end)

    return {
        files = files,
        maxWidth = maxWidth,
        maxHeight = maxHeight,
        maxFrame = maxFrame,
        allIndexed = allIndexed,
        samePalette = samePalette,
        firstPalette = firstPalette,
        firstPaletteFile = firstPaletteFile,
        layerGroups = sortedLayers,
        mismatchedPaletteFiles = mismatchedPaletteFiles
    }
end

-- ============================================================================
-- SPRITE CREATION
-- ============================================================================

local function convertIndexedToRGB(indexedImage, palette)
    local rgbImage = Image(indexedImage.width, indexedImage.height, ColorMode.RGB)

    local colorCache = {}
    for i = 0, #palette - 1 do
        colorCache[i] = palette:getColor(i)
    end

    for y = 0, indexedImage.height - 1 do
        for x = 0, indexedImage.width - 1 do
            local pixelValue = indexedImage:getPixel(x, y)
            rgbImage:drawPixel(x, y, colorCache[pixelValue])
        end
    end

    return rgbImage
end

local function createSpriteFromFiles(scanData)
    local files = scanData.files

    if #files == 0 then
        app.alert("No valid PNG files found.")
        return
    end

    if scanData.maxWidth == 0 or scanData.maxHeight == 0 then
        app.alert("Failed to load any valid images.")
        return
    end

    local useIndexed = scanData.allIndexed and scanData.samePalette
    local colorMode = useIndexed and ColorMode.INDEXED or ColorMode.RGB
    local maxFrame = scanData.maxFrame

    local newSprite = Sprite(scanData.maxWidth, scanData.maxHeight, colorMode)

    if useIndexed and scanData.firstPalette then
        newSprite:setPalette(scanData.firstPalette)
    end

    if maxFrame > 1 then
        for i = 2, maxFrame do
            newSprite:newEmptyFrame()
        end
    end

    if #scanData.layerGroups > 0 and #newSprite.layers > 0 then
        newSprite:deleteLayer(newSprite.layers[1])
    end

    local importCount = 0
    for _, layerGroup in ipairs(scanData.layerGroups) do
        local layer = newSprite:newLayer()
        layer.name = "Layer " .. layerGroup.layerIndex

        for _, file in ipairs(layerGroup.cels) do
            local image = file.image

            if image then
                if colorMode == ColorMode.RGB and image.colorMode == ColorMode.INDEXED then
                    image = convertIndexedToRGB(image, file.palette)
                end

                newSprite:newCel(layer, file.frame, image, Point(0, 0))
                importCount = importCount + 1
            end
        end
    end

    app.activeSprite = newSprite
    app.refresh()

    return importCount, #scanData.layerGroups, maxFrame, colorMode
end

-- ============================================================================
-- UI HELPER FUNCTIONS
-- ============================================================================

local function formatFileList(files, perLine)
    local lines = {}
    for i = 1, #files, perLine do
        local lineItems = {}
        for j = i, math.min(i + perLine - 1, #files) do
            local file = files[j]
            table.insert(lineItems, string.format("F%d-L%d", file.frame, file.layer))
        end
        table.insert(lines, table.concat(lineItems, ", "))
    end
    return lines
end

local function updatePreview(selectedFolder, dlg)
    local scanData = scanPngFiles(selectedFolder)
    local files = scanData.files
    local colorModeText = ""
    local reasonText = ""
    local showAnalysis = #files > 0
    local nonIndexedFiles = {}
    local mismatchedFiles = {}

    if showAnalysis then
        if scanData.allIndexed and scanData.samePalette then
            colorModeText = "Indexed"
            reasonText = "All images are indexed and share same palette"
        elseif not scanData.allIndexed then
            colorModeText = "RGBA"
            for _, file in ipairs(files) do
                if file.colorMode ~= ColorMode.INDEXED then
                    table.insert(nonIndexedFiles, file)
                end
            end
            reasonText = "Some images are not in Indexed color mode:"
        else
            colorModeText = "RGBA"
            mismatchedFiles = scanData.mismatchedPaletteFiles
            reasonText = string.format("Palette mismatch (base: F%d-L%d):",
                scanData.firstPaletteFile.frame,
                scanData.firstPaletteFile.layer)
        end
    end

    dlg:modify({
        id = "file_count",
        text = #files .. " valid PNG file(s) detected in"
    })
    dlg:modify({
        id = "folder_path",
        text = selectedFolder,
        visible = showAnalysis
    })
    dlg:modify({
        id = "sprite_mode",
        text = "Sprite Mode: " .. colorModeText,
        visible = showAnalysis
    })
    dlg:modify({
        id = "reason",
        text = reasonText,
        visible = showAnalysis
    })

    for i = 1, 3 do
        dlg:modify({
            id = "error_line_" .. i,
            visible = false
        })
    end

    local errorFiles = {}
    if #nonIndexedFiles > 0 then
        for i = 1, math.min(20, #nonIndexedFiles) do
            table.insert(errorFiles, nonIndexedFiles[i])
        end
    elseif #mismatchedFiles > 0 then
        for i = 1, math.min(20, #mismatchedFiles) do
            table.insert(errorFiles, mismatchedFiles[i])
        end
    end

    if #errorFiles > 0 then
        local lines = formatFileList(errorFiles, 10)

        for i = 1, math.min(2, #lines) do
            dlg:modify({
                id = "error_line_" .. i,
                text = lines[i],
                visible = true
            })
        end
    end

    local totalErrors = #nonIndexedFiles > 0 and #nonIndexedFiles or #mismatchedFiles
    if totalErrors > 20 then
        dlg:modify({
            id = "error_line_3",
            text = string.format("and %d more", totalErrors - 20),
            visible = true
        })
    end

    dlg:modify({
        id = "import_button",
        enabled = #files > 0,
        text = #files > 0 and ("Import " .. #files .. " File(s)") or "No Valid Files"
    })

    return scanData
end

-- ============================================================================
-- DIALOG CONSTRUCTION
-- ============================================================================

local dlg = Dialog("Import")

local scanData = nil

dlg:separator({ text = "Input Folder" })

dlg:file({
    id = "input_folder",
    onchange = function()
        local data = dlg.data
        if data.input_folder and data.input_folder ~= "" then
            local folderPath = app.fs.filePath(data.input_folder)
            if folderPath == "" then
                folderPath = data.input_folder
            end
            scanData = updatePreview(folderPath, dlg)
        end
    end
})

dlg:separator({
    text = "Folder Analysis",
})

dlg:label({
    id = "file_count",
    text = "No Folder Selected",
})

dlg:newrow()

dlg:label({
    id = "folder_path",
    text = "",
    visible = false
})

dlg:newrow()

dlg:label({
    id = "sprite_mode",
    text = "",
    visible = false
})

dlg:newrow()

dlg:label({
    id = "reason",
    text = "",
    visible = false
})

for i = 1, 3 do
    dlg:newrow()
    dlg:label({
        id = "error_line_" .. i,
        text = "",
        visible = false
    })
end

dlg:separator({ text = "Info" })

dlg:label({
    text = "Only png files matching Frame-X-Layer-Y.png will be imported"
})

dlg:separator()

dlg:button({
    id = "import_button",
    text = "No Valid Files",
    enabled = false,
    onclick = function()
        if scanData then
            local celCount, layers, frames, colorMode = createSpriteFromFiles(scanData)

            if celCount then
                local colorModeText = (colorMode == ColorMode.RGB) and "RGBA" or "Indexed"
                app.alert({
                    title = "Import Complete",
                    text = {
                        "Successfully imported " .. celCount .. " cel(s)",
                        "Layers: " .. layers,
                        "Frames: " .. frames,
                        "Color Mode: " .. colorModeText
                    }
                })
                dlg:close()
            end
        end
    end
})

dlg:button({ text = "Cancel" })

dlg:show()
