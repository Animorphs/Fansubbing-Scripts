script_name = "Terminology Fixer"
script_description = "Fix names and other terminology"
script_version = "1.0"
script_author = "Animorphs"

local function get_user_path()
    local config_pre = aegisub.decode_path("?user")
    local psep = config_pre:match("\\") and "\\" or "/"
    return config_pre, psep
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local data = f:read("*all")
    f:close()
    return data
end

local function write_file(path, data)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

local function is_array(t)
    local n = 0
    for k, _ in pairs(t) do
        if type(k) ~= "number" then return false end
        if k > n then n = k end
    end
    for i = 1, n do
        if t[i] == nil then return false end
    end
    return true
end

local function sorted_keys(t)
    local keys = {}
    for k, _ in pairs(t) do
        keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b)
        return tostring(a):lower() < tostring(b):lower()
    end)
    return keys
end

local function serialize_value(v, indent)
    indent = indent or ""
    local t = type(v)
    if t == "table" then
        local out = {"{\n"}
        if is_array(v) then
            for i = 1, #v do
                out[#out + 1] = indent .. "    " .. serialize_value(v[i], indent .. "    ") .. ",\n"
            end
        else
            for _, k in ipairs(sorted_keys(v)) do
                local val = v[k]
                local key
                if type(k) == "string" then
                    key = string.format("[%q]", k)
                else
                    key = string.format("[%s]", tostring(k))
                end
                out[#out + 1] = indent .. "    " .. key .. " = " .. serialize_value(val, indent .. "    ") .. ",\n"
            end
        end
        out[#out + 1] = indent .. "}"
        return table.concat(out)
    elseif t == "string" then
        return string.format("%q", v)
    elseif t == "number" or t == "boolean" then
        return tostring(v)
    else
        return "nil"
    end
end

local function table_to_file(path, tbl)
    local data = "return " .. serialize_value(tbl) .. "\n"
    return write_file(path, data)
end

local function table_from_file(path)
    local data = read_file(path)
    if not data then return nil end
    local chunk, err = loadstring(data)
    if err then
        aegisub.log(err)
        return nil
    end
    return chunk()
end

local function default_config()
    return {
        shows = {},
        last_show = nil,
        flag_honorifics = false,
        whole_word = true,
        mapping_op = "->"
    }
end

local function get_config_path()
    local base, psep = get_user_path()
    return base .. psep .. "term-fixer-shows.config"
end

local function load_config()
    local path = get_config_path()
    local raw = table_from_file(path)
    local def = default_config()
    local cfg
    if type(raw) ~= "table" then
        cfg = def
        table_to_file(path, cfg)
        return cfg
    end
    cfg = raw
    if type(cfg.shows) ~= "table" then cfg.shows = {} end
    if cfg.last_show == nil then cfg.last_show = def.last_show end
    if cfg.flag_honorifics == nil then cfg.flag_honorifics = def.flag_honorifics end
    if cfg.whole_word == nil then cfg.whole_word = def.whole_word end
    if cfg.mapping_op == nil then cfg.mapping_op = def.mapping_op end
    return cfg
end

local function save_config(cfg)
    local path = get_config_path()
    -- Normalize for stable ordering and de-duplication
    local normalized = {
        shows = {},
        last_show = cfg.last_show,
        flag_honorifics = cfg.flag_honorifics,
        whole_word = cfg.whole_word,
        mapping_op = cfg.mapping_op
    }
    for _, show in ipairs(sorted_keys(cfg.shows or {})) do
        local rep = cfg.shows[show] or {}
        local cleaned = {}
        for _, k in ipairs(sorted_keys(rep)) do
            cleaned[k] = rep[k]
        end
        normalized.shows[show] = cleaned
    end
    table_to_file(path, normalized)
end

local HONORIFIC_TERMS = {
    "-kun", "-chan", "-san", "-sama", "-dono",
    "-nee", "onee", "neesama", "neechan", "neesan",
    "-nii", "onii", "niisama", "niichan", "niisan",
    "sensei", "senpai"
}

local EXAMPLE_OLD = "example old terminology"
local EXAMPLE_NEW = "example new terminology"

local function escape_lua_pattern(s)
    return (s:gsub("([%%%^%$%(%)%.%[%]%*%+%-%?])", "%%%1"))
end

local function to_ci_pattern(s)
    local escaped = escape_lua_pattern(s)
    return (escaped:gsub("%a", function(c)
        return string.format("[%s%s]", c:lower(), c:upper())
    end))
end

local function serialize_replacements(tbl, op)
    local lines = {}
    for old, new in pairs(tbl or {}) do
        lines[#lines + 1] = old .. " " .. op .. " " .. new
    end
    table.sort(lines, function(a, b)
        return a:lower() < b:lower()
    end)
    return table.concat(lines, "\n")
end

local function parse_replacements(text, op)
    local replacements = {}
    local op_pat = escape_lua_pattern(op)
    for line in (text or ""):gmatch("[^\r\n]+") do
        local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed ~= "" then
            local old, new = trimmed:match("^(.-)%s*" .. op_pat .. "%s*(.-)%s*$")
            if old and new and old ~= "" then
                replacements[old] = new
            end
        end
    end
    return replacements
end

local function validate_replacements(text, op)
    local errors = {}
    local line_no = 0
    local op_pat = escape_lua_pattern(op)
    for line in (text or ""):gmatch("[^\r\n]+") do
        line_no = line_no + 1
        local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed ~= "" then
            local old, new = trimmed:match("^(.-)%s*" .. op_pat .. "%s*(.-)%s*$")
            if not old or not new or old == "" or new == "" then
                errors[#errors + 1] = "Line " .. line_no .. ": Incorrect syntax. Each line must be \"term1 " .. op .. " term2\".\n\tCurrent line: " .. trimmed .. "\n"
            elseif old == new then
                errors[#errors + 1] = "Line " .. line_no .. ": Identical terms defined. \n\tCurrent line: " .. trimmed .. "\n"
            end
        end
    end
    return #errors == 0, errors
end

local function get_show_names(cfg)
    local names = {}
    for show_name, _ in pairs(cfg.shows or {}) do
        names[#names + 1] = show_name
    end
    table.sort(names)
    return names
end

local function get_initial_show(cfg)
    local last = cfg.last_show
    if last and last ~= "" and cfg.shows and cfg.shows[last] then
        return last
    end
    local names = get_show_names(cfg)
    return names[1]
end

local function apply_replacements(subs, replacements, whole_word)
    local count = 0
    for i, line in ipairs(subs) do
        if line.class == "dialogue" then
            local original_text = line.text
            local modified_text = original_text

            for old, new in pairs(replacements) do
                local pat = to_ci_pattern(old)
                if whole_word then
                    pat = "%f[%w]" .. pat .. "%f[%W]"
                end
                modified_text = modified_text:gsub(pat, new)
            end

            if modified_text ~= original_text then
                line.text = modified_text

                local effect = line.effect or ""
                if not effect:match("%[term fix%]") then
                    line.effect = effect .. "[term fix]"
                end

                subs[i] = line
                count = count + 1
            end
        end
    end
    return count
end

local function scan_honorifics(subs)
    local hon_count = 0
    for i, line in ipairs(subs) do
        if line.class == "dialogue" then
            local text = line.text or ""
            local text_lower = text:lower()
            local found = false
            for _, term in ipairs(HONORIFIC_TERMS) do
                if string.find(text_lower, term:lower(), 1, true) then
                    found = true
                    break
                end
            end
            if found then
                local effect = line.effect or ""
                if not effect:match("%[honorific%]") then
                    line.effect = effect .. "[honorific]"
                end
                subs[i] = line
                hon_count = hon_count + 1
            end
        end
    end
    return hon_count
end

local function make_dialog(state)
    local show_label = state.show_name or "(none)"
    local ops = {"->", ">", "=>", "="}
    local dialog = {
        {class = "label", label = show_label, x = 0, y = 0, width = 50, height = 1},
        {class = "textbox", name = "list_text", value = state.list_text or "", x = 0, y = 1, width = 50, height = 20},
        {class = "checkbox", name = "scan_honorifics", label = "Flag honorifics", value = state.scan_honorifics, hint = "Marks lines that still contain honorifics like -san/-chan in the Effect column.", x = 0, y = 21, width = 10, height = 1},
        {class = "checkbox", name = "whole_word", label = "Whole-word match", value = state.whole_word, hint = "Only replace whole words (e.g., don't replace \"fly\" in \"butterfly\", if you have a rule for \"fly = glide\").", x = 11, y = 21, width = 12, height = 1},
        {class = "label", label = "Operator:", x = 24, y = 21, width = 6, height = 1},
        {class = "dropdown", name = "mapping_op", items = ops, value = state.mapping_op or ops[3], x = 30, y = 21, width = 5, height = 1}
    }

    local button, res = aegisub.dialog.display(dialog, {"Run", "Save", "Select Show", "New Show", "Delete Show", "Update Operator", "Help", "Cancel"})
    return button, res
end

local function select_show_dialog(cfg, current)
    local show_names = get_show_names(cfg)
    if #show_names == 0 then
        aegisub.dialog.display({{class="label", label="No shows available.", x=0,y=0,width=1,height=1}})
        return nil
    end
    local dialog = {
        {class = "label", label = "Select show:", x = 0, y = 0, width = 2, height = 1},
        {class = "dropdown", name = "show_name", items = show_names, value = current or show_names[1], x = 0, y = 1, width = 2, height = 1}
    }
    local button, res = aegisub.dialog.display(dialog, {"Select", "Cancel"})
    if button ~= "Select" then
        return nil
    end
    return res.show_name
end

local function new_show_dialog()
    local dialog = {
        {class = "label", label = "New show name:", x = 0, y = 0, width = 4, height = 1},
        {class = "edit", name = "new_show_name", value = "", x = 0, y = 1, width = 4, height = 1}
    }
    local button, res = aegisub.dialog.display(dialog, {"Create", "Cancel"})
    if button ~= "Create" then
        return nil
    end
    return res
end

local function confirm_delete_dialog(show_name)
    local dialog = {
        {class = "label", label = "Delete show '" .. show_name .. "'? This cannot be undone.", x = 0, y = 0, width = 4, height = 1}
    }
    local button = aegisub.dialog.display(dialog, {"Delete", "Cancel"})
    return button == "Delete"
end

local function help_dialog(op)
    local example_line = EXAMPLE_OLD .. " " .. op .. " " .. EXAMPLE_NEW
    local dialog = {
        {class = "label", label = "You can keep different terminology lists per show (e.g., one for \"Death Note\", one for \"Attack on Titan\", etc.).", x = 0, y = 0, width = 4, height = 1},
        {class = "label", label = "Replacements are one per line: old phrase, then \"" .. op .. "\", then new phrase.", x = 0, y = 1, width = 4, height = 1},
        {class = "label", label = "Examples:", x = 0, y = 2, width = 4, height = 1},
        {class = "label", label = example_line, x = 0, y = 3, width = 4, height = 1},
        {class = "label", label = "Yagami Raito " .. op .. " Light Yagami", x = 0, y = 4, width = 4, height = 1},
        {class = "label", label = "Shinigami " .. op .. " Grim Reaper", x = 0, y = 5, width = 4, height = 1}
    }
    aegisub.dialog.display(dialog, {"OK"})
end

local function ensure_show(cfg, name)
    if not name or name == "" then return nil end
    cfg.shows = cfg.shows or {}
    cfg.shows[name] = cfg.shows[name] or {}
    return name
end

function replace_words(subs)
    local cfg = load_config()

    local state = {
        show_name = get_initial_show(cfg),
        last_show = get_initial_show(cfg),
        list_text = "",
        scan_honorifics = cfg.flag_honorifics,
        whole_word = cfg.whole_word,
        mapping_op = cfg.mapping_op,
        last_mapping_op = cfg.mapping_op
    }
    if state.show_name and state.show_name ~= "" then
        state.list_text = serialize_replacements(cfg.shows[state.show_name] or {}, state.mapping_op)
    end

    local button, res
    repeat
        button, res = make_dialog(state)
        if not button or button == "Cancel" then aegisub.cancel() end

        state.list_text = res.list_text or ""
        state.scan_honorifics = res.scan_honorifics
        state.whole_word = res.whole_word
        cfg.flag_honorifics = state.scan_honorifics
        cfg.whole_word = state.whole_word

        if res.mapping_op and res.mapping_op ~= state.mapping_op and button ~= "Update Operator" then
            aegisub.dialog.display({{class="label", label="Operator changed. Click \"Update Operator\" to apply it.", x=0,y=0,width=1,height=1}})
            button = nil
        end

        if button == "Update Operator" then
            local old_op = state.last_mapping_op or state.mapping_op
            local new_op = res.mapping_op or state.mapping_op
            local ok_old, err_old = validate_replacements(state.list_text or "", old_op)
            if ok_old then
                local converted = parse_replacements(state.list_text or "", old_op)
                state.list_text = serialize_replacements(converted, new_op)
                state.mapping_op = new_op
                state.last_mapping_op = new_op
                cfg.mapping_op = new_op
            else
                local ok_new, _ = validate_replacements(state.list_text or "", new_op)
                if ok_new then
                    state.mapping_op = new_op
                    state.last_mapping_op = new_op
                    cfg.mapping_op = new_op
                else
                    local msg = table.concat(err_old, "\n")
                    aegisub.dialog.display({{class="label", label=msg, x=0,y=0,width=1,height=1}})
                end
            end
            button = nil
        end

        if button == "Select Show" then
            local selected = select_show_dialog(cfg, state.show_name)
            if selected and selected ~= "" then
                state.show_name = selected
                state.last_show = selected
                cfg.last_show = selected
                state.list_text = serialize_replacements(cfg.shows[selected] or {}, state.mapping_op)
                save_config(cfg)
            end
            button = nil
        end

        if button == "Help" then
            help_dialog(state.mapping_op)
            button = nil
        end

        if button == "Save" then
            local target = state.show_name
            if not target or target == "" then
                aegisub.dialog.display({{class="label", label="Select a show to save.", x=0,y=0,width=1,height=1}})
            else
                local ok, errors = validate_replacements(state.list_text or "", state.mapping_op)
                if not ok then
                    local msg = table.concat(errors, "\n")
                    aegisub.dialog.display({{class="label", label=msg, x=0,y=0,width=1,height=1}})
                    button = nil
                else
                ensure_show(cfg, target)
                cfg.shows[target] = parse_replacements(state.list_text or "", state.mapping_op)
                cfg.last_show = target
                save_config(cfg)
                state.last_show = target
                end
            end
        end

        if button == "New Show" then
            local add_res = new_show_dialog()
            if add_res and add_res.new_show_name and add_res.new_show_name ~= "" then
                local target = add_res.new_show_name
                ensure_show(cfg, target)
                cfg.shows[target] = parse_replacements(EXAMPLE_OLD .. " " .. state.mapping_op .. " " .. EXAMPLE_NEW, state.mapping_op)
                state.show_name = target
                state.last_show = target
                cfg.last_show = target
                state.list_text = EXAMPLE_OLD .. " " .. state.mapping_op .. " " .. EXAMPLE_NEW
                save_config(cfg)
            else
                aegisub.dialog.display({{class="label", label="Provide a show name to create.", x=0,y=0,width=1,height=1}})
            end
        end

        if button == "Delete Show" then
            if state.show_name and state.show_name ~= "" then
                if confirm_delete_dialog(state.show_name) then
                    cfg.shows[state.show_name] = nil
                    if cfg.last_show == state.show_name then
                        cfg.last_show = nil
                    end
                    local updated = get_show_names(cfg)
                    state.show_name = updated[1]
                    state.last_show = state.show_name
                    cfg.last_show = state.show_name
                    if state.show_name and state.show_name ~= "" then
                        state.list_text = serialize_replacements(cfg.shows[state.show_name] or {}, state.mapping_op)
                    else
                        state.list_text = ""
                    end
                    save_config(cfg)
                end
            end
        end

        if button == "Run" then
            local ok, errors = validate_replacements(state.list_text or "", state.mapping_op)
            if not ok then
                local msg = table.concat(errors, "\n")
                aegisub.dialog.display({{class="label", label=msg, x=0,y=0,width=1,height=1}})
                button = nil
            end
        end

    until button == "Run"

    local show_name = state.show_name
    if (state.list_text or "") == "" and show_name and show_name ~= "" then
        state.list_text = serialize_replacements(cfg.shows[show_name] or {}, state.mapping_op)
    end

    local replacements = parse_replacements(state.list_text or "", state.mapping_op)
    if show_name and show_name ~= "" then
        ensure_show(cfg, show_name)
        cfg.shows[show_name] = replacements
        cfg.last_show = show_name
        save_config(cfg)
    end

    local count = apply_replacements(subs, replacements, state.whole_word)

    local hon_count = 0
    if state.scan_honorifics then
        hon_count = scan_honorifics(subs)
    end

    aegisub.debug.out(string.format("%s: %d lines modified.\n", show_name or "(no show)", count))
    aegisub.debug.out(string.format("%s: %d remaining honorifics.\n", show_name or "(no show)", hon_count))
    aegisub.set_undo_point(script_name)
end

aegisub.register_macro(script_author .. "/" .. script_name, script_description, replace_words)
