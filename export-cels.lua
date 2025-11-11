--[[
Aseprite Script: Exports each cel from the active sprite as an individual PNG file
named using the format "Frame-X-Layer-Y.png".
]] --

-- ============================================================================
-- INITIALIZATION & VALIDATION
-- ============================================================================

local sprite = app.activeSprite
if not sprite then
    app.alert({
        title = "No Active Sprite",
        text = "Please select an sprite before running this script."
    })
    return
end
local basePath = sprite.filename
if sprite.isModified or not basePath:match("[/\\]") then
    app.alert({
        title = "Unsaved Changes",
        text = "Please save the sprite before exporting."
    })
    return
end
local outputFolder = app.fs.joinPath(
    app.fs.filePath(basePath),
    app.fs.fileTitle(basePath)
)

-- ============================================================================
-- CEL VALIDATION FUNCTIONS
-- ============================================================================

local function checkValidCel(cel)
    local hasValidPixels = false
    local paletteGroupId = nil
    for it in cel.image:pixels() do
        local colorIndex = it()
        if colorIndex % 16 ~= 0 then
            hasValidPixels = true
            local groupId = math.floor(colorIndex / 16) + 1
            if not paletteGroupId then
                paletteGroupId = groupId
            elseif paletteGroupId ~= groupId then
                return nil, hasValidPixels
            end
        end
    end
    return paletteGroupId, hasValidPixels
end
local function scanCels()
    local allCels = {}
    local multiPalCels = {}

    for _, layer in ipairs(sprite.layers) do
        if not layer.name:match("^Palette%-Mask") then
            for _, cel in ipairs(layer.cels) do
                local paletteGroupId, hasValidPixels = checkValidCel(cel)
                if hasValidPixels then
                    local celData = {
                        layer = layer,
                        cel = cel,
                        layerIndex = layer.stackIndex,
                        frame = cel.frameNumber
                    }
                    table.insert(allCels, celData)

                    if not paletteGroupId then
                        table.insert(multiPalCels, celData)
                    end
                end
            end
        end
    end
    return allCels, multiPalCels
end

-- ============================================================================
-- MASK INVALID FUNCTION
-- ============================================================================

