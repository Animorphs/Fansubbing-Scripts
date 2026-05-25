script_name = "Terminology Fixer"
script_description = "Fix names and other terminology"
script_version = "1.1"
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
    local loader = loadstring or load
    local chunk, err = loader(data)
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
        mapping_op = "->",
        whole_word = true,
        case_sensitive = false,
        include_comments = false,
        flag_honorifics = false
    }
end

local function get_config_path()
    local base, psep = get_user_path()
    return base .. psep .. "term-fixer-shows.config"
end

local function trim(s)
    return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function parse_style_filter(text)
    local styles = {}
    local seen = {}
    local normalized = (text or ""):gsub("[\r\n;]+", ",")
    for part in normalized:gmatch("[^,]+") do
        local style = trim(part)
        local key = style:lower()
        if style ~= "" and not seen[key] then
            seen[key] = true
            styles[#styles + 1] = style
        end
    end
    table.sort(styles, function(a, b)
        return a:lower() < b:lower()
    end)
    return styles
end

local function serialize_style_filter(styles)
    return table.concat(styles or {}, ", ")
end

local function is_flat_replacement_table(t)
    if type(t) ~= "table" then
        return false
    end
    for k, v in pairs(t) do
        if type(k) ~= "string" or type(v) ~= "string" then
            return false
        end
    end
    return true
end

local function copy_replacements_sorted(replacements)
    local copied = {}
    for _, key in ipairs(sorted_keys(replacements or {})) do
        copied[key] = replacements[key]
    end
    return copied
end

local function default_show_data()
    return {
        sections = {
            {name = nil, replacements = {}}
        },
        styles = {}
    }
end

local function normalize_show_data(raw)
    local normalized = default_show_data()
    if type(raw) ~= "table" then
        return normalized
    end

    if is_flat_replacement_table(raw) and raw.sections == nil and raw.styles == nil then
        normalized.sections[1].replacements = copy_replacements_sorted(raw)
        return normalized
    end

    normalized.sections = {}
    if type(raw.sections) == "table" then
        for i = 1, #raw.sections do
            local section = raw.sections[i]
            if type(section) == "table" then
                local name = trim(section.name)
                if name == "" then
                    name = nil
                end
                normalized.sections[#normalized.sections + 1] = {
                    name = name,
                    replacements = copy_replacements_sorted(section.replacements or {})
                }
            end
        end
    end

    if #normalized.sections == 0 and is_flat_replacement_table(raw.replacements or false) then
        normalized.sections[1] = {
            name = nil,
            replacements = copy_replacements_sorted(raw.replacements)
        }
    end

    if #normalized.sections == 0 then
        normalized.sections[1] = {name = nil, replacements = {}}
    end

    if type(raw.styles) == "table" then
        normalized.styles = parse_style_filter(table.concat(raw.styles, ","))
    elseif type(raw.style_filter) == "string" then
        normalized.styles = parse_style_filter(raw.style_filter)
    end

    return normalized
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
    if cfg.case_sensitive == nil then cfg.case_sensitive = def.case_sensitive end
    if cfg.include_comments == nil then cfg.include_comments = def.include_comments end

    for show_name, show_data in pairs(cfg.shows) do
        cfg.shows[show_name] = normalize_show_data(show_data)
    end

    return cfg
end

local function save_config(cfg)
    local path = get_config_path()
    local normalized = {
        shows = {},
        last_show = cfg.last_show,
        flag_honorifics = cfg.flag_honorifics,
        whole_word = cfg.whole_word,
        mapping_op = cfg.mapping_op,
        case_sensitive = cfg.case_sensitive,
        include_comments = cfg.include_comments
    }
    for _, show in ipairs(sorted_keys(cfg.shows or {})) do
        local show_data = normalize_show_data(cfg.shows[show])
        local saved_sections = {}
        for i = 1, #show_data.sections do
            saved_sections[i] = {
                name = show_data.sections[i].name,
                replacements = copy_replacements_sorted(show_data.sections[i].replacements)
            }
        end
        normalized.shows[show] = {
            sections = saved_sections,
            styles = parse_style_filter(serialize_style_filter(show_data.styles))
        }
    end
    table_to_file(path, normalized)
end

local HONORIFIC_TERMS = {
    "-kun", "-chan", "-san", "-sama", "-dono",
    "-nee", "onee", "neesama", "neechan", "neesan",
    "-nii", "onii", "niisama", "niichan", "niisan",
    "sensei", "senpai"
}

local function build_example_section_template(op)
    op = op or "->"
    return table.concat({
        "### Character names",
        "Yagami Raito " .. op .. " Light Yagami",
        "Amane Misa " .. op .. " Misa Amane",
        "",
        "### Term swaps",
        "Shinigami " .. op .. " Grim Reaper",
        "SPK " .. op .. " Special Provision for Kira"
    }, "\n")
end

local function escape_lua_pattern(s)
    return (s:gsub("([%%%^%$%(%)%.%[%]%*%+%-%?])", "%%%1"))
end

local function serialize_show_data(show_data, op)
    show_data = normalize_show_data(show_data)
    local blocks = {}
    for i = 1, #show_data.sections do
        local section = show_data.sections[i]
        local lines = {}
        if section.name and section.name ~= "" then
            lines[#lines + 1] = "### " .. section.name
        end
        for _, old in ipairs(sorted_keys(section.replacements)) do
            lines[#lines + 1] = old .. " " .. op .. " " .. section.replacements[old]
        end
        if #lines > 0 then
            blocks[#blocks + 1] = table.concat(lines, "\n")
        end
    end
    return table.concat(blocks, "\n\n")
end

local function parse_show_data(text, style_filter_text, op)
    local sections = {}
    local current = nil
    local op_pat = escape_lua_pattern(op)
    local normalized_text = (text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")

    local function ensure_current_section()
        if not current then
            current = {name = nil, replacements = {}}
            sections[#sections + 1] = current
        end
        return current
    end

    for line in (normalized_text .. "\n"):gmatch("(.-)\n") do
        local trimmed = trim(line)
        if trimmed ~= "" then
            local header = trimmed:match("^###%s*(.-)%s*$")
            if header ~= nil then
                current = {name = trim(header), replacements = {}}
                if current.name == "" then
                    current.name = nil
                end
                sections[#sections + 1] = current
            else
                local old, new = trimmed:match("^(.-)%s*" .. op_pat .. "%s*(.-)%s*$")
                if old and new and old ~= "" then
                    ensure_current_section().replacements[old] = new
                end
            end
        end
    end

    if #sections == 0 then
        sections[1] = {name = nil, replacements = {}}
    end

    return {
        sections = sections,
        styles = parse_style_filter(style_filter_text or "")
    }
end

local function validate_replacements(text, op)
    local errors = {}
    local line_no = 0
    local op_pat = escape_lua_pattern(op)
    local normalized_text = (text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")

    for line in (normalized_text .. "\n"):gmatch("(.-)\n") do
        line_no = line_no + 1
        local trimmed = trim(line)
        if trimmed ~= "" then
            local header = trimmed:match("^###%s*(.-)%s*$")
            if header ~= nil then
                if trim(header) == "" then
                    errors[#errors + 1] = "Line " .. line_no .. ": Section headers must have a name.\n\tCurrent line: " .. trimmed .. "\n"
                end
            else
                local old, new = trimmed:match("^(.-)%s*" .. op_pat .. "%s*(.-)%s*$")
                if not old or not new or old == "" or new == "" then
                    errors[#errors + 1] = "Line " .. line_no .. ": Incorrect syntax. Each line must be \"term1 " .. op .. " term2\".\n\tCurrent line: " .. trimmed .. "\n"
                elseif old == new then
                    errors[#errors + 1] = "Line " .. line_no .. ": Identical terms defined.\n\tCurrent line: " .. trimmed .. "\n"
                end
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
    table.sort(names, function(a, b)
        return a:lower() < b:lower()
    end)
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

local function collect_styles(subs)
    local styles = {}
    local seen = {}
    for _, line in ipairs(subs) do
        if line.class == "dialogue" then
            local style = trim(line.style)
            local key = style:lower()
            if style ~= "" and not seen[key] then
                seen[key] = true
                styles[#styles + 1] = style
            end
        end
    end
    table.sort(styles, function(a, b)
        return a:lower() < b:lower()
    end)
    return styles
end

local function style_matches_filters(style_name, style_filters)
    if not style_filters or #style_filters == 0 then
        return true
    end

    local style_lower = (style_name or ""):lower()
    for _, filter_text in ipairs(style_filters) do
        local filter_lower = filter_text:lower()
        if filter_lower ~= "" and style_lower:find(filter_lower, 1, true) then
            return true
        end
    end

    return false
end

local function is_word_char(ch)
    return ch ~= "" and ch:match("[%w]") ~= nil
end

local function is_special_boundary_left(text, start_idx)
    if start_idx <= 2 then
        return false
    end
    local seq = text:sub(start_idx - 2, start_idx - 1)
    return seq == "\\N" or seq == "\\n" or seq == "\\h"
end

local function is_special_boundary_right(text, end_idx)
    if end_idx + 2 > #text then
        return false
    end
    local seq = text:sub(end_idx + 1, end_idx + 2)
    return seq == "\\N" or seq == "\\n" or seq == "\\h"
end

local function has_word_boundaries(text, start_idx, end_idx, term)
    local first = term:sub(1, 1)
    local last = term:sub(-1)

    if is_word_char(first) then
        if start_idx > 1 and not is_special_boundary_left(text, start_idx) then
            local prev = text:sub(start_idx - 1, start_idx - 1)
            if is_word_char(prev) then
                return false
            end
        end
    end

    if is_word_char(last) then
        if end_idx < #text and not is_special_boundary_right(text, end_idx) then
            local next_char = text:sub(end_idx + 1, end_idx + 1)
            if is_word_char(next_char) then
                return false
            end
        end
    end

    return true
end

local function boundary_matches(text, start_idx, end_idx, term, whole_word)
    if not whole_word then
        return true
    end
    return has_word_boundaries(text, start_idx, end_idx, term)
end

local function build_rules(show_data, case_sensitive)
    show_data = normalize_show_data(show_data)
    local rules = {}
    local index = 0
    for _, section in ipairs(show_data.sections) do
        for _, old in ipairs(sorted_keys(section.replacements)) do
            index = index + 1
            local new = section.replacements[old]
            rules[#rules + 1] = {
                old = old,
                new = new,
                old_cmp = case_sensitive and old or old:lower(),
                index = index
            }
        end
    end

    table.sort(rules, function(a, b)
        if #a.old ~= #b.old then
            return #a.old > #b.old
        end
        local a_lower = a.old:lower()
        local b_lower = b.old:lower()
        if a_lower ~= b_lower then
            return a_lower < b_lower
        end
        return a.index < b.index
    end)

    return rules
end

local function find_next_rule_match(text, rules, case_sensitive, whole_word, start_pos)
    local cmp_text = case_sensitive and text or text:lower()
    local best_match = nil

    for _, rule in ipairs(rules) do
        local find_pos = start_pos
        while true do
            local s, e = cmp_text:find(rule.old_cmp, find_pos, true)
            if not s then
                break
            end
            if boundary_matches(text, s, e, rule.old, whole_word) then
                if not best_match
                    or s < best_match.start_idx
                    or (s == best_match.start_idx and #rule.old > #best_match.rule.old)
                    or (s == best_match.start_idx and #rule.old == #best_match.rule.old and rule.index < best_match.rule.index) then
                    best_match = {start_idx = s, end_idx = e, rule = rule}
                end
                break
            end
            find_pos = s + 1
        end
    end

    return best_match
end

local function replace_literal_term(text, term, replacement, case_sensitive, whole_word)
    local out = {}
    local pos = 1
    local cmp_text = case_sensitive and text or text:lower()
    local cmp_term = case_sensitive and term or term:lower()

    while pos <= #text do
        local s, e = cmp_text:find(cmp_term, pos, true)
        if not s then
            out[#out + 1] = text:sub(pos)
            break
        end

        if boundary_matches(text, s, e, term, whole_word) then
            out[#out + 1] = text:sub(pos, s - 1)
            out[#out + 1] = replacement
            pos = e + 1
        else
            out[#out + 1] = text:sub(pos, s)
            pos = s + 1
        end
    end

    return table.concat(out)
end

local function text_has_match(text, rules, case_sensitive, whole_word)
    return find_next_rule_match(text, rules, case_sensitive, whole_word, 1) ~= nil
end

local function protect_existing_replacements(text, rules, case_sensitive, whole_word)
    local protected = {}
    local protected_text = text

    for _, rule in ipairs(rules) do
        if text_has_match(rule.new, rules, case_sensitive, whole_word) then
            local token = string.char(30) .. "TERM_FIXER_" .. tostring(#protected + 1) .. string.char(31)
            local updated = replace_literal_term(protected_text, rule.new, token, true, whole_word)
            if updated ~= protected_text then
                protected[#protected + 1] = {
                    token = token,
                    value = rule.new
                }
                protected_text = updated
            end
        end
    end

    return protected_text, protected
end

local function restore_protected_replacements(text, protected)
    local restored = text
    for _, item in ipairs(protected) do
        restored = restored:gsub(escape_lua_pattern(item.token), item.value)
    end
    return restored
end

local function apply_rules_to_text(text, rules, case_sensitive, whole_word)
    if #rules == 0 or text == "" then
        return text, false
    end

    local protected_text, protected = protect_existing_replacements(text, rules, case_sensitive, whole_word)
    local out = {}
    local pos = 1
    local changed = false

    while pos <= #protected_text do
        local match = find_next_rule_match(protected_text, rules, case_sensitive, whole_word, pos)
        if not match then
            out[#out + 1] = protected_text:sub(pos)
            break
        end
        out[#out + 1] = protected_text:sub(pos, match.start_idx - 1)
        out[#out + 1] = match.rule.new
        changed = true
        pos = match.end_idx + 1
    end

    local restored = restore_protected_replacements(table.concat(out), protected)
    return restored, changed
end

local function apply_replacements(subs, show_data, whole_word, case_sensitive, include_comments)
    local count = 0
    local style_filters = show_data.styles or {}
    local rules = build_rules(show_data, case_sensitive)

    for i, line in ipairs(subs) do
        if line.class == "dialogue" then
            local is_comment = line.comment == true
            if (include_comments or not is_comment) and style_matches_filters(line.style, style_filters) then
                local original_text = line.text or ""
                local modified_text, changed = apply_rules_to_text(original_text, rules, case_sensitive, whole_word)

                if changed and modified_text ~= original_text then
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
    end

    return count
end

local function scan_honorifics(subs, show_data, include_comments)
    local hon_count = 0
    local style_filters = show_data.styles or {}
    for i, line in ipairs(subs) do
        if line.class == "dialogue" then
            local is_comment = line.comment == true
            if (include_comments or not is_comment) and style_matches_filters(line.style, style_filters) then
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
    end
    return hon_count
end

local function make_dialog(state)
    local show_label = state.show_name or "(none)"
    local styles_hint = "Blank means all styles. Use comma-separated partial style names, for example: Default, signs - animorphs."
    if state.available_styles and #state.available_styles > 0 then
        styles_hint = styles_hint .. " Available: " .. table.concat(state.available_styles, ", ")
    end

    local dialog = {
        {class = "label", label = show_label, x = 0, y = 0, width = 50, height = 1},
        {class = "textbox", name = "list_text", value = state.list_text or "", x = 0, y = 1, width = 50, height = 27},
        {class = "checkbox", name = "whole_word", label = "Whole-word match", value = state.whole_word, hint = "When on, only whole words are replaced. \\N, \\n, and \\h count as word boundaries.", x = 0, y = 28, width = 12, height = 1},
        {class = "checkbox", name = "case_sensitive", label = "Case-sensitive", value = state.case_sensitive, hint = "When on, matches must use the same capitalization.", x = 13, y = 28, width = 12, height = 1},
        {class = "checkbox", name = "include_comments", label = "Include comments", value = state.include_comments, hint = "When on, commented lines are also processed.", x = 25, y = 28, width = 12, height = 1},
        {class = "checkbox", name = "scan_honorifics", label = "Flag honorifics", value = state.scan_honorifics, hint = "When on, lines containing honorifics (processed after the swaps occur) like -san or -chan are marked in Effect.", x = 37, y = 28, width = 12, height = 1},
        {class = "label", label = "Styles:", x = 0, y = 29, width = 5, height = 1},
        {class = "edit", name = "style_filter_text", value = state.style_filter_text or "", hint = styles_hint, x = 5, y = 29, width = 45, height = 1}
    }

    local button, res = aegisub.dialog.display(dialog, {"Run", "Save", "Select Show", "New Show", "Delete Show", "Operator", "Help", "Cancel"})
    return button, res
end

local function select_show_dialog(cfg, current)
    local show_names = get_show_names(cfg)
    if #show_names == 0 then
        aegisub.dialog.display({{class = "label", label = "No shows available.", x = 0, y = 0, width = 1, height = 1}})
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

local ensure_show

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

local function ensure_show_name_for_action(cfg, state)
    if state.show_name and state.show_name ~= "" then
        return state.show_name
    end

    local add_res = new_show_dialog()
    if not add_res or not add_res.new_show_name or trim(add_res.new_show_name) == "" then
        return nil
    end

    local target = trim(add_res.new_show_name)
    ensure_show(cfg, target)
    state.show_name = target
    state.last_show = target
    cfg.last_show = target
    return target
end

local function confirm_delete_dialog(show_name)
    local dialog = {
        {class = "label", label = "Delete show '" .. show_name .. "'? This cannot be undone.", x = 0, y = 0, width = 4, height = 1}
    }
    local button = aegisub.dialog.display(dialog, {"Delete", "Cancel"})
    return button == "Delete"
end

local function operator_dialog(current_op)
    local ops = {"->", ">", "=>", "="}
    local dialog = {
        {class = "label", label = "Choose operator:", x = 0, y = 0, width = 2, height = 1},
        {class = "dropdown", name = "mapping_op", items = ops, value = current_op or ops[1], x = 0, y = 1, width = 2, height = 1}
    }
    local button, res = aegisub.dialog.display(dialog, {"Confirm", "Cancel"})
    if button ~= "Confirm" then
        return nil
    end
    return res.mapping_op
end

local function help_dialog(op)
    local dialog = {
        {class = "label", label = "Replacements are one per line: old phrase, then \"" .. op .. "\", then new phrase.", x = 0, y = 0, width = 10, height = 1},
        {class = "label", label = "You can keep different terminology lists per show and optionally split them into sections with lines like \"### Honorifics swap\".", x = 0, y = 1, width = 10, height = 1},
        {class = "label", label = "Sections stay in the order you write them, and entries sort alphabetically inside each section.", x = 0, y = 2, width = 10, height = 1},
        {class = "label", label = "Styles are optional and comma-separated. Blank means all styles. Each value is an includes match against the style name, for example: Default, Overlap.", x = 0, y = 3, width = 10, height = 1},
        {class = "label", label = "\"Include comments\" decides whether commented lines are processed too.", x = 0, y = 4, width = 10, height = 1},
        {class = "label", label = "", x = 0, y = 5, width = 10, height = 1},
        {class = "label", label = "Examples:", x = 0, y = 6, width = 10, height = 1},
        {class = "label", label = "### Character Names", x = 0, y = 7, width = 10, height = 1},
        {class = "label", label = "Yagami Raito " .. op .. " Light Yagami", x = 0, y = 8, width = 10, height = 1},
        {class = "label", label = "Amane Misa " .. op .. " Misa Amane", x = 0, y = 9, width = 10, height = 1},
        {class = "label", label = "### Term swaps", x = 0, y = 10, width = 10, height = 1},
        {class = "label", label = "Shinigami " .. op .. " Grim Reaper", x = 0, y = 11, width = 10, height = 1},
        {class = "label", label = "SPK " .. op .. " Special Provision for Kira", x = 0, y = 12, width = 10, height = 1}
    }
    aegisub.dialog.display(dialog, {"OK"})
end

ensure_show = function(cfg, name)
    if not name or name == "" then return nil end
    cfg.shows = cfg.shows or {}
    cfg.shows[name] = normalize_show_data(cfg.shows[name])
    return name
end

local function get_show_data(cfg, show_name)
    if not show_name or show_name == "" then
        return default_show_data()
    end
    ensure_show(cfg, show_name)
    return normalize_show_data(cfg.shows[show_name])
end

function replace_words(subs, sel)
    local cfg = load_config()
    local initial_show = get_initial_show(cfg)
    local initial_show_data = get_show_data(cfg, initial_show)

    local state = {
        show_name = initial_show,
        last_show = initial_show,
        list_text = serialize_show_data(initial_show_data, cfg.mapping_op),
        style_filter_text = serialize_style_filter(initial_show_data.styles),
        scan_honorifics = cfg.flag_honorifics,
        whole_word = cfg.whole_word,
        case_sensitive = cfg.case_sensitive,
        include_comments = cfg.include_comments,
        mapping_op = cfg.mapping_op,
        last_mapping_op = cfg.mapping_op,
        available_styles = collect_styles(subs)
    }

    local button, res
    repeat
        button, res = make_dialog(state)
        if not button or button == "Cancel" then aegisub.cancel() end

        state.list_text = res.list_text or ""
        state.style_filter_text = res.style_filter_text or ""
        state.scan_honorifics = res.scan_honorifics
        state.whole_word = res.whole_word
        state.case_sensitive = res.case_sensitive
        state.include_comments = res.include_comments
        cfg.flag_honorifics = state.scan_honorifics
        cfg.whole_word = state.whole_word
        cfg.case_sensitive = state.case_sensitive
        cfg.include_comments = state.include_comments

        if button == "Operator" then
            local old_op = state.last_mapping_op or state.mapping_op
            local new_op = operator_dialog(old_op)
            if new_op and new_op ~= old_op then
                local ok_old, err_old = validate_replacements(state.list_text or "", old_op)
                if ok_old then
                    local converted = parse_show_data(state.list_text or "", state.style_filter_text or "", old_op)
                    state.list_text = serialize_show_data(converted, new_op)
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
                        aegisub.dialog.display({{class = "label", label = msg, x = 0, y = 0, width = 1, height = 1}})
                    end
                end
            end
            button = nil
        end

        if button == "Select Show" then
            local selected = select_show_dialog(cfg, state.show_name)
            if selected and selected ~= "" then
                local selected_show_data = get_show_data(cfg, selected)
                state.show_name = selected
                state.last_show = selected
                cfg.last_show = selected
                state.list_text = serialize_show_data(selected_show_data, state.mapping_op)
                state.style_filter_text = serialize_style_filter(selected_show_data.styles)
                save_config(cfg)
            end
            button = nil
        end

        if button == "Help" then
            help_dialog(state.mapping_op)
            button = nil
        end

        if button == "Save" then
            local ok, errors = validate_replacements(state.list_text or "", state.mapping_op)
            if not ok then
                local msg = table.concat(errors, "\n")
                aegisub.dialog.display({{class = "label", label = msg, x = 0, y = 0, width = 1, height = 1}})
                button = nil
            else
                local target = ensure_show_name_for_action(cfg, state)
                if not target then
                    button = nil
                else
                    ensure_show(cfg, target)
                    cfg.shows[target] = parse_show_data(state.list_text or "", state.style_filter_text or "", state.mapping_op)
                    cfg.last_show = target
                    save_config(cfg)
                    state.last_show = target
                    state.list_text = serialize_show_data(cfg.shows[target], state.mapping_op)
                    state.style_filter_text = serialize_style_filter(cfg.shows[target].styles)
                end
            end
        end

        if button == "New Show" then
            local add_res = new_show_dialog()
            if add_res and add_res.new_show_name and add_res.new_show_name ~= "" then
                local target = trim(add_res.new_show_name)
                ensure_show(cfg, target)
                local seed_text
                if (not state.show_name or state.show_name == "") and trim(state.list_text or "") ~= "" then
                    seed_text = state.list_text or ""
                else
                    seed_text = build_example_section_template(state.mapping_op)
                end
                cfg.shows[target] = parse_show_data(seed_text, "", state.mapping_op)
                state.show_name = target
                state.last_show = target
                cfg.last_show = target
                state.list_text = serialize_show_data(cfg.shows[target], state.mapping_op)
                state.style_filter_text = ""
                save_config(cfg)
            elseif add_res then
                aegisub.dialog.display({{class = "label", label = "Provide a show name to create.", x = 0, y = 0, width = 1, height = 1}})
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
                        local updated_show_data = get_show_data(cfg, state.show_name)
                        state.list_text = serialize_show_data(updated_show_data, state.mapping_op)
                        state.style_filter_text = serialize_style_filter(updated_show_data.styles)
                    else
                        state.list_text = ""
                        state.style_filter_text = ""
                    end
                    save_config(cfg)
                end
            end
        end

        if button == "Run" then
            local ok, errors = validate_replacements(state.list_text or "", state.mapping_op)
            if not ok then
                local msg = table.concat(errors, "\n")
                aegisub.dialog.display({{class = "label", label = msg, x = 0, y = 0, width = 1, height = 1}})
                button = nil
            else
                local target = ensure_show_name_for_action(cfg, state)
                if not target then
                    button = nil
                end
            end
        end
    until button == "Run"

    local show_name = state.show_name
    if (state.list_text or "") == "" and show_name and show_name ~= "" then
        state.list_text = serialize_show_data(get_show_data(cfg, show_name), state.mapping_op)
    end

    local show_data = parse_show_data(state.list_text or "", state.style_filter_text or "", state.mapping_op)
    if show_name and show_name ~= "" then
        ensure_show(cfg, show_name)
        cfg.shows[show_name] = show_data
        cfg.last_show = show_name
        save_config(cfg)
    end

    local count = apply_replacements(subs, show_data, state.whole_word, state.case_sensitive, state.include_comments)

    local hon_count = 0
    if state.scan_honorifics then
        hon_count = scan_honorifics(subs, show_data, state.include_comments)
    end

    aegisub.debug.out(string.format("%s: %d lines modified.\n", show_name or "(no show)", count))
    if state.scan_honorifics then
        aegisub.debug.out(string.format("%s: %d remaining honorifics.\n", show_name or "(no show)", hon_count))
    end
    aegisub.set_undo_point(script_name)
end

aegisub.register_macro(script_author .. "/" .. script_name, script_description, replace_words)
