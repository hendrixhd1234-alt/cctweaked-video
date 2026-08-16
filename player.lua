local animlib = require("animlib")

local UI_HEADER = colors.yellow
local UI_TEXT = colors.white
local UI_ACCENT = colors.cyan
local UI_BG = colors.black
local UI_ERROR = colors.red
local UI_DIM = colors.gray

local mon = peripheral.find("monitor")
local speaker = peripheral.find("speaker")

local scroll_offset = 0
local anims_list = {}

local function scanForAnimations()
    local found = {}
    local list = fs.list("")
    table.sort(list)
    
    for _, item in ipairs(list) do
        if fs.isDir(item) then
            local subList = fs.list(item)
            for _, subItem in ipairs(subList) do
                if subItem:sub(-7) == ".mcanim" then
                    local rawName = subItem:sub(1, -8)
                    local cleanName = rawName:gsub("^anim_", ""):gsub("^vis_", ""):gsub("_", " ")
                    
                    table.insert(found, {
                        path = fs.combine(item, subItem),
                        name = cleanName,
                        full_name = rawName,
                        display_str = "[Play] " .. cleanName
                    })
                end
            end
        end
    end
    return found
end

local function drawMenu()
    term.setBackgroundColor(UI_BG)
    term.clear()
    
    term.setCursorPos(1,1)
    term.setTextColor(UI_HEADER)
    term.write("=== Animation Player ===")
    
    term.setCursorPos(1,2)
    term.setTextColor(UI_DIM)
    local mon_status = mon and "MONITOR OK" or "NO MONITOR"
    local spk_status = speaker and "SPEAKER OK" or "NO SPEAKER"
    term.write(mon_status .. " | " .. spk_status)

    term.setCursorPos(1,3)
    term.setTextColor(UI_HEADER)
    term.write(string.rep("-", 20))

    local w, h = term.getSize()
    local list_start_y = 4
    local available_lines = h - 4

    if #anims_list == 0 then
        term.setCursorPos(1, 5)
        term.setTextColor(UI_ERROR)
        term.write("No animations found!")
        term.setCursorPos(1, 7)
        term.setTextColor(UI_DIM)
        term.write("Click anywhere to refresh.")
    else
        for i = 1, available_lines do
            local index = i + scroll_offset
            if index <= #anims_list then
                local anim = anims_list[index]
                term.setCursorPos(1, list_start_y + i - 1)
                
                term.setTextColor(UI_ACCENT)
                term.write("[Play] ")
                term.setTextColor(UI_TEXT)
                term.write(anim.name)
            end
        end
    end
    
    term.setCursorPos(1, h)
    term.setTextColor(UI_ERROR)
    term.write("[X] Exit")
    
    if #anims_list > available_lines then
        term.setCursorPos(w, 4)
        term.setTextColor(scroll_offset > 0 and UI_ACCENT or UI_DIM)
        term.write("^")
        term.setCursorPos(w, h-1)
        term.setTextColor((scroll_offset + available_lines < #anims_list) and UI_ACCENT or UI_DIM)
        term.write("v")
    end
end

anims_list = scanForAnimations()
drawMenu()

while true do
    local event, p1, x, y = os.pullEvent()
    local w, h = term.getSize()
    
    if event == "mouse_scroll" then
        local direction = p1
        local available_lines = h - 4
        
        if direction == 1 then
            if scroll_offset + available_lines < #anims_list then
                scroll_offset = scroll_offset + 1
                drawMenu()
            end
        elseif direction == -1 then
            if scroll_offset > 0 then
                scroll_offset = scroll_offset - 1
                drawMenu()
            end
        end

    elseif event == "mouse_click" then
        local button = p1
        
        if y == h and x <= 8 then
            term.setBackgroundColor(colors.black)
            term.clear()
            term.setCursorPos(1,1)
            print("Goodbye!")
            break
        end
        
        local list_y = y - 3
        local clicked_index = list_y + scroll_offset
        
        if y >= 4 and y < h then
            if clicked_index > 0 and clicked_index <= #anims_list then
                local selected = anims_list[clicked_index]
                
                if x <= #selected.display_str then
                    term.setCursorPos(1, y)
                    term.clearLine()
                    term.setTextColor(colors.lime)
                    term.write(">> Loading... ")
                    
                    if mon then 
                        mon.setTextScale(0.5)
                        mon.clear() 
                    end
                    sleep(0.1)

                    local ok, err = pcall(animlib.play, selected.path, mon)
                    
                    if mon then mon.clear() end
                    drawMenu()
                    
                    if not ok then
                        term.setCursorPos(1, y)
                        term.clearLine()
                        term.setTextColor(UI_ERROR)
                        term.write("Error! See output.")
                        print("\n" .. tostring(err))
                        sleep(2)
                        drawMenu()
                    end
                else
                    anims_list = scanForAnimations()
                    drawMenu()
                end
            else
                anims_list = scanForAnimations()
                drawMenu()
            end
        end
    end
end