script_name = "Identify Overlaps"
script_description = "Identify time overlaps in lines with the same dialogue style"
script_version = "1.1"
script_author = "Animorphs"

function check_style(style)
    local allowed_styles = {"^Default", "^Dialogue", "^Subtitle", "^Alt", "^Main"}
    for _, allowed_style in ipairs(allowed_styles) do
        if style:match(allowed_style) then
            return true
        end
    end
    return false
end

function identify_overlaps(subs, sel)
    for i = 1, #subs do
        local current_line = subs[i]
        if current_line.class == "dialogue" and check_style(current_line.style) then
            for j = i + 1, #subs do
                local next_line = subs[j]
                if next_line.class == "dialogue" and next_line.style == current_line.style then -- ensure exclusion of alt styles and such
                    if current_line.start_time < next_line.end_time and next_line.start_time < current_line.end_time then
                        local both_an8 =
                            string.find(current_line.text, "\\an8") and string.find(next_line.text, "\\an8")
                        local neither_an8 =
                            not string.find(current_line.text, "\\an8") and not string.find(next_line.text, "\\an8")

                        if both_an8 or neither_an8 then
                            if not string.find(current_line.effect, "%[Overlap%]") then
                                current_line.effect = "[Overlap] " .. current_line.effect
                            end
                            if not string.find(next_line.effect, "%[Overlap%]") then
                                next_line.effect = "[Overlap] " .. next_line.effect
                            end

                            subs[i] = current_line
                            subs[j] = next_line
                        end
                    end
                end
            end
        end
    end

    aegisub.set_undo_point(script_name)
end

aegisub.register_macro(script_author .. "/" .. script_name, script_description, identify_overlaps)
