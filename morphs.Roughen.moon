export script_name = "Roughen"
export script_description = "Adds roughening to shapes"
export script_author = "Animorphs"
export script_version = "1.0"
export script_namespace = "morphs.roughen"

LineCollection = require "a-mo.LineCollection"
ASS = require "l0.ASSFoundation"
ILL = require "ILL.ILL"

topLeftAlign = ASS\createTag "align", 7

roughenTemplate = {
    { class: "label",     x: 0, y: 0, label: "Size (px):" },
    { class: "floatedit", x: 1, y: 0, hint: "Roughening strength in pixels", value: 2, min: 0.1, max: 1000, step: 0.1, name: "size" },
    { class: "label",     x: 0, y: 1, label: "Detail:" },
    { class: "intedit",   x: 1, y: 1, hint: "Detail level (1-100)", value: 10, min: 1, max: 100, step: 1, name: "detail" },
    { class: "checkbox",  x: 0, y: 2, width: 4, height: 1, label: "Comment original", value: false, name: "keep_recipe_line", hint: "Comments the original line, appends a {roughen(size,detail)} note, and inserts the roughened result below." },
    { class: "checkbox",  x: 0, y: 3, width: 4, height: 1, label: "Vary detail by timestamp group", value: false, name: "sync_timestamps", hint: "Lines with the same start and end times use the same values, while different timestamp groups will use slightly varied values." },
}

createGUI = ->
    btn, res = aegisub.dialog.display roughenTemplate, {"OK", "Cancel"}, {"ok": "OK", "cancel": "Cancel"}
    aegisub.cancel! unless btn

    for key, value in pairs res
        for i = 1, #roughenTemplate
            configEntry = roughenTemplate[i]
            continue unless configEntry.name == key
            if configEntry.value != nil
                configEntry.value = value
            elseif configEntry.text != nil
                configEntry.text = value
            break
    res

detailToTolerance = (detail) ->
    minTol = 0.5
    maxTol = 50
    t = (detail - 1) / 99
    return maxTol * math.exp(t * math.log(minTol / maxTol))

roughenPoint = (rad) ->
    return (px, py) ->
        return px + (math.random! * 2 - 1) * rad, py + (math.random! * 2 - 1) * rad

timestampKey = (line) ->
    return tostring(line.start_time) .. "|" .. tostring(line.end_time)

detailForTimestamp = (baseDetail, key, detailMap) ->
    offset = detailMap[key]
    unless offset
        offset = detailMap.__nextOffset or 0.01
        detailMap[key] = offset
        detailMap.__nextOffset = offset + 0.01
        if detailMap.__nextOffset > 0.99
            detailMap.__nextOffset = 0.01
    detail = baseDetail + offset
    if detail > 100
        detail = baseDetail - offset
    if detail < 1
        detail = baseDetail + offset
    return detail

normalizeTextAlignmentToTopLeft = (data) ->
    pos, align, org = data\getPosition!
    return unless pos and align
    return if topLeftAlign\equal align

    metrics = data\getTextMetrics true
    width, height = metrics.width, metrics.height
    pos\add topLeftAlign\getPositionOffset width, height, align

    effTags = data\getEffectiveTags -1, true, true, false
    trans, tags = effTags\checkTransformed!, effTags.tags
    if tags.angle\modEq(0, 360) and tags.angle_x\modEq(0, 360) and tags.angle_y\modEq(0, 360) and not (trans.angle or trans.angle_x or trans.angle_y)
        data\replaceTags {topLeftAlign, pos}
    elseif org
        data\replaceTags {topLeftAlign, pos, org}
    else
        data\replaceTags {topLeftAlign, pos}

cloneLine = (line) ->
    copy = {}
    for key, value in pairs line
        copy[key] = value
    copy

appendRecipeNote = (text, size, detail) ->
    recipe = "{roughen(#{string.format "%g", size},#{string.format "%g", detail})}"
    return recipe if not text or text == ""
    return text .. recipe if text\match "%s$"
    return text .. " " .. recipe

roughen = (shape, res, seed) ->
    tolerance = detailToTolerance res.detail
    
    math.randomseed seed
    
    path = ILL.Path(shape)\flatten(tolerance, true)
        
    if res.size > 0
        path = path\map(roughenPoint(res.size))
    
    return path\export!

main = (sub, sel) ->
    res = createGUI!
    lineCnt = #sel
    return if lineCnt == 0

    timestampDetailMap = {}
    
    for reverseIndex = lineCnt, 1, -1
        aegisub.cancel! if aegisub.progress.is_cancelled!
        i = lineCnt - reverseIndex + 1
        idx = sel[reverseIndex]
        rawLine = sub[idx]
        lineCollection = LineCollection sub, {idx}
        line = lineCollection.lines[1]
        aegisub.cancel! if aegisub.progress.is_cancelled!
        aegisub.progress.task "Processing line %d of %d lines..."\format i, lineCnt if i % 10 == 0
        aegisub.progress.set 100 * i / lineCnt

        originalLine = cloneLine rawLine
        data = ASS\parse line
        local shape
        
        if data\getSectionCount(ASS.Section.Drawing) > 0
            data\callback ((section) -> shape = section\toString!), ASS.Section.Drawing
        elseif data\getSectionCount(ASS.Section.Text) > 0
            normalizeTextAlignmentToTopLeft data
            data\callback ((section) ->
                extents, bbox, shape = section\getTextMetrics true
                shape = shape\gsub " c", ""
            ), ASS.Section.Text
        else
            aegisub.log "No text or drawing in the line.\n"
            aegisub.cancel!

        detail = res.detail
        if res.sync_timestamps
            key = timestampKey line
            detail = detailForTimestamp res.detail, key, timestampDetailMap

        seed = 0
        for j = 1, #shape
            seed = seed + shape\byte(j)
        seed = seed + res.size * 1000 + detail * 100
        seed = math.floor(seed + 0.5)

        local_res = {
            size: res.size
            detail: detail
        }

        shape = roughen(shape, local_res, seed)
        
        drawing = ASS.Draw.DrawingBase{str: shape}
        data\removeSections 2, #data.sections
        data\insertSections ASS.Section.Drawing {drawing}
        data\removeTags {"fontname", "fontsize", "italic", "bold", "underline", "strikeout", "spacing"}
        data\replaceTags {ASS\createTag 'scale_x', 100}
        data\replaceTags {ASS\createTag 'scale_y', 100}
        
        data\commit!
        line\createRaw!

        if res.keep_recipe_line
            recipeLine = cloneLine originalLine
            recipeLine.comment = true
            recipeLine.text = appendRecipeNote recipeLine.text, res.size, detail

            roughenedLine = cloneLine line
            roughenedLine.comment = false

            sub[idx] = recipeLine
            sub.insert idx + 1, roughenedLine
        else
            sub[idx] = line

aegisub.register_macro script_author .. "/" .. script_name, script_description, main