local function maskMultiPalCels(multiPalCels)
    app.transaction(function()
        for _, celData in ipairs(multiPalCels) do
            local originalCel = celData.cel
            local frameNumber = celData.frame
            local layerName = celData.layer.name

            local maskLayerName = string.format(
                "Palette-Mask-L%d-%s",
                celData.layerIndex,
                layerName
            )

            local maskLayer = nil
            for _, layer in ipairs(sprite.layers) do
                if layer.name == maskLayerName then
                    maskLayer = layer
                    break
                end
            end

            if not maskLayer then
                maskLayer = sprite:newLayer()
                maskLayer.name = maskLayerName
            end

            local maskImage = Image(sprite.width, sprite.height, sprite.colorMode)
            for it in originalCel.image:pixels() do
                local colorIndex = it()
                if colorIndex % 16 ~= 0 then
                    local groupId = math.floor(colorIndex / 16) + 1
                    local maskColorIndex = ((groupId - 1) % 15) + 1
                    local x = it.x + originalCel.position.x
                    local y = it.y + originalCel.position.y
                    if x >= 0 and x < sprite.width and y >= 0 and y < sprite.height then
                        maskImage:drawPixel(x, y, maskColorIndex)
                    end
                end
            end

            local existingCel = maskLayer:cel(frameNumber)
            if existingCel then
                sprite:deleteCel(existingCel)
            end

            sprite:newCel(maskLayer, frameNumber, maskImage, Point(0, 0))
        end
    end)
    app.alert({
        title = "Masking Complete",
        text = string.format("Created palette mask layers for %d multi palette cels.", #multiPalCels)
    })
end

-- ============================================================================
-- EXPORT FUNCTIONS
-- ============================================================================

local function exportCel(celData)
    local layer = celData.layer
    local cel = celData.cel
    local newSprite = Sprite(sprite.width, sprite.height, sprite.colorMode)
    newSprite:setPalette(sprite.palettes[1])
    newSprite:newCel(newSprite.layers[1], 1, cel.image, cel.position)
    local filename = app.fs.joinPath(
        outputFolder,
        string.format(
            "Frame-%d-Layer-%d.png",
            cel.frameNumber,
            layer.stackIndex
        )
    )
    newSprite:saveCopyAs(filename)
    newSprite:close()
    return true
end
local function exportAllCels(singlePalCels)
    local exportedCount = 0
    for _, celData in ipairs(singlePalCels) do
        if exportCel(celData) then
            exportedCount = exportedCount + 1
        end
    end
    return exportedCount
end

-- ============================================================================
-- UI HELPER FUNCTIONS
-- ============================================================================

local function createCelList(cels, perLine, maxCels)
    local lines = {}
    local limit = math.min(#cels, maxCels)
    for i = 1, limit, perLine do
        local lineItems = {}
        for j = i, math.min(i + perLine - 1, limit) do
            local cel = cels[j]
            table.insert(lineItems, string.format("F%d-L%d", cel.frame, cel.layerIndex))
        end
        table.insert(lines, table.concat(lineItems, ", "))
    end
    return lines
end

local function getColorModeName(colorMode)
    if colorMode == ColorMode.RGB then
        return "RGB"
    elseif colorMode == ColorMode.GRAYSCALE then
        return "Grayscale"
    elseif colorMode == ColorMode.INDEXED then
        return "Indexed"
    else
        return "Unknown"
    end
end

-- ============================================================================
-- DIALOG CONSTRUCTION
-- ============================================================================

local palette = sprite.palettes[1]
local colorCount = #palette
local allCels, multiPalCels = scanCels()
local totalCelCount = #allCels
local multiPalCelCount = #multiPalCels
local singlePalCelCount = totalCelCount - multiPalCelCount
local dlg = Dialog("Export")
dlg:separator({ text = "Output Folder" })
dlg:label({ text = outputFolder })
dlg:separator({ text = "Sprite Analysis" })
dlg:label({
    text = string.format("Color Mode: %s", getColorModeName(sprite.colorMode))
})
dlg:label({
    text = string.format("Palette Colors: %d", colorCount)
})
dlg:separator({ text = "Cel Analysis" })
dlg:label({
    text = string.format("Single Palette: %d | Multi Palette: %d", singlePalCelCount, multiPalCelCount)
})
if multiPalCelCount > 0 then
    dlg:newrow()
    dlg:label({ text = "Multi Palette Cels:" })

    local multiPalLines = createCelList(multiPalCels, 10, 20)

    for i = 1, math.min(2, #multiPalLines) do
        dlg:newrow()
        dlg:label({ text = multiPalLines[i] })
    end

    if multiPalCelCount > 20 then
        dlg:newrow()
        dlg:label({ text = string.format("and %d more", multiPalCelCount - 20) })
    end
end

dlg:separator({ text = "Info" })

dlg:label({
    text = "Images will be exported in the format: Frame-X-Layer-Y.png"
})

dlg:separator()
dlg:button({
    text = totalCelCount > 0 and ("Export " .. totalCelCount .. " Cels") or "No Valid Cels",
    enabled = totalCelCount > 0,
    onclick = function()
        local exportedCount = exportAllCels(allCels)
        app.alert({
            title = "Export Complete",
            text = {
                "Successfully exported " .. exportedCount .. " cels.",
                "Location: " .. outputFolder
            }
        })
        dlg:close()
    end
})
dlg:button({
    text = "Mask Multi Palette",
    enabled = multiPalCelCount > 0,
    onclick = function()
        maskMultiPalCels(multiPalCels)
    end
})
dlg:button({ text = "Cancel" })
dlg:show()