local player = {}

local ok_zlib, zlib = pcall(require, "zlib_decompress")
local ok_b64, base64 = pcall(require, "base64")
local ok_dfpwm, dfpwm = pcall(require, "cc.audio.dfpwm")

if not ok_zlib then error("Missing library: zlib_decompress.lua") end
if not ok_b64 then error("Missing library: base64.lua") end
if not ok_dfpwm then error("Missing library: dfpwm") end

function player.play(master_filename, mon)
    local master_file = fs.open(master_filename, "r")
    if not master_file then print("Master animation file not found: " .. master_filename); return end
    local master_content = master_file.readAll()
    master_file.close()
    
    local master_anim = textutils.unserializeJSON(master_content)
    if not master_anim or not master_anim.header or not master_anim.chunks then
        print("Invalid master animation file format."); return
    end

    local animation_dir = fs.getDir(master_filename)
    local header = master_anim.header
    local time_per_frame = 1 / (header.fps or 10)
    local anim_scale = header.scale or 0.5
    local term_colors = {}; for char, name in pairs(header.palette) do term_colors[char] = colors[name] end
    
    mon = mon or term.current()
    local original_scale = mon.getTextScale(); mon.setTextScale(anim_scale)
    
    local mon_width, mon_height = mon.getSize()
    local anim_width = header.width; local anim_height = header.height

    if mon_width < anim_width or mon_height < anim_height then
        print(string.format("Error: Monitor too small! Anim: %dx%d, Mon: %dx%d", anim_width, anim_height, mon_width, mon_height))
        mon.setTextScale(original_scale); return
    end

    local x_offset = math.floor((mon_width - anim_width) / 2)
    local y_offset = math.floor((mon_height - anim_height) / 2)
    mon.setCursorPos(1, 1); mon.clear()

    local isPaused = false
    local isStopped = false
    local audio_file_handle = nil
    local speaker_available = false
    local decoder = nil

    local function init_audio()
        speaker_available = peripheral.find("speaker")
        if speaker_available and master_anim.audio then
            local audio_path = fs.combine(animation_dir, master_anim.audio)
            if fs.exists(audio_path) then
                audio_file_handle = fs.open(audio_path, "rb")
                decoder = dfpwm.make_decoder()
                return true
            end
        end
        return false
    end

    local function cleanup_audio()
        if audio_file_handle then
            audio_file_handle.close()
            audio_file_handle = nil
        end
        if speaker_available then
            speaker_available.stop()
        end
    end

    local function videoThread()
        local empty_text_line = string.rep(" ", header.width)
        local empty_fg_line = string.rep("0", header.width)
        
        local frame_buffer = {}
        for y=1, anim_height do 
            frame_buffer[y] = {}
            for x=1, anim_width do frame_buffer[y][x] = "f" end
        end

        local start_time = os.clock()
        local frames_played = 0

        for _, chunk_filename in ipairs(master_anim.chunks) do

            local full_chunk_path = fs.combine(animation_dir, chunk_filename)
            local chunk_file = fs.open(full_chunk_path, "rb")
            if not chunk_file then break end
            
            local base64_content = chunk_file.readAll()
            chunk_file.close()
            base64_content = base64_content:gsub("%s", "")
            
            local chunk_data
            local ok, result = pcall(function()
                local compressed_data = base64.decode(base64_content)
                local json_string = zlib.decompress(compressed_data)
                return textutils.unserializeJSON(json_string)
            end)
            
            if not ok or not result or not result.frames then break end
            chunk_data = result

            for _, frame in ipairs(chunk_data.frames) do
                if isStopped then break end
                
                while isPaused and not isStopped do
                    sleep(0.1)
                    start_time = os.clock() - (frames_played * time_per_frame)
                end

                if frame.type == "full" then
                    local i = 1
                    for y = 1, header.height do
                        for x = 1, header.width do
                            frame_buffer[y][x] = string.sub(frame.bgs, i, i)
                            i = i + 1
                        end
                    end
                elseif frame.type == "delta" then
                    for _, change in ipairs(frame.changes) do
                        frame_buffer[change.y][change.x] = change.bg
                    end
                elseif frame.type == "bin_delta" then
                    local d = frame.data
                    for k = 1, #d, 3 do
                        local x = string.byte(d, k)
                        local y = string.byte(d, k+1)
                        local col = string.sub(d, k+2, k+2)
                        if frame_buffer[y] then frame_buffer[y][x] = col end
                    end
                end

                for y = 1, header.height do
                    mon.setCursorPos(1 + x_offset, y + y_offset)
                    local bg_line = table.concat(frame_buffer[y])
                    mon.blit(empty_text_line, empty_fg_line, bg_line)
                end
                
                frames_played = frames_played + 1
                local target_time = start_time + (frames_played * time_per_frame)
                local current_time = os.clock()
                local sleep_duration = target_time - current_time

                if sleep_duration > 0 then 
                    sleep(sleep_duration) 
                else
                    os.queueEvent("yield")
                    os.pullEvent("yield")
                end
            end
            
            chunk_data = nil

            pcall(collectgarbage, "collect")
        end
        isStopped = true
        os.queueEvent("terminate_playback")
    end

    local function audioThread()
        if not init_audio() then return end
        decoder = dfpwm.make_decoder()

        local chunk_size = 6 * 1025

        while not isStopped do
            if isPaused then
                if speaker_available then speaker_available.stop() end
                while isPaused and not isStopped do
                    sleep(0.1)
                end
            end

            local chunk = audio_file_handle.read(chunk_size)
            if not chunk then break end
            
            local pcm_data = decoder(chunk)
            
            local play_start_time = os.clock()
            while not speaker_available.playAudio(pcm_data) do
                os.pullEvent("speaker_audio_empty")
                if isStopped then break end
                
                if os.clock() - play_start_time > 0.5 then 
                    os.queueEvent("yield") os.pullEvent("yield") 
                    play_start_time = os.clock()
                end
            end
        end
        cleanup_audio()
    end

    local function inputThread()
        local w, h = term.getSize()
        local status_line_y = h
        
        local function update_status_line()
            term.setCursorPos(1, status_line_y)
            term.clearLine()
            if isStopped then
                term.setTextColor(colors.gray)
                term.write("Playback stopped.")
            elseif isPaused then
                term.setTextColor(colors.orange)
                term.write("PAUSED... [Space] Resume | [Q] Stop")
            else
                term.setTextColor(colors.lime)
                term.write("Playing... [Space] Pause | [Q] Stop")
            end
        end

        update_status_line()

        while not isStopped do
            local event, p1 = os.pullEvent() 
        
            if event == "terminate_playback" then
                break
            
            elseif event == "key" then
                local key = p1
                
                if key == keys.q or key == keys.backspace then
                    isStopped = true
                    isPaused = false
                    os.queueEvent("key")
                elseif key == keys.space then
                    isPaused = not isPaused
                end
                update_status_line()
            end
        end
        
        term.setCursorPos(1, status_line_y)
        term.clearLine()
    end

    parallel.waitForAll(videoThread, audioThread, inputThread)

    mon.setTextScale(original_scale)
    mon.setBackgroundColor(colors.black)
    mon.clear()
    cleanup_audio()
end

return player